import Foundation

/// Process-wide run id so `cancel()` never waits on the pipeline actor.
/// (Waiting used to freeze the UI on “Initializing…” while a prior large scan held the actor.)
final class ScanRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    
    /// Invalidate any in-flight run. Safe from any thread.
    @discardableResult
    func bump() -> UInt64 {
        lock.lock()
        generation &+= 1
        let g = generation
        lock.unlock()
        return g
    }
    
    func isActive(_ g: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation
    }
}

/// Off-main-actor duplicate detection pipeline (P0–P2).
actor ScanPipeline {
    
    /// Shared cancel/generation — `cancel()` is nonisolated and never blocks on this actor.
    nonisolated let runs = ScanRunControl()
    
    /// Synchronous cancel — does not hop onto the actor (critical for responsive stop/restart).
    nonisolated func cancel() {
        runs.bump()
    }
    
    func findDuplicates(
        files: [FileInfo],
        scanRoots: [URL],
        mode: ScanMode,
        progress: @Sendable (ScanProgressUpdate) async -> Void
    ) async -> (groups: [DuplicateGroup], stats: ScanStatisticsSnapshot, timing: ScanTimingBreakdown) {
        let myGen = runs.bump()
        let started = Date()
        var stats = ScanStatisticsSnapshot()
        var timing = ScanTimingBreakdown()
        let finalHashMode = ContentHasher.finalMode(for: mode)
        
        func cancelled() -> Bool { !runs.isActive(myGen) }
        
        let prepareStart = Date()
        let unique = pathDedupe(files)
        stats.totalFiles = unique.count
        stats.totalSize = unique.reduce(0) { $0 + $1.size }
        
        guard !cancelled() else {
            timing.total = Date().timeIntervalSince(started)
            return ([], stats, timing)
        }
        
        await progress(.init(
            phase: "scan.phase.processing",
            message: "scan.prepare.signature",
            phaseDetail: "\(unique.count)",
            percent: 0.46,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        // Snapshot short-circuit (mode-aware)
        let rootKeys = ScanResultSnapshot.rootKeys(from: scanRoots)
        guard let signature = await listSignatureCancellable(unique, isCancelled: cancelled) else {
            timing.prepare = Date().timeIntervalSince(prepareStart)
            timing.total = Date().timeIntervalSince(started)
            return ([], stats, timing)
        }
        
        guard !cancelled() else {
            timing.prepare = Date().timeIntervalSince(prepareStart)
            timing.total = Date().timeIntervalSince(started)
            return ([], stats, timing)
        }
        
        await progress(.init(
            phase: "scan.phase.processing",
            message: "scan.prepare.snapshot",
            phaseDetail: "\(unique.count)",
            percent: 0.48,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        if let snap = ScanSnapshotStore.load(),
           snap.matches(roots: rootKeys, signature: signature, mode: mode),
           let reused = snap.materialize(using: unique) {
            let sizeCounts = Dictionary(grouping: unique, by: \.size).mapValues(\.count)
            let flagged = reused.map { g -> DuplicateGroup in
                let identityMismatch = PackageIdentity.hasIdentityMismatch(packages: g.files)
                if identityMismatch {
                    return DuplicateGroup(
                        files: g.files,
                        fileSize: g.fileSize,
                        hash: g.hash,
                        needsReview: true,
                        isVerified: false,
                        packageIdentityMismatch: true,
                        id: g.id
                    )
                }
                let review = DuplicateReviewPolicy.needsReview(
                    fileSize: g.fileSize,
                    sameSizeCandidateCount: sizeCounts[g.fileSize] ?? g.files.count,
                    memberCount: g.files.count
                )
                return DuplicateGroup(
                    files: g.files,
                    fileSize: g.fileSize,
                    hash: g.hash,
                    needsReview: review,
                    isVerified: false,
                    packageIdentityMismatch: false,
                    id: g.id
                )
            }
            timing.prepare = Date().timeIntervalSince(prepareStart)
            timing.path = .snapshotHit
            timing.hashing = 0
            timing.finalize = 0
            timing.total = Date().timeIntervalSince(started)
            stats.cachedFiles = unique.count
            stats.newFiles = 0
            stats.processedFiles = unique.count
            await progress(.init(
                phase: "scan.phase.finalizing",
                message: "scan.cache.hit",
                phaseDetail: "scan.cache.hit.detail",
                percent: 1.0,
                estimatedRemaining: 0,
                stats: stats
            ))
            return (flagged, stats, timing)
        }
        
        let bySize = Dictionary(grouping: unique, by: \.size)
        let multiSize = bySize.filter { $0.value.count > 1 }
        let singletonCount = unique.count - multiSize.values.reduce(0) { $0 + $1.count }
        let candidates = multiSize.values.flatMap { $0 }
        let totalCandidates = max(candidates.count, 1)
        stats.processedFiles = singletonCount
        
        await progress(.init(
            phase: "scan.phase.processing",
            message: "scan.prepare.cache",
            phaseDetail: "\(candidates.count) candidates · \(singletonCount) unique-by-size",
            percent: 0.50,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        // Keys normalized once on disk load; subsequent scans use in-memory hot cache.
        var cache = ScanCacheManager.shared.loadCache()
        
        await progress(.init(
            phase: "scan.phase.processing",
            message: "scan.prepare.match",
            phaseDetail: "\(candidates.count) candidates · \(cache.cachedFiles.count) cached",
            percent: 0.51,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        timing.prepare = Date().timeIntervalSince(prepareStart)
        
        let hashStart = Date()
        var finalGroups: [String: [FileInfo]] = [:]
        let networkScan = StorageConcurrency.isNetworkScan(roots: scanRoots, sample: candidates)
        let concurrency = StorageConcurrency.level(for: scanRoots, candidateSample: candidates)
        var doneCandidates = 0
        var lastProgressAt = Date.distantPast
        var cacheDirty = false
        
        // Partition cache hits vs misses across all size buckets first
        var needHashAll: [FileInfo] = []
        needHashAll.reserveCapacity(candidates.count)
        let cacheMap = cache.cachedFiles
        for bucket in multiSize.values {
            for file in bucket {
                let key = file.pathKey
                if let cached = cacheMap[key],
                   ContentHasher.isFinalHash(cached.hash, for: mode),
                   !cached.hasChanged(comparedTo: file) {
                    finalGroups[cached.hash, default: []].append(file)
                    stats.cachedFiles += 1
                    doneCandidates += 1
                } else {
                    needHashAll.append(file)
                    stats.newFiles += 1
                }
            }
        }
        
        // NAS: global path order + single-pass turboFinal (skip partial) — open latency dominates
        // Local: keep size-bucket order (larger first) then path sort within worklists
        if networkScan {
            needHashAll.sort { $0.pathKey < $1.pathKey }
        } else {
            // Larger size groups first (more likely dups), path-stable within size
            needHashAll.sort { a, b in
                if a.size != b.size { return a.size > b.size }
                return a.pathKey < b.pathKey
            }
        }
        
        if !needHashAll.isEmpty {
            cacheDirty = true
            var hashedCount = 0
            let cacheHitBase = stats.cachedFiles
            
            func reportHashProgress(force: Bool = false) async {
                let now = Date()
                guard force || now.timeIntervalSince(lastProgressAt) >= 0.15 else { return }
                lastProgressAt = now
                doneCandidates = min(cacheHitBase + hashedCount, candidates.count)
                stats.processedFiles = singletonCount + doneCandidates
                let frac = Double(doneCandidates) / Double(totalCandidates)
                let msg = networkScan ? "scan.hashing.network" : "scan.hashing"
                let detail = networkScan
                    ? "\(doneCandidates)/\(candidates.count) · NAS sequential · conc \(concurrency)"
                    : "\(doneCandidates)/\(candidates.count) · hits \(stats.cachedFiles) · new \(stats.newFiles)"
                await progress(.init(
                    phase: "scan.phase.processing",
                    message: msg,
                    phaseDetail: detail,
                    percent: 0.52 + 0.40 * min(1, frac),
                    estimatedRemaining: estimateRemaining(started: started, fraction: max(frac, 0.01)),
                    stats: stats
                ))
            }
            
            if networkScan {
                // NAS: single-pass turboFinal only (no partial second open), path-ordered chunks
                let chunkSize = max(concurrency * 4, 8)
                var i = 0
                while i < needHashAll.count {
                    if cancelled() { break }
                    let end = min(i + chunkSize, needHashAll.count)
                    let slice = Array(needHashAll[i..<end])
                    i = end
                    let results = await hashFiles(slice, mode: finalHashMode, concurrency: concurrency, isCancelled: cancelled)
                    for (file, hash) in results {
                        guard let hash, ContentHasher.isFinalHash(hash, for: mode) else {
                            stats.errorFiles += 1
                            continue
                        }
                        finalGroups[hash, default: []].append(file)
                        cache.cachedFiles[file.pathKey] = CachedFileInfo(
                            url: file.url,
                            size: file.size,
                            modificationDate: file.modificationDate,
                            hash: hash
                        )
                        hashedCount += 1
                    }
                    await reportHashProgress()
                }
            } else {
                let small = needHashAll.filter { $0.size <= ContentHasher.smallFileThreshold }
                let large = needHashAll.filter { $0.size > ContentHasher.smallFileThreshold }
                
                if !small.isEmpty {
                    let chunkSize = max(concurrency * 4, 16)
                    var i = 0
                    while i < small.count {
                        if cancelled() { break }
                        let end = min(i + chunkSize, small.count)
                        let slice = Array(small[i..<end])
                        i = end
                        let results = await hashFiles(slice, mode: finalHashMode, concurrency: concurrency, isCancelled: cancelled)
                        for (file, hash) in results {
                            guard let hash, ContentHasher.isFinalHash(hash, for: mode) else {
                                stats.errorFiles += 1
                                continue
                            }
                            finalGroups[hash, default: []].append(file)
                            cache.cachedFiles[file.pathKey] = CachedFileInfo(
                                url: file.url,
                                size: file.size,
                                modificationDate: file.modificationDate,
                                hash: hash
                            )
                            hashedCount += 1
                        }
                        await reportHashProgress()
                    }
                }
                
                if !large.isEmpty {
                    let partials = await hashFiles(large, mode: .partial, concurrency: concurrency, isCancelled: cancelled)
                    var partialGroups: [String: [FileInfo]] = [:]
                    for (file, hash) in partials {
                        if let hash {
                            partialGroups[hash, default: []].append(file)
                        } else {
                            stats.errorFiles += 1
                        }
                    }
                    let orderedGroups = partialGroups.values.sorted {
                        ($0.first?.pathKey ?? "") < ($1.first?.pathKey ?? "")
                    }
                    for groupFiles in orderedGroups {
                        if cancelled() { break }
                        let ordered = groupFiles.sorted { $0.pathKey < $1.pathKey }
                        let finals = await hashFiles(ordered, mode: finalHashMode, concurrency: concurrency, isCancelled: cancelled)
                        for (file, hash) in finals {
                            guard let hash, ContentHasher.isFinalHash(hash, for: mode) else {
                                stats.errorFiles += 1
                                continue
                            }
                            finalGroups[hash, default: []].append(file)
                            cache.cachedFiles[file.pathKey] = CachedFileInfo(
                                url: file.url,
                                size: file.size,
                                modificationDate: file.modificationDate,
                                hash: hash
                            )
                            hashedCount += 1
                        }
                        await reportHashProgress()
                    }
                }
            }
            await reportHashProgress(force: true)
        }
        
        timing.hashing = Date().timeIntervalSince(hashStart)
        
        // Cancelled mid-hash: keep partial per-file hash cache (resume speed) but never
        // publish incomplete groups or a result snapshot — that made the next scan
        // short-circuit with wrong/incomplete results.
        if cancelled() {
            if cacheDirty {
                cache.lastScanDate = Date()
                ScanCacheManager.shared.saveCache(cache)
            }
            timing.total = Date().timeIntervalSince(started)
            return ([], stats, timing)
        }
        
        // Finalize starts immediately after hash so grouping / sentinels / I/O
        // are never an unaccounted gap (that used to make total ≫ sum of bars).
        let finalizeStart = Date()
        doneCandidates = candidates.count
        stats.processedFiles = singletonCount + doneCandidates
        
        await progress(.init(
            phase: "scan.phase.finalizing",
            message: "scan.finalize.groups",
            phaseDetail: "scan.finalize.groups.detail",
            percent: 0.93,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        // same-size candidate counts for review heuristics
        let sizeBucketCounts = Dictionary(uniqueKeysWithValues: multiSize.map { ($0.key, $0.value.count) })
        
        // Local packages only: silent content sentinels for tree-hash collisions.
        // On NAS, re-walking packages is multi-minute SMB latency at ~0% CPU — skip and soft-review.
        if !networkScan {
            finalGroups = splitPackageGroupsWithSentinels(finalGroups)
        }
        
        var groups: [DuplicateGroup] = []
        groups.reserveCapacity(min(finalGroups.count, candidates.count / 2 + 1))
        var groupBucketsDone = 0
        let groupBucketTotal = max(finalGroups.count, 1)
        var lastFinalizeProgress = Date.distantPast
        for (hash, files) in finalGroups {
            groupBucketsDone += 1
            // Singles cannot form a duplicate group — skip before extra work.
            guard files.count > 1 else { continue }
            let uniq = pathDedupe(files)
            guard uniq.count > 1 else { continue }
            let sorted = sortForKeepPreference(uniq)
            let size = sorted[0].size
            let allPackages = uniq.allSatisfy(\.isPackage)
            let identityMismatch = PackageIdentity.hasIdentityMismatch(packages: uniq)
            let packageVerified = allPackages && hash.hasPrefix("pkgv:")
            let review: Bool
            let verified: Bool
            if identityMismatch {
                // Same content, different package names → show but never auto-trust
                review = true
                verified = false
            } else if packageVerified {
                review = false
                verified = true
            } else if allPackages {
                // Tree-only match without successful sentinel → still show but soft-review
                review = true
                verified = false
            } else {
                review = DuplicateReviewPolicy.needsReview(
                    fileSize: size,
                    sameSizeCandidateCount: sizeBucketCounts[size] ?? uniq.count,
                    memberCount: uniq.count
                )
                verified = false
            }
            groups.append(DuplicateGroup(
                files: sorted,
                fileSize: size,
                hash: hash,
                needsReview: review,
                isVerified: verified,
                packageIdentityMismatch: identityMismatch
            ))
            
            let now = Date()
            if now.timeIntervalSince(lastFinalizeProgress) >= 0.2 {
                lastFinalizeProgress = now
                let frac = Double(groupBucketsDone) / Double(groupBucketTotal)
                await progress(.init(
                    phase: "scan.phase.finalizing",
                    message: "scan.finalize.groups",
                    phaseDetail: "\(groups.count)",
                    percent: 0.93 + 0.03 * min(1, frac),
                    estimatedRemaining: 0,
                    stats: stats
                ))
                await Task.yield()
            }
        }
        groups.sort { $0.duplicateSize > $1.duplicateSize }
        
        if stats.newFiles == 0 && stats.cachedFiles > 0 {
            timing.path = .hashCacheOnly
        } else {
            timing.path = .full
        }
        
        await progress(.init(
            phase: "scan.phase.finalizing",
            message: "scan.finalize.persist",
            phaseDetail: "\(groups.count)",
            percent: 0.97,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        // Persist fingerprints for *all* packages (not only same-size candidates).
        // Next /Applications scan can skip interior walks when package mtime is unchanged.
        var packageBestHash: [String: String] = [:]
        for g in groups {
            for f in g.files where f.isPackage {
                packageBestHash[f.pathKey] = g.hash
            }
        }
        for file in unique where file.isPackage {
            let hash = packageBestHash[file.pathKey] ?? file.precomputedHash
            guard let hash, ContentHasher.isFinalHash(hash, for: mode) else { continue }
            if let existing = cache.cachedFiles[file.pathKey],
               !existing.hasChanged(comparedTo: file),
               existing.hash == hash {
                continue
            }
            cache.cachedFiles[file.pathKey] = CachedFileInfo(
                url: file.url,
                size: file.size,
                modificationDate: file.modificationDate,
                hash: hash
            )
            cacheDirty = true
        }
        
        if cacheDirty {
            cache.cleanObsoleteEntries(currentFiles: unique, scanPaths: scanRoots)
            cache.lastScanDate = Date()
            // Memory hot-cache updates immediately; disk write is async so UI is not
            // blocked on encoding a 10MB+ plist after a large NAS scan.
            ScanCacheManager.shared.saveCache(cache, syncDisk: false)
        }
        
        // Snapshot: hot path for next identical scan; disk write also async.
        let snapshot = ScanResultSnapshot.build(roots: scanRoots, files: unique, groups: groups, mode: mode)
        ScanSnapshotStore.save(snapshot, syncDisk: false)
        
        stats.processedFiles = unique.count
        timing.finalize = Date().timeIntervalSince(finalizeStart)
        // Contiguous wall clock for this pipeline leg (prepare+hash+finalize ≈ total).
        timing.total = Date().timeIntervalSince(started)
        
        await progress(.init(
            phase: "scan.phase.finalizing",
            message: "scan.complete",
            phaseDetail: stats.newFiles == 0
                ? "scan.cache.reuse.detail"
                : "hits \(stats.cachedFiles) · hashed \(stats.newFiles)",
            percent: 1.0,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        return (groups, stats, timing)
    }
    
    // MARK: - Helpers
    
    /// For package tree-hash collisions, confirm with light content sentinels (no UI).
    private func splitPackageGroupsWithSentinels(
        _ groups: [String: [FileInfo]]
    ) -> [String: [FileInfo]] {
        var result: [String: [FileInfo]] = [:]
        result.reserveCapacity(groups.count)
        
        for (hash, items) in groups {
            let packages = items.filter(\.isPackage)
            let plain = items.filter { !$0.isPackage }
            
            if !plain.isEmpty {
                result[hash, default: []].append(contentsOf: plain)
            }
            
            guard !packages.isEmpty else { continue }
            
            // Only tree-fingerprint collisions need silent content confirmation
            if packages.count > 1 && hash.hasPrefix("pkg:") {
                var bySentinel: [String: [FileInfo]] = [:]
                for pkg in packages {
                    let key = PackageScanner.sentinelFingerprint(
                        packageURL: pkg.url,
                        skipHidden: true
                    ) ?? "pkgv:fail-\(pkg.pathKey.hashValue)"
                    bySentinel[key, default: []].append(pkg)
                }
                for (sentinel, pkgs) in bySentinel {
                    result[sentinel, default: []].append(contentsOf: pkgs)
                }
            } else {
                result[hash, default: []].append(contentsOf: packages)
            }
        }
        return result
    }
    
    private func pathDedupe(_ files: [FileInfo]) -> [FileInfo] {
        var map: [String: FileInfo] = [:]
        map.reserveCapacity(files.count)
        for f in files {
            let key = f.pathKey
            if let existing = map[key] {
                if f.modificationDate > existing.modificationDate {
                    map[key] = f
                }
            } else {
                map[key] = f
            }
        }
        return Array(map.values)
    }
    
    private func estimateRemaining(started: Date, fraction: Double) -> TimeInterval {
        guard fraction > 0.05 else { return 0 }
        let elapsed = Date().timeIntervalSince(started)
        return max(0, elapsed / fraction - elapsed)
    }
    
    /// Cancellable list fingerprint — yields periodically so cancel can run and UI can restart.
    private func listSignatureCancellable(
        _ files: [FileInfo],
        isCancelled: () -> Bool
    ) async -> String? {
        var xor0: UInt64 = 0
        var xor1: UInt64 = 0
        var totalSize: Int64 = 0
        let chunk = 4096
        var index = 0
        while index < files.count {
            if isCancelled() { return nil }
            let end = min(index + chunk, files.count)
            for i in index..<end {
                let f = files[i]
                totalSize += f.size
                let sec = Int64(f.modificationDate.timeIntervalSince1970)
                var h0 = XXHash64(seed: 0x9E37_79B1_85EB_CA87)
                var h1 = XXHash64(seed: 0xC2B2_AE3D_27D4_EB4F)
                if let pathData = f.pathKey.data(using: .utf8) {
                    h0.update(pathData)
                    h1.update(pathData)
                }
                var sizeBE = f.size.bigEndian
                var secBE = sec.bigEndian
                withUnsafeBytes(of: &sizeBE) { raw in
                    h0.update(bytes: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
                    h1.update(bytes: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
                }
                withUnsafeBytes(of: &secBE) { raw in
                    h0.update(bytes: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
                    h1.update(bytes: raw.bindMemory(to: UInt8.self).baseAddress!, count: raw.count)
                }
                xor0 ^= h0.digest()
                xor1 ^= h1.digest()
            }
            index = end
            await Task.yield()
        }
        if isCancelled() { return nil }
        var outer0 = XXHash64(seed: 0x4F1B_BCDC_BFA5_853D)
        var outer1 = XXHash64(seed: 0x27D4_EB2F_1656_67C5)
        var countBE = Int64(files.count).bigEndian
        var totalBE = totalSize.bigEndian
        var x0 = xor0.bigEndian
        var x1 = xor1.bigEndian
        withUnsafeBytes(of: &countBE) { outer0.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &totalBE) { outer0.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &x0) { outer0.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &x1) { outer0.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &countBE) { outer1.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &totalBE) { outer1.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &x0) { outer1.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        withUnsafeBytes(of: &x1) { outer1.update(bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        return String(format: "ls2:%016llx%016llx", outer0.digest(), outer1.digest())
    }
    
    private func hashFiles(
        _ files: [FileInfo],
        mode: ContentHasher.Mode,
        concurrency: Int,
        isCancelled: () -> Bool
    ) async -> [(FileInfo, String?)] {
        var results: [(Int, FileInfo, String?)] = []
        results.reserveCapacity(files.count)
        var next = 0
        var inFlight = 0
        
        await withTaskGroup(of: (Int, FileInfo, String?).self) { group in
            func enqueue() {
                while next < files.count && inFlight < concurrency {
                    if isCancelled() { return }
                    let i = next
                    let file = files[i]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        // Packages already have structural fingerprint from enumeration
                        if file.isPackage {
                            if let pre = file.precomputedHash {
                                return (i, file, pre)
                            }
                            let rebuilt = PackageScanner.makePackageItem(
                                at: file.url,
                                skipHidden: true,
                                minSize: 0,
                                maxSize: Int64.max
                            )
                            return (i, file, rebuilt?.precomputedHash)
                        }
                        let hash = ContentHasher.hashFile(at: file.url, size: file.size, mode: mode)
                        return (i, file, hash)
                    }
                }
            }
            
            enqueue()
            for await item in group {
                inFlight -= 1
                results.append(item)
                if !isCancelled() { enqueue() }
            }
        }
        
        results.sort { $0.0 < $1.0 }
        return results.map { ($0.1, $0.2) }
    }
    
    private func sortForKeepPreference(_ files: [FileInfo]) -> [FileInfo] {
        files.sorted { a, b in
            let aNet = a.url.path.hasPrefix("/Volumes/")
            let bNet = b.url.path.hasPrefix("/Volumes/")
            if aNet != bNet { return !aNet }
            if a.url.path.count != b.url.path.count {
                return a.url.path.count < b.url.path.count
            }
            let aCopy = a.url.lastPathComponent.lowercased().contains("copy")
                || a.url.lastPathComponent.contains("副本")
            let bCopy = b.url.lastPathComponent.lowercased().contains("copy")
                || b.url.lastPathComponent.contains("副本")
            if aCopy != bCopy { return !aCopy }
            return a.modificationDate > b.modificationDate
        }
    }
}
