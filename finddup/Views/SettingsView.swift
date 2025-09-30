import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("excluded_extensions") private var excludedExtensionsString = "tmp,cache,log"
    @AppStorage("skip_hidden_files") private var skipHiddenFiles = true
    @AppStorage("skip_system_files") private var skipSystemFiles = true
    @AppStorage("min_file_size") private var minFileSize = 1
    @AppStorage("max_file_size_gb") private var maxFileSizeGB = 50.0
    @AppStorage("confirm_before_delete") private var confirmBeforeDelete = true
    @AppStorage("move_to_trash") private var moveToTrash = true
    @AppStorage("auto_delete_duplicates") private var autoDeleteDuplicates = false
    
    @State private var newExtension = ""
    @State private var showingResetConfirmation = false
    /// When embedded in `Settings` scene, hide custom chrome (system provides window).
    var isPreferencesScene: Bool = false
    
    private var excludedExtensions: [String] {
        excludedExtensionsString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    
    var body: some View {
        Group {
            if isPreferencesScene {
                preferencesBody
            } else {
                sheetBody
            }
        }
        .alert("settings.reset.confirm.title".localized, isPresented: $showingResetConfirmation) {
            Button("settings.reset.confirm".localized, role: .destructive) {
                resetToDefaults()
            }
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            Text("settings.reset.confirm.message".localized)
        }
    }
    
    // MARK: - Settings scene (⌘, native window)
    
    private var preferencesBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsSections
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.page)
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 520, minHeight: 420)
    }
    
    // MARK: - Sheet fallback (legacy)
    
    private var sheetBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("settings.title".localized)
                        .font(.headline.weight(.semibold))
                    Text("settings.subtitle".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("settings.done".localized) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.brand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.chrome)
            
            Rectangle().fill(AppTheme.separator).frame(height: 1)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    settingsSections
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(AppTheme.page)
        }
        .frame(width: 440, height: 600)
    }
    
    @ViewBuilder
    private var settingsSections: some View {
        // Language follows System Settings — short note only
        SettingsSection(
            title: "settings.language".localized,
            icon: "globe",
            iconColor: .blue
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                        .foregroundStyle(.secondary)
                    Text("settings.language.system.note".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("settings.language.current".localized(currentLanguageLabel))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        
        ScanSettingsSection(
            skipHiddenFiles: $skipHiddenFiles,
            skipSystemFiles: $skipSystemFiles,
            minFileSize: $minFileSize,
            maxFileSizeGB: $maxFileSizeGB
        )
        
        FileFilteringSection(
            excludedExtensions: excludedExtensions,
            newExtension: $newExtension,
            onAddExtension: addExtension,
            onRemoveExtension: removeExtension,
            onImagePreset: applyImagePreset,
            onDocumentPreset: applyDocumentPreset,
            onMediaPreset: applyMediaPreset
        )
        
        DeletionSettingsSection(
            confirmBeforeDelete: $confirmBeforeDelete,
            moveToTrash: $moveToTrash,
            autoDeleteDuplicates: $autoDeleteDuplicates,
            onResetDefaults: { showingResetConfirmation = true }
        )
        
        CacheManagementSection()
        AboutSection()
    }
    
    private var currentLanguageLabel: String {
        LocalizationManager.shared.currentLanguage.hasPrefix("zh")
            ? "language.chinese".localized
            : "language.english".localized
    }
    
    private func addExtension() {
        let ext = newExtension.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !ext.isEmpty && !excludedExtensions.contains(ext) {
            excludedExtensionsString = (excludedExtensions + [ext]).joined(separator: ",")
            newExtension = ""
        }
    }
    
    private func removeExtension(_ ext: String) {
        excludedExtensionsString = excludedExtensions.filter { $0 != ext }.joined(separator: ",")
    }
    
    private func applyImagePreset() {
        excludedExtensionsString = "jpg,jpeg,png,gif,bmp,tiff,webp"
    }
    
    private func applyDocumentPreset() {
        excludedExtensionsString = "pdf,doc,docx,txt,rtf,pages"
    }
    
    private func applyMediaPreset() {
        excludedExtensionsString = "mp4,mov,avi,mkv,mp3,wav,aac"
    }
    
    private func resetToDefaults() {
        excludedExtensionsString = "tmp,cache,log"
        skipHiddenFiles = true
        skipSystemFiles = true
        minFileSize = 1
        maxFileSizeGB = 50.0
        confirmBeforeDelete = true
        moveToTrash = true
        autoDeleteDuplicates = false
    }
}
