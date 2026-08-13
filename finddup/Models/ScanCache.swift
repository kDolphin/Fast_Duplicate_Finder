import Foundation

// MARK: - 路径标准化工具
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

// MARK: - 缓存文件信息
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

// MARK: - 扫描缓存
struct ScanCache: Codable {
    var cachedFiles: [String: CachedFileInfo] = [:]
    var lastScanDate: Date = Date()
    
    // 缓存配置
    private static let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60 // 30天
    private static let maxCacheEntries = 2_000_000 // 最大缓存条目数
    private static let maxCacheSize: Int64 = 300 * 1024 * 1024 // 300MB估算大小
    
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
    
    /// 清理过期的缓存条目
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
    
    /// 清理超出大小限制的缓存条目
    private mutating func cleanOversizeEntries() -> Int {
        guard cachedFiles.count > Self.maxCacheEntries else { return 0 }
        
        // 按最后扫描时间排序，保留最新的
        let sortedEntries = cachedFiles.sorted { $0.value.lastScanDate > $1.value.lastScanDate }
        let entriesToKeep = sortedEntries.prefix(Self.maxCacheEntries)
        let entriesToRemove = sortedEntries.dropFirst(Self.maxCacheEntries)
        
        // 重建缓存字典
        let newCachedFiles = Dictionary(uniqueKeysWithValues: entriesToKeep.map { ($0.key, $0.value) })
        cachedFiles = newCachedFiles
        
        return entriesToRemove.count
    }
    
    /// 获取缓存统计信息
    func getCacheStats() -> (totalEntries: Int, estimatedSize: Int64, oldestEntry: Date?, newestEntry: Date?) {
        let totalEntries = cachedFiles.count
        
        // 估算缓存大小 (每个条目约1KB)
        let estimatedSize = Int64(totalEntries * 1024)
        
        let dates = cachedFiles.values.map { $0.lastScanDate }
        let oldestEntry = dates.min()
        let newestEntry = dates.max()
        
        return (totalEntries, estimatedSize, oldestEntry, newestEntry)
    }
}

// MARK: - 缓存管理器
class ScanCacheManager {
    static let shared = ScanCacheManager()
    
    private let cacheFileURL: URL
    private let useBinaryFormat = true  // 使用二进制格式
    /// Avoid re-decoding a multi‑MB plist on every scan (hot path for large NAS libraries).
    private var hotCache: ScanCache?
    private let hotLock = NSLock()
    
    init() {
        // 获取应用信息用于调试
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
        
        // 在沙盒环境中，使用应用的缓存目录
        let cacheDirectory: URL
        if let appCacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = appCacheDirectory.appendingPathComponent("finddup")
            #if DEBUG
            print("   - Using app cache directory: \(appCacheDirectory.path)")
            #endif
        } else {
            // 备用方案：使用用户主目录（非沙盒环境）
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
        
        // 检查缓存文件是否存在
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
        let legacyFileName = "scan_cache.json"  // 总是检查JSON格式的旧缓存
        
        // 1. 用户主目录缓存
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        paths.append(homeDirectory.appendingPathComponent(".cache/finddup/\(cacheFileName)"))
        paths.append(homeDirectory.appendingPathComponent(".cache/finddup/\(legacyFileName)"))
        
        // 2. 系统缓存目录
        if let systemCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            paths.append(systemCacheDir.appendingPathComponent("finddup/\(cacheFileName)"))
            paths.append(systemCacheDir.appendingPathComponent("finddup/\(legacyFileName)"))
        }
        
        // 3. 应用支持目录
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(appSupportDir.appendingPathComponent("finddup/\(cacheFileName)"))
            paths.append(appSupportDir.appendingPathComponent("finddup/\(legacyFileName)"))
        }
        
        return paths.filter { $0 != cacheFileURL } // 排除当前路径
    }
    
    /// - Parameter syncDisk: when false, update memory immediately and encode/write on a utility queue
    ///   so large NAS scans are not blocked for tens of seconds on a 10MB+ plist.
    func saveCache(_ cache: ScanCache, syncDisk: Bool = true) {
        hotLock.lock()
        hotCache = cache
        hotLock.unlock()
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
            // UI can refresh from hot cache immediately (disk write still in flight).
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
    
    /// 缓存健康检查和维护
    func performCacheMaintenance() -> ScanCache {
        #if DEBUG
        print("🔧 Performing cache maintenance...")
        #endif
        
        var cache = loadCache()
        let originalCount = cache.cachedFiles.count
        
        // 执行维护清理 - 创建空的扫描参数来触发全局清理
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
            
            // 保存清理后的缓存
            saveCache(cache)
        } else {
            #if DEBUG
            print("✅ Cache is healthy, no maintenance needed")
            #endif
        }
        
        return cache
    }
    
    /// 获取缓存健康状态
    func getCacheHealth() -> (isHealthy: Bool, issues: [String], recommendations: [String]) {
        let cache = loadCache()
        let stats = cache.getCacheStats()
        
        var issues: [String] = []
        var recommendations: [String] = []
        
        // 检查缓存大小
        if stats.totalEntries > 250_000 {
            issues.append("缓存条目过多 (\(stats.totalEntries))")
            recommendations.append("考虑清理旧缓存或减少扫描范围")
        }
        
        // 检查缓存年龄
        if let oldest = stats.oldestEntry {
            let age = Date().timeIntervalSince(oldest)
            if age > 60 * 24 * 60 * 60 { // 60天
                issues.append("存在过旧的缓存条目 (\(Int(age / 86400))天)")
                recommendations.append("运行缓存维护清理过期条目")
            }
        }
        
        // 检查估算大小
        if stats.estimatedSize > 250 * 1024 * 1024 { // 250MB
            issues.append("缓存文件过大 (\(ByteCountFormatter.string(fromByteCount: stats.estimatedSize, countStyle: .file)))")
            recommendations.append("执行缓存清理")
        }
        
        let isHealthy = issues.isEmpty
        return (isHealthy, issues, recommendations)
    }
    
    /// 获取缓存文件URL
    func getCacheFileURL() -> URL {
        return cacheFileURL
    }
    
    /// Live stats from the in-memory cache (falls back to disk load).
    func currentCacheStats() -> (totalEntries: Int, estimatedSize: Int64, oldestEntry: Date?, newestEntry: Date?) {
        loadCache().getCacheStats()
    }
}
