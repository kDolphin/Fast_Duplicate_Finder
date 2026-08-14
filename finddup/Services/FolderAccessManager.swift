import Foundation

/// Holds security-scoped access for user-chosen folders for the process lifetime
/// and persists app-scoped bookmarks so the next launch can restore them.
@MainActor
final class FolderAccessManager {
    static let shared = FolderAccessManager()
    
    private let defaultsKey = "scan_folder_bookmarks_v1"
    
    private struct Live {
        var url: URL
        var bookmark: Data
        var isAccessing: Bool
    }
    
    private var live: [Live] = []
    
    /// Resolve stored bookmarks, start access, return usable folder URLs.
    func restoreAndAccess() -> [URL] {
        stopAll()
        guard let blobs = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] else {
            return []
        }
        var urls: [URL] = []
        var stored: [Data] = []
        for data in blobs {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                let accessing = url.startAccessingSecurityScopedResource()
                var bookmark = data
                if stale,
                   let fresh = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                   ) {
                    bookmark = fresh
                }
                live.append(Live(url: url, bookmark: bookmark, isAccessing: accessing))
                urls.append(url)
                if !bookmark.isEmpty { stored.append(bookmark) }
            } catch {
                continue
            }
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
        return urls
    }
    
    /// Align live access + persisted bookmarks with the sidebar folder list.
    func sync(_ urls: [URL]) {
        let newKeys = urls.map { $0.path.standardizedPath }
        let liveKeys = live.map { $0.url.path.standardizedPath }
        if newKeys == liveKeys { return }
        
        var kept: [String: Live] = [:]
        for item in live {
            let key = item.url.path.standardizedPath
            if newKeys.contains(key) {
                kept[key] = item
            } else if item.isAccessing {
                item.url.stopAccessingSecurityScopedResource()
            }
        }
        
        for url in urls {
            let key = url.path.standardizedPath
            if kept[key] != nil { continue }
            let bookmark = (try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )) ?? Data()
            let accessing = url.startAccessingSecurityScopedResource()
            kept[key] = Live(url: url, bookmark: bookmark, isAccessing: accessing)
        }
        
        live = newKeys.compactMap { kept[$0] }
        persist()
    }
    
    func stopAll() {
        for item in live where item.isAccessing {
            item.url.stopAccessingSecurityScopedResource()
        }
        live = []
    }
    
    private func persist() {
        let blobs = live.map(\.bookmark).filter { !$0.isEmpty }
        UserDefaults.standard.set(blobs, forKey: defaultsKey)
    }
}
