import SwiftUI

struct ContentView: View {
    @StateObject private var duplicateFinder = DuplicateFinder()
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var selectedFolders: [URL] = []
    @State private var isScanning = false
    @State private var showingPermissionAlert = false
    @State private var permissionDeniedPath: String = ""
    @State private var groupExpandState = GroupExpandState()
    @State private var showingDeletePreview = false
    @State private var filesToDelete: Set<URL> = []
    /// Active cleanup batch (filter-scoped). Preview / confirm only act on this set.
    @State private var cleanupSelection: Set<URL> = []
    @State private var isDeleting = false
    @State private var deleteResult: DeleteResult?
    @State private var showingDeleteResult = false
    @State private var showingReviewBeforeDelete = false
    @State private var showingPackageIdentityBeforeDelete = false
    @State private var didRestoreFolders = false
    
    // Deletion settings
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
                        expandState: $groupExpandState,
                        selectedForDelete: $filesToDelete,
                        onDeletePreview: { scopedSelection in
                            if autoDeleteDuplicates && !confirmBeforeDelete {
                                prepareAutoDelete(selection: scopedSelection)
                            } else {
                                prepareDeletePreview(selection: scopedSelection)
                            }
                        },
                        onDeleteFile: deleteFile,
                        onVerifyGroup: { id in
                            Task { await duplicateFinder.verifyGroupPrecise(id: id) }
                        },
                        onVerifyAllReview: {
                            Task { await duplicateFinder.verifyAllReviewGroups() }
                        },
                        onCancelVerify: {
                            duplicateFinder.cancelVerify()
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
                } else if duplicateFinder.lastOutcome == .completed {
                    NoResultsView(cancelled: false)
                } else if duplicateFinder.lastOutcome == .cancelled {
                    NoResultsView(cancelled: true)
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
            if !didRestoreFolders {
                didRestoreFolders = true
                selectedFolders = FolderAccessManager.shared.restoreAndAccess()
                ScanCacheManager.shared.preloadInBackground()
            }
        }
        .onChange(of: selectedFolders) { newFolders in
            FolderAccessManager.shared.sync(newFolders)
        }
        .sheet(isPresented: $showingDeletePreview) {
            DeletePreviewSheet(
                duplicateGroups: duplicateFinder.duplicateGroups,
                filesToDelete: $cleanupSelection,
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
    
    // MARK: - Scan
    private func startScan() {
        if isScanning {
            // Stop
            duplicateFinder.cancelScan()
            isScanning = false
        } else {
            // Start
            guard !selectedFolders.isEmpty else { return }
            
            // Permission probe
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
        // Clear previous results and errors
        duplicateFinder.duplicateGroups = []
        duplicateFinder.errorMessage = nil
        filesToDelete.removeAll()
        groupExpandState.reset()
        
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
    
    // MARK: - Delete
    /// - Parameter selection: filter-scoped marks from ResultsView (not the full global set).
    private func prepareAutoDelete(selection: Set<URL>) {
        cleanupSelection = selection
        guard !cleanupSelection.isEmpty else { return }
        if gateBulkDeleteWarnings() { return }
        deleteSelectedFiles(moveToTrash: moveToTrash)
    }
    
    private func prepareDeletePreview(selection: Set<URL>) {
        cleanupSelection = selection
        guard !cleanupSelection.isEmpty else { return }
        if gateBulkDeleteWarnings() { return }
        proceedDeletePreview()
    }
    
    /// Returns true if a warning sheet was presented (caller should stop).
    @discardableResult
    private func gateBulkDeleteWarnings() -> Bool {
        // Warnings only for items in the active cleanup batch (current filter).
        let markedIdentity = duplicateFinder.duplicateGroups.contains { group in
            group.packageIdentityMismatch &&
            group.files.contains { cleanupSelection.contains($0.url) }
        }
        if markedIdentity {
            showingPackageIdentityBeforeDelete = true
            return true
        }
        let markedNeedsReview = duplicateFinder.duplicateGroups.contains { group in
            group.needsReview && !group.isVerified && !group.packageIdentityMismatch &&
            group.files.contains { cleanupSelection.contains($0.url) }
        }
        if markedNeedsReview {
            showingReviewBeforeDelete = true
            return true
        }
        return false
    }
    
    private func proceedDeletePreview() {
        guard !cleanupSelection.isEmpty else { return }
        if confirmBeforeDelete {
            showingDeletePreview = true
        } else {
            deleteSelectedFiles(moveToTrash: moveToTrash)
        }
    }
    
    private func deleteFile(_ file: FileInfo) {
        do {
            if moveToTrash && !VolumeKind.isNetwork(file.url) {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            } else {
                try FileManager.default.removeItem(at: file.url)
            }
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
        let batch = cleanupSelection
        
        Task {
            var successCount = 0
            var failureCount = 0
            var permissionDenied = false
            var deniedPath = ""
            var deleted: [URL] = []
            
            for fileURL in batch {
                do {
                    // Local → Trash when asked; network volumes always remove permanently
                    if moveToTrash && !VolumeKind.isNetwork(fileURL) {
                        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                    } else {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    successCount += 1
                    deleted.append(fileURL)
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
                    for url in deleted {
                        filesToDelete.remove(url)
                    }
                    cleanupSelection.removeAll()
                    deleteResult = DeleteResult(successCount: successCount, failureCount: failureCount)
                    isDeleting = false
                    showingDeleteResult = true
                    if successCount > 0 {
                        duplicateFinder.removeDeletedURLs(Set(deleted))
                        DeleteSelectionPolicy.prune(&filesToDelete, groups: duplicateFinder.duplicateGroups)
                    }
                }
            }
        }
    }
    
    // MARK: - Permissions
    private func needsPermissionCheck(for folders: [URL]) -> Bool {
        // Probe by actually listing — TCC paths may fail even after a picker grant.
        for folder in folders {
            // Common protected locations first
            let pathComponents = folder.pathComponents
            let protectedFolders = ["Desktop", "Documents", "Downloads", 
                                   "Pictures", "Movies", "Music", "Library"]
            
            let isProtectedPath = protectedFolders.contains { folderName in
                pathComponents.contains(folderName)
            }
            
            if isProtectedPath {
                // Try a real listing
                do {
                    _ = try FileManager.default.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                } catch CocoaError.fileReadNoPermission, CocoaError.fileNoSuchFile {
                    return true
                } catch {
                    // Any other error: treat as needing a permission check
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
            // Try to read the folder
            do {
                // Start security-scoped access first
                let hasAccess = folder.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        folder.stopAccessingSecurityScopedResource()
                    }
                }
                
                // List directory contents
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
                // Other Cocoa errors: keep checking remaining folders
            } catch {
                // Non-CocoaError: still treat as a possible permission issue
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
    
}

// MARK: - Welcome
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
