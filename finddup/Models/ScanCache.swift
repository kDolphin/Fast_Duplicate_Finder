import Foundation

// MARK: - Path canonicalization
extension String {
    /// Stable cache key across launches (firmlinks, trailing slash, Unicode).
    var standardizedPath: String {
        var path: String
        if self.hasPrefix("/Volumes/") {
            path = replacingOccurrences(of: "//", with: "/")
            if path.count > 1 && path.hasSuffix("/") {
                path = String(path.dropLast())
            }
        } else {
            let url = URL(fileURLWithPath: self)
            path = url.resolvingSymlinksInPath().standardized.path
            if path.count > 1 && path.hasSuffix("/") {
                path = String(path.dropLast())
            }
        }
        // APFS firmlink: /System/Volumes/Data/Users/... ↔ /Users/...
        let dataPrefix = "/System/Volumes/Data"
        if path.hasPrefix(dataPrefix) {
            let stripped = String(path.dropFirst(dataPrefix.count))
            path = stripped.isEmpty ? "/" : stripped
        }
        return path.precomposedStringWithCanonicalMapping
    }
}

// MARK: - Cached file record
struct CachedFileInfo: Codable {
    let urlPath: String
    let size: Int64
    let modificationDate: Date
    /// Whole-second mtime for stable compare after plist round-trip
    let mtimeSec: Int64
    let hash: String
    let lastScanDate: Date
    
    enum CodingKeys: String, CodingKey {
        case urlPath, size, modificationDate, mtimeSec, hash, lastScanDate
    }
    
    init(url: URL, size: Int64, modificationDate: Date, hash: String) {
        self.urlPath = url.path.standardizedPath
        self.size = size
        self.modificationDate = modificationDate
        self.mtimeSec = Int64(modificationDate.timeIntervalSince1970)
        self.hash = hash
        self.lastScanDate = Date()
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlPath = try c.decode(String.self, forKey: .urlPath)
        size = try c.decode(Int64.self, forKey: .size)
        modificationDate = try c.decode(Date.self, forKey: .modificationDate)
        hash = try c.decode(String.self, forKey: .hash)
        lastScanDate = try c.decode(Date.self, forKey: .lastScanDate)
        if let sec = try c.decodeIfPresent(Int64.self, forKey: .mtimeSec) {
            mtimeSec = sec
        } else {
            mtimeSec = Int64(modificationDate.timeIntervalSince1970)
        }
    }
    
    var url: URL {
        URL(fileURLWithPath: urlPath)
    }
    
    func hasChanged(comparedTo fileInfo: FileInfo) -> Bool {
        if size != fileInfo.size { return true }
        let fileSec = Int64(fileInfo.modificationDate.timeIntervalSince1970)
        return mtimeSec != fileSec
    }
}

// MARK: - Scan cache
struct ScanCache: Codable {
    var cachedFiles: [String: CachedFileInfo] = [:]
    var lastScanDate: Date = Date()
    
    // Limits
    private static let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    private static let maxCacheEntries = 2_000_000 // max entries
    private static let maxCacheSize: Int64 = 300 * 1024 * 1024 // ~300 MB estimate
    
    mutating func cleanObsoleteEntries(currentFiles: [FileInfo], scanPaths: [URL]) {
        // Prefer cached pathKey — avoid re-standardizing 100k+ paths on every save.
        let currentFilePaths = Set(currentFiles.map(\.pathKey))
        let scanPathStrings = scanPaths.map { $0.path.standardizedPath }
        
        // Only drop entries under current roots that no longer exist (O(cache) but no logging)
        var obsolete: [String] = []
        for cachedPath in cachedFiles.keys {
            let inScan = scanPathStrings.contains { root in
                cachedPath == root || cachedPath.hasPrefix(root + "/")
            }
            if inScan && !currentFilePaths.contains(cachedPath) {
                obsolete.append(cachedPath)
            }
        }
        for key in obsolete {
            cachedFiles.removeValue(forKey: key)
        }
        
        _ = cleanExpiredEntries()
        _ = cleanOversizeEntries()
    }
    
    /// Drop entries older than `maxCacheAge`.
    private mutating func cleanExpiredEntries() -> Int {
        let now = Date()
        let expiredKeys = cachedFiles.compactMap { (key, value) in
            let age = now.timeIntervalSince(value.lastScanDate)
            return age > Self.maxCacheAge ? key : nil
        }
        
        for key in expiredKeys {
            cachedFiles.removeValue(forKey: key)
        }
        
        return expiredKeys.count
    }
    
    /// Drop oldest entries when over `maxCacheEntries`.
    private mutating func cleanOversizeEntries() -> Int {
        guard cachedFiles.count > Self.maxCacheEntries else { return 0 }
        
        // Keep the most recently scanned entries
        let sortedEntries = cachedFiles.sorted { $0.value.lastScanDate > $1.value.lastScanDate }
        let entriesToKeep = sortedEntries.prefix(Self.maxCacheEntries)
        let entriesToRemove = sortedEntries.dropFirst(Self.maxCacheEntries)
        
        // Rebuild the dictionary
        let newCachedFiles = Dictionary(uniqueKeysWithValues: entriesToKeep.map { ($0.key, $0.value) })
        cachedFiles = newCachedFiles
        
        return entriesToRemove.count
    }
    
    /// Merge a scan working set. Drops only keys under `scanRoots` that are not
    /// in `currentPathKeys`; other volumes stay put.
    mutating func merge(
        working: [String: CachedFileInfo],
        scanRoots: [String],
        currentPathKeys: Set<String>
    ) {
        for (key, value) in working {
            cachedFiles[key] = value
        }
        if !scanRoots.isEmpty {
            for path in Array(cachedFiles.keys) {
                let underRoot = scanRoots.contains { root in
                    path == root || path.hasPrefix(root + "/")
                }
                if underRoot && !currentPathKeys.contains(path) {
                    cachedFiles.removeValue(forKey: path)
                }
            }
        }
        lastScanDate = Date()
    }
    
    /// Cache statistics for Settings.
    func getCacheStats() -> (totalEntries: Int, estimatedSize: Int64, oldestEntry: Date?, newestEntry: Date?) {
        let totalEntries = cachedFiles.count
        
        // Rough size: ~1 KB per entry
        let estimatedSize = Int64(totalEntries * 1024)
        
        let dates = cachedFiles.values.map { $0.lastScanDate }
        let oldestEntry = dates.min()
        let newestEntry = dates.max()
        
        return (totalEntries, estimatedSize, oldestEntry, newestEntry)
    }
}

// MARK: - Cache manager
class ScanCacheManager {
    static let shared = ScanCacheManager()
    
    private let cacheFileURL: URL
    private let useBinaryFormat = true  // binary plist
    /// Avoid re-decoding a multi‑MB plist on every scan (hot path for large NAS libraries).
    private var hotCache: ScanCache?
    private let hotLock = NSLock()
    
    init() {
        // Bundle / sandbox info for debug logs
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let isInSandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        
        #if DEBUG
        print("🏗️ Cache initialization:")
        #endif
        #if DEBUG
        print("   - Bundle ID: \(bundleId)")
        #endif
        #if DEBUG
        print("   - Sandboxed: \(isInSandbox)")
        #endif
        
        // Sandboxed: use the app caches directory
        let cacheDirectory: URL
        if let appCacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = appCacheDirectory.appendingPathComponent("finddup")
            #if DEBUG
            print("   - Using app cache directory: \(appCacheDirectory.path)")
            #endif
        } else {
            // Fallback: ~/.cache when not sandboxed
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            cacheDirectory = homeDirectory.appendingPathComponent(".cache/finddup")
            #if DEBUG
            print("   - Using home cache directory: \(homeDirectory.path)")
            #endif
        }
        
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            #if DEBUG
            print("✅ Cache directory created: \(cacheDirectory.path)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to create cache directory: \(error)")
            #endif
        }
        
        cacheFileURL = cacheDirectory.appendingPathComponent(useBinaryFormat ? "scan_cache.plist" : "scan_cache.json")
        #if DEBUG
        print("📁 Cache file URL: \(cacheFileURL.path) (format: \(useBinaryFormat ? "binary" : "JSON"))")
        #endif
        
        // Log whether the cache file already exists
        let cacheExists = FileManager.default.fileExists(atPath: cacheFileURL.path)
        #if DEBUG
        print("💾 Cache file exists: \(cacheExists)")
        #endif
        
        if cacheExists {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: cacheFileURL.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                let modificationDate = attributes[.modificationDate] as? Date ?? Date()
                #if DEBUG
                print("   - Cache size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
                #endif
                #if DEBUG
                print("   - Last modified: \(modificationDate)")
                #endif
            } catch {
                #if DEBUG
                print("   - Failed to get cache attributes: \(error)")
                #endif
            }
        }
    }
    
    func isHot() -> Bool {
        hotLock.lock()
        defer { hotLock.unlock() }
        return hotCache != nil
    }
    
    /// Decode the on-disk cache off the caller’s thread (first launch is multi‑MB).
    func preloadInBackground() {
        guard !isHot() else { return }
        Task.detached(priority: .utility) {
            _ = ScanCacheManager.shared.loadCache()
        }
    }
    
    func loadCache() -> ScanCache {
        hotLock.lock()
        if let hotCache {
            let copy = hotCache
            hotLock.unlock()
            return copy
        }
        hotLock.unlock()
        
        var loaded: ScanCache
        if let cache = loadCacheFromURL(cacheFileURL) {
            loaded = cache
        } else {
            loaded = ScanCache()
            for cachePath in getPossibleCachePaths() {
                if let cache = loadCacheFromURL(cachePath) {
                    loaded = cache
                    break
                }
            }
        }
        // Normalize keys once on disk load (path canonicalization).
        if !loaded.cachedFiles.isEmpty {
            var normalized: [String: CachedFileInfo] = [:]
            normalized.reserveCapacity(loaded.cachedFiles.count)
            for (key, value) in loaded.cachedFiles {
                let k = key.standardizedPath
                if ContentHasher.isFinalHash(value.hash) {
                    normalized[k] = value
                }
            }
            loaded.cachedFiles = normalized
        }
        
        hotLock.lock()
        hotCache = loaded
        hotLock.unlock()
        
        // Persist migrated location if we found a legacy path only
        if !FileManager.default.fileExists(atPath: cacheFileURL.path), !loaded.cachedFiles.isEmpty {
            saveCache(loaded)
        }
        return loaded
    }
    
    private func loadCacheFromURL(_ url: URL) -> ScanCache? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            if fileSize > 200 * 1024 * 1024 {
                return nil
            }
        } catch {
            return nil
        }
        
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        
        do {
            if useBinaryFormat {
                return try PropertyListDecoder().decode(ScanCache.self, from: data)
            } else {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ScanCache.self, from: data)
            }
        } catch {
            return nil
        }
    }
    
    private func getPossibleCachePaths() -> [URL] {
        var paths: [URL] = []
        
        let cacheFileName = useBinaryFormat ? "scan_cache.plist" : "scan_cache.json"
        let legacyFileName = "scan_cache.json"  // always look for the old JSON cache
        
        // 1. Home-directory cache
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        paths.append(homeDirectory.appendingPathComponent(".cache/finddup/\(cacheFileName)"))
        paths.append(homeDirectory.appendingPathComponent(".cache/finddup/\(legacyFileName)"))
        
        // 2. System caches directory
        if let systemCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            paths.append(systemCacheDir.appendingPathComponent("finddup/\(cacheFileName)"))
            paths.append(systemCacheDir.appendingPathComponent("finddup/\(legacyFileName)"))
        }
        
        // 3. Application Support
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(appSupportDir.appendingPathComponent("finddup/\(cacheFileName)"))
            paths.append(appSupportDir.appendingPathComponent("finddup/\(legacyFileName)"))
        }
        
        return paths.filter { $0 != cacheFileURL } // skip the live path
    }
    
    /// - Parameter syncDisk: when false, update memory immediately and encode/write on a utility queue
    ///   so large NAS scans are not blocked for tens of seconds on a 10MB+ plist.
    ///
    /// **Important:** Prefer `mergeAndSave` after a scan. Replacing the entire hot cache with a
    /// working copy loaded at scan start can **drop hashes from another volume** if two scans
    /// overlap, or if a home scan finishes after a NAS scan and overwrites with a stale base.
    func saveCache(_ cache: ScanCache, syncDisk: Bool = true) {
        hotLock.lock()
        hotCache = cache
        hotLock.unlock()
        writeCache(cache, syncDisk: syncDisk)
    }
    
    /// Merge this scan's cache working set into the global hot cache (and disk).
    /// - Upserts all keys from `working`
    /// - Removes only paths under `scanRoots` that are absent from `currentFiles`
    /// - Leaves entries for other roots untouched (e.g. keep `/Volumes/…` when scanning `~/`)
    func mergeAndSave(
        working: ScanCache,
        scanRoots: [URL],
        currentFiles: [FileInfo],
        syncDisk: Bool = false
    ) {
        let roots = scanRoots.map { $0.path.standardizedPath }
        let current = Set(currentFiles.map(\.pathKey))
        
        hotLock.lock()
        var base: ScanCache
        if let hot = hotCache {
            base = hot
        } else {
            hotLock.unlock()
            base = loadCache()
            hotLock.lock()
            base = hotCache ?? base
        }
        
        base.merge(
            working: working.cachedFiles,
            scanRoots: roots,
            currentPathKeys: current
        )
        hotCache = base
        let toWrite = base
        hotLock.unlock()
        
        writeCache(toWrite, syncDisk: syncDisk)
    }
    
    /// Upsert hashes mid-scan without running obsolete cleanup (safe progressive flush).
    func upsertEntries(_ entries: [String: CachedFileInfo], syncDisk: Bool = false) {
        guard !entries.isEmpty else { return }
        hotLock.lock()
        var base = hotCache ?? ScanCache()
        if hotCache == nil {
            hotLock.unlock()
            base = loadCache()
            hotLock.lock()
            base = hotCache ?? base
        }
        for (key, value) in entries {
            base.cachedFiles[key] = value
        }
        base.lastScanDate = Date()
        hotCache = base
        let toWrite = base
        hotLock.unlock()
        writeCache(toWrite, syncDisk: syncDisk)
    }
    
    private func writeCache(_ cache: ScanCache, syncDisk: Bool) {
        if syncDisk {
            persistCacheToDisk(cache)
            notifyDidChange()
        } else {
            let url = cacheFileURL
            let binary = useBinaryFormat
            Task.detached(priority: .utility) {
                Self.writeCacheFile(cache, to: url, binary: binary)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: ScanCacheManager.didChangeNotification,
                        object: ScanCacheManager.shared
                    )
                }
            }
            notifyDidChange()
        }
    }
    
    private func persistCacheToDisk(_ cache: ScanCache) {
        Self.writeCacheFile(cache, to: cacheFileURL, binary: useBinaryFormat)
    }
    
    private static func writeCacheFile(_ cache: ScanCache, to cacheFileURL: URL, binary: Bool) {
        do {
            let data: Data
            if binary {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                data = try encoder.encode(cache)
            } else {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                data = try encoder.encode(cache)
            }
            
            let tempURL = cacheFileURL.appendingPathExtension("tmp")
            try data.write(to: tempURL)
            if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                _ = try FileManager.default.replaceItem(
                    at: cacheFileURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: cacheFileURL)
            }
        } catch {
            // Silent fail — scan results still valid without durable cache
        }
    }
    
    /// Posted on the main queue after cache contents change (save / clear).
    static let didChangeNotification = Notification.Name("ScanCacheManager.didChange")
    
    private func notifyDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    
    func clearCache() {
        // Keep an empty hot cache so loadCache() does not resurrect a stale in-memory copy.
        hotLock.lock()
        hotCache = ScanCache()
        hotLock.unlock()
        #if DEBUG
        print("🗑️ Clearing cache file: \(cacheFileURL.path)")
        #endif
        do {
            if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                try FileManager.default.removeItem(at: cacheFileURL)
            }
            let tmp = cacheFileURL.appendingPathExtension("tmp")
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            #if DEBUG
            print("✅ Cache cleared successfully")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to clear cache: \(error)")
            #endif
        }
        notifyDidChange()
    }
    
    /// Run expiry / size cleanup and persist if anything was dropped.
    func performCacheMaintenance() -> ScanCache {
        #if DEBUG
        print("🔧 Performing cache maintenance...")
        #endif
        
        var cache = loadCache()
        let originalCount = cache.cachedFiles.count
        
        // Empty scan args → global expiry / cap cleanup only
        cache.cleanObsoleteEntries(currentFiles: [], scanPaths: [])
        
        let finalCount = cache.cachedFiles.count
        let cleanedCount = originalCount - finalCount
        
        if cleanedCount > 0 {
            #if DEBUG
            print("🧹 Maintenance completed:")
            #endif
            #if DEBUG
            print("   - Original entries: \(originalCount)")
            #endif
            #if DEBUG
            print("   - Cleaned entries: \(cleanedCount)")
            #endif
            #if DEBUG
            print("   - Final entries: \(finalCount)")
            #endif
            
            // Persist the cleaned cache
            saveCache(cache)
        } else {
            #if DEBUG
            print("✅ Cache is healthy, no maintenance needed")
            #endif
        }
        
        return cache
    }
    
    /// Cache health for diagnostics (not user-facing).
    func getCacheHealth() -> (isHealthy: Bool, issues: [String], recommendations: [String]) {
        let cache = loadCache()
        let stats = cache.getCacheStats()
        
        var issues: [String] = []
        var recommendations: [String] = []
        
        // Entry count
        if stats.totalEntries > 250_000 {
            issues.append("Too many cache entries (\(stats.totalEntries))")
            recommendations.append("Clear old cache or scan a smaller tree")
        }
        
        // Age
        if let oldest = stats.oldestEntry {
            let age = Date().timeIntervalSince(oldest)
            if age > 60 * 24 * 60 * 60 { // 60 days
                issues.append("Stale cache entries (\(Int(age / 86400)) days)")
                recommendations.append("Run cache maintenance to drop expired entries")
            }
        }
        
        // Estimated size
        if stats.estimatedSize > 250 * 1024 * 1024 { // 250 MB
            issues.append("Cache file is large (\(ByteCountFormatter.string(fromByteCount: stats.estimatedSize, countStyle: .file)))")
            recommendations.append("Clear the cache")
        }
        
        let isHealthy = issues.isEmpty
        return (isHealthy, issues, recommendations)
    }
    
    /// On-disk cache file URL.
    func getCacheFileURL() -> URL {
        return cacheFileURL
    }
    
    /// Live stats from the in-memory cache (falls back to disk load).
    func currentCacheStats() -> (totalEntries: Int, estimatedSize: Int64, oldestEntry: Date?, newestEntry: Date?) {
        loadCache().getCacheStats()
    }
}
