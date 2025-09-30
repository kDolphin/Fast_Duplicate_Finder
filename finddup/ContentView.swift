import SwiftUI

struct ContentView: View {
    @StateObject private var duplicateFinder = DuplicateFinder()
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var selectedFolders: [URL] = []
    @State private var isScanning = false
    @State private var showingPermissionAlert = false
    @State private var permissionDeniedPath: String = ""
    @State private var expandedGroups: Set<UUID> = []
    @State private var showingDeletePreview = false
    @State private var filesToDelete: Set<URL> = []
    @State private var isDeleting = false
    @State private var deleteResult: DeleteResult?
    @State private var showingDeleteResult = false
    @State private var showingReviewBeforeDelete = false
    @State private var showingPackageIdentityBeforeDelete = false
    
    // 删除设置
    @AppStorage("confirm_before_delete") private var confirmBeforeDelete = true
    @AppStorage("move_to_trash") private var moveToTrash = true
    @AppStorage("auto_delete_duplicates") private var autoDeleteDuplicates = false
    
    private var hasResults: Bool {
        !duplicateFinder.duplicateGroups.isEmpty && !isScanning
    }
    
    var body: some View {
        // Custom split (not NavigationSplitView) so sidebar / chrome tops align and
        // we avoid the system title vs in-app brand misalignment.
        HStack(spacing: 0) {
            SidebarView(
                selectedFolders: $selectedFolders,
                isScanning: $isScanning,
                hasResults: hasResults,
                filesScanned: duplicateFinder.totalFilesScanned,
                showBrandHeader: true,
                onOpenSettings: openSettings,
                onFoldersSelected: { folders in
                    selectedFolders = folders
                },
                onScanTapped: startScan
            )
            
            Rectangle()
                .fill(AppTheme.separator)
                .frame(width: 1)
            
            Group {
                if isScanning {
                    ScanningView(
                        progress: duplicateFinder.scanProgress,
                        progressPercent: duplicateFinder.scanProgressPercent,
                        currentPhase: duplicateFinder.currentPhase,
                        phaseProgress: duplicateFinder.phaseProgress,
                        estimatedTimeRemaining: duplicateFinder.estimatedTimeRemaining
                    )
                } else if let errorMessage = duplicateFinder.errorMessage {
                    ErrorView(message: errorMessage)
                } else if !duplicateFinder.duplicateGroups.isEmpty {
                    ResultsView(
                        duplicateGroups: duplicateFinder.duplicateGroups,
                        expandedGroups: $expandedGroups,
                        selectedForDelete: $filesToDelete,
                        onDeletePreview: {
                            if autoDeleteDuplicates {
                                prepareAutoDelete()
                            } else {
                                prepareDeletePreview()
                            }
                        },
                        onDeleteFile: deleteFile,
                        onVerifyGroup: { id in
                            Task { await duplicateFinder.verifyGroupPrecise(id: id) }
                        },
                        onVerifyAllReview: {
                            Task { await duplicateFinder.verifyAllReviewGroups() }
                        },
                        isVerifying: duplicateFinder.isVerifying,
                        verifyProgressText: duplicateFinder.verifyProgressText,
                        totalScanDuration: duplicateFinder.totalScanDuration,
                        totalFilesScanned: duplicateFinder.totalFilesScanned,
                        timing: duplicateFinder.lastTiming,
                        cacheHits: duplicateFinder.scanStatistics.cachedFiles,
                        newlyHashed: duplicateFinder.scanStatistics.newFiles,
                        embedsTopBar: true
                    )
                } else if !selectedFolders.isEmpty {
                    FolderInfoView(selectedFolders: $selectedFolders)
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.page)
        .onReceive(NotificationCenter.default.publisher(for: .openAppSettings)) { _ in
            openSettings()
        }
        .onAppear {
            LocalizationManager.shared.reloadFromSystem()
        }
        .sheet(isPresented: $showingDeletePreview) {
            DeletePreviewSheet(
                duplicateGroups: duplicateFinder.duplicateGroups,
                filesToDelete: $filesToDelete,
                onConfirm: { moveToTrash in
                    confirmDeletion(moveToTrash: moveToTrash)
                }
            )
        }
        .alert("permission.denied.title".localized, isPresented: $showingPermissionAlert) {
            Button("permission.open.settings".localized) {
                openSystemPreferences()
            }
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            Text("permission.denied.message".localized(getLocationName(for: permissionDeniedPath)))
        }
        .alert("alert.deletion.complete".localized, isPresented: $showingDeleteResult) {
            Button("alert.ok".localized) { }
        } message: {
            if let result = deleteResult {
                Text("alert.delete.result".localized(result.successCount, result.failureCount))
            }
        }
        .alert("review.delete.warn.title".localized, isPresented: $showingReviewBeforeDelete) {
            Button("review.verify.all".localized) {
                Task { await duplicateFinder.verifyAllReviewGroups() }
            }
            Button("review.delete.anyway".localized, role: .destructive) {
                proceedDeletePreview()
            }
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            Text("review.delete.warn.message".localized(duplicateFinder.reviewGroupCount))
        }
        .alert("review.package.identity.warn.title".localized, isPresented: $showingPackageIdentityBeforeDelete) {
            Button("review.delete.anyway".localized, role: .destructive) {
                // After identity ack, still block on ordinary sampling-review groups
                if duplicateFinder.reviewGroupCount > duplicateFinder.packageIdentityMismatchCount {
                    showingReviewBeforeDelete = true
                } else {
                    proceedDeletePreview()
                }
            }
            Button("alert.cancel".localized, role: .cancel) { }
        } message: {
            Text("review.package.identity.warn.message".localized(duplicateFinder.packageIdentityMismatchCount))
        }
        .frame(minWidth: AppTheme.windowMinWidth, minHeight: AppTheme.windowMinHeight)
    }
    
    /// Opens Settings window (⌘, / app menu / gear).
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - 扫描相关方法
    private func startScan() {
        if isScanning {
            // 停止扫描
            duplicateFinder.cancelScan()
            isScanning = false
        } else {
            // 开始扫描
            guard !selectedFolders.isEmpty else { return }
            
            // 权限预检查
            if needsPermissionCheck(for: selectedFolders) {
                requestPermissionForFolders(selectedFolders) { granted in
                    if granted {
                        performScan()
                    } else {
                        permissionDeniedPath = selectedFolders.first?.path ?? ""
                        showingPermissionAlert = true
                    }
                }
            } else {
                performScan()
            }
        }
    }
    
    private func performScan() {
        // 清空之前的结果和错误信息
        duplicateFinder.duplicateGroups = []
        duplicateFinder.errorMessage = nil
        filesToDelete.removeAll()
        expandedGroups.removeAll()
        
        isScanning = true
        duplicateFinder.findDuplicates(in: selectedFolders) {
            DispatchQueue.main.async {
                isScanning = false
                // Default marks: non-keep copies; identity-mismatch packages start empty
                filesToDelete = DeleteSelectionPolicy.defaultSelection(
                    for: duplicateFinder.duplicateGroups
                )
            }
        }
    }
    
    // MARK: - 删除相关方法
    private func prepareAutoDelete() {
        // Use current user selection (already seeded / edited in the list)
        guard !filesToDelete.isEmpty else { return }
        if gateBulkDeleteWarnings() { return }
        deleteSelectedFiles(moveToTrash: moveToTrash)
    }
    
    private func prepareDeletePreview() {
        guard !filesToDelete.isEmpty else { return }
        if gateBulkDeleteWarnings() { return }
        proceedDeletePreview()
    }
    
    /// Returns true if a warning sheet was presented (caller should stop).
    @discardableResult
    private func gateBulkDeleteWarnings() -> Bool {
        // Only warn about identity-mismatch if user actually marked some of those packages
        let markedIdentity = duplicateFinder.duplicateGroups.contains { group in
            group.packageIdentityMismatch &&
            group.files.contains { filesToDelete.contains($0.url) }
        }
        if markedIdentity {
            showingPackageIdentityBeforeDelete = true
            return true
        }
        // Unverified sampling matches among marked files
        let markedNeedsReview = duplicateFinder.duplicateGroups.contains { group in
            group.needsReview && !group.isVerified && !group.packageIdentityMismatch &&
            group.files.contains { filesToDelete.contains($0.url) }
        }
        if markedNeedsReview {
            showingReviewBeforeDelete = true
            return true
        }
        return false
    }
    
    private func proceedDeletePreview() {
        if confirmBeforeDelete {
            showingDeletePreview = true
        } else {
            deleteSelectedFiles(moveToTrash: moveToTrash)
        }
    }
    
    private func deleteFile(_ file: FileInfo) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            filesToDelete.remove(file.url)
            duplicateFinder.removeDeletedFile(file)
            DeleteSelectionPolicy.prune(&filesToDelete, groups: duplicateFinder.duplicateGroups)
        } catch {
            #if DEBUG
            print("Failed to delete file: \(error)")
            #endif
        }
    }
    
    private func confirmDeletion(moveToTrash: Bool) {
        showingDeletePreview = false
        deleteSelectedFiles(moveToTrash: moveToTrash)
    }
    
    private func deleteSelectedFiles(moveToTrash: Bool) {
        isDeleting = true
        
        Task {
            var successCount = 0
            var failureCount = 0
            var permissionDenied = false
            var deniedPath = ""
            
            for fileURL in filesToDelete {
                do {
                    // 智能删除：网络文件直接删除，本地文件根据选择处理
                    if moveToTrash && !isNetworkVolume(fileURL) {
                        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                    } else {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    successCount += 1
                } catch CocoaError.fileWriteFileExists {
                    failureCount += 1
                } catch CocoaError.fileReadNoPermission, CocoaError.fileWriteNoPermission {
                    permissionDenied = true
                    deniedPath = fileURL.path
                    break
                } catch {
                    failureCount += 1
                    #if DEBUG
                    print("Failed to delete \(fileURL.path): \(error)")
                    #endif
                }
            }
            
            await MainActor.run {
                if permissionDenied {
                    permissionDeniedPath = deniedPath
                    isDeleting = false
                    showingPermissionAlert = true
                } else {
                    deleteResult = DeleteResult(successCount: successCount, failureCount: failureCount)
                    isDeleting = false
                    showingDeleteResult = true
                    // 重新扫描以更新结果
                    if successCount > 0 {
                        performScan()
                    }
                }
            }
        }
    }
    
    // MARK: - 权限相关方法
    private func needsPermissionCheck(for folders: [URL]) -> Bool {
        // 通过实际尝试访问来判断是否需要权限
        for folder in folders {
            // 先检查常见的受保护目录
            let pathComponents = folder.pathComponents
            let protectedFolders = ["Desktop", "Documents", "Downloads", 
                                   "Pictures", "Movies", "Music", "Library"]
            
            let isProtectedPath = protectedFolders.contains { folderName in
                pathComponents.contains(folderName)
            }
            
            if isProtectedPath {
                // 尝试实际访问来验证
                do {
                    _ = try FileManager.default.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                } catch CocoaError.fileReadNoPermission, CocoaError.fileNoSuchFile {
                    return true
                } catch {
                    // 其他错误也认为需要检查权限
                    return true
                }
            }
        }
        return false
    }
    
    private func requestPermissionForFolders(_ folders: [URL], completion: @escaping (Bool) -> Void) {
        var hasPermissionIssue = false
        var deniedFolder: URL?
        
        for folder in folders {
            // 尝试访问文件夹
            do {
                // 先获取security-scoped resource访问权
                let hasAccess = folder.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        folder.stopAccessingSecurityScopedResource()
                    }
                }
                
                // 尝试读取目录内容
                _ = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError {
                if error.code == .fileReadNoPermission {
                    hasPermissionIssue = true
                    deniedFolder = folder
                    break
                }
                // 其他错误继续检查
            } catch {
                // 非 CocoaError 类型的错误，也认为可能有权限问题
                hasPermissionIssue = true
                deniedFolder = folder
                break
            }
        }
        
        if hasPermissionIssue {
            if let denied = deniedFolder {
                permissionDeniedPath = denied.path
            }
            completion(false)
        } else {
            completion(true)
        }
    }
    
    private func getLocationName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let pathComponents = url.pathComponents
        
        if pathComponents.contains("Desktop") {
            return "permission.location.desktop".localized
        } else if pathComponents.contains("Documents") {
            return "permission.location.documents".localized
        } else if pathComponents.contains("Downloads") {
            return "permission.location.downloads".localized
        } else if pathComponents.contains("Pictures") {
            return "permission.location.pictures".localized
        } else if pathComponents.contains("Movies") {
            return "permission.location.movies".localized
        } else if pathComponents.contains("Music") {
            return "permission.location.music".localized
        } else {
            return "permission.location.folder".localized
        }
    }
    
    private func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
    
    private func isNetworkVolume(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            return !(resourceValues.volumeIsLocal ?? true)
        } catch {
            return false
        }
    }
    
}

// MARK: - 欢迎视图
struct WelcomeView: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 24) {
            BrandMark(size: 64)
            
            VStack(spacing: 8) {
                Text("app.title".localized)
                    .font(.title.weight(.semibold))
                
                Text("app.subtitle".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                welcomeTip(icon: "folder.badge.plus", text: "welcome.tip.1".localized)
                welcomeTip(icon: "bolt.fill", text: "welcome.tip.2".localized)
                welcomeTip(icon: "checkmark.shield", text: "welcome.tip.3".localized)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
    }
    
    private func welcomeTip(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.brand)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
