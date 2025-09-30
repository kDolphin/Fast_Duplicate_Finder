import SwiftUI

struct SidebarView: View {
    @Binding var selectedFolders: [URL]
    @Binding var isScanning: Bool
    var hasResults: Bool = false
    var filesScanned: Int = 0
    var showBrandHeader: Bool = true
    var onOpenSettings: (() -> Void)? = nil
    let onFoldersSelected: ([URL]) -> Void
    let onScanTapped: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showBrandHeader {
                HStack(spacing: 10) {
                    BrandMark(size: 28)
                    Text("app.title".localized)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: { onOpenSettings?() }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(AppTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("sidebar.settings.help".localized)
                }
                .padding(.horizontal, 14)
                .frame(height: AppTheme.topBarHeight)
                .background(AppTheme.chrome)
                
                Rectangle()
                    .fill(AppTheme.separator)
                    .frame(height: 1)
            }
            
            // Section title — single line, breathing room under brand
            HStack(alignment: .center, spacing: 8) {
                Text(hasResults ? "sidebar.scanning.scope".localized : "sidebar.locations".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if !selectedFolders.isEmpty {
                    Text("\(selectedFolders.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.brandSoft))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Folder list
            Group {
                if selectedFolders.isEmpty {
                    emptyDropZone
                        .padding(.horizontal, 14)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(selectedFolders, id: \.self) { folder in
                                locationRow(folder)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            
            // Add / Clear — prominent action strip
            if !selectedFolders.isEmpty {
                HStack(spacing: 8) {
                    Button(action: addMoreFolders) {
                        Label("sidebar.add.more.folders".localized, systemImage: "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.brand)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.brandSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AppTheme.brand.opacity(0.28), lineWidth: 1)
                    )
                    .disabled(isScanning)
                    .opacity(isScanning ? 0.45 : 1)
                    
                    Button(action: clearFolders) {
                        Label("sidebar.clear.all".localized, systemImage: "trash.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.danger)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.danger.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AppTheme.danger.opacity(0.28), lineWidth: 1)
                    )
                    .disabled(isScanning)
                    .opacity(isScanning ? 0.45 : 1)
                    .help("sidebar.clear.all.help".localized)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            
            // Scan CTA
            VStack(spacing: 6) {
                Button(action: onScanTapped) {
                    HStack(spacing: 8) {
                        Image(systemName: isScanning ? "stop.fill" : "magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                        Text(isScanning ? "sidebar.stop.scan".localized : "sidebar.start.scan".localized)
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isScanning ? AppTheme.danger : AppTheme.brand)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(selectedFolders.isEmpty)
                .opacity(selectedFolders.isEmpty ? 0.45 : 1)
                
                if selectedFolders.isEmpty {
                    Text("sidebar.scan.need.folder".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(minWidth: AppTheme.sidebarMinWidth, idealWidth: AppTheme.sidebarWidth, maxWidth: 280)
        .background(AppTheme.page)
        .focusable(false)
    }
    
    private func clearFolders() {
        selectedFolders.removeAll()
    }
    
    private var emptyDropZone: some View {
        Button(action: { if !isScanning { selectFolders() } }) {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppTheme.brand.opacity(0.9))
                Text("sidebar.select.folder".localized)
                    .font(.caption.weight(.medium))
                Text("sidebar.drop.hint".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.brandSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.brand.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
    }
    
    private func locationRow(_ folder: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.brand)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(folder.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer(minLength: 2)
            
            Button {
                selectedFolders.removeAll { $0 == folder }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .opacity(isScanning ? 0.35 : 1)
            .help("sidebar.remove.folder".localized)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hasResults ? AppTheme.brandSoft : AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
    
    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK {
            onFoldersSelected(panel.urls)
        }
    }
    
    private func addMoreFolders() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK {
            let newFolders = panel.urls.filter { new in
                !selectedFolders.contains { $0.path == new.path }
            }
            onFoldersSelected(selectedFolders + newFolders)
        }
    }
}
