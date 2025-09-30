import SwiftUI
import Foundation

/// Pre-scan summary of selected folders (paths only — full stats come from the scan).
struct FolderInfoView: View {
    @Binding var selectedFolders: [URL]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.brandSoft)
                            .frame(width: 56, height: 56)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AppTheme.brand)
                    }
                    
                    Text("folder.info.title".localized)
                        .font(.title2.weight(.semibold))
                    
                    Text("folder.info.subtitle".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .padding(.top, 28)
                
                if selectedFolders.count > 1 {
                    summaryCard
                        .padding(.horizontal, 20)
                }
                
                LazyVStack(spacing: 10) {
                    ForEach(selectedFolders, id: \.self) { folder in
                        folderCard(folder)
                    }
                }
                .padding(.horizontal, 20)
                
                Text("folder.info.hint".localized)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                Text("folder.info.ready.scan".localized)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppTheme.brand)
                
                Spacer(minLength: 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
    }
    
    private var summaryCard: some View {
        HStack {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(AppTheme.brand)
            Text("folder.info.total".localized)
                .font(.headline.weight(.medium))
            Spacer()
            Text("\(selectedFolders.count)")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.brand)
            Text("folder.info.selected.folders".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(AppTheme.brandSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
    
    private func folderCard(_ folder: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(AppTheme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent)
                    .font(.headline.weight(.medium))
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
}
