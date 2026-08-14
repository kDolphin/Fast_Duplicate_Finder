import SwiftUI

// MARK: - Filter

enum ResultsListFilter: String, CaseIterable, Identifiable {
    case all
    case review
    case packages
    
    var id: String { rawValue }
    
    var titleKey: String {
        switch self {
        case .all: return "results.filter.all"
        case .review: return "results.filter.review"
        case .packages: return "results.filter.packages"
        }
    }
}

// MARK: - Results root

struct ResultsView: View {
    let duplicateGroups: [DuplicateGroup]
    @Binding var expandState: GroupExpandState
    @Binding var selectedForDelete: Set<URL>
    /// Invoked with the selection restricted to the current filter (and search).
    let onDeletePreview: (Set<URL>) -> Void
    let onDeleteFile: (FileInfo) -> Void
    let onVerifyGroup: (UUID) -> Void
    let onVerifyAllReview: () -> Void
    var onCancelVerify: (() -> Void)? = nil
    let isVerifying: Bool
    let verifyProgressText: String
    let totalScanDuration: TimeInterval
    let totalFilesScanned: Int
    var timing: ScanTimingBreakdown = ScanTimingBreakdown()
    var cacheHits: Int = 0
    var newlyHashed: Int = 0
    /// When true, top filter bar is drawn by parent full-width chrome.
    var embedsTopBar: Bool = true
    var onOpenSettings: (() -> Void)? = nil
    
    @State private var filter: ResultsListFilter = .all
    /// Bound to the field — updates every keystroke, must stay cheap.
    @State private var searchField = ""
    /// Applied to the list after a short debounce.
    @State private var appliedSearch = ""
    @State private var searchDebounce: Task<Void, Never>?
    @StateObject private var searchIndex = GroupSearchIndex()
    
    private var reviewCount: Int {
        duplicateGroups.reduce(0) { $0 + (($1.needsReview && !$1.isVerified) ? 1 : 0) }
    }
    
    /// O(1) for bulk expand-all; no scanning tens of thousands of IDs.
    private var allFilteredExpanded: Bool {
        expandState.isFullyExpanded
    }
    
    var body: some View {
        let query = appliedSearch
        let groups = visibleGroups(query: query)
        let selectedCount = markedCount(in: groups, query: query)
        return VStack(spacing: 0) {
            if embedsTopBar {
                ResultsChromeBar(
                    groupCount: groups.count,
                    selectedCount: selectedCount,
                    filter: $filter,
                    searchText: $searchField,
                    reviewCount: reviewCount,
                    purposeRiskPendingCount: purposeRiskPending(in: groups),
                    isVerifying: isVerifying,
                    allExpanded: allFilteredExpanded,
                    onToggleAll: toggleAllFiltered,
                    onApplyKeepSuggestions: applyKeepSuggestionsToFiltered,
                    onSearchSubmit: { _ = flushSearch() },
                    onDeletePreview: {
                        let q = flushSearch()
                        let visible = visibleGroups(query: q)
                        onDeletePreview(markedURLs(in: visible, query: q))
                    },
                    onVerifyAllReview: onVerifyAllReview,
                    onCancelVerify: onCancelVerify,
                    onOpenSettings: onOpenSettings
                )
            }
            
            VStack(spacing: 10) {
                ResultsMetricsStrip(
                    groupCount: groups.count,
                    freeableSize: markedBytes(in: groups, query: query),
                    potentialFreeableSize: potentialBytes(in: groups, query: query),
                    totalFilesScanned: totalFilesScanned,
                    totalScanDuration: totalScanDuration,
                    reviewCount: reviewCount
                )
                
                if timing.hasDetails {
                    TimingStrip(
                        timing: timing,
                        cacheHits: cacheHits,
                        newlyHashed: newlyHashed
                    )
                }
                
                if isVerifying, !verifyProgressText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verifyProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
            
            if groups.isEmpty {
                ResultsEmptyFilterView(filter: filter, hasSearch: !appliedSearch.isEmpty)
            } else {
                ScrollView {
                    // LazyVStack: only visible rows materialize. Expand-all must stay O(1)
                    // (GroupExpandState.expandAll) so we never build 40k expanded trees at once.
                    LazyVStack(spacing: 4, pinnedViews: []) {
                        ForEach(groups) { group in
                            OutlineGroupRow(
                                group: group,
                                isExpanded: expandState.isExpanded(group.id),
                                isVerifying: isVerifying,
                                selectedForDelete: $selectedForDelete,
                                onToggle: { toggleGroup(group.id) },
                                onDeleteFile: onDeleteFile,
                                onVerifyGroup: { onVerifyGroup(group.id) },
                                onApplyKeepSuggestion: group.packageIdentityMismatch
                                    ? { applyKeepSuggestion(for: group) }
                                    : nil
                            )
                            .id(group.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .transaction { $0.animation = nil }
            }
        }
        .background(AppTheme.page)
        .focusable(false)
        .onChange(of: searchField) { newValue in
            scheduleSearchApply(newValue)
        }
        .onDisappear {
            searchDebounce?.cancel()
        }
        .background(
            FilterBridge(
                filter: $filter,
                searchText: $searchField,
                allExpanded: allFilteredExpanded,
                reviewCount: reviewCount,
                onToggleAll: toggleAllFiltered
            )
        )
    }
    
    @discardableResult
    private func flushSearch() -> String {
        searchDebounce?.cancel()
        let trimmed = searchField.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedSearch = trimmed
        return trimmed
    }
    
    private func scheduleSearchApply(_ raw: String) {
        searchDebounce?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            appliedSearch = ""
            return
        }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            appliedSearch = trimmed
        }
    }
    
    private func visibleGroups(query: String) -> [DuplicateGroup] {
        searchIndex.prepare(duplicateGroups)
        var list = duplicateGroups
        switch filter {
        case .all: break
        case .review:
            list = list.filter { $0.needsReview && !$0.isVerified }
        case .packages:
            list = list.filter(\.isPackageGroup)
        }
        if !query.isEmpty {
            let lowered = query.lowercased()
            list = list.filter { searchIndex.matches($0, query: lowered) }
        }
        return list
    }
    
    private func purposeRiskPending(in groups: [DuplicateGroup]) -> Int {
        var n = 0
        for group in groups where group.packageIdentityMismatch && group.files.count > 1 {
            let nonKeepMarked = group.files.dropFirst().contains { selectedForDelete.contains($0.url) }
            if !nonKeepMarked { n += 1 }
        }
        return n
    }
    
    private func fileMatchesSearch(_ file: FileInfo, query: String) -> Bool {
        query.isEmpty || searchIndex.fileMatches(file, query: query.lowercased())
    }
    
    private func potentialBytes(in groups: [DuplicateGroup], query: String) -> Int64 {
        var total: Int64 = 0
        for group in groups {
            for (index, file) in group.files.enumerated() where index > 0 && fileMatchesSearch(file, query: query) {
                total += group.fileSize
            }
        }
        return total
    }
    
    private func markedCount(in groups: [DuplicateGroup], query: String) -> Int {
        var n = 0
        for group in groups {
            for file in group.files where selectedForDelete.contains(file.url) && fileMatchesSearch(file, query: query) {
                n += 1
            }
        }
        return n
    }
    
    private func markedBytes(in groups: [DuplicateGroup], query: String) -> Int64 {
        var total: Int64 = 0
        for group in groups {
            for file in group.files where selectedForDelete.contains(file.url) && fileMatchesSearch(file, query: query) {
                total += group.fileSize
            }
        }
        return total
    }
    
    private func markedURLs(in groups: [DuplicateGroup], query: String) -> Set<URL> {
        var urls = Set<URL>()
        for group in groups {
            for file in group.files where selectedForDelete.contains(file.url) && fileMatchesSearch(file, query: query) {
                urls.insert(file.url)
            }
        }
        return urls
    }
    
    private func toggleAllFiltered() {
        // O(1): do not insert 40k UUIDs into a Set (that freezes the main thread).
        if expandState.isFullyExpanded {
            expandState.collapseAllGroups()
        } else {
            expandState.expandAllGroups()
        }
    }
    
    private func toggleGroup(_ id: UUID) {
        expandState.toggle(id)
    }
    
    private func applyKeepSuggestion(for group: DuplicateGroup) {
        DeleteSelectionPolicy.applyKeepSuggestions(to: &selectedForDelete, groups: [group])
    }
    
    /// Bulk: purpose-risk groups in the current filter → mark all non-keep members.
    private func applyKeepSuggestionsToFiltered() {
        let pending = DeleteSelectionPolicy.purposeRiskGroupsNeedingSuggestions(
            in: visibleGroups(query: appliedSearch),
            selection: selectedForDelete
        )
        guard !pending.isEmpty else { return }
        DeleteSelectionPolicy.applyKeepSuggestions(to: &selectedForDelete, groups: pending)
    }
}

/// Lowercased path blobs, built once per group so typing does not re-lowercase 40k paths.
private final class GroupSearchIndex: ObservableObject {
    private var haystacks: [UUID: String] = [:]
    
    func prepare(_ groups: [DuplicateGroup]) {
        if haystacks.count == groups.count, groups.allSatisfy({ haystacks[$0.id] != nil }) {
            return
        }
        if haystacks.count > groups.count + 256 {
            haystacks.removeAll(keepingCapacity: true)
        }
        haystacks.reserveCapacity(groups.count)
        for group in groups where haystacks[group.id] == nil {
            var blob = ""
            blob.reserveCapacity(group.files.count * 80)
            for file in group.files {
                blob.append(file.url.path.lowercased())
                blob.append("\n")
            }
            haystacks[group.id] = blob
        }
    }
    
    func matches(_ group: DuplicateGroup, query: String) -> Bool {
        if let haystack = haystacks[group.id] {
            return haystack.contains(query)
        }
        return group.files.contains { fileMatches($0, query: query) }
    }
    
    func fileMatches(_ file: FileInfo, query: String) -> Bool {
        file.url.path.lowercased().contains(query)
    }
}

/// Placeholder so ResultsView keeps filter state when parent owns chrome later.
private struct FilterBridge: View {
    @Binding var filter: ResultsListFilter
    @Binding var searchText: String
    let allExpanded: Bool
    let reviewCount: Int
    let onToggleAll: () -> Void
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}

// MARK: - Full-width chrome bar (aligned with sidebar)

struct ResultsChromeBar: View {
    let groupCount: Int
    var selectedCount: Int = 0
    @Binding var filter: ResultsListFilter
    @Binding var searchText: String
    let reviewCount: Int
    /// Purpose-risk groups still unselected (for bulk “apply keep suggestions”).
    var purposeRiskPendingCount: Int = 0
    let isVerifying: Bool
    let allExpanded: Bool
    let onToggleAll: () -> Void
    var onApplyKeepSuggestions: (() -> Void)? = nil
    var onSearchSubmit: (() -> Void)? = nil
    let onDeletePreview: () -> Void
    let onVerifyAllReview: () -> Void
    var onCancelVerify: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    /// Brand + group count live in metrics strip / window title — not repeated here.
    var showBrand: Bool = false
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            chromeRow(compact: false)
            chromeRow(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: AppTheme.topBarHeight)
        .background(AppTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
        }
    }
    
    @ViewBuilder
    private func chromeRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            // Filter first (includes Needs review)
            Picker("", selection: $filter) {
                ForEach(ResultsListFilter.allCases) { f in
                    Text(f.titleKey.localized).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: compact ? 168 : 200, idealWidth: 240, maxWidth: 280)
            .layoutPriority(2)
            
            // Longer search — brand removed frees space
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("results.search.placeholder".localized, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { onSearchSubmit?() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: compact ? 120 : 180, idealWidth: compact ? 160 : 280, maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
            .layoutPriority(1)
            
            // Actions: Expand → Precise-compare needs-review → Clean up
            HStack(spacing: 6) {
                Button(action: onToggleAll) {
                    HStack(spacing: 4) {
                        Image(systemName: allExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                        if !compact {
                            Text(allExpanded ? "results.collapse.all".localized : "results.expand.all".localized)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, compact ? 8 : 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(allExpanded ? "results.collapse.all".localized : "results.expand.all".localized)
                .disabled(isVerifying)
                
                if reviewCount > 0 || isVerifying {
                    Button(action: {
                        if isVerifying {
                            onCancelVerify?()
                            return
                        }
                        if filter != .review { filter = .review }
                        onVerifyAllReview()
                    }) {
                        HStack(spacing: 5) {
                            if isVerifying {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            if compact {
                                Text(isVerifying ? "review.verify.stop.short".localized : "review.verify.all.short".localized(reviewCount))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            } else {
                                Text(isVerifying ? "review.verify.stop".localized : "review.verify.all.count".localized(reviewCount))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(isVerifying ? AppTheme.danger : AppTheme.review)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, 6)
                        .background((isVerifying ? AppTheme.danger : AppTheme.review).opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(isVerifying ? "review.verify.stop.help".localized : "review.verify.all.help".localized)
                }
                
                // Purpose-risk: default unchecked; one tap applies keep suggestions for many groups.
                if purposeRiskPendingCount > 0, let onApplyKeepSuggestions {
                    Button(action: onApplyKeepSuggestions) {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist")
                                .font(.system(size: 11, weight: .semibold))
                            if compact {
                                Text("results.apply.keep.short".localized(purposeRiskPendingCount))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            } else {
                                Text("results.apply.keep".localized(purposeRiskPendingCount))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(AppTheme.keep)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.keep.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isVerifying)
                    .help("results.apply.keep.help".localized)
                }
                
                Button(action: onDeletePreview) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11, weight: .bold))
                        if !compact {
                            if selectedCount > 0 {
                                Text("results.cleanup.count".localized(selectedCount))
                                    .font(.callout.weight(.semibold))
                            } else {
                                Text("results.cleanup".localized)
                                    .font(.callout.weight(.semibold))
                            }
                        } else if selectedCount > 0 {
                            Text("\(selectedCount)")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 10 : 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.danger)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isVerifying || selectedCount == 0)
                .opacity(isVerifying || selectedCount == 0 ? 0.45 : 1)
                .help("results.cleanup.help".localized)
                
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("sidebar.settings".localized)
                }
            }
            .layoutPriority(3)
        }
        .frame(minWidth: compact ? 480 : 640)
    }
}

// MARK: - Metrics

struct ResultsMetricsStrip: View {
    let groupCount: Int
    let freeableSize: Int64
    let potentialFreeableSize: Int64
    let totalFilesScanned: Int
    let totalScanDuration: TimeInterval
    let reviewCount: Int
    
    private var freeableHint: String {
        if freeableSize <= 0 {
            return "results.metric.freeable.none".localized
        }
        if freeableSize < potentialFreeableSize {
            let cap = ByteCountFormatter.string(fromByteCount: potentialFreeableSize, countStyle: .file)
            return "results.metric.freeable.more".localized(cap)
        }
        return "results.metric.freeable.hint".localized
    }
    
    var body: some View {
        HStack(spacing: 10) {
            CompactMetricTile(
                icon: "square.stack.3d.up.fill",
                iconBg: reviewCount > 0 ? AppTheme.review.opacity(0.12) : AppTheme.metricBlue.opacity(0.12),
                iconFg: reviewCount > 0 ? AppTheme.review : AppTheme.metricBlue,
                value: "\(groupCount)",
                title: "results.metric.groups".localized,
                subtitle: reviewCount > 0
                    ? "results.metric.groups.review".localized(reviewCount)
                    : "results.metric.groups.ok".localized
            )
            CompactMetricTile(
                icon: "internaldrive.fill",
                iconBg: (freeableSize > 0 ? AppTheme.metricGreen : AppTheme.metricGray).opacity(0.14),
                iconFg: freeableSize > 0 ? AppTheme.metricGreen : AppTheme.metricGray,
                value: ByteCountFormatter.string(fromByteCount: freeableSize, countStyle: .file),
                title: "results.metric.freeable".localized,
                subtitle: freeableHint
            )
            CompactMetricTile(
                icon: "clock.fill",
                iconBg: AppTheme.metricGray.opacity(0.14),
                iconFg: AppTheme.metricGray,
                value: "\(totalFilesScanned)",
                title: "results.metric.scan".localized,
                subtitle: "results.metric.scan.detail".localized(ResultsDuration.format(totalScanDuration))
            )
        }
    }
}

struct CompactMetricTile: View {
    let icon: String
    let iconBg: Color
    let iconFg: Color
    let value: String
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Timing always visible

struct TimingStrip: View {
    let timing: ScanTimingBreakdown
    let cacheHits: Int
    let newlyHashed: Int
    
    private var pathLabel: String {
        switch timing.path {
        case .snapshotHit: return "timing.path.snapshot".localized
        case .hashCacheOnly: return "timing.path.cache".localized
        case .full: return "timing.path.full".localized
        }
    }
    
    private var pathColor: Color {
        switch timing.path {
        case .snapshotHit: return .green
        case .hashCacheOnly: return .teal
        case .full: return .secondary
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("timing.breakdown".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(pathLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(pathColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(pathColor)
                Spacer()
                if cacheHits + newlyHashed > 0 {
                    Text("timing.cache.stats".localized(cacheHits, newlyHashed))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            ScanTimingBreakdownView(
                timing: timing,
                cacheHits: cacheHits,
                newlyHashed: newlyHashed,
                showHeader: false
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerSmall, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerSmall, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Empty filter

struct ResultsEmptyFilterView: View {
    let filter: ResultsListFilter
    let hasSearch: Bool
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("results.filter.empty.title".localized)
                .font(.headline)
            Text(
                hasSearch
                    ? "results.filter.empty.search".localized
                    : "results.filter.empty.\(filter.rawValue)".localized
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
    }
}

enum ResultsDuration {
    /// Stable multi-unit strings so a lone "39 min" never hides the missing ~15 min gap.
    static func format(_ t: TimeInterval) -> String {
        if t < 0.001 { return "duration.under_ms".localized }
        if t < 1 { return "duration.ms".localized(t * 1000) }
        if t < 60 { return "duration.s".localized(t) }
        let totalSec = Int(t.rounded(.towardZero))
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        // Always show seconds past 1 minute (e.g. 39:42) so bars and total can be checked.
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Timing breakdown bars

struct ScanTimingBreakdownView: View {
    let timing: ScanTimingBreakdown
    let cacheHits: Int
    let newlyHashed: Int
    var showHeader: Bool = true
    
    private var segments: [(key: String, value: TimeInterval, color: Color)] {
        [
            ("timing.enumerate", timing.enumerate, .blue),
            ("timing.prepare", timing.prepare, AppTheme.brand),
            ("timing.hashing", timing.hashing, .orange),
            ("timing.finalize", timing.finalize, .green)
        ]
    }
    
    private var barTotal: TimeInterval {
        max(timing.total, segments.map(\.value).reduce(0, +), 0.001)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                Text("timing.breakdown".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        let w = max(0, geo.size.width * CGFloat(seg.value / barTotal))
                        if w > 0.5 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(seg.color.opacity(0.85))
                                .frame(width: w)
                        }
                    }
                }
            }
            .frame(height: 5)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.10)))
            
            HStack(spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 3) {
                        Circle().fill(seg.color).frame(width: 5, height: 5)
                        Text("\(seg.key.localized) \(ResultsDuration.format(seg.value))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
