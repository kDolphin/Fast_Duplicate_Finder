import Foundation
import Combine
import SwiftUI

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
    
    @AppStorage("excluded_extensions") private var excludedExtensionsString = "tmp,cache,log"
    @AppStorage("skip_hidden_files") private var skipHiddenFiles = true
    @AppStorage("skip_system_files") private var skipSystemFiles = true
    @AppStorage("min_file_size") private var minFileSize = 1
    @AppStorage("max_file_size_gb") private var maxFileSizeGB = 50.0
    
    @Published var isVerifying = false
    @Published var verifyProgressText = ""
    
    private var currentScanTask: Task<Void, Never>?
    private let pipeline = ScanPipeline()
    
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
        // Nonisolated — must not wait for the pipeline actor (previous large scan may hold it).
        pipeline.cancel()
        
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
            
            // Wall clock for the whole run (must equal enumerate + pipeline phases).
            let scanWallStart = Date()
            
            // 1) Enumerate immediately — do not await pipeline first (that froze “Initializing…”).
            self.currentPhase = "scan.phase.scanning".localized
            self.scanProgress = "scan.files".localized
            self.scanProgressPercent = 0.05
            let hasNetworkRoot = folders.contains { $0.path.hasPrefix("/Volumes/") }
            if hasNetworkRoot {
                self.scanProgress = "scan.files.network".localized
            }
            
            let enumStarted = Date()
            let enumerated = await FileEnumerator.enumerate(
                folders: folders,
                settings: settings,
                isCancelled: { Task.isCancelled },
                onProgress: { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        self.applyEnumerationProgress(update, started: enumStarted, folderCount: folders.count)
                    }
                }
            )
            let enumerateDuration = Date().timeIntervalSince(enumStarted)
            
            if Task.isCancelled {
                self.scanProgress = "scan.cancelled".localized
                self.scanProgressPercent = 0
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
            
            if Task.isCancelled {
                self.scanProgress = "scan.cancelled".localized
                self.scanProgressPercent = 0
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
            
            completion()
            self.currentScanTask = nil
        }
    }
    
    func cancelScan() {
        currentScanTask?.cancel()
        pipeline.cancel()
        scanProgress = "scan.cancelled".localized
        scanProgressPercent = 0
        errorMessage = nil
    }
    
    func removeDeletedFile(_ file: FileInfo) {
        duplicateGroups = duplicateGroups.compactMap { group in
            let remaining = group.files.filter { $0.url != file.url }
            guard remaining.count >= 2 else { return nil }
            let sorted = sortForDisplay(remaining)
            let mismatch = PackageIdentity.hasIdentityMismatch(packages: sorted)
            // Re-evaluate: deleting may resolve a name-mismatch group
            let review: Bool
            let verified: Bool
            if mismatch {
                review = true
                verified = false
            } else if group.packageIdentityMismatch {
                // Was name-mismatch; remaining names now related → keep content confidence
                review = false
                verified = group.isVerified || group.hash.hasPrefix("pkgv:") || group.hash.hasPrefix("sha256:")
            } else {
                review = group.needsReview
                verified = group.isVerified
            }
            return DuplicateGroup(
                files: sorted,
                fileSize: group.fileSize,
                hash: group.hash,
                needsReview: review,
                isVerified: verified,
                packageIdentityMismatch: mismatch,
                id: group.id
            )
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
    
    func verifyGroupsPrecise(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        isVerifying = true
        defer {
            isVerifying = false
            verifyProgressText = ""
        }
        
        var next: [DuplicateGroup] = []
        let targets = duplicateGroups.filter { ids.contains($0.id) }
        let keep = duplicateGroups.filter { !ids.contains($0.id) }
        next.append(contentsOf: keep)
        
        var index = 0
        for group in targets {
            index += 1
            verifyProgressText = "verify.progress".localized(index, targets.count)
            
            let ordered = group.files.sorted { $0.pathKey < $1.pathKey }
            let hashed: [(FileInfo, String?)] = await Task.detached(priority: .userInitiated) {
                ordered.map { file in
                    if file.isPackage {
                        return (file, PackageScanner.strongContentFingerprint(
                            packageURL: file.url,
                            skipHidden: true
                        ))
                    }
                    return (file, ContentHasher.hashFile(at: file.url, size: file.size, mode: .full))
                }
            }.value
            
            var byHash: [String: [FileInfo]] = [:]
            for (file, hash) in hashed {
                guard let hash else { continue }
                byHash[hash, default: []].append(file)
            }
            
            for (hash, files) in byHash where files.count > 1 {
                let sorted = files.sorted { a, b in
                    if a.url.path.hasPrefix("/Volumes/") != b.url.path.hasPrefix("/Volumes/") {
                        return !a.url.path.hasPrefix("/Volumes/")
                    }
                    return a.url.path.count < b.url.path.count
                }
                let mismatch = PackageIdentity.hasIdentityMismatch(packages: sorted)
                // Content may match, but unrelated package names stay untrusted for delete
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
        
        // Write SHA-256 results into cache for next scans
        await Task.detached {
            var cache = ScanCacheManager.shared.loadCache()
            for group in next where group.isVerified {
                for file in group.files {
                    cache.cachedFiles[file.pathKey] = CachedFileInfo(
                        url: file.url,
                        size: file.size,
                        modificationDate: file.modificationDate,
                        hash: group.hash
                    )
                }
            }
            ScanCacheManager.shared.saveCache(cache)
        }.value
        
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
            let aNet = a.url.path.hasPrefix("/Volumes/")
            let bNet = b.url.path.hasPrefix("/Volumes/")
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
    
    static func enumerate(
        folders: [URL],
        settings: ScanSettings,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> [FileInfo] {
        // Sequential roots so progress is readable; each root reports live callbacks.
        // Parallel roots would interleave progress confusingly on multi-folder scans.
        var all: [FileInfo] = []
        var totalVisited = 0
        var totalFiles = 0
        
        // Package interior walks dominate /Applications scans — reuse durable hash cache by path+mtime.
        let packageHashCache = ScanCacheManager.shared.loadCache().cachedFiles
        
        for folder in folders {
            if isCancelled() { break }
            let isNetwork = folder.path.hasPrefix("/Volumes/")
            let name = folder.lastPathComponent
            let baseVisited = totalVisited
            let baseFiles = totalFiles
            let batch = enumerateFolder(
                folder,
                settings: settings,
                packageHashCache: packageHashCache,
                isCancelled: isCancelled,
                onTick: { visited, files in
                    onProgress(Progress(
                        visited: baseVisited + visited,
                        files: baseFiles + files,
                        isNetwork: isNetwork,
                        folderName: name
                    ))
                }
            )
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
    
    private static func enumerateFolder(
        _ folder: URL,
        settings: ScanSettings,
        packageHashCache: [String: CachedFileInfo],
        isCancelled: @escaping @Sendable () -> Bool,
        onTick: @escaping @Sendable (_ visited: Int, _ files: Int) -> Void
    ) -> (files: [FileInfo], visited: Int) {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
        }
        
        // Skip package interiors (.app, BDMV/AVCHD, .photoslibrary, …).
        // Product choice: treat packages as opaque (e.g. no Blu-ray BACKUP/CLIPINF pairs).
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if settings.skipHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        
        let isNetwork = folder.path.hasPrefix("/Volumes/")
        // NAS: fewer metadata keys per entry (each attr can be an extra RTT)
        var keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        if !isNetwork {
            keys.append(.creationDateKey)
        }
        
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
                // (skipsPackageDescendants already prevents descent; still register the package)
                if values.isPackage == true, values.isDirectory == true {
                    if let pkg = PackageScanner.makePackageItem(
                        at: url,
                        skipHidden: settings.skipHiddenFiles,
                        minSize: settings.minSizeBytes,
                        maxSize: settings.maxSizeBytes,
                        hashCache: packageHashCache
                    ) {
                        results.append(pkg)
                    }
                    continue
                }
                
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size > 0 else { continue }
                guard size >= settings.minSizeBytes && size <= settings.maxSizeBytes else { continue }
                
                // Never use Date() as fallback — that breaks cache/snapshot across relaunches
                let mod = values.contentModificationDate
                    ?? values.creationDate
                    ?? Date(timeIntervalSince1970: 0)
                let created = values.creationDate ?? mod
                results.append(FileInfo(url: url, size: size, modificationDate: mod, creationDate: created))
            } catch {
                continue
            }
        }
        
        onTick(visited, results.count)
        return (results, visited)
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
