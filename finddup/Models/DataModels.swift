import Foundation

// MARK: - 文件 / 整包 扫描项
struct FileInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    /// File byte size, or package logical total size (sum of interior files)
    let size: Int64
    let modificationDate: Date
    let creationDate: Date
    /// True when this item is an opaque package (.app, BDMV, …)
    let isPackage: Bool
    /// Precomputed fingerprint (package tree hash `pkg:…`); nil for regular files
    let precomputedHash: String?
    /// Cached once — `standardizedPath` is hot on large NAS scans (100k+ items).
    let pathKey: String
    
    init(
        url: URL,
        size: Int64,
        modificationDate: Date,
        creationDate: Date,
        isPackage: Bool = false,
        precomputedHash: String? = nil
    ) {
        self.id = UUID()
        self.url = url
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.isPackage = isPackage
        self.precomputedHash = precomputedHash
        self.pathKey = url.path.standardizedPath
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(pathKey)
    }
    
    static func == (lhs: FileInfo, rhs: FileInfo) -> Bool {
        lhs.pathKey == rhs.pathKey
    }
}

// MARK: - 重复文件组模型
struct DuplicateGroup: Identifiable, Sendable {
    let id: UUID
    let files: [FileInfo]
    let fileSize: Int64
    let hash: String
    /// Sampling-based turbo match may need full-file confirmation
    var needsReview: Bool
    /// User (or auto) ran full SHA-256; safe to treat as exact
    var isVerified: Bool
    /// Package members share content but have unrelated names (wrapper / multi-launcher shells)
    var packageIdentityMismatch: Bool
    
    init(
        files: [FileInfo],
        fileSize: Int64,
        hash: String,
        needsReview: Bool = false,
        isVerified: Bool = false,
        packageIdentityMismatch: Bool = false,
        id: UUID = UUID()
    ) {
        self.id = id
        self.files = files
        self.fileSize = fileSize
        self.hash = hash
        self.needsReview = needsReview
        self.isVerified = isVerified
        self.packageIdentityMismatch = packageIdentityMismatch
    }
    
    var totalSize: Int64 {
        Int64(files.count) * fileSize
    }
    
    var duplicateSize: Int64 {
        Int64(files.count - 1) * fileSize
    }
    
    var isPackageGroup: Bool {
        !files.isEmpty && files.allSatisfy(\.isPackage)
    }
}

/// Zero-cost heuristics: when turbo sampling might mis-group same-size files.
enum DuplicateReviewPolicy {
    /// Always suggest review for files this large (sampling finals)
    static let largeFileBytes: Int64 = 16 * 1024 * 1024
    /// Medium files only if the size-bucket was crowded
    static let mediumFileBytes: Int64 = 2 * 1024 * 1024
    static let crowdedBucketCount = 30
    static let manyMembersInGroup = 8
    
    static func needsReview(
        fileSize: Int64,
        sameSizeCandidateCount: Int,
        memberCount: Int
    ) -> Bool {
        if fileSize >= largeFileBytes { return true }
        if fileSize >= mediumFileBytes && sameSizeCandidateCount >= crowdedBucketCount {
            return true
        }
        if memberCount >= manyMembersInGroup && fileSize >= mediumFileBytes {
            return true
        }
        return false
    }
}

/// Same content, different *purpose* (name, path locale, multi-product same role).
enum PackageIdentity {
    /// Why a content-matched group is unsafe to auto-clean.
    enum PurposeRisk: String, Sendable, Equatable {
        case none
        /// .app shells / multi-launcher wrappers
        case packageShell
        /// Locale in filename *or* parent path (fr_CA folder, en.lproj, …)
        case localeVariants
        /// Same relative role under different product roots (e.g. CodeResources in each .ccl)
        case multiProductRole
        /// Other intentional different basenames (not copy/副本)
        case differentNames
    }
    
    // Precompiled once — per-call NSRegularExpression was a major group-build cost.
    private static let copySuffixRegexes: [NSRegularExpression] = {
        let patterns = [
            #"\s+copy(\s+\d+)?$"#,
            #"\s+副本(\s*\d+)?$"#,
            #"\s+的副本$"#,
            #"\s*\(\d+\)$"#,
            #"[-_]+copy(\d+)?$"#,
            #"[-_]+副本(\d+)?$"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()
    
    private static let embeddedLocaleRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[._-]([a-z]{2,3})[_-]([A-Za-z]{2,8})(?=$|[._-])"#,
        options: []
    )
    
    /// True when basenames are essentially the same (copy / 副本 / (1) variants).
    static func basenamesAreRelated(_ names: [String]) -> Bool {
        let stems = Set(names.map { normalizeBasename($0) }.filter { !$0.isEmpty })
        return stems.count <= 1
    }
    
    /// Content-matched items with purpose risk → do not auto-mark for delete.
    static func hasIdentityMismatch(packages: [FileInfo]) -> Bool {
        purposeRisk(for: packages) != .none
    }
    
    /// Comprehensive purpose check (order: locale → multi-product → name/package).
    /// Uses `pathKey` strings only — never `URL.standardizedFileURL` (filesystem hit
    /// freezes NAS group assembly at ~tens of groups/s with near-zero CPU).
    static func purposeRisk(for members: [FileInfo]) -> PurposeRisk {
        guard members.count > 1 else { return .none }
        let names = members.map { $0.url.lastPathComponent }
        let paths = members.map(\.pathKey)
        
        let exactNames = Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let sameName = exactNames.count == 1
        
        // 1) Locale encoded in filename (content.fr_CA.json)
        if looksLikeLocaleVariants(names) {
            return .localeVariants
        }
        
        // 2) Locale encoded in path (.../locale/fr_CA/messages.properties, en.lproj/…)
        if looksLikePathLocaleVariants(paths: paths, names: names) {
            return .localeVariants
        }
        
        // 3) Same role under different product packages (CodeResources in each .app/.ccl)
        if looksLikeMultiProductRole(paths: paths) {
            return .multiProductRole
        }
        
        // 3b) Same nested relative path under sibling modules
        //     e.g. …/CoreSync/customhook/X  vs  …/CoreSyncExtension/customhook/X
        if looksLikeSiblingModuleRole(paths: paths, names: names) {
            return .multiProductRole
        }
        
        // 4) Package shells with different display names
        if members.allSatisfy(\.isPackage), !sameName, !basenamesAreRelated(names) {
            return .packageShell
        }
        
        // 5) Different basenames that are not copy/副本 variants
        if !sameName, !basenamesAreRelated(names) {
            return .differentNames
        }
        
        return .none
    }
    
    /// Apply review/verified flags after content matching.
    static func reviewFlags(for members: [FileInfo], contentVerified: Bool) -> (
        needsReview: Bool,
        isVerified: Bool,
        packageIdentityMismatch: Bool
    ) {
        let mismatch = hasIdentityMismatch(packages: members)
        if mismatch {
            return (true, false, true)
        }
        if members.allSatisfy(\.isPackage) {
            return (contentVerified ? false : true, contentVerified, false)
        }
        return (false, contentVerified, false)
    }
    
    /// Strip extension + common “copy” suffixes so “App.app” and “App copy.app” count as related.
    static func normalizeBasename(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        s = s.precomposedStringWithCanonicalMapping.lowercased()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var changed = true
        while changed {
            changed = false
            let before = s
            for regex in copySuffixRegexes {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                let next = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
                if next != s {
                    s = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
            if s == before { break }
        }
        return s
    }
    
    // MARK: - Locale in filename
    
    /// Extract tags like fr_CA, es-ES, zh_Hans from a file name or path component.
    static func localeTag(in filename: String) -> String? {
        let base = (filename as NSString).deletingPathExtension
        if let t = parseLocaleToken(base) { return t }
        // Embedded: content.fr_CA / foo-en_US-bar
        guard let regex = embeddedLocaleRegex else { return nil }
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        let matches = regex.matches(in: base, options: [], range: range)
        guard let last = matches.last,
              let full = Range(last.range, in: base) else {
            return nil
        }
        let raw = String(base[full]).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return parseLocaleToken(raw)
    }
    
    /// Validate a single token as language_REGION / language-Script.
    private static func parseLocaleToken(_ raw: String) -> String? {
        let parts = raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard parts.count >= 2 else {
            // bare xx.lproj handled separately
            return nil
        }
        let lang = parts[0].lowercased()
        let region = parts[1]
        guard lang.count >= 2, lang.count <= 3, lang.allSatisfy(\.isLetter) else { return nil }
        let regionOk = (region.count == 2 && region.uppercased() == region)
            || (region.count >= 4 && region.first?.isUppercase == true)
        guard regionOk, !region.allSatisfy(\.isNumber) else { return nil }
        return "\(lang)_\(region)"
    }
    
    static func stemWithoutLocale(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension
            .precomposedStringWithCanonicalMapping
        if let regex = embeddedLocaleRegex {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "._- ")).lowercased()
    }
    
    static func looksLikeLocaleVariants(_ names: [String]) -> Bool {
        let tags = names.compactMap { localeTag(in: $0) }
        guard tags.count == names.count, Set(tags).count > 1 else { return false }
        let stems = Set(names.map { stemWithoutLocale($0) }.filter { !$0.isEmpty })
        return stems.count == 1
    }
    
    // MARK: - Locale in path (.../locale/fr_CA/x, en.lproj/x)
    
    private static let localeContainerNames: Set<String> = [
        "locale", "locales", "l10n", "i18n", "localization", "localizations", "lang", "langs"
    ]
    
    /// Slot id for path-based locale, e.g. fr_CA, en.lproj, or __default__ under locale/.
    static func pathLocaleSlot(for path: String) -> String? {
        let comps = (path as NSString).pathComponents.filter { $0 != "/" && $0 != "." }
        guard comps.count >= 2 else { return nil }
        
        for (i, comp) in comps.enumerated() {
            let lower = comp.lowercased()
            
            // en.lproj / zh-Hans.lproj
            if lower.hasSuffix(".lproj") {
                let base = String(comp.dropLast(6)) // strip .lproj
                if let tag = parseLocaleToken(base) { return tag }
                if base.count >= 2, base.count <= 3, base.allSatisfy(\.isLetter) {
                    return base.lowercased()
                }
                return lower
            }
            
            // .../locale/fr_CA/file  or  .../locale/file (default)
            if localeContainerNames.contains(lower), i + 1 < comps.count {
                let next = comps[i + 1]
                let nextIsFile = (i + 1 == comps.count - 1)
                if nextIsFile {
                    return "__default__"
                }
                if let tag = parseLocaleToken(next) { return tag }
                if let tag = localeTag(in: next) { return tag }
                // plain folder name that looks like locale
                if next.count <= 12, next.rangeOfCharacter(from: .letters) != nil {
                    return next.lowercased()
                }
            }
            
            // path component itself is fr_CA / zh_Hans
            if i < comps.count - 1, let tag = parseLocaleToken(comp) {
                return tag
            }
        }
        return nil
    }
    
    /// Same leaf name family, different locale path slots.
    static func looksLikePathLocaleVariants(paths: [String], names: [String]) -> Bool {
        let slots = paths.map { pathLocaleSlot(for: $0) }
        let present = slots.compactMap { $0 }
        // Need at least two members with a slot, and more than one distinct slot
        guard present.count >= 2, Set(present).count > 1 else { return false }
        // Prefer when basenames are related (same messages.properties)
        if basenamesAreRelated(names) { return true }
        // Or same exact basename
        let exact = Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        return exact.count == 1
    }
    
    // MARK: - Multi-product same role (CodeResources under each .ccl / .app)
    
    private static let productRootExtensions: Set<String> = [
        "app", "framework", "bundle", "appex", "xpc", "plugin", "ccl",
        "photoslibrary", "photoslibrary", "component", "saver", "service",
        "osax", "mdimporter", "preferencemode", "instrdst", "kext"
    ]
    
    /// Parent directory of a POSIX path (string-only, no filesystem).
    private static func parentPath(_ path: String) -> String? {
        if path == "/" { return nil }
        var p = path
        if p.count > 1, p.hasSuffix("/") { p = String(p.dropLast()) }
        guard let slash = p.lastIndex(of: "/") else { return nil }
        if slash == p.startIndex { return "/" }
        return String(p[..<slash])
    }
    
    private static func lastPathComponent(_ path: String) -> String {
        if path == "/" { return "/" }
        var p = path
        if p.count > 1, p.hasSuffix("/") { p = String(p.dropLast()) }
        if let slash = p.lastIndex(of: "/") {
            return String(p[p.index(after: slash)...])
        }
        return p
    }
    
    private static func pathExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
    
    /// Nearest product root directory path, if any. String-only — no URL FS access.
    static func productRoot(for path: String) -> String? {
        var current = parentPath(path) ?? path
        for _ in 0..<24 {
            let name = lastPathComponent(current)
            let ext = pathExtension(name)
            if productRootExtensions.contains(ext) {
                return current
            }
            guard let parent = parentPath(current), parent != current else { break }
            current = parent
        }
        return nil
    }
    
    static func pathRelativeToProductRoot(_ path: String) -> (root: String, relative: String)? {
        guard let root = productRoot(for: path) else { return nil }
        guard path.hasPrefix(root) else { return nil }
        var rel = String(path.dropFirst(root.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        rel = rel.precomposedStringWithCanonicalMapping
        guard !rel.isEmpty else { return nil }
        return (root, rel)
    }
    
    /// Different product roots, identical relative path inside each (same role).
    static func looksLikeMultiProductRole(paths: [String]) -> Bool {
        var byRelative: [String: Set<String>] = [:]
        var mapped = 0
        for path in paths {
            guard let pair = pathRelativeToProductRoot(path) else { continue }
            mapped += 1
            byRelative[pair.relative, default: []].insert(pair.root)
        }
        // Majority under product roots with same relative path, ≥2 different roots
        guard mapped >= 2 else { return false }
        for (_, roots) in byRelative {
            if roots.count >= 2, roots.count == mapped || roots.count >= max(2, (paths.count + 1) / 2) {
                return true
            }
        }
        // All mapped members share one relative path across different roots
        if byRelative.count == 1, let roots = byRelative.values.first, roots.count >= 2 {
            return true
        }
        return false
    }
    
    /// Sibling folders under a shared parent, identical nested relative path.
    /// Example: Adobe Sync/CoreSync/customhook/Hook vs …/CoreSyncExtension/customhook/Hook.
    /// Requires nesting (module/dir/file) so bare Desktop/a vs Downloads/a is not flagged.
    static func looksLikeSiblingModuleRole(paths: [String], names: [String]) -> Bool {
        let exactNames = Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        guard exactNames.count == 1 || basenamesAreRelated(names) else { return false }
        
        // pathKey / standardized strings only — never standardizedFileURL (NAS I/O).
        let standardized = paths.map { $0.precomposedStringWithCanonicalMapping }
        guard let common = longestCommonDirectoryPrefix(standardized) else { return false }
        let commonDepth = common.split(separator: "/").filter { !$0.isEmpty }.count
        // Avoid flagging under shallow roots like /Users/me
        guard commonDepth >= 3 else { return false }
        
        var modules = Set<String>()
        var relative: String?
        
        for path in standardized {
            guard path.hasPrefix(common) else { return false }
            var rest = String(path.dropFirst(common.count))
            if rest.hasPrefix("/") { rest = String(rest.dropFirst()) }
            let parts = rest.split(separator: "/").map(String.init)
            // module + at least one intermediate directory + file  → ≥ 3 components
            guard parts.count >= 3 else { return false }
            let module = parts[0]
            let rel = parts.dropFirst().joined(separator: "/")
            if let existing = relative {
                if existing != rel { return false }
            } else {
                relative = rel
            }
            modules.insert(module.precomposedStringWithCanonicalMapping)
        }
        
        return modules.count >= 2
    }
    
    /// Longest common parent directory of all paths (trailing slash stripped).
    static func longestCommonDirectoryPrefix(_ paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        var prefixComps = first.split(separator: "/").map(String.init)
        // Drop filename from first
        if !prefixComps.isEmpty { prefixComps.removeLast() }
        
        for path in paths.dropFirst() {
            var comps = path.split(separator: "/").map(String.init)
            if !comps.isEmpty { comps.removeLast() }
            var i = 0
            while i < prefixComps.count, i < comps.count, prefixComps[i] == comps[i] {
                i += 1
            }
            prefixComps = Array(prefixComps.prefix(i))
            if prefixComps.isEmpty { return nil }
        }
        guard !prefixComps.isEmpty else { return nil }
        return "/" + prefixComps.joined(separator: "/")
    }
    
    static func badgeKey(for risk: PurposeRisk) -> String {
        switch risk {
        case .none: return ""
        case .packageShell: return "review.package.names.differ"
        case .localeVariants: return "review.purpose.locale"
        case .multiProductRole: return "review.purpose.multiproduct"
        case .differentNames: return "review.purpose.names"
        }
    }
    
    static func hintKey(for risk: PurposeRisk, members: [FileInfo]) -> String {
        switch risk {
        case .none:
            return "review.suggested.hint"
        case .packageShell:
            return sharesSameBundleShell(packages: members)
                ? "review.package.shell.hint"
                : "review.package.names.hint"
        case .localeVariants:
            return "review.purpose.locale.hint"
        case .multiProductRole:
            return "review.purpose.multiproduct.hint"
        case .differentNames:
            return "review.purpose.names.hint"
        }
    }
    
    static func selectHintKey(for risk: PurposeRisk) -> String {
        switch risk {
        case .localeVariants: return "results.select.hint.locale"
        case .packageShell: return "results.select.hint.identity"
        case .multiProductRole: return "results.select.hint.multiproduct"
        case .differentNames: return "results.select.hint.purpose"
        case .none: return "results.select.hint"
        }
    }
    
    /// Best-effort bundle id for .app-style packages (Contents/Info.plist).
    static func bundleIdentifier(for packageURL: URL) -> String? {
        let infoURL = packageURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path),
              let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return nil
        }
        return dict["CFBundleIdentifier"] as? String
    }
    
    /// Same bundle id under different names → classic multi-launcher / wrapper shell.
    static func sharesSameBundleShell(packages: [FileInfo]) -> Bool {
        guard packages.count > 1, packages.allSatisfy(\.isPackage) else { return false }
        let names = packages.map { $0.url.lastPathComponent }
        guard !basenamesAreRelated(names) else { return false }
        let ids = packages.compactMap { bundleIdentifier(for: $0.url) }
        guard ids.count == packages.count, let first = ids.first else { return false }
        return ids.allSatisfy { $0 == first }
    }
    
    /// Legacy name used in UI.
    static func sharesSameBundleShell(_ packages: [FileInfo]) -> Bool {
        sharesSameBundleShell(packages: packages)
    }
}

// MARK: - 删除结果模型
struct DeleteResult: Sendable {
    let successCount: Int
    let failureCount: Int
    
    var totalCount: Int {
        successCount + failureCount
    }
    
    var hasFailures: Bool {
        failureCount > 0
    }
}

// MARK: - 扫描模式（产品固定为极速；枚举保留以兼容快照）
enum ScanMode: String, Sendable, CaseIterable, Identifiable {
    /// Only supported product mode: dual xxHash finals + optional UI verify
    case turbo
    
    var id: String { rawValue }
    static let storageKey = "scan_mode"
    static let productDefault: ScanMode = .turbo
    
    static func fromStorage(_ raw: String?) -> ScanMode {
        .turbo
    }
}

// MARK: - 扫描设置快照（离开 MainActor 后使用）
struct ScanSettings: Sendable {
    var excludedExtensions: Set<String>
    var skipHiddenFiles: Bool
    var skipSystemFiles: Bool
    var minFileSizeKB: Int
    var maxFileSizeGB: Double
    var scanMode: ScanMode = .turbo
    
    var minSizeBytes: Int64 { Int64(minFileSizeKB) * 1024 }
    var maxSizeBytes: Int64 { Int64(maxFileSizeGB * 1024 * 1024 * 1024) }
}

// MARK: - 进度回调载荷
struct ScanProgressUpdate: Sendable {
    var phase: String
    var message: String
    var phaseDetail: String
    var percent: Double
    var estimatedRemaining: TimeInterval
    var stats: ScanStatisticsSnapshot
}

struct ScanStatisticsSnapshot: Sendable {
    var totalFiles: Int = 0
    var totalSize: Int64 = 0
    var processedFiles: Int = 0
    var processedSize: Int64 = 0
    var cachedFiles: Int = 0
    var newFiles: Int = 0
    var errorFiles: Int = 0
    
    var progressPercent: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }
    
    var cacheHitRate: Double {
        let done = cachedFiles + newFiles
        guard done > 0 else { return 0 }
        return Double(cachedFiles) / Double(done)
    }
}

/// Wall-clock breakdown of one scan (seconds).
struct ScanTimingBreakdown: Sendable, Equatable {
    var enumerate: TimeInterval = 0
    /// Path dedupe + list signature + snapshot check + load hash cache
    var prepare: TimeInterval = 0
    /// Partial + standard hashing (and pure cache-hit assembly)
    var hashing: TimeInterval = 0
    /// Build groups + save snapshot/cache
    var finalize: TimeInterval = 0
    var total: TimeInterval = 0
    
    /// How the heavy path finished.
    enum Path: String, Sendable, Equatable {
        case full
        case snapshotHit   // identical file list → reused groups
        case hashCacheOnly // all candidates from hash cache (no content re-hash)
    }
    var path: Path = .full
    
    var hasDetails: Bool {
        total > 0 || enumerate > 0 || prepare > 0 || hashing > 0 || finalize > 0
    }
}
