import Foundation
import Combine
import SwiftUI

enum ScanOutcome: Sendable {
    case idle
    case completed
    case cancelled
}

/// Per-scan cancel bit so off-main enumeration sees Stop immediately.
final class ScanCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - UI-facing scan statistics (kept for compatibility)
struct ScanStatistics {
    var totalFiles: Int = 0
    var totalSize: Int64 = 0
    var processedFiles: Int = 0
    var processedSize: Int64 = 0
    var cachedFiles: Int = 0
    var newFiles: Int = 0
    var errorFiles: Int = 0
    var permissionErrors: Int = 0
    var ioErrors: Int = 0
    var corruptedFiles: Int = 0
    var skippedFiles: Int = 0
    
    var progressPercent: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }
    
    var cacheHitRate: Double {
        let done = cachedFiles + newFiles
        guard done > 0 else { return 0 }
        return Double(cachedFiles) / Double(done)
    }
    
    mutating func apply(_ snap: ScanStatisticsSnapshot) {
        totalFiles = snap.totalFiles
        totalSize = snap.totalSize
        processedFiles = snap.processedFiles
        processedSize = snap.processedSize
        cachedFiles = snap.cachedFiles
        newFiles = snap.newFiles
        errorFiles = snap.errorFiles
    }
}

/// UI coordinator. Heavy work runs in `ScanPipeline` / `FileEnumerator` off the main actor.
@MainActor
final class DuplicateFinder: ObservableObject {
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var scanProgress: String = ""
    @Published var scanProgressPercent: Double = 0.0
    @Published var errorMessage: String?
    @Published var scanStatistics = ScanStatistics()
    @Published var estimatedTimeRemaining: TimeInterval = 0
    @Published var currentPhase: String = ""
    @Published var phaseProgress: String = ""
    @Published var totalScanDuration: TimeInterval = 0
    @Published var totalFilesScanned: Int = 0
    @Published var lastTiming = ScanTimingBreakdown()
    /// Distinguishes “never scanned” from empty results / cancel (UI state).
    @Published var lastOutcome: ScanOutcome = .idle
    
    @AppStorage("excluded_extensions") private var excludedExtensionsString = "tmp,cache,log"
    @AppStorage("skip_hidden_files") private var skipHiddenFiles = true
    @AppStorage("skip_system_files") private var skipSystemFiles = true
    @AppStorage("min_file_size") private var minFileSize = 1
    @AppStorage("max_file_size_gb") private var maxFileSizeGB = 50.0
    
    @Published var isVerifying = false
    @Published var verifyProgressText = ""
    
    private var currentScanTask: Task<Void, Never>?
    private let pipeline = ScanPipeline()
    private var cancelFlag = ScanCancelFlag()
    private var verifyCancel = ScanCancelFlag()
    
    private var excludedExtensions: Set<String> {
        Set(excludedExtensionsString.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces).lowercased()
        })
    }
    
    private var settingsSnapshot: ScanSettings {
        ScanSettings(
            excludedExtensions: excludedExtensions,
            skipHiddenFiles: skipHiddenFiles,
            skipSystemFiles: skipSystemFiles,
            minFileSizeKB: minFileSize,
            maxFileSizeGB: maxFileSizeGB,
            scanMode: .turbo
        )
    }
    
    var reviewGroupCount: Int {
        duplicateGroups.filter { $0.needsReview && !$0.isVerified }.count
    }
    
    /// Package groups with same content but unrelated names (wrappers / multi-launchers).
    var packageIdentityMismatchCount: Int {
        duplicateGroups.filter(\.packageIdentityMismatch).count
    }
    
    func findDuplicates(in folders: [URL], completion: @escaping () -> Void) {
        currentScanTask?.cancel()
        cancelFlag.cancel()
        // Nonisolated — must not wait for the pipeline actor (previous large scan may hold it).
        pipeline.cancel()
        let cancelFlag = ScanCancelFlag()
        self.cancelFlag = cancelFlag
        
        let settings = settingsSnapshot
        
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            
            self.scanProgress = "scan.initializing".localized
            self.scanProgressPercent = 0.02
            self.errorMessage = nil
            self.duplicateGroups = []
            self.estimatedTimeRemaining = 0
            self.currentPhase = "scan.phase.initializing".localized
            self.phaseProgress = ""
            self.scanStatistics = ScanStatistics()
            self.lastTiming = ScanTimingBreakdown()
            self.totalScanDuration = 0
            self.lastOutcome = .idle
            ProcessInfo.processInfo.disableSuddenTermination()
            defer { ProcessInfo.processInfo.enableSuddenTermination() }
            
            // Wall clock for the whole run (must equal enumerate + pipeline phases).
            let scanWallStart = Date()
            
            // 1) Warm hash cache off the main actor — first launch decodes a multi‑MB plist
            // and used to freeze the UI at 5% “Scanning files…”.
            if !ScanCacheManager.shared.areShardsReady(for: folders) {
                self.currentPhase = "scan.phase.initializing".localized
                self.scanProgress = "scan.prepare.cache".localized
                self.scanProgressPercent = 0.03
                await Task.detached(priority: .userInitiated) {
                    _ = ScanCacheManager.shared.loadCache(for: folders)
                }.value
                if cancelFlag.isCancelled || Task.isCancelled {
                    self.scanProgress = "scan.cancelled".localized
                    self.scanProgressPercent = 0
                    self.lastOutcome = .cancelled
                    completion()
                    return
                }
            }
            
            // 2) Enumerate off the main actor so the first directory walk cannot freeze the bar.
            self.currentPhase = "scan.phase.scanning".localized
            self.scanProgress = "scan.files".localized
            self.scanProgressPercent = 0.05
            let hasNetworkRoot = folders.contains {
                VolumeKind.classify(path: $0.path, volumeIsLocal: nil)
            }
            if hasNetworkRoot {
                self.scanProgress = "scan.files.network".localized
            }
            
            let enumStarted = Date()
            let enumerated = await Task.detached(priority: .userInitiated) {
                let packageHashCache = ScanCacheManager.shared.loadCache(for: folders).cachedFiles
                return await FileEnumerator.enumerate(
                    folders: folders,
                    settings: settings,
                    packageHashCache: packageHashCache,
                    isCancelled: { cancelFlag.isCancelled },
                    onProgress: { update in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.applyEnumerationProgress(update, started: enumStarted, folderCount: folders.count)
                        }
                    }
                )
            }.value
            let enumerateDuration = Date().timeIntervalSince(enumStarted)
            
            if Task.isCancelled || cancelFlag.isCancelled {
                self.scanProgress = "scan.cancelled".localized
                self.scanProgressPercent = 0
                self.lastOutcome = .cancelled
                completion()
                return
            }
            
            // 2) Global size → hash pipeline (off main actor)
            let roots = folders
            let result = await self.pipeline.findDuplicates(
                files: enumerated,
                scanRoots: roots,
                mode: settings.scanMode
            ) { update in
                await MainActor.run { [weak self] in
                    self?.applyProgress(update)
                }
            }
            
            if Task.isCancelled || cancelFlag.isCancelled {
                self.scanProgress = "scan.cancelled".localized
                self.scanProgressPercent = 0
                self.lastOutcome = .cancelled
                completion()
                return
            }
            
            let wallTotal = Date().timeIntervalSince(scanWallStart)
            var timing = result.timing
            timing.enumerate = enumerateDuration
            // Prefer real wall clock; fold any tiny hop/scheduling slack into finalize
            // so the four bars always sum to the reported total.
            let phases =
                timing.enumerate + timing.prepare + timing.hashing + timing.finalize
            if wallTotal > phases {
                timing.finalize += wallTotal - phases
            }
            timing.total = max(wallTotal, phases)
            
            self.duplicateGroups = result.groups
            self.scanStatistics.apply(result.stats)
            self.lastTiming = timing
            self.totalScanDuration = timing.total
            self.totalFilesScanned = result.stats.totalFiles
            self.scanProgress = "scan.complete".localized
            self.scanProgressPercent = 1.0
            self.estimatedTimeRemaining = 0
            self.currentPhase = "scan.phase.finalizing".localized
            self.lastOutcome = .completed
            
            completion()
            self.currentScanTask = nil
        }
    }
    
    func cancelScan() {
        cancelFlag.cancel()
        currentScanTask?.cancel()
        pipeline.cancel()
        scanProgress = "scan.cancelled".localized
        scanProgressPercent = 0
        errorMessage = nil
        lastOutcome = .cancelled
    }
    
    func removeDeletedFile(_ file: FileInfo) {
        removeDeletedURLs([file.url])
    }
    
    func removeDeletedURLs(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        duplicateGroups = DuplicateGroupEditing.removing(urls, from: duplicateGroups).map { group in
            DuplicateGroup(
                files: sortForDisplay(group.files),
                fileSize: group.fileSize,
                hash: group.hash,
                needsReview: group.needsReview,
                isVerified: group.isVerified,
                packageIdentityMismatch: group.packageIdentityMismatch,
                id: group.id
            )
        }
        if duplicateGroups.isEmpty {
            lastOutcome = .completed
        }
    }
    
    /// Full-file SHA-256 on one group (precise). Updates or splits/removes the group.
    func verifyGroupPrecise(id: UUID) async {
        await verifyGroupsPrecise(ids: [id])
    }
    
    /// Full-file SHA-256 on all groups that still need review.
    /// Skips package identity-mismatch groups — content may already match; names make delete unsafe.
    func verifyAllReviewGroups() async {
        let ids = Set(
            duplicateGroups
                .filter { $0.needsReview && !$0.isVerified && !$0.packageIdentityMismatch }
                .map(\.id)
        )
        guard !ids.isEmpty else { return }
        await verifyGroupsPrecise(ids: ids)
    }
    
    func cancelVerify() {
        verifyCancel.cancel()
    }
    
    func verifyGroupsPrecise(ids: Set<UUID>) async {
        guard !ids.isEmpty, !isVerifying else { return }
        verifyCancel = ScanCancelFlag()
        let flag = verifyCancel
        isVerifying = true
        verifyProgressText = "verify.progress".localized(0, 1)
        ProcessInfo.processInfo.disableSuddenTermination()
        defer {
            isVerifying = false
            verifyProgressText = ""
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        
        let targets = duplicateGroups.filter { ids.contains($0.id) }
        let keep = duplicateGroups.filter { !ids.contains($0.id) }
        let workFiles = targets.flatMap(\.files)
        guard !workFiles.isEmpty else { return }
        
        let roots = workFiles.prefix(8).map(\.url)
        let conc = StorageConcurrency.level(for: roots, candidateSample: workFiles)
        let total = workFiles.count
        verifyProgressText = "verify.progress".localized(0, total)
        
        let hashed = await Task.detached(priority: .userInitiated) {
            await StorageConcurrency.hashFiles(
                workFiles,
                mode: .full,
                concurrency: conc,
                isCancelled: { flag.isCancelled },
                onProgress: { done in
                    Task { @MainActor in
                        self.verifyProgressText = "verify.progress".localized(done, total)
                    }
                }
            )
        }.value
        
        var byPath: [String: String] = [:]
        var precise: [String: CachedFileInfo] = [:]
        for (file, hash) in hashed {
            guard let hash, ContentHasher.isPreciseHash(hash) else { continue }
            byPath[file.pathKey] = hash
            precise[file.pathKey] = CachedFileInfo(
                url: file.url,
                size: file.size,
                modificationDate: file.modificationDate,
                hash: hash
            )
        }
        if !precise.isEmpty {
            await Task.detached(priority: .utility) {
                ScanCacheManager.shared.upsertPrecise(precise, syncDisk: true)
            }.value
        }
        
        var next = keep
        for group in targets {
            let complete = group.files.allSatisfy { byPath[$0.pathKey] != nil }
            if !complete {
                next.append(group)
                continue
            }
            var buckets: [String: [FileInfo]] = [:]
            for file in group.files {
                guard let hash = byPath[file.pathKey] else { continue }
                buckets[hash, default: []].append(file)
            }
            for (hash, files) in buckets where files.count > 1 {
                let sorted = sortForDisplay(files)
                let mismatch = PackageIdentity.hasIdentityMismatch(packages: sorted)
                next.append(DuplicateGroup(
                    files: sorted,
                    fileSize: sorted[0].size,
                    hash: hash,
                    needsReview: mismatch,
                    isVerified: !mismatch,
                    packageIdentityMismatch: mismatch
                ))
            }
        }
        next.sort { $0.duplicateSize > $1.duplicateSize }
        duplicateGroups = next
    }
    
    // MARK: - Progress
    
    private func applyEnumerationProgress(
        _ update: FileEnumerator.Progress,
        started: Date,
        folderCount: Int
    ) {
        currentPhase = "scan.phase.scanning".localized
        if update.isNetwork {
            scanProgress = "scan.files.network".localized
            phaseProgress = "scan.files.network.detail".localized(
                update.folderName,
                update.visited,
                update.files
            )
        } else {
            scanProgress = "scan.files.found".localized(update.files)
            phaseProgress = "scan.phase.progress".localized(folderCount)
                + " · "
                + "scan.files.visited".localized(update.visited, update.files)
        }
        
        // Progress from items visited (dirs + files) — moves even when few files validated yet
        let scale = update.isNetwork ? 1500.0 : 6000.0
        let byCount = 0.05 + 0.40 * (1.0 - exp(-Double(update.visited) / scale))
        // Time crawl so a stalled NAS listing never sits at 5% for minutes
        let elapsed = Date().timeIntervalSince(started)
        let byTime = 0.05 + min(0.28, elapsed * (update.isNetwork ? 0.012 : 0.008))
        scanProgressPercent = min(0.45, max(byCount, byTime))
    }
    
    private func applyProgress(_ update: ScanProgressUpdate) {
        currentPhase = update.phase.localized
        scanProgress = update.message.localized
        if update.phaseDetail == "scan.cache.hit.detail"
            || update.phaseDetail == "scan.cache.reuse.detail"
            || update.phaseDetail == "scan.finalize.groups.detail" {
            phaseProgress = update.phaseDetail.localized
        } else if update.phaseDetail.contains("/") || update.phaseDetail.isEmpty
                    || update.phaseDetail.contains("cache") || update.phaseDetail.contains("hits")
                    || update.phaseDetail.contains("·") {
            phaseProgress = update.phaseDetail
        } else if let n = Int(update.phaseDetail) {
            // During finalize, n is group count; during prepare it is file count.
            if update.message == "scan.finalize.groups" || update.message == "scan.finalize.persist" {
                phaseProgress = "scan.finalize.groups.count".localized(n)
            } else {
                phaseProgress = "scan.phase.sorting.detail".localized(n)
            }
        } else {
            phaseProgress = update.phaseDetail
        }
        scanProgressPercent = update.percent
        estimatedTimeRemaining = update.estimatedRemaining
        scanStatistics.apply(update.stats)
    }
    
    private func sortForDisplay(_ files: [FileInfo]) -> [FileInfo] {
        files.sorted { a, b in
            let aNet = VolumeKind.isNetwork(a.url)
            let bNet = VolumeKind.isNetwork(b.url)
            if aNet != bNet { return !aNet }
            return a.url.path.count < b.url.path.count
        }
    }
}

// MARK: - File enumeration (off main actor)

enum FileEnumerator {
    
    struct Progress: Sendable {
        var visited: Int
        var files: Int
        var isNetwork: Bool
        var folderName: String
    }
    
    /// Thread-safe progress counters for parallel NAS subtree listing.
    private final class ProgressBucket: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var visited = 0
        private(set) var files = 0
        
        func add(visited deltaV: Int, files deltaF: Int) -> (visited: Int, files: Int) {
            lock.lock()
            self.visited += deltaV
            self.files += deltaF
            let v = self.visited
            let f = self.files
            lock.unlock()
            return (v, f)
        }
        
        func snapshot() -> (visited: Int, files: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (visited, files)
        }
    }
    
    static func enumerate(
        folders: [URL],
        settings: ScanSettings,
        packageHashCache: [String: CachedFileInfo]? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> [FileInfo] {
        // Sequential roots so progress is readable; each root reports live callbacks.
        // Within a network root, first-level subtrees run in parallel (see below).
        var all: [FileInfo] = []
        var totalVisited = 0
        var totalFiles = 0
        
        // Package interior walks dominate /Applications scans — reuse durable hash cache by path+mtime.
        // Prefer a preloaded map so the first scan does not decode the plist on the UI task.
        let packageHashCache = packageHashCache ?? ScanCacheManager.shared.loadCache(for: folders).cachedFiles
        
        if let first = folders.first {
            onProgress(Progress(
                visited: 0,
                files: 0,
                isNetwork: VolumeKind.isNetwork(first),
                folderName: first.lastPathComponent
            ))
        }
        
        for folder in folders {
            if isCancelled() { break }
            let isNetwork = VolumeKind.isNetwork(folder)
            let name = folder.lastPathComponent
            let baseVisited = totalVisited
            let baseFiles = totalFiles
            
            let batch: (files: [FileInfo], visited: Int)
            if isNetwork {
                batch = await enumerateNetworkRoot(
                    folder,
                    settings: settings,
                    packageHashCache: packageHashCache,
                    isCancelled: isCancelled,
                    onTick: { visited, files in
                        onProgress(Progress(
                            visited: baseVisited + visited,
                            files: baseFiles + files,
                            isNetwork: true,
                            folderName: name
                        ))
                    }
                )
            } else {
                batch = enumerateSubtree(
                    folder,
                    settings: settings,
                    packageHashCache: packageHashCache,
                    isNetwork: false,
                    manageSecurityScope: true,
                    isCancelled: isCancelled,
                    onTick: { visited, files in
                        onProgress(Progress(
                            visited: baseVisited + visited,
                            files: baseFiles + files,
                            isNetwork: false,
                            folderName: name
                        ))
                    }
                )
            }
            
            totalVisited = baseVisited + batch.visited
            totalFiles = baseFiles + batch.files.count
            all.append(contentsOf: batch.files)
            onProgress(Progress(
                visited: totalVisited,
                files: totalFiles,
                isNetwork: isNetwork,
                folderName: name
            ))
        }
        return all
    }
    
    // MARK: - Network parallel first-level subtrees
    
    /// List immediate children, process root-level files/packages, parallel-walk each subdirectory.
    private static func enumerateNetworkRoot(
        _ folder: URL,
        settings: ScanSettings,
        packageHashCache: [String: CachedFileInfo],
        isCancelled: @escaping @Sendable () -> Bool,
        onTick: @escaping @Sendable (_ visited: Int, _ files: Int) -> Void
    ) async -> (files: [FileInfo], visited: Int) {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
        }
        
        let keys = networkResourceKeys
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if settings.skipHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: settings.skipHiddenFiles ? [.skipsHiddenFiles] : []
            )
        } catch {
            // Fallback: single-threaded full walk if shallow list fails
            return enumerateSubtree(
                folder,
                settings: settings,
                packageHashCache: packageHashCache,
                isNetwork: true,
                manageSecurityScope: false,
                isCancelled: isCancelled,
                onTick: onTick
            )
        }
        
        var rootFiles: [FileInfo] = []
        var subdirs: [URL] = []
        var visited = 0
        rootFiles.reserveCapacity(64)
        subdirs.reserveCapacity(children.count)
        
        for url in children {
            if isCancelled() { break }
            visited += 1
            if settings.skipSystemFiles && isSystemPath(url) { continue }
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty && settings.excludedExtensions.contains(ext) { continue }
            
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isPackage == true, values.isDirectory == true {
                    if let pkg = packageItem(
                        url: url,
                        values: values,
                        settings: settings,
                        packageHashCache: packageHashCache
                    ) {
                        rootFiles.append(pkg)
                    }
                    continue
                }
                if values.isDirectory == true {
                    subdirs.append(url)
                    continue
                }
                if let file = regularFileItem(url: url, values: values, settings: settings) {
                    rootFiles.append(file)
                }
            } catch {
                continue
            }
        }
        
        let progress = ProgressBucket()
        _ = progress.add(visited: visited, files: rootFiles.count)
        onTick(visited, rootFiles.count)
        
        // Stable order: path-sorted subtrees (helps NAS sequential access a bit)
        subdirs.sort { $0.path < $1.path }
        
        let concurrency = StorageConcurrency.networkEnumConcurrency
        var collected: [FileInfo] = rootFiles
        collected.reserveCapacity(max(1024, rootFiles.count + subdirs.count * 32))
        
        await withTaskGroup(of: (files: [FileInfo], visited: Int).self) { group in
            var next = 0
            var inFlight = 0
            
            func enqueue() {
                while next < subdirs.count && inFlight < concurrency {
                    if isCancelled() { return }
                    let dir = subdirs[next]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        // Local counters; flush into shared bucket for UI (not every entry).
                        var lastFlushV = 0
                        var lastFlushF = 0
                        let batch = enumerateSubtree(
                            dir,
                            settings: settings,
                            packageHashCache: packageHashCache,
                            isNetwork: true,
                            manageSecurityScope: false,
                            isCancelled: isCancelled,
                            onTick: { v, f in
                                let dV = v - lastFlushV
                                let dF = f - lastFlushF
                                guard dV >= 40 || dF >= 10 else { return }
                                lastFlushV = v
                                lastFlushF = f
                                let snap = progress.add(visited: dV, files: dF)
                                onTick(snap.visited, snap.files)
                            }
                        )
                        // Flush remainder so totals match final batch.visited/files
                        let remV = batch.visited - lastFlushV
                        let remF = batch.files.count - lastFlushF
                        if remV > 0 || remF > 0 {
                            _ = progress.add(visited: remV, files: remF)
                        }
                        // Return zero visited/files so outer merge does not double-count
                        return (batch.files, 0)
                    }
                }
            }
            
            enqueue()
            for await batch in group {
                inFlight -= 1
                if isCancelled() {
                    group.cancelAll()
                    break
                }
                collected.append(contentsOf: batch.files)
                // Visited/files already flushed via ProgressBucket inside workers
                let snap = progress.snapshot()
                onTick(snap.visited, snap.files)
                enqueue()
            }
        }
        
        let final = progress.snapshot()
        onTick(final.visited, final.files)
        return (collected, final.visited)
    }
    
    // MARK: - Single-subtree walk
    
    /// Recursive enumerator for one folder tree.
    /// - Parameter manageSecurityScope: true only for user-selected local roots.
    private static func enumerateSubtree(
        _ folder: URL,
        settings: ScanSettings,
        packageHashCache: [String: CachedFileInfo],
        isNetwork: Bool,
        manageSecurityScope: Bool,
        isCancelled: @escaping @Sendable () -> Bool,
        onTick: @escaping @Sendable (_ visited: Int, _ files: Int) -> Void
    ) -> (files: [FileInfo], visited: Int) {
        let accessed = manageSecurityScope ? folder.startAccessingSecurityScopedResource() : false
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
        }
        
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if settings.skipHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        
        let keys = isNetwork ? networkResourceKeys : localResourceKeys
        
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return ([], 0)
        }
        
        // NAS: report more often (slow listing); local: less UI thrash
        let reportEvery = isNetwork ? 40 : 200
        var results: [FileInfo] = []
        results.reserveCapacity(isNetwork ? 1024 : 4096)
        var visited = 0
        var lastReport = Date.distantPast
        
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            visited += 1
            
            let now = Date()
            if visited % reportEvery == 0 || now.timeIntervalSince(lastReport) >= 0.25 {
                lastReport = now
                onTick(visited, results.count)
            }
            
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty && settings.excludedExtensions.contains(ext) { continue }
            if settings.skipSystemFiles && isSystemPath(url) { continue }
            
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                
                // Opaque package: one object, do not list interior as separate files
                if values.isPackage == true, values.isDirectory == true {
                    if let pkg = packageItem(
                        url: url,
                        values: values,
                        settings: settings,
                        packageHashCache: packageHashCache
                    ) {
                        results.append(pkg)
                    }
                    continue
                }
                
                if let file = regularFileItem(url: url, values: values, settings: settings) {
                    results.append(file)
                }
            } catch {
                continue
            }
        }
        
        onTick(visited, results.count)
        return (results, visited)
    }
    
    // MARK: - Item builders (reuse resourceValues — no second NAS RTT)
    
    private static var networkResourceKeys: [URLResourceKey] {
        [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
    }
    
    private static var localResourceKeys: [URLResourceKey] {
        networkResourceKeys + [.creationDateKey]
    }
    
    private static func packageItem(
        url: URL,
        values: URLResourceValues,
        settings: ScanSettings,
        packageHashCache: [String: CachedFileInfo]
    ) -> FileInfo? {
        let mod = values.contentModificationDate
            ?? values.creationDate
            ?? Date(timeIntervalSince1970: 0)
        let created = values.creationDate ?? mod
        return PackageScanner.makePackageItem(
            at: url,
            skipHidden: settings.skipHiddenFiles,
            minSize: settings.minSizeBytes,
            maxSize: settings.maxSizeBytes,
            hashCache: packageHashCache,
            knownModificationDate: mod,
            knownCreationDate: created
        )
    }
    
    private static func regularFileItem(
        url: URL,
        values: URLResourceValues,
        settings: ScanSettings
    ) -> FileInfo? {
        guard values.isRegularFile == true else { return nil }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { return nil }
        guard size >= settings.minSizeBytes && size <= settings.maxSizeBytes else { return nil }
        // Never use Date() as fallback — that breaks cache/snapshot across relaunches
        let mod = values.contentModificationDate
            ?? values.creationDate
            ?? Date(timeIntervalSince1970: 0)
        let created = values.creationDate ?? mod
        return FileInfo(url: url, size: size, modificationDate: mod, creationDate: created)
    }
    
    private static func isSystemPath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasPrefix("/system/")
            || path.hasPrefix("/private/")
            || path.hasPrefix("/usr/")
            || path.hasPrefix("/bin/")
            || path.hasPrefix("/sbin/")
            || path.contains("/library/caches/")
    }
}
