import SwiftUI

// MARK: - 设置区块组件
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var iconColor: Color = AppTheme.brand
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 24, height: 24)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 扫描设置
struct ScanSettingsSection: View {
    @Binding var skipHiddenFiles: Bool
    @Binding var skipSystemFiles: Bool
    @Binding var minFileSize: Int
    @Binding var maxFileSizeGB: Double
    
    var body: some View {
        SettingsSection(title: "settings.scan.settings".localized, icon: "magnifyingglass", iconColor: .blue) {
            VStack(spacing: 14) {
                SettingsToggle(
                    title: "settings.skip.hidden".localized,
                    subtitle: "settings.skip.hidden.help".localized,
                    isOn: $skipHiddenFiles
                )
                Divider().opacity(0.5)
                SettingsToggle(
                    title: "settings.skip.system".localized,
                    subtitle: "settings.skip.system.help".localized,
                    isOn: $skipSystemFiles
                )
                Divider().opacity(0.5)
                
                SettingsFileSizeField(
                    title: "settings.min.size".localized,
                    value: $minFileSize,
                    unit: "KB"
                )
                
                SettingsFileSizeGBField(
                    title: "settings.max.size".localized,
                    value: $maxFileSizeGB,
                    unit: "GB"
                )
            }
        }
    }
}

// MARK: - 文件过滤设置
struct FileFilteringSection: View {
    let excludedExtensions: [String]
    @Binding var newExtension: String
    let onAddExtension: () -> Void
    let onRemoveExtension: (String) -> Void
    let onImagePreset: () -> Void
    let onDocumentPreset: () -> Void
    let onMediaPreset: () -> Void
    
    var body: some View {
        SettingsSection(title: "settings.file.filtering".localized, icon: "doc.text", iconColor: .purple) {
            VStack(alignment: .leading, spacing: 14) {
                Text("settings.file.filtering.desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.quick.presets".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 6) {
                        PresetButton(title: "settings.image.files".localized, icon: "photo", isCompact: true) {
                            onImagePreset()
                        }
                        PresetButton(title: "settings.document.files".localized, icon: "doc", isCompact: true) {
                            onDocumentPreset()
                        }
                        PresetButton(title: "settings.media.files".localized, icon: "play.rectangle", isCompact: true) {
                            onMediaPreset()
                        }
                        Spacer(minLength: 0)
                    }
                }
                
                Divider().opacity(0.5)
                
                Text("settings.excluded.extensions".localized)
                    .font(.subheadline.weight(.semibold))
                
                if excludedExtensions.isEmpty {
                    Text("settings.no.excluded.extensions".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                        ForEach(excludedExtensions, id: \.self) { ext in
                            HStack(spacing: 4) {
                                Text(".\(ext)")
                                    .font(.caption.weight(.medium))
                                Button(action: { onRemoveExtension(ext) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(AppTheme.brandSoft, in: Capsule())
                            .foregroundStyle(AppTheme.brand)
                        }
                    }
                }
                
                HStack(spacing: 8) {
                    TextField("settings.enter.extension".localized, text: $newExtension)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onAddExtension() }
                    Button("settings.add".localized, action: onAddExtension)
                        .buttonStyle(.bordered)
                        .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 删除设置
struct DeletionSettingsSection: View {
    @Binding var confirmBeforeDelete: Bool
    @Binding var moveToTrash: Bool
    @Binding var autoDeleteDuplicates: Bool
    let onResetDefaults: () -> Void
    
    var body: some View {
        SettingsSection(title: "settings.deletion.settings".localized, icon: "trash", iconColor: .red) {
            VStack(spacing: 14) {
                SettingsToggle(
                    title: "settings.confirm.before.delete".localized,
                    subtitle: "settings.confirm.before.delete.help".localized,
                    isOn: $confirmBeforeDelete
                )
                Divider().opacity(0.5)
                SettingsToggle(
                    title: "settings.move.to.trash".localized,
                    subtitle: "settings.move.to.trash.help".localized,
                    isOn: $moveToTrash
                )
                Divider().opacity(0.5)
                SettingsToggle(
                    title: "settings.auto.delete".localized,
                    subtitle: "settings.auto.delete.help".localized,
                    isOn: $autoDeleteDuplicates,
                    isWarning: true
                )
                
                Divider().opacity(0.5)
                
                Button(role: .destructive, action: onResetDefaults) {
                    Label("settings.reset.defaults".localized, systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - 关于信息
struct AboutSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    private var buildDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }
    
    var body: some View {
        SettingsSection(title: "settings.about".localized, icon: "info.circle") {
            VStack(spacing: 12) {
                HStack {
                    Text("settings.version".localized)
                    Spacer()
                    Text("\(appVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("settings.build.date".localized)
                    Spacer()
                    Text(buildDate)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("settings.system.info".localized)
                    Spacer()
                    Text("\(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - 基础组件
struct SettingsToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var isWarning: Bool = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isWarning ? AppTheme.danger : .primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

struct SettingsFileSizeGBField: View {
    let title: String
    @Binding var value: Double
    let unit: String
    
    private var minValue: Double { 0.1 }
    private var maxValue: Double { 1000.0 } // 最大1TB
    
    private var helpText: String {
        return "settings.max.size.help".localized
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack {
                    TextField("settings.value".localized, value: $value, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: value) { newValue in
                            // 输入验证
                            if newValue < minValue {
                                value = minValue
                            } else if newValue > maxValue {
                                value = maxValue
                            }
                        }
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                }
            }
            
            // 范围提示
            Text("settings.range.gb".localized(minValue, maxValue))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct SettingsFileSizeField: View {
    let title: String
    @Binding var value: Int
    let unit: String
    
    private var minValue: Int {
        unit == "KB" ? 1 : 1
    }
    
    private var maxValue: Int {
        unit == "KB" ? 1024 : 100000 // KB最大1MB，MB最大100GB
    }
    
    private var helpText: String {
        if unit == "KB" {
            return "settings.min.size.help".localized
        } else {
            return "settings.max.size.help".localized
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack {
                    TextField("settings.value".localized, value: $value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: value) { newValue in
                            // 输入验证
                            if newValue < minValue {
                                value = minValue
                            } else if newValue > maxValue {
                                value = maxValue
                            }
                        }
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                }
            }
            
            // 范围提示
            Text("settings.range".localized(minValue, maxValue, unit))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct PresetButton: View {
    let title: String
    let icon: String
    var isDestructive: Bool = false
    var isCompact: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: isCompact ? 10 : 11, weight: .medium))
                Text(title)
                    .font(.system(size: isCompact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.vertical, isCompact ? 4 : 6)
            .padding(.horizontal, isCompact ? 8 : 10)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isDestructive ? .red : AppTheme.brand)
        // Hug content — do not stretch across the card
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 缓存管理
struct CacheManagementSection: View {
    @State private var cacheStats: (totalEntries: Int, estimatedSize: Int64, oldestEntry: Date?, newestEntry: Date?) = (0, 0, nil, nil)
    @State private var cacheLocation: String = ""
    @State private var showingClearConfirmation = false
    @State private var isClearing = false
    
    var body: some View {
        SettingsSection(title: "settings.cache.title".localized, icon: "externaldrive") {
            VStack(spacing: 16) {
                // 缓存信息
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("settings.cache.location".localized)
                        Spacer()
                        Text(cacheLocation)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    
                    HStack {
                        Text("settings.cache.entries".localized)
                        Spacer()
                        Text("\(cacheStats.totalEntries)")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("settings.cache.size".localized)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cacheStats.estimatedSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    
                    if let oldestEntry = cacheStats.oldestEntry {
                        HStack {
                            Text("settings.cache.oldest".localized)
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: oldestEntry, relativeTo: Date()))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Divider()
                
                // 清除按钮
                HStack {
                    Button(action: {
                        showingClearConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("settings.cache.clear".localized)
                        }
                    }
                    .disabled(isClearing || cacheStats.totalEntries == 0)
                    
                    Spacer()
                    
                    if isClearing {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
        }
        .onAppear {
            loadCacheInfo()
        }
        // Scan / clear update memory + disk without leaving Settings — refresh live.
        .onReceive(NotificationCenter.default.publisher(for: ScanCacheManager.didChangeNotification)) { _ in
            loadCacheInfo()
        }
        .alert("settings.cache.clear.confirm.title".localized, isPresented: $showingClearConfirmation) {
            Button("settings.cache.clear.confirm.clear".localized, role: .destructive) {
                clearCache()
            }
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            Text("settings.cache.clear.confirm.message".localized(cacheStats.totalEntries))
        }
    }
    
    private func loadCacheInfo() {
        let cacheManager = ScanCacheManager.shared
        cacheStats = cacheManager.currentCacheStats()
        cacheLocation = cacheManager.getCacheFileURL().path
    }
    
    private func clearCache() {
        isClearing = true
        // Synchronous clear: empties hot cache + deletes file, posts didChange.
        ScanCacheManager.shared.clearCache()
        ScanSnapshotStore.clear()
        loadCacheInfo()
        isClearing = false
    }
}
