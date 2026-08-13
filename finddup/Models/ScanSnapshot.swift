import Foundation

/// Full-scan result snapshot: if the same roots yield the same file list
/// (path + size + mtime seconds), reuse groups without re-hashing.
struct ScanResultSnapshot: Codable, Sendable {
    var rootKeys: [String]
    var listSignature: String
    var fileCount: Int
    var totalSize: Int64
    var groups: [StoredDuplicateGroup]
    var savedAt: Date
    /// ScanMode.rawValue — different modes must not reuse each other's groups
    var scanMode: String
    
    struct StoredDuplicateGroup: Codable, Sendable {
        var hash: String
        var fileSize: Int64
        var paths: [String]
    }
    
    enum CodingKeys: String, CodingKey {
        case rootKeys, listSignature, fileCount, totalSize, groups, savedAt, scanMode
    }
    
    init(
        rootKeys: [String],
        listSignature: String,
        fileCount: Int,
        totalSize: Int64,
        groups: [StoredDuplicateGroup],
        savedAt: Date,
        scanMode: String
    ) {
        self.rootKeys = rootKeys
        self.listSignature = listSignature
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.groups = groups
        self.savedAt = savedAt
        self.scanMode = scanMode
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootKeys = try c.decode([String].self, forKey: .rootKeys)
        listSignature = try c.decode(String.self, forKey: .listSignature)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        totalSize = try c.decode(Int64.self, forKey: .totalSize)
        groups = try c.decode([StoredDuplicateGroup].self, forKey: .groups)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        scanMode = try c.decodeIfPresent(String.self, forKey: .scanMode) ?? ScanMode.turbo.rawValue
    }
    
    static func rootKeys(from urls: [URL]) -> [String] {
        urls.map { $0.path.standardizedPath }.sorted()
    }
    
    /// Order-independent signature (no full-list sort). Whole-second mtimes.
    /// Dual xxHash64 XOR + count/totalSize — fast enough for 100k+ NAS lists
    /// (SHA256-per-file used to stall the UI for minutes on “Processing cache…”).
    static func listSignature(for files: [FileInfo]) -> String {
        var xor0: UInt64 = 0
        var xor1: UInt64 = 0
        var totalSize: Int64 = 0
        for f in files {
            totalSize += f.size
            let sec = Int64(f.modificationDate.timeIntervalSince1970)
            // Mix path|size|mtime without allocating a joined String each time.
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
        // Domain-separate list cardinality / payload size so empty vs non-empty differ.
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
    
    static func build(
        roots: [URL],
        files: [FileInfo],
        groups: [DuplicateGroup],
        mode: ScanMode
    ) -> ScanResultSnapshot {
        ScanResultSnapshot(
            rootKeys: rootKeys(from: roots),
            listSignature: listSignature(for: files),
            fileCount: files.count,
            totalSize: files.reduce(0) { $0 + $1.size },
            groups: groups.map { g in
                StoredDuplicateGroup(
                    hash: g.hash,
                    fileSize: g.fileSize,
                    paths: g.files.map(\.pathKey)
                )
            },
            savedAt: Date(),
            scanMode: mode.rawValue
        )
    }
    
    /// Prefer signature + mode match; roots soft-canonicalized.
    func matches(roots: [String], signature: String, mode: ScanMode) -> Bool {
        guard listSignature == signature else { return false }
        guard scanMode == mode.rawValue else { return false }
        if rootKeys.isEmpty || roots.isEmpty { return true }
        return Set(rootKeys.map { $0.standardizedPath }) == Set(roots.map { $0.standardizedPath })
    }
    
    /// Rebuild live groups using current FileInfo objects (same paths).
    func materialize(using files: [FileInfo]) -> [DuplicateGroup]? {
        var byPath: [String: FileInfo] = [:]
        byPath.reserveCapacity(files.count)
        for f in files {
            byPath[f.pathKey] = f
            // Also index raw path in case older snapshots used non-canonical keys
            byPath[f.url.path.standardizedPath] = f
        }
        var result: [DuplicateGroup] = []
        for g in groups {
            var members: [FileInfo] = []
            members.reserveCapacity(g.paths.count)
            for p in g.paths {
                let key = p.standardizedPath
                guard let f = byPath[key] ?? byPath[p] else { return nil }
                members.append(f)
            }
            guard members.count >= 2 else { return nil }
            let mismatch = PackageIdentity.hasIdentityMismatch(packages: members)
            result.append(DuplicateGroup(
                files: members,
                fileSize: g.fileSize,
                hash: g.hash,
                needsReview: mismatch,
                isVerified: false,
                packageIdentityMismatch: mismatch
            ))
        }
        return result.sorted { $0.duplicateSize > $1.duplicateSize }
    }
}

enum ScanSnapshotStore {
    /// v2: only complete scans publish snapshots. v1 files may contain incomplete
    /// groups written after cancel and are intentionally ignored.
    private static let fileName = "last_scan_snapshot_v2.plist"
    private static let hotLock = NSLock()
    private static var hotSnapshot: ScanResultSnapshot?
    
    /// Prefer Application Support (not purged like Caches).
    private static var fileURLs: [URL] {
        var urls: [URL] = []
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("finddup", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent(fileName))
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("finddup", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent(fileName))
        }
        return urls
    }
    
    static func load() -> ScanResultSnapshot? {
        hotLock.lock()
        if let hotSnapshot {
            let snap = hotSnapshot
            hotLock.unlock()
            return snap
        }
        hotLock.unlock()
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? PropertyListDecoder().decode(ScanResultSnapshot.self, from: data) else {
                continue
            }
            hotLock.lock()
            hotSnapshot = snap
            hotLock.unlock()
            return snap
        }
        return nil
    }
    
    static func save(_ snapshot: ScanResultSnapshot, syncDisk: Bool = true) {
        hotLock.lock()
        hotSnapshot = snapshot
        hotLock.unlock()
        if syncDisk {
            writeToDisk(snapshot)
        } else {
            Task.detached(priority: .utility) {
                writeToDisk(snapshot)
            }
        }
    }
    
    private static func writeToDisk(_ snapshot: ScanResultSnapshot) {
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        for url in fileURLs {
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
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }
    
    static func clear() {
        hotLock.lock()
        hotSnapshot = nil
        hotLock.unlock()
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
