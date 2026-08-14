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
            // 标题和统计信息
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
            
            // 文件列表
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(markedGroups.enumerated()), id: \.element.id) { index, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("delete.preview.group".localized(index + 1, ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            // 文件列表
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
            
            // 操作按钮
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
            // 2文件组：点击任何文件都切换到只选择该文件
            if filesToDelete.contains(fileURL) {
                // 如果点击的是已选中的文件，取消选择
                filesToDelete.remove(fileURL)
            } else {
                // 如果点击的是未选中的文件，清除组内所有选择，然后选择这个文件
                for groupFileURL in groupFileURLs {
                    filesToDelete.remove(groupFileURL)
                }
                filesToDelete.insert(fileURL)
            }
        } else {
            // 多文件组
            if filesToDelete.contains(fileURL) {
                // 取消选择这个文件
                filesToDelete.remove(fileURL)
            } else {
                // 选择这个文件
                filesToDelete.insert(fileURL)
                
                // 如果选择第一个文件，需要确保至少有一个其他文件被取消选择
                if isFirstFile {
                    let selectedInGroup = groupFileURLs.intersection(filesToDelete)
                    if selectedInGroup.count == group.files.count {
                        // 如果选择了所有文件，取消选择第二个文件
                        if group.files.count > 1 {
                            let secondFileURL = group.files[1].url
                            filesToDelete.remove(secondFileURL)
                        }
                    }
                } else {
                    // 选择非第一个文件时，如果选择了所有文件，取消选择第一个
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
            // 文件图标
            Image(systemName: isFirst ? "star.fill" : "doc.fill")
                .foregroundStyle(isFirst ? .yellow : .blue)
                .font(.title3)
                .frame(width: 20)
            
            // 文件信息
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
            
            // 选择框（所有文件都显示，但有不同的交互）
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
