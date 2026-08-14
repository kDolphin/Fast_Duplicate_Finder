import Foundation

/// One on-disk cache file per volume. Prefer the volume UUID so remounts stay stable;
/// fall back to a path prefix when the volume is offline.
struct CacheShardID: Hashable, Sendable {
    let token: String
    
    var fileName: String {
        "scan_cache_\(token).plist"
    }
    
    /// Primary id for a live URL (mounted volume).
    static func id(for url: URL) -> CacheShardID {
        if let uuid = volumeUUID(url) {
            return CacheShardID(token: "u-\(uuid)")
        }
        return fallback(forPath: url.path)
    }
    
    /// Ids to open when scanning `url` — UUID plus path fallback so a migrate-while-unmounted
    /// shard is still found and can be absorbed into the UUID file.
    static func lookupIDs(for url: URL) -> [CacheShardID] {
        let primary = id(for: url)
        let fallbackID = fallback(forPath: url.path)
        if fallbackID.token == primary.token { return [primary] }
        return [primary, fallbackID]
    }
    
    static func fallback(forPath raw: String) -> CacheShardID {
        let path = raw.standardizedPath
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                return CacheShardID(token: "p-Volumes-\(sanitize(String(parts[1])))")
            }
            return CacheShardID(token: "p-Volumes")
        }
        return CacheShardID(token: "p-boot")
    }
    
    static func id(forPath path: String) -> CacheShardID {
        id(for: URL(fileURLWithPath: path))
    }
    
    private static func volumeUUID(_ url: URL) -> String? {
        let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard let uuid, !uuid.isEmpty else { return nil }
        return uuid
    }
    
    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }
}
