import Foundation

/// Build package-level scan items and silent content sentinels.
/// Packages stay opaque to normal file enumeration (`skipsPackageDescendants`);
/// we register one object per package and walk interior only for fingerprinting.
enum PackageScanner: Sendable {
    
    struct WalkSummary: Sendable {
        var totalSize: Int64
        var fileCount: Int
        /// Sorted (relativePath, size) for tree hash; also used to pick sentinels
        var entries: [(relPath: String, size: Int64)]
    }
    
    /// One metadata walk: total size + path/size tree fingerprint.
    /// When `hashCache` has a fresh entry (same package-root mtime), skip the interior walk.
    /// Pass `knownModificationDate` from the enumerator to avoid a second NAS metadata RTT.
    static func makePackageItem(
        at packageURL: URL,
        skipHidden: Bool,
        minSize: Int64,
        maxSize: Int64,
        hashCache: [String: CachedFileInfo]? = nil,
        knownModificationDate: Date? = nil,
        knownCreationDate: Date? = nil
    ) -> FileInfo? {
        let mod: Date
        let created: Date
        if let knownModificationDate {
            mod = knownModificationDate
            created = knownCreationDate ?? knownModificationDate
        } else {
            let values = try? packageURL.resourceValues(forKeys: [
                .contentModificationDateKey, .creationDateKey
            ])
            mod = values?.contentModificationDate
                ?? values?.creationDate
                ?? Date(timeIntervalSince1970: 0)
            created = values?.creationDate ?? mod
        }
        let pathKey = packageURL.path.standardizedPath
        let modSec = Int64(mod.timeIntervalSince1970)
        
        // Fast path: package root mtime unchanged → reuse cached size + fingerprint
        if let cache = hashCache,
           let cached = cache[pathKey],
           ContentHasher.isFinalHash(cached.hash),
           cached.mtimeSec == modSec,
           cached.size > 0,
           cached.size >= minSize,
           cached.size <= maxSize {
            return FileInfo(
                url: packageURL,
                size: cached.size,
                modificationDate: mod,
                creationDate: created,
                isPackage: true,
                precomputedHash: cached.hash
            )
        }
        
        guard let summary = walk(packageURL: packageURL, skipHidden: skipHidden) else {
            return nil
        }
        guard summary.totalSize > 0 else { return nil }
        guard summary.totalSize >= minSize && summary.totalSize <= maxSize else {
            return nil
        }
        
        let treeHash = treeFingerprint(entries: summary.entries)
        
        return FileInfo(
            url: packageURL,
            size: summary.totalSize,
            modificationDate: mod,
            creationDate: created,
            isPackage: true,
            precomputedHash: treeHash
        )
    }
    
    /// Stronger package content fingerprint (used by “precise compare” on package groups).
    static func strongContentFingerprint(packageURL: URL, skipHidden: Bool) -> String? {
        guard let summary = walk(packageURL: packageURL, skipHidden: skipHidden),
              !summary.entries.isEmpty else {
            return nil
        }
        var h0 = XXHash64(seed: 2)
        var h1 = XXHash64(seed: 3)
        withUnsafeBytes(of: Int64(summary.totalSize).bigEndian) { raw in
            let d = Data(raw)
            h0.update(d)
            h1.update(d)
        }
        for entry in summary.entries {
            let header = "\(entry.relPath)|\(entry.size)\n"
            if let hd = header.data(using: .utf8) {
                h0.update(hd)
                h1.update(hd)
            }
            let fileURL = packageURL.appendingPathComponent(entry.relPath)
            if let sample = sampleFileContent(url: fileURL, size: entry.size) {
                h0.update(sample)
                h1.update(sample)
            }
        }
        return "pkgv:" + String(format: "%016llx%016llx", h0.digest(), h1.digest())
    }
    
    /// Silent content confirmation for packages that already share a tree fingerprint.
    /// Returns a content fingerprint string (or nil on failure).
    static func sentinelFingerprint(packageURL: URL, skipHidden: Bool) -> String? {
        guard let summary = walk(packageURL: packageURL, skipHidden: skipHidden),
              !summary.entries.isEmpty else {
            return nil
        }
        
        let sentinels = pickSentinels(from: summary.entries)
        var h0 = XXHash64(seed: 0)
        var h1 = XXHash64(seed: 1)
        withUnsafeBytes(of: Int64(summary.totalSize).bigEndian) { raw in
            let d = Data(raw)
            h0.update(d)
            h1.update(d)
        }
        
        let rootPath = packageURL.path
        for entry in sentinels {
            let fileURL = packageURL.appendingPathComponent(entry.relPath)
            // Domain-separate each sentinel
            let header = "\(entry.relPath)|\(entry.size)\n"
            if let hd = header.data(using: .utf8) {
                h0.update(hd)
                h1.update(hd)
            }
            guard let sample = sampleFileContent(url: fileURL, size: entry.size) else {
                continue
            }
            h0.update(sample)
            h1.update(sample)
            _ = rootPath
        }
        
        return "pkgv:" + String(format: "%016llx%016llx", h0.digest(), h1.digest())
    }
    
    // MARK: - Walk
    
    private static func walk(packageURL: URL, skipHidden: Bool) -> WalkSummary? {
        var options: FileManager.DirectoryEnumerationOptions = []
        if skipHidden {
            options.insert(.skipsHiddenFiles)
        }
        // Descend into nested packages (.framework inside .app) for a complete tree
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return nil
        }
        
        let root = packageURL.standardizedFileURL.path
        var entries: [(String, Int64)] = []
        var total: Int64 = 0
        
        while let url = enumerator.nextObject() as? URL {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size > 0 else { continue }
                
                let full = url.standardizedFileURL.path
                // Relative path from package root
                var rel: String
                if full.hasPrefix(root) {
                    rel = String(full.dropFirst(root.count))
                    if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                } else {
                    rel = url.lastPathComponent
                }
                rel = rel.precomposedStringWithCanonicalMapping
                entries.append((rel, size))
                total += size
            } catch {
                continue
            }
        }
        
        entries.sort { $0.0 < $1.0 }
        return WalkSummary(totalSize: total, fileCount: entries.count, entries: entries)
    }
    
    private static func treeFingerprint(entries: [(relPath: String, size: Int64)]) -> String {
        var h0 = XXHash64(seed: 0)
        var h1 = XXHash64(seed: 1)
        withUnsafeBytes(of: Int64(entries.count).bigEndian) { raw in
            let d = Data(raw)
            h0.update(d)
            h1.update(d)
        }
        for e in entries {
            let line = "\(e.relPath)|\(e.size)\n"
            if let data = line.data(using: .utf8) {
                h0.update(data)
                h1.update(data)
            }
        }
        return "pkg:" + String(format: "%016llx%016llx", h0.digest(), h1.digest())
    }
    
    private static func pickSentinels(
        from entries: [(relPath: String, size: Int64)]
    ) -> [(relPath: String, size: Int64)] {
        guard !entries.isEmpty else { return [] }
        if entries.count <= 5 { return entries }
        
        var picks: [(String, Int64)] = []
        let first = entries[0]
        let mid = entries[entries.count / 2]
        let last = entries[entries.count - 1]
        picks.append(first)
        if mid.relPath != first.relPath { picks.append(mid) }
        if last.relPath != mid.relPath && last.relPath != first.relPath {
            picks.append(last)
        }
        
        // Prefer a few “important” names if present
        let preferredSuffixes = [
            "info.plist", "contents.json", "index.bdmv", "movieobject.bdmv"
        ]
        for e in entries {
            let lower = e.relPath.lowercased()
            if preferredSuffixes.contains(where: { lower.hasSuffix($0) }) {
                if !picks.contains(where: { $0.0 == e.relPath }) {
                    picks.append(e)
                }
            }
            if picks.count >= 6 { break }
        }
        
        // Largest file (often main media inside disc package)
        if let largest = entries.max(by: { $0.size < $1.size }) {
            if !picks.contains(where: { $0.0 == largest.relPath }) {
                picks.append(largest)
            }
        }
        
        return picks
    }
    
    private static func sampleFileContent(url: URL, size: Int64) -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let n = Int(size)
            if n <= 256 * 1024 {
                return handle.readData(ofLength: n)
            }
            var out = Data()
            let sample = 64 * 1024
            try handle.seek(toOffset: 0)
            out.append(handle.readData(ofLength: sample))
            try handle.seek(toOffset: UInt64(max(0, n / 2 - sample / 2)))
            out.append(handle.readData(ofLength: sample))
            try handle.seek(toOffset: UInt64(max(0, n - sample)))
            out.append(handle.readData(ofLength: sample))
            return out
        } catch {
            return nil
        }
    }
}
