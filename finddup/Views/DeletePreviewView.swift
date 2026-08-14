import SwiftUI

struct DeletePreviewSheet: View {
    let duplicateGroups: [DuplicateGroup]
    @Binding var filesToDelete: Set<URL>
    let onConfirm: (Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @AppStorage("move_to_trash") private var defaultMoveToTrash = true
    
    private var hasNetworkFiles: Bool {
        filesToDelete.contains { isNetworkVolume($0) }
    }
    
    private var markedGroups: [DuplicateGroup] {
        duplicateGroups.filter { group in
            group.files.contains { filesToDelete.contains($0.url) }
        }
    }
    
    private var hasPackageIdentityRisk: Bool {
        duplicateGroups.contains { group in
            group.packageIdentityMismatch &&
            group.files.contains { filesToDelete.contains($0.url) }
        }
    }
    
    private var totalSizeToFree: Int64 {
        var total: Int64 = 0
        for group in duplicateGroups {
            for file in group.files {
                if filesToDelete.contains(file.url) {
                    total += group.fileSize
                }
            }
        }
        return total
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Title and totals
            VStack(spacing: 8) {
                Text("delete.preview.title".localized)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("delete.preview.message".localized(filesToDelete.count, ByteCountFormatter.string(fromByteCount: totalSizeToFree, countStyle: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if hasNetworkFiles {
                    Text("delete.network.warning".localized)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                
                if hasPackageIdentityRisk {
                    Text("delete.package.identity.warning".localized)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            
            Divider()
            
            // File list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(markedGroups.enumerated()), id: \.element.id) { index, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("delete.preview.group".localized(index + 1, ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            // File list
                            ForEach(Array(group.files.enumerated()), id: \.offset) { index, file in
                                FilePreviewRow(
                                    file: file,
                                    isFirst: index == 0,
                                    isSelected: filesToDelete.contains(file.url),
                                    onToggle: {
                                        toggleFileSelection(file: file, group: group)
                                    }
                                )
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("alert.cancel".localized) {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button(defaultMoveToTrash ? "results.move.to.trash".localized : "results.delete.permanently".localized) {
                    onConfirm(defaultMoveToTrash)
                }
                .buttonStyle(.borderedProminent)
                .tint(defaultMoveToTrash ? .orange : .red)
                .disabled(filesToDelete.isEmpty)
                .focusable(false)
                
                Button(defaultMoveToTrash ? "results.delete.permanently".localized : "results.move.to.trash".localized) {
                    onConfirm(!defaultMoveToTrash)
                }
                .buttonStyle(.borderedProminent)
                .tint(defaultMoveToTrash ? .red : .orange)
                .disabled(filesToDelete.isEmpty)
                .focusable(false)
            }
            .padding()
        }
        .frame(width: 800, height: 600)
    }
    
    private func toggleFileSelection(file: FileInfo, group: DuplicateGroup) {
        let fileURL = file.url
        let groupFileURLs = Set(group.files.map { $0.url })
        let isFirstFile = group.files.first?.url == fileURL
        
        if group.files.count == 2 {
            // Two-file group: clicking a file selects only that file
            if filesToDelete.contains(fileURL) {
                // Already marked — unmark
                filesToDelete.remove(fileURL)
            } else {
                // Clear other marks in the group, then mark this file
                for groupFileURL in groupFileURLs {
                    filesToDelete.remove(groupFileURL)
                }
                filesToDelete.insert(fileURL)
            }
        } else {
            // Three or more files
            if filesToDelete.contains(fileURL) {
                // Unmark this file
                filesToDelete.remove(fileURL)
            } else {
                // Mark this file
                filesToDelete.insert(fileURL)
                
                // Keep at least one survivor if the keep (first) file is marked
                if isFirstFile {
                    let selectedInGroup = groupFileURLs.intersection(filesToDelete)
                    if selectedInGroup.count == group.files.count {
                        // All marked — unmark the second file
                        if group.files.count > 1 {
                            let secondFileURL = group.files[1].url
                            filesToDelete.remove(secondFileURL)
                        }
                    }
                } else {
                    // Marking a non-keep file: if everything is marked, unmark the first
                    let selectedInGroup = groupFileURLs.intersection(filesToDelete)
                    if selectedInGroup.count == group.files.count {
                        let firstFileURL = group.files.first!.url
                        filesToDelete.remove(firstFileURL)
                    }
                }
            }
        }
    }
    
    private func isNetworkVolume(_ url: URL) -> Bool {
        VolumeKind.isNetwork(url)
    }
}

struct FilePreviewRow: View {
    let file: FileInfo
    let isFirst: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: isFirst ? "star.fill" : "doc.fill")
                .foregroundStyle(isFirst ? .yellow : .blue)
                .font(.title3)
                .frame(width: 20)
            
            // File info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(file.url.lastPathComponent)
                        .font(.body)
                        .fontWeight(isFirst ? .semibold : .regular)
                    
                    if isFirst {
                        Text("results.recommended.keep".localized)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                    }
                    
                    Spacer()
                }
                
                Text(file.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            // Checkbox (every row; keep-file has different toggle rules)
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .red : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .opacity(isFirst && !isSelected ? 0.8 : 1.0)
        .background(isFirst && !isSelected ? Color.green.opacity(0.05) : Color.clear)
    }
}
