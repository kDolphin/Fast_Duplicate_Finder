import Foundation

/// Off-main-actor duplicate detection pipeline (P0–P2).
actor ScanPipeline {
    
    private var cancelled = false
    
    func cancel() {
        cancelled = true
    }
    
    func reset() {
        cancelled = false
    }
    
    func findDuplicates(
        files: [FileInfo],
        scanRoots: [URL],
        mode: ScanMode,
        progress: @Sendable (ScanProgressUpdate) async -> Void
    ) async -> (groups: [DuplicateGroup], stats: ScanStatisticsSnapshot, timing: ScanTimingBreakdown) {
        cancelled = false
        let started = Date()
        var stats = ScanStatisticsSnapshot()
        var timing = ScanTimingBreakdown()
        let finalHashMode = ContentHasher.finalMode(for: mode)
        
        let prepareStart = Date()
        let unique = pathDedupe(files)
        stats.totalFiles = unique.count
        stats.totalSize = unique.reduce(0) { $0 + $1.size }
        
        guard !cancelled else {
            timing.total = Date().timeIntervalSince(started)
            return ([], stats, timing)
        }
        
        await progress(.init(
            phase: "scan.phase.processing",
            message: "scan.cache.processing",
            phaseDetail: "\(unique.count)",
            percent: 0.48,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        // Snapshot short-circuit (mode-aware)
        let rootKeys = ScanResultSnapshot.rootKeys(from: scanRoots)
        let signature = ScanResultSnapshot.listSignature(for: unique)
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
            message: "scan.cache.processing",
            phaseDetail: "\(candidates.count) candidates · \(singletonCount) unique-by-size",
            percent: 0.50,
            estimatedRemaining: 0,
            stats: stats
        ))
        
        var cache = ScanCacheManager.shared.loadCache()
        var normalized: [String: CachedFileInfo] = [:]
        normalized.reserveCapacity(cache.cachedFiles.count)
        for (key, value) in cache.cachedFiles {
            guard ContentHasher.isFinalHash(value.hash, for: mode) else { continue }
            normalized[key.standardizedPath] = value
        }
        cache.cachedFiles = normalized
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
        for bucket in multiSize.values {
            for file in bucket {
                let key = file.pathKey
                if let cached = cache.cachedFiles[key],
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
                    if cancelled { break }
                    let end = min(i + chunkSize, needHashAll.count)
                    let slice = Array(needHashAll[i..<end])
                    i = end
                    let results = await hashFiles(slice, mode: finalHashMode, concurrency: concurrency)
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
                        if cancelled { break }
                        let end = min(i + chunkSize, small.count)
                        let slice = Array(small[i..<end])
                        i = end
                        let results = await hashFiles(slice, mode: finalHashMode, concurrency: concurrency)
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
                    let partials = await hashFiles(large, mode: .partial, concurrency: concurrency)
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
                        if cancelled { break }
                        let ordered = groupFiles.sorted { $0.pathKey < $1.pathKey }
                        let finals = await hashFiles(ordered, mode: finalHashMode, concurrency: concurrency)
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
        
        doneCandidates = candidates.count
        stats.processedFiles = singletonCount + doneCandidates
        
        // same-size candidate counts for review heuristics
        let sizeBucketCounts = Dictionary(uniqueKeysWithValues: multiSize.map { ($0.key, $0.value.count) })
        
        // Silent package content sentinels for tree-hash collisions (user-invisible)
        finalGroups = splitPackageGroupsWithSentinels(finalGroups)
        
        var groups: [DuplicateGroup] = []
        for (hash, files) in finalGroups {
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
        }
        groups.sort { $0.duplicateSize > $1.duplicateSize }
        
        timing.hashing = Date().timeIntervalSince(hashStart)
        if stats.newFiles == 0 && stats.cachedFiles > 0 {
            timing.path = .hashCacheOnly
        } else {
            timing.path = .full
        }
        
        let finalizeStart = Date()
        await progress(.init(
            phase: "scan.phase.finalizing",
            message: "scan.finalizing",
            phaseDetail: "\(groups.count)",
            percent: 0.96,
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
            ScanCacheManager.shared.saveCache(cache)
        }
        
        ScanSnapshotStore.save(
            ScanResultSnapshot.build(roots: scanRoots, files: unique, groups: groups, mode: mode)
        )
        
        stats.processedFiles = unique.count
        timing.finalize = Date().timeIntervalSince(finalizeStart)
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
    
    private func hashFiles(
        _ files: [FileInfo],
        mode: ContentHasher.Mode,
        concurrency: Int
    ) async -> [(FileInfo, String?)] {
        var results: [(Int, FileInfo, String?)] = []
        results.reserveCapacity(files.count)
        var next = 0
        var inFlight = 0
        
        await withTaskGroup(of: (Int, FileInfo, String?).self) { group in
            func enqueue() {
                while next < files.count && inFlight < concurrency {
                    if cancelled { return }
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
                if !cancelled { enqueue() }
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
