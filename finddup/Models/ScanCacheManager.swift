import Foundation

private struct CacheShardIndex: Codable {
    var shards: [String: Entry] = [:]
    
    struct Entry: Codable {
        var entries: Int
        var oldest: Date?
        var newest: Date?
    }
}

/// Per-volume shard files (`scan_cache_u-<uuid>.plist`). Loads only shards needed
/// for the current scan roots. Slims each shard on write so a single file stays
/// under the 200 MB decode fuse.
class ScanCacheManager {
    static let shared = ScanCacheManager()
    
    static let didChangeNotification = Notification.Name("ScanCacheManager.didChange")
    
    private let cacheDirectory: URL
    private let indexURL: URL
    private let lock = NSLock()
    /// In-memory shards keyed by `CacheShardID.token`.
    private var loaded: [String: ScanCache] = [:]
    private var didMigrate = false
    
    init() {
        let base: URL
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = caches.appendingPathComponent("finddup")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/finddup")
        }
        cacheDirectory = base
        indexURL = base.appendingPathComponent("scan_cache_index.plist")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    
    // MARK: - Public
    
    func cacheDirectoryURL() -> URL { cacheDirectory }
    
    /// Settings still calls this; show the cache folder (multiple shard files).
    func getCacheFileURL() -> URL { cacheDirectory }
    
    func migrateIfNeeded() {
        lock.lock()
        if didMigrate {
            lock.unlock()
            return
        }
        didMigrate = true
        lock.unlock()
        migrateLegacyMonolith()
    }
    
    func preloadInBackground() {
        Task.detached(priority: .utility) {
            ScanCacheManager.shared.migrateIfNeeded()
        }
    }
    
    func areShardsReady(for roots: [URL]) -> Bool {
        let tokens = Set(roots.flatMap { CacheShardID.lookupIDs(for: $0).map(\.token) })
        lock.lock()
        defer { lock.unlock() }
        return tokens.allSatisfy { loaded[$0] != nil }
    }
    
    /// Union of shards for `roots` (UUID + path fallback). Used as the working map.
    func loadCache(for roots: [URL]) -> ScanCache {
        migrateIfNeeded()
        var union = ScanCache()
        var seen = Set<String>()
        for root in roots {
            for id in CacheShardID.lookupIDs(for: root) where seen.insert(id.token).inserted {
                let shard = loadShard(id)
                for (key, value) in shard.cachedFiles {
                    union.cachedFiles[key] = value
                }
                for (key, value) in shard.preciseFiles {
                    union.preciseFiles[key] = value
                }
            }
        }
        return union
    }
    
    /// Back-compat: in-memory union of already-loaded shards (does not open every file).
    func loadCache() -> ScanCache {
        migrateIfNeeded()
        lock.lock()
        let copy = loaded
        lock.unlock()
        var union = ScanCache()
        for shard in copy.values {
            for (key, value) in shard.cachedFiles {
                union.cachedFiles[key] = value
            }
            for (key, value) in shard.preciseFiles {
                union.preciseFiles[key] = value
            }
        }
        return union
    }
    
    func mergeAndSave(
        working: ScanCache,
        scanRoots: [URL],
        currentFiles: [FileInfo],
        syncDisk: Bool = false
    ) {
        migrateIfNeeded()
        let current = Set(currentFiles.map(\.pathKey))
        let buckets = bucket(working.cachedFiles)
        let preciseBuckets = bucket(working.preciseFiles)
        var tokens = Set(buckets.keys).union(preciseBuckets.keys)
        for root in scanRoots {
            for id in CacheShardID.lookupIDs(for: root) {
                tokens.insert(id.token)
            }
        }
        
        let primaryByRoot = scanRoots.map { (root: $0, id: CacheShardID.id(for: $0)) }
        
        for token in tokens {
            let id = CacheShardID(token: token)
            var shard = loadShard(id)
            let work = buckets[token] ?? [:]
            let rootsForShard = primaryByRoot
                .filter { $0.id.token == token || CacheShardID.fallback(forPath: $0.root.path).token == token }
                .map { $0.root.path.standardizedPath }
            shard.merge(
                working: work,
                precise: preciseBuckets[token] ?? [:],
                scanRoots: rootsForShard,
                currentPathKeys: current
            )
            storeAndWrite(id, shard, syncDisk: syncDisk)
        }
        
        absorbFallbacks(scanRoots: scanRoots, syncDisk: syncDisk)
        notifyDidChange()
    }
    
    func upsertPrecise(_ entries: [String: CachedFileInfo], syncDisk: Bool = true) {
        guard !entries.isEmpty else { return }
        migrateIfNeeded()
        let buckets = bucket(entries)
        for (token, work) in buckets {
            let id = CacheShardID(token: token)
            var shard = loadShard(id)
            for (key, value) in work {
                shard.preciseFiles[key] = value
            }
            shard.lastScanDate = Date()
            storeAndWrite(id, shard, syncDisk: syncDisk)
        }
        notifyDidChange()
    }
    
    func upsertEntries(_ entries: [String: CachedFileInfo], syncDisk: Bool = false) {
        guard !entries.isEmpty else { return }
        migrateIfNeeded()
        let buckets = bucket(entries)
        for (token, work) in buckets {
            let id = CacheShardID(token: token)
            var shard = loadShard(id)
            for (key, value) in work {
                shard.cachedFiles[key] = value
            }
            shard.lastScanDate = Date()
            storeAndWrite(id, shard, syncDisk: syncDisk)
        }
        notifyDidChange()
    }
    
    func saveCache(_ cache: ScanCache, syncDisk: Bool = true) {
        // Split a flat map (legacy callers / maintenance) into shards.
        mergeAndSave(working: cache, scanRoots: [], currentFiles: [], syncDisk: syncDisk)
    }
    
    func clearCache() {
        lock.lock()
        loaded.removeAll()
        lock.unlock()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in files {
                let name = url.lastPathComponent
                if name.hasPrefix("scan_cache") {
                    try? fm.removeItem(at: url)
                }
            }
        }
        writeIndex(CacheShardIndex())
        notifyDidChange()
    }
    
    func onDiskFileSize() -> Int64 {
        shardFileURLs().reduce(0) { $0 + fileSize(at: $1) }
    }
    
    func currentCacheStats() -> (totalEntries: Int, fileSize: Int64, oldestEntry: Date?, newestEntry: Date?) {
        migrateIfNeeded()
        let index = readIndex()
        let entries = index.shards.values.reduce(0) { $0 + $1.entries }
        let oldest = index.shards.values.compactMap(\.oldest).min()
        let newest = index.shards.values.compactMap(\.newest).max()
        return (entries, onDiskFileSize(), oldest, newest)
    }
    
    func performCacheMaintenance() -> ScanCache {
        migrateIfNeeded()
        for url in shardFileURLs() {
            guard let token = tokenFromFileName(url.lastPathComponent) else { continue }
            let id = CacheShardID(token: token)
            var shard = loadShard(id)
            let before = shard.cachedFiles.count
            _ = shard.cleanExpiredEntries()
            if shard.cachedFiles.count != before {
                storeAndWrite(id, shard, syncDisk: true)
            }
        }
        notifyDidChange()
        return loadCache()
    }
    
    func getCacheHealth() -> (isHealthy: Bool, issues: [String], recommendations: [String]) {
        let stats = currentCacheStats()
        var issues: [String] = []
        var recommendations: [String] = []
        if stats.fileSize > 250 * 1024 * 1024 {
            issues.append("Cache files are large (\(ByteCountFormatter.string(fromByteCount: stats.fileSize, countStyle: .file)))")
            recommendations.append("Clear the cache")
        }
        return (issues.isEmpty, issues, recommendations)
    }
    
    // MARK: - Shards
    
    private func loadShard(_ id: CacheShardID) -> ScanCache {
        lock.lock()
        if let hit = loaded[id.token] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        
        var shard = decodeShardFile(fileURL(for: id)) ?? ScanCache()
        if !shard.cachedFiles.isEmpty {
            var normalized: [String: CachedFileInfo] = [:]
            normalized.reserveCapacity(shard.cachedFiles.count)
            for (key, value) in shard.cachedFiles {
                let k = key.standardizedPath
                if ContentHasher.isFinalHash(value.hash) {
                    normalized[k] = value
                }
            }
            shard.cachedFiles = normalized
        }
        if !shard.preciseFiles.isEmpty {
            var normalized: [String: CachedFileInfo] = [:]
            for (key, value) in shard.preciseFiles {
                let k = key.standardizedPath
                if ContentHasher.isPreciseHash(value.hash) {
                    normalized[k] = value
                }
            }
            shard.preciseFiles = normalized
        }
        
        lock.lock()
        loaded[id.token] = shard
        lock.unlock()
        return shard
    }
    
    private func storeAndWrite(_ id: CacheShardID, _ shard: ScanCache, syncDisk: Bool) {
        var slimmed = shard
        let data = slimmed.slimForDisk()
        lock.lock()
        loaded[id.token] = slimmed
        lock.unlock()
        
        let url = fileURL(for: id)
        let write = {
            Self.writeData(data, to: url)
        }
        if syncDisk {
            write()
            updateIndex(id: id, shard: slimmed)
        } else {
            updateIndex(id: id, shard: slimmed)
            Task.detached(priority: .utility) {
                write()
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: ScanCacheManager.didChangeNotification,
                        object: ScanCacheManager.shared
                    )
                }
            }
        }
    }
    
    private func absorbFallbacks(scanRoots: [URL], syncDisk: Bool) {
        for root in scanRoots {
            let primary = CacheShardID.id(for: root)
            let fallback = CacheShardID.fallback(forPath: root.path)
            guard primary.token != fallback.token else { continue }
            lock.lock()
            let fallbackCache = loaded[fallback.token]
            lock.unlock()
            guard let fallbackCache, !fallbackCache.cachedFiles.isEmpty else { continue }
            
            var dest = loadShard(primary)
            for (key, value) in fallbackCache.cachedFiles {
                dest.cachedFiles[key] = value
            }
            storeAndWrite(primary, dest, syncDisk: syncDisk)
            
            lock.lock()
            loaded[fallback.token] = ScanCache()
            lock.unlock()
            try? FileManager.default.removeItem(at: fileURL(for: fallback))
            var index = readIndex()
            index.shards.removeValue(forKey: fallback.token)
            writeIndex(index)
        }
    }
    
    private func bucket(_ entries: [String: CachedFileInfo]) -> [String: [String: CachedFileInfo]] {
        var out: [String: [String: CachedFileInfo]] = [:]
        for (path, info) in entries {
            let token = CacheShardID.id(forPath: path).token
            out[token, default: [:]][path] = info
        }
        return out
    }
    
    private func fileURL(for id: CacheShardID) -> URL {
        cacheDirectory.appendingPathComponent(id.fileName)
    }
    
    private func decodeShardFile(_ url: URL) -> ScanCache? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = fileSize(at: url)
        if size > Int64(ScanCache.shardHardMaxBytes) { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(ScanCache.self, from: data)
    }
    
    private static func writeData(_ data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItem(
                    at: url,
                    withItemAt: tmp,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
    
    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
    
    private func shardFileURLs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("scan_cache_") && $0.pathExtension == "plist"
                && $0.lastPathComponent != "scan_cache_index.plist"
                && $0.lastPathComponent != "scan_cache.plist"
        }
    }
    
    private func tokenFromFileName(_ name: String) -> String? {
        guard name.hasPrefix("scan_cache_"), name.hasSuffix(".plist") else { return nil }
        let mid = name.dropFirst("scan_cache_".count).dropLast(".plist".count)
        if mid.isEmpty || mid == "index" { return nil }
        return String(mid)
    }
    
    // MARK: - Legacy monolith → shards
    
    private func migrateLegacyMonolith() {
        let candidates = [
            cacheDirectory.appendingPathComponent("scan_cache.plist"),
            cacheDirectory.appendingPathComponent("scan_cache.json")
        ] + legacySearchPaths()
        
        var source: ScanCache?
        var sourceURL: URL?
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let cache = decodeShardFile(url) ?? decodeJSON(url) {
                source = cache
                sourceURL = url
                break
            }
        }
        guard var cache = source else { return }
        
        var normalized: [String: CachedFileInfo] = [:]
        for (key, value) in cache.cachedFiles {
            let k = key.standardizedPath
            if ContentHasher.isFinalHash(value.hash) {
                normalized[k] = value
            }
        }
        cache.cachedFiles = normalized
        
        let buckets = bucket(cache.cachedFiles)
        for (token, files) in buckets {
            var shard = ScanCache()
            shard.cachedFiles = files
            shard.lastScanDate = cache.lastScanDate
            storeAndWrite(CacheShardID(token: token), shard, syncDisk: true)
        }
        
        if let sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        notifyDidChange()
    }
    
    private func decodeJSON(_ url: URL) -> ScanCache? {
        guard url.pathExtension == "json",
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanCache.self, from: data)
    }
    
    private func legacySearchPaths() -> [URL] {
        var paths: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".cache/finddup/scan_cache.plist"))
        paths.append(home.appendingPathComponent(".cache/finddup/scan_cache.json"))
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(appSupport.appendingPathComponent("finddup/scan_cache.plist"))
            paths.append(appSupport.appendingPathComponent("finddup/scan_cache.json"))
        }
        return paths.filter { $0.deletingLastPathComponent() != cacheDirectory }
    }
    
    // MARK: - Index
    
    private func readIndex() -> CacheShardIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? PropertyListDecoder().decode(CacheShardIndex.self, from: data) else {
            return CacheShardIndex()
        }
        return index
    }
    
    private func writeIndex(_ index: CacheShardIndex) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
    
    private func updateIndex(id: CacheShardID, shard: ScanCache) {
        lock.lock()
        var index = readIndex()
        let stats = shard.getCacheStats()
        index.shards[id.token] = CacheShardIndex.Entry(
            entries: stats.totalEntries,
            oldest: stats.oldestEntry,
            newest: stats.newestEntry
        )
        writeIndex(index)
        lock.unlock()
    }
    
    private func notifyDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
