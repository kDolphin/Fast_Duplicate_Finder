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
    /// Whole-file precise fingerprints (`t128f:` / `pkgv:`). Not used as turbo group keys.
    var preciseFiles: [String: CachedFileInfo] = [:]
    var lastScanDate: Date = Date()
    
    enum CodingKeys: String, CodingKey {
        case cachedFiles, preciseFiles, lastScanDate
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cachedFiles = try c.decodeIfPresent([String: CachedFileInfo].self, forKey: .cachedFiles) ?? [:]
        preciseFiles = try c.decodeIfPresent([String: CachedFileInfo].self, forKey: .preciseFiles) ?? [:]
        lastScanDate = try c.decodeIfPresent(Date.self, forKey: .lastScanDate) ?? Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cachedFiles, forKey: .cachedFiles)
        try c.encode(preciseFiles, forKey: .preciseFiles)
        try c.encode(lastScanDate, forKey: .lastScanDate)
    }
    
    // Limits (per shard)
    static let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    static let shardSoftMaxEntries = 500_000
    static let shardSoftMaxBytes = 120 * 1024 * 1024
    static let shardHardMaxBytes = 200 * 1024 * 1024 // refuse to decode this file
    
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
        keepNewest(Self.shardSoftMaxEntries)
        keepNewestPrecise(Self.shardSoftMaxEntries)
    }
    
    /// Drop entries older than `maxCacheAge`.
    @discardableResult
    mutating func cleanExpiredEntries() -> Int {
        let now = Date()
        let expiredKeys = cachedFiles.compactMap { (key, value) in
            let age = now.timeIntervalSince(value.lastScanDate)
            return age > Self.maxCacheAge ? key : nil
        }
        
        for key in expiredKeys {
            cachedFiles.removeValue(forKey: key)
        }
        let expiredPrecise = preciseFiles.compactMap { (key, value) -> String? in
            now.timeIntervalSince(value.lastScanDate) > Self.maxCacheAge ? key : nil
        }
        for key in expiredPrecise {
            preciseFiles.removeValue(forKey: key)
        }
        
        return expiredKeys.count + expiredPrecise.count
    }
    
    /// Keep the most recently scanned entries.
    mutating func keepNewest(_ maxCount: Int) {
        guard cachedFiles.count > maxCount else { return }
        let sorted = cachedFiles.sorted { $0.value.lastScanDate > $1.value.lastScanDate }
        cachedFiles = Dictionary(uniqueKeysWithValues: sorted.prefix(maxCount).map { ($0.key, $0.value) })
    }
    
    mutating func keepNewestPrecise(_ maxCount: Int) {
        guard preciseFiles.count > maxCount else { return }
        let sorted = preciseFiles.sorted { $0.value.lastScanDate > $1.value.lastScanDate }
        preciseFiles = Dictionary(uniqueKeysWithValues: sorted.prefix(maxCount).map { ($0.key, $0.value) })
    }
    
    static func encodeBinary(_ cache: ScanCache) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(cache)
    }
    
    /// Expire + drop oldest until the encoded plist is at most `maxBytes`.
    mutating func slimForDisk(maxBytes: Int = Int(ScanCache.shardSoftMaxBytes)) -> Data {
        _ = cleanExpiredEntries()
        keepNewest(Self.shardSoftMaxEntries)
        keepNewestPrecise(Self.shardSoftMaxEntries)
        var data = Self.encodeBinary(self) ?? Data()
        var steps = 0
        while data.count > maxBytes && (cachedFiles.count > 2_000 || preciseFiles.count > 2_000) && steps < 12 {
            keepNewest(max(cachedFiles.count * 4 / 5, 2_000))
            keepNewestPrecise(max(preciseFiles.count * 4 / 5, 2_000))
            data = Self.encodeBinary(self) ?? Data()
            steps += 1
        }
        return data
    }
    
    /// Merge a scan working set. Drops only keys under `scanRoots` that are not
    /// in `currentPathKeys`; other volumes stay put.
    mutating func merge(
        working: [String: CachedFileInfo],
        precise: [String: CachedFileInfo] = [:],
        scanRoots: [String],
        currentPathKeys: Set<String>
    ) {
        for (key, value) in working {
            cachedFiles[key] = value
        }
        for (key, value) in precise {
            preciseFiles[key] = value
        }
        if !scanRoots.isEmpty {
            for path in Array(cachedFiles.keys) {
                let underRoot = scanRoots.contains { root in
                    path == root || path.hasPrefix(root + "/")
                }
                if underRoot && !currentPathKeys.contains(path) {
                    cachedFiles.removeValue(forKey: path)
                    preciseFiles.removeValue(forKey: path)
                }
            }
            for path in Array(preciseFiles.keys) where cachedFiles[path] == nil {
                let underRoot = scanRoots.contains { root in
                    path == root || path.hasPrefix(root + "/")
                }
                if underRoot && !currentPathKeys.contains(path) {
                    preciseFiles.removeValue(forKey: path)
                }
            }
        }
        lastScanDate = Date()
    }
    
    /// Cache statistics for Settings (entry count and age; file size is on disk).
    func getCacheStats() -> (totalEntries: Int, oldestEntry: Date?, newestEntry: Date?) {
        let dates = cachedFiles.values.map { $0.lastScanDate }
        return (cachedFiles.count, dates.min(), dates.max())
    }
}

