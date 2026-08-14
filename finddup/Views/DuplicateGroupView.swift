import SwiftUI

/// Dense outline-style group: thin header + nested member rows with user-selectable delete marks.
struct OutlineGroupRow: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let isVerifying: Bool
    @Binding var selectedForDelete: Set<URL>
    let onToggle: () -> Void
    let onDeleteFile: (FileInfo) -> Void
    let onVerifyGroup: () -> Void
    /// Optional: mark all non-keep members in this group (follow the Keep suggestion).
    var onApplyKeepSuggestion: (() -> Void)? = nil
    
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    
    private var canApplyKeepSuggestion: Bool {
        guard isExpanded, group.files.count > 1 else { return false }
        return group.files.dropFirst().contains { !selectedForDelete.contains($0.url) }
    }
    
    private var accent: Color {
        if group.packageIdentityMismatch { return AppTheme.review }
        if group.isVerified { return AppTheme.keep }
        if group.needsReview { return AppTheme.review }
        if group.isPackageGroup { return AppTheme.package }
        return AppTheme.brand
    }
    
    private var selectedInGroup: Int {
        guard isExpanded else { return 0 }
        return group.files.reduce(0) { $0 + (selectedForDelete.contains($1.url) ? 1 : 0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header only — keep collapsed rows cheap for 10k–40k lists.
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: group.isPackageGroup ? "shippingbox.fill" : "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    
                    Text(groupTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if group.isPackageGroup {
                        StatusChip(title: "results.package.badge".localized, color: AppTheme.package)
                    }
                    
                    if group.packageIdentityMismatch {
                        StatusChip(
                            title: group.purposeBadgeKey.localized,
                            color: AppTheme.review
                        )
                    } else if group.isVerified {
                        StatusChip(title: "review.verified".localized, color: AppTheme.keep)
                    } else if group.needsReview {
                        StatusChip(title: "review.suggested".localized, color: AppTheme.review)
                    }
                    
                    if isExpanded && selectedInGroup > 0 {
                        Text("results.selected.count".localized(selectedInGroup))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppTheme.danger)
                    }
                    
                    Spacer(minLength: 6)
                    
                    Text(Self.sizeFormatter.string(fromByteCount: group.fileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    
                    Text(Self.sizeFormatter.string(fromByteCount: group.duplicateSize))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                        .help("results.group.waste".localized(
                            Self.sizeFormatter.string(fromByteCount: group.duplicateSize)
                        ))
                    
                    if group.needsReview && !group.isVerified && !group.packageIdentityMismatch {
                        Button(action: onVerifyGroup) {
                            HStack(spacing: 4) {
                                if isVerifying {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text("review.verify.group".localized)
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(AppTheme.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.brandSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isVerifying)
                        .help("review.verify.group.help".localized)
                    }
                }
                .frame(minHeight: AppTheme.groupRowHeight)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                expandedDetails
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerSmall, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerSmall, style: .continuous)
                .strokeBorder(
                    (group.needsReview && !group.isVerified) ? accent.opacity(0.28) : AppTheme.hairline,
                    lineWidth: 1
                )
        )
    }
    
    @ViewBuilder
    private var expandedDetails: some View {
        if group.packageIdentityMismatch {
            Text(group.purposeHintKey.localized)
                .font(.caption2)
                .foregroundStyle(AppTheme.review.opacity(0.95))
                .padding(.horizontal, 40)
                .padding(.bottom, 2)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(alignment: .top, spacing: 10) {
                Text(group.purposeSelectHintKey.localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                if let onApplyKeepSuggestion, canApplyKeepSuggestion {
                    Button(action: onApplyKeepSuggestion) {
                        Text("results.apply.keep.group".localized)
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("results.apply.keep.group.help".localized)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 4)
        } else if group.needsReview && !group.isVerified {
            Text("review.suggested.hint".localized)
                .font(.caption2)
                .foregroundStyle(AppTheme.review.opacity(0.9))
                .padding(.horizontal, 40)
                .padding(.bottom, 4)
        } else {
            Text("results.select.hint".localized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 40)
                .padding(.bottom, 4)
        }
        
        VStack(spacing: 0) {
            ForEach(Array(group.files.enumerated()), id: \.offset) { index, file in
                OutlineMemberRow(
                    file: file,
                    isRecommendedKeep: index == 0,
                    isMarkedForDelete: selectedForDelete.contains(file.url),
                    packageIdentityRisk: group.packageIdentityMismatch,
                    onToggleMark: { toggleMark(file) },
                    onDelete: { onDeleteFile(file) }
                )
            }
        }
        .padding(.bottom, 4)
    }
    
    private func toggleMark(_ file: FileInfo) {
        if selectedForDelete.contains(file.url) {
            selectedForDelete.remove(file.url)
        } else {
            // Prefer leaving at least one file unmarked in the group
            let othersUnmarked = group.files.contains {
                $0.url != file.url && !selectedForDelete.contains($0.url)
            }
            if !othersUnmarked {
                // Would mark every member — block, keep one survivor
                return
            }
            selectedForDelete.insert(file.url)
        }
    }
    
    private var groupTitle: String {
        if group.isPackageGroup {
            if group.files.count <= 3 {
                return group.files.map(\.url.lastPathComponent).joined(separator: " · ")
            }
            return "results.duplicate.packages".localized(group.files.count)
        }
        if let first = group.files.first?.url.lastPathComponent, group.files.count <= 4 {
            return "\(first)  ·  \(group.files.count)"
        }
        return "results.duplicate.files".localized(group.files.count)
    }
}

struct OutlineMemberRow: View {
    let file: FileInfo
    let isRecommendedKeep: Bool
    let isMarkedForDelete: Bool
    var packageIdentityRisk: Bool = false
    let onToggleMark: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDeleteAlert = false
    @State private var hovering = false
    
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 28)
            
            // User-selectable: mark for cleanup
            Button(action: onToggleMark) {
                Image(systemName: isMarkedForDelete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isMarkedForDelete ? AppTheme.danger : Color.secondary.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isMarkedForDelete
                    ? "results.unmark.delete".localized
                    : "results.mark.delete".localized
            )
            
            Image(systemName: file.isPackage
                  ? "shippingbox.fill"
                  : iconName(for: file.url))
                .font(.system(size: 12))
                .foregroundStyle(file.isPackage ? AppTheme.package : .blue.opacity(0.85))
                .frame(width: 16)
            
            Text(file.url.lastPathComponent)
                .font(.callout.weight(isRecommendedKeep ? .semibold : .regular))
                .lineLimit(1)
                .layoutPriority(1)
            
            if isRecommendedKeep {
                StatusChip(title: "results.keep.suggest".localized, color: AppTheme.keep)
            }
            
            if isMarkedForDelete {
                StatusChip(title: "results.will.delete".localized, color: AppTheme.danger)
            }
            
            if file.isPackage {
                StatusChip(title: "results.package.badge".localized, color: AppTheme.package)
            }
            
            Text(file.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 4)
            
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            
            Button {
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(hovering ? 1 : 0.7))
            }
            .buttonStyle(.borderless)
            .help("delete.file.help".localized)
        }
        .frame(minHeight: AppTheme.memberRowHeight)
        .padding(.horizontal, 10)
        .background(
            isMarkedForDelete
                ? AppTheme.danger.opacity(0.05)
                : (isRecommendedKeep ? AppTheme.keep.opacity(0.06) : (hovering ? AppTheme.rowHover : .clear))
        )
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            // Double-click toggles mark (faster bulk editing)
            onToggleMark()
        }
        .alert("alert.confirm.delete".localized, isPresented: $showingDeleteAlert) {
            Button("alert.delete".localized, role: .destructive, action: onDelete)
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            if packageIdentityRisk {
                Text("alert.delete.package.identity".localized(file.url.lastPathComponent))
            } else {
                Text("alert.delete.file.confirm".localized(file.url.lastPathComponent))
            }
        }
        .contextMenu {
            Button("results.reveal.finder".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Button(
                isMarkedForDelete ? "results.unmark.delete".localized : "results.mark.delete".localized
            ) {
                onToggleMark()
            }
            Button("results.delete".localized, role: .destructive) {
                showingDeleteAlert = true
            }
        }
    }
    
    private func iconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff":
            return "photo"
        case "mp4", "mov", "m4v", "mkv":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "zip", "dmg", "rar", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }
}

typealias DuplicateGroupRow = OutlineGroupRow
typealias FileRow = OutlineMemberRow

// MARK: - Default selection policy

enum DeleteSelectionPolicy {
    /// Seed marks after a scan. Purpose-risk / identity-mismatch groups start empty
    /// (user opts in via “Apply keep suggestions”).
    static func defaultSelection(for groups: [DuplicateGroup]) -> Set<URL> {
        var set = Set<URL>()
        for group in groups {
            if group.packageIdentityMismatch {
                // User must opt-in — same shell / different names / purpose risk
                continue
            }
            for (index, file) in group.files.enumerated() where index > 0 {
                set.insert(file.url)
            }
        }
        return set
    }
    
    /// Mark every non-keep member (index > 0) in each group. Keeps index 0 (suggested keep).
    /// Used for purpose-risk bulk apply when the user trusts sort-for-keep order.
    @discardableResult
    static func applyKeepSuggestions(
        to selection: inout Set<URL>,
        groups: [DuplicateGroup]
    ) -> Int {
        var added = 0
        for group in groups {
            guard group.files.count > 1 else { continue }
            for (index, file) in group.files.enumerated() where index > 0 {
                if selection.insert(file.url).inserted {
                    added += 1
                }
            }
        }
        return added
    }
    
    /// Purpose-risk groups that still have no non-keep member marked.
    static func purposeRiskGroupsNeedingSuggestions(
        in groups: [DuplicateGroup],
        selection: Set<URL>
    ) -> [DuplicateGroup] {
        groups.filter { group in
            guard group.packageIdentityMismatch, group.files.count > 1 else { return false }
            let nonKeepMarked = group.files.dropFirst().contains { selection.contains($0.url) }
            return !nonKeepMarked
        }
    }
    
    /// Keep selection in sync when groups shrink after deletes.
    static func prune(_ selection: inout Set<URL>, groups: [DuplicateGroup]) {
        let live = Set(groups.flatMap { $0.files.map(\.url) })
        selection = selection.intersection(live)
    }
}
