import Foundation
import CryptoKit

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
    /// XOR of per-file digests + count/totalSize so reordering does not change the result.
    static func listSignature(for files: [FileInfo]) -> String {
        var xor = [UInt8](repeating: 0, count: 32)
        var totalSize: Int64 = 0
        for f in files {
            totalSize += f.size
            var h = SHA256()
            let sec = Int64(f.modificationDate.timeIntervalSince1970)
            var line = f.pathKey
            line += "|"
            line += String(f.size)
            line += "|"
            line += String(sec)
            if let data = line.data(using: .utf8) {
                h.update(data: data)
            }
            let digest = h.finalize()
            var i = 0
            for b in digest {
                xor[i] ^= b
                i += 1
            }
        }
        var outer = SHA256()
        withUnsafeBytes(of: Int64(files.count).bigEndian) { outer.update(bufferPointer: $0) }
        withUnsafeBytes(of: totalSize.bigEndian) { outer.update(bufferPointer: $0) }
        outer.update(data: Data(xor))
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
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
    /// Prefer Application Support (not purged like Caches).
    private static var fileURLs: [URL] {
        var urls: [URL] = []
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("finddup", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent("last_scan_snapshot.plist"))
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("finddup", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent("last_scan_snapshot.plist"))
        }
        return urls
    }
    
    static func load() -> ScanResultSnapshot? {
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? PropertyListDecoder().decode(ScanResultSnapshot.self, from: data) else {
                continue
            }
            return snap
        }
        return nil
    }
    
    static func save(_ snapshot: ScanResultSnapshot) {
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
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
