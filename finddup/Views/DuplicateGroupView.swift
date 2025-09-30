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
    
    private var purposeRisk: PackageIdentity.PurposeRisk {
        PackageIdentity.purposeRisk(for: group.files)
    }
    
    private var accent: Color {
        if group.packageIdentityMismatch { return AppTheme.review }
        if group.isVerified { return AppTheme.keep }
        if group.needsReview { return AppTheme.review }
        if group.isPackageGroup { return AppTheme.package }
        return AppTheme.brand
    }
    
    private var selectedInGroup: Int {
        group.files.filter { selectedForDelete.contains($0.url) }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        let key = PackageIdentity.badgeKey(for: purposeRisk)
                        StatusChip(
                            title: (key.isEmpty ? "review.package.names.differ" : key).localized,
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
                    
                    Text(ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    
                    Text(ByteCountFormatter.string(fromByteCount: group.duplicateSize, countStyle: .file))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                        .help("results.group.waste".localized(
                            ByteCountFormatter.string(fromByteCount: group.duplicateSize, countStyle: .file)
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
                if group.packageIdentityMismatch {
                    Text(PackageIdentity.hintKey(for: purposeRisk, members: group.files).localized)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.review.opacity(0.95))
                        .padding(.horizontal, 40)
                        .padding(.bottom, 2)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(PackageIdentity.selectHintKey(for: purposeRisk).localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 4)
                        .fixedSize(horizontal: false, vertical: true)
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
    /// Seed marks after a scan. Identity-mismatch packages start with nothing selected.
    static func defaultSelection(for groups: [DuplicateGroup]) -> Set<URL> {
        var set = Set<URL>()
        for group in groups {
            if group.packageIdentityMismatch {
                // User must opt-in — same shell / different names
                continue
            }
            for (index, file) in group.files.enumerated() where index > 0 {
                set.insert(file.url)
            }
        }
        return set
    }
    
    /// Keep selection in sync when groups shrink after deletes.
    static func prune(_ selection: inout Set<URL>, groups: [DuplicateGroup]) {
        let live = Set(groups.flatMap { $0.files.map(\.url) })
        selection = selection.intersection(live)
    }
}
