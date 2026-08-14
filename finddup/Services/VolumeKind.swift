import Foundation

/// Local vs network volume. Prefer `volumeIsLocal` so USB disks under `/Volumes/`
/// stay on the local hash path; SMB/AFP stay on the NAS path.
enum VolumeKind: Sendable {
    private static let lock = NSLock()
    private static var networkByVolumeKey: [String: Bool] = [:]
    
    /// True when the URL lives on a non-local volume (SMB, AFP, most NAS mounts).
    static func isNetwork(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey])
        let key = values?.volume?.path ?? volumeKeyFallback(url.path)
        
        lock.lock()
        if let cached = networkByVolumeKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        let isNet: Bool
        if let local = values?.volumeIsLocal {
            isNet = !local
        } else {
            isNet = classify(path: url.path, volumeIsLocal: nil)
        }
        
        lock.lock()
        networkByVolumeKey[key] = isNet
        lock.unlock()
        return isNet
    }
    
    /// Testable rule: explicit `volumeIsLocal` wins; otherwise only unknown
    /// `/Volumes/…` mounts (not APFS firmlinks) are treated as network.
    static func classify(path: String, volumeIsLocal: Bool?) -> Bool {
        if let local = volumeIsLocal { return !local }
        return path.hasPrefix("/Volumes/") && !path.hasPrefix("/System/Volumes/")
    }
    
    static func resetCacheForTests() {
        lock.lock()
        networkByVolumeKey.removeAll()
        lock.unlock()
    }
    
    private static func volumeKeyFallback(_ path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                return "/Volumes/\(parts[1])"
            }
            return "/Volumes"
        }
        return "/"
    }
}
