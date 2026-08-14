import AppKit
import Foundation

struct GitHubReleaseInfo: Sendable, Equatable {
    var version: String
    var pageURL: URL
    var notes: String
}

enum UpdateCheckReason: Sendable {
    case automatic
    case manual
}

/// Polls GitHub Releases for a newer tag. Never downloads or replaces the app.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    static let repoOwner = UpdateGitHub.owner
    static let repoName = UpdateGitHub.repo
    static let autoCheckKey = "auto_check_updates"
    static let lastCheckKey = "last_update_check_at"
    static let skippedKey = "skipped_update_version"
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60
    static let launchDelayNanoseconds: UInt64 = 15_000_000_000
    
    @Published var isChecking = false
    @Published var statusText = ""
    
    private var didScheduleLaunchCheck = false
    
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    
    var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
    }
    
    func scheduleLaunchCheckIfNeeded() {
        guard !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.launchDelayNanoseconds)
            await self?.check(reason: .automatic)
        }
    }
    
    func check(reason: UpdateCheckReason) async {
        if reason == .automatic {
            guard autoCheckEnabled else { return }
            if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < Self.autoCheckInterval {
                return
            }
        }
        guard !isChecking else { return }
        isChecking = true
        statusText = "settings.updates.checking".localized
        defer { isChecking = false }
        
        do {
            let info = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            
            guard AppVersion.isNewer(info.version, than: Self.currentVersion) else {
                statusText = "settings.updates.uptodate".localized(Self.currentVersion)
                if reason == .manual {
                    presentUpToDate()
                }
                return
            }
            
            if reason == .automatic {
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey) ?? ""
                if skipped == info.version { return }
            }
            
            statusText = "settings.updates.available.status".localized(info.version)
            presentAvailable(info)
        } catch {
            statusText = "settings.updates.error.status".localized
            if reason == .manual {
                presentError(error)
            }
        }
    }
    
    func openReleasesPage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
    
    func skip(version: String) {
        UserDefaults.standard.set(version, forKey: Self.skippedKey)
        statusText = "settings.updates.skipped".localized(version)
    }
    
    nonisolated static func normalizeTag(_ tag: String) -> String {
        AppVersion.normalize(tag)
    }
    
    // MARK: - Network
    
    nonisolated static func fetchLatest() async throws -> GitHubReleaseInfo {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(UpdateGitHub.owner)/\(UpdateGitHub.repo)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "FastDuplicateFinder/\(AppVersion.marketing) (+https://github.com/\(UpdateGitHub.owner)/\(UpdateGitHub.repo))",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
        guard !decoded.draft, !decoded.prerelease else {
            throw UpdateCheckError.noRelease
        }
        let version = AppVersion.normalize(decoded.tagName)
        guard !version.isEmpty, let page = URL(string: decoded.htmlURL) else {
            throw UpdateCheckError.invalidPayload
        }
        return GitHubReleaseInfo(
            version: version,
            pageURL: page,
            notes: trimmedNotes(decoded.body ?? "")
        )
    }
    
    nonisolated static func trimmedNotes(_ body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 420 { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: 420)
        return String(collapsed[..<idx]) + "…"
    }
    
    // MARK: - Alerts
    
    private func presentAvailable(_ info: GitHubReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "settings.updates.available.title".localized
        alert.informativeText = "settings.updates.available.message".localized(
            info.version,
            Self.currentVersion,
            info.notes.isEmpty ? "—" : info.notes
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "settings.updates.open".localized)
        alert.addButton(withTitle: "settings.updates.skip".localized)
        alert.addButton(withTitle: "settings.updates.later".localized)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openReleasesPage(info.pageURL)
        case .alertSecondButtonReturn:
            skip(version: info.version)
        default:
            break
        }
    }
    
    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "settings.updates.uptodate.title".localized
        alert.informativeText = "settings.updates.uptodate".localized(Self.currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "alert.ok".localized)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "settings.updates.error.title".localized
        alert.informativeText = "settings.updates.error.message".localized(error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "alert.ok".localized)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

enum UpdateGitHub {
    static let owner = "kDolphin"
    static let repo = "Fast_Duplicate_Finder"
}

enum AppVersion: Sendable {
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" {
            s = String(s.dropFirst())
        }
        return s
    }
    
    /// Semver-ish: `v1.0.10` is newer than `1.0.9`.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = parts(remote)
        let l = parts(local)
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
    
    static func parts(_ raw: String) -> [Int] {
        normalize(raw).split(separator: ".").map { component in
            let digits = component.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}

enum UpdateCheckError: LocalizedError {
    case httpStatus(Int)
    case noRelease
    case invalidPayload
    
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "settings.updates.error.http".localized(code)
        case .noRelease, .invalidPayload:
            return "settings.updates.error.invalid".localized
        }
    }
}

private struct GitHubLatestRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease
    }
}
