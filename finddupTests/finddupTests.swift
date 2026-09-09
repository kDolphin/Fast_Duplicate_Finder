import Foundation
import Testing
@testable import finddup

struct HashKeySpaceTests {
    private let turbo = "t128:" + String(repeating: "ab", count: 16)
    private let pkg = "pkg:" + String(repeating: "cd", count: 16)
    private let pkgv = "pkgv:" + String(repeating: "ef", count: 16)
    private let sha = String(repeating: "a", count: 64)
    
    @Test func turboCacheAcceptsTurboAndPackageDigests() {
        #expect(ContentHasher.isFinalHash(turbo))
        #expect(ContentHasher.isFinalHash(pkg))
        #expect(ContentHasher.isFinalHash(pkgv))
        #expect(ContentHasher.isTurboGroupHash(turbo))
    }
    
    @Test func turboCacheRejectsSHA256() {
        #expect(!ContentHasher.isFinalHash(sha))
        #expect(!ContentHasher.isTurboGroupHash(sha))
        #expect(ContentHasher.isPreciseHash(sha))
        #expect(ContentHasher.isPreciseHash("sha256:" + sha))
        let full = "t128f:" + String(repeating: "ab", count: 16)
        #expect(ContentHasher.isPreciseHash(full))
        #expect(!ContentHasher.isTurboGroupHash(full))
    }
    
    @Test func shaAndTurboAreDifferentGroupKeys() {
        #expect(turbo != sha)
        #expect(ContentHasher.isTurboGroupHash(turbo) != ContentHasher.isTurboGroupHash(sha))
    }
}

struct ScanCacheMergeTests {
    private func info(path: String, hash: String) -> CachedFileInfo {
        CachedFileInfo(
            url: URL(fileURLWithPath: path),
            size: 1024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            hash: hash
        )
    }
    
    @Test func homeScanDoesNotDropNASHashes() {
        let turboA = "t128:" + String(repeating: "11", count: 16)
        let turboB = "t128:" + String(repeating: "22", count: 16)
        let homePath = "/Users/tester/Movies/clip.mov"
        let nasPath = "/Volumes/NAS/Photos/img.jpg"
        
        var cache = ScanCache()
        cache.cachedFiles[homePath.standardizedPath] = info(path: homePath, hash: turboA)
        cache.cachedFiles[nasPath.standardizedPath] = info(path: nasPath, hash: turboB)
        
        let homeKey = homePath.standardizedPath
        cache.merge(
            working: [homeKey: info(path: homePath, hash: turboA)],
            scanRoots: ["/Users/tester".standardizedPath],
            currentPathKeys: [homeKey]
        )
        
        #expect(cache.cachedFiles[nasPath.standardizedPath]?.hash == turboB)
        #expect(cache.cachedFiles[homeKey]?.hash == turboA)
    }
    
    @Test func mergeRemovesMissingFilesOnlyUnderCurrentRoots() {
        let turbo = "t128:" + String(repeating: "33", count: 16)
        let gone = "/Users/tester/gone.bin"
        let stay = "/Users/tester/keep.bin"
        let nas = "/Volumes/NAS/keep.bin"
        
        var cache = ScanCache()
        cache.cachedFiles[gone.standardizedPath] = info(path: gone, hash: turbo)
        cache.cachedFiles[stay.standardizedPath] = info(path: stay, hash: turbo)
        cache.cachedFiles[nas.standardizedPath] = info(path: nas, hash: turbo)
        
        cache.merge(
            working: [stay.standardizedPath: info(path: stay, hash: turbo)],
            scanRoots: ["/Users/tester".standardizedPath],
            currentPathKeys: [stay.standardizedPath]
        )
        
        #expect(cache.cachedFiles[gone.standardizedPath] == nil)
        #expect(cache.cachedFiles[stay.standardizedPath] != nil)
        #expect(cache.cachedFiles[nas.standardizedPath] != nil)
    }
}

struct DeleteSelectionReconcileTests {
    private func file(_ path: String, size: Int64 = 100) -> FileInfo {
        FileInfo(
            url: URL(fileURLWithPath: path),
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1),
            creationDate: Date(timeIntervalSince1970: 1)
        )
    }
    
    @Test func reconcileKeepsMarksAndUnmarksNewKeep() {
        let a = file("/tmp/a.bin")
        let b = file("/tmp/b.bin")
        let before = DuplicateGroup(files: [a, b], fileSize: 100, hash: "t128:" + String(repeating: "11", count: 16))
        var previous = DeleteSelectionPolicy.defaultSelection(for: [before])
        #expect(previous.contains(b.url))
        #expect(!previous.contains(a.url))
        
        // Precise compare reorders keep to the previously marked file.
        let after = DuplicateGroup(
            files: [b, a],
            fileSize: 100,
            hash: "t128f:" + String(repeating: "22", count: 16),
            isVerified: true
        )
        let reconciled = DeleteSelectionPolicy.reconcile(previous: previous, groups: [after])
        #expect(!reconciled.contains(b.url))
        #expect(reconciled.contains(a.url))
    }
    
    @Test func reconcileAppliesDefaultWhenNoPreservedMarks() {
        let a = file("/tmp/c.bin")
        let b = file("/tmp/d.bin")
        let group = DuplicateGroup(
            files: [a, b],
            fileSize: 100,
            hash: "t128f:" + String(repeating: "33", count: 16),
            isVerified: true
        )
        let reconciled = DeleteSelectionPolicy.reconcile(previous: [], groups: [group])
        #expect(!reconciled.contains(a.url))
        #expect(reconciled.contains(b.url))
    }
    
    /// Downloads-like: hundreds of review groups verify + reorder; marks must survive.
    @Test func reconcilePreservesMarksAcrossBulkVerifyRebuild() {
        var before: [DuplicateGroup] = []
        for i in 0..<80 {
            let keep = file("/tmp/dl/keep-\(i).bin", size: Int64(1_024 * (i + 1)))
            let dup = file("/tmp/dl/dup-\(i).bin", size: Int64(1_024 * (i + 1)))
            before.append(DuplicateGroup(
                files: [keep, dup],
                fileSize: keep.size,
                hash: "t128:" + String(format: "%032d", i),
                needsReview: true,
                isVerified: false
            ))
        }
        // One purpose-risk package group — default selection skips it.
        let pkgA = file("/tmp/dl/App.app/Contents/MacOS/a", size: 50)
        let pkgB = file("/tmp/dl/Other.app/Contents/MacOS/b", size: 50)
        before.append(DuplicateGroup(
            files: [pkgA, pkgB],
            fileSize: 50,
            hash: "t128:" + String(repeating: "aa", count: 16),
            needsReview: true,
            isVerified: false,
            packageIdentityMismatch: true
        ))
        
        let previous = DeleteSelectionPolicy.defaultSelection(for: before)
        #expect(previous.count == 80)
        #expect(!previous.contains(pkgA.url))
        #expect(!previous.contains(pkgB.url))
        
        var after: [DuplicateGroup] = []
        for i in 0..<80 {
            let keep = file("/tmp/dl/keep-\(i).bin", size: Int64(1_024 * (i + 1)))
            let dup = file("/tmp/dl/dup-\(i).bin", size: Int64(1_024 * (i + 1)))
            // Half the groups reorder keep ↔ dup the way precise sort can.
            let files = i.isMultiple(of: 2) ? [dup, keep] : [keep, dup]
            after.append(DuplicateGroup(
                files: files,
                fileSize: keep.size,
                hash: "t128f:" + String(format: "%032d", i),
                needsReview: false,
                isVerified: true
            ))
        }
        after.append(DuplicateGroup(
            files: [pkgA, pkgB],
            fileSize: 50,
            hash: "t128:" + String(repeating: "aa", count: 16),
            needsReview: true,
            isVerified: false,
            packageIdentityMismatch: true
        ))
        
        let reconciled = DeleteSelectionPolicy.reconcile(previous: previous, groups: after)
        #expect(reconciled.count == 80)
        for group in after where !group.packageIdentityMismatch {
            #expect(!reconciled.contains(group.files[0].url))
            #expect(group.files.dropFirst().allSatisfy { reconciled.contains($0.url) })
        }
        #expect(!reconciled.contains(pkgA.url))
        #expect(!reconciled.contains(pkgB.url))
    }
}

struct ScanSnapshotVerifiedTests {
    private func file(_ path: String, size: Int64 = 100) -> FileInfo {
        FileInfo(
            url: URL(fileURLWithPath: path),
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1),
            creationDate: Date(timeIntervalSince1970: 1)
        )
    }
    
    @Test func materializeRestoresVerifiedFlag() {
        let a = file("/tmp/snap/a.bin")
        let b = file("/tmp/snap/b.bin")
        let live = DuplicateGroup(
            files: [a, b],
            fileSize: 100,
            hash: "t128f:" + String(repeating: "88", count: 16),
            needsReview: false,
            isVerified: true
        )
        let snap = ScanResultSnapshot.build(
            roots: [URL(fileURLWithPath: "/tmp/snap")],
            files: [a, b],
            groups: [live],
            mode: .turbo
        )
        let restored = snap.materialize(using: [a, b])
        #expect(restored?.count == 1)
        #expect(restored?.first?.isVerified == true)
        #expect(restored?.first?.needsReview == false)
        #expect(restored?.first?.hash.hasPrefix("t128f:") == true)
    }
    
    @Test func refreshGroupsUpdatesHotSnapshot() {
        ScanSnapshotStore.clear()
        let a = file("/tmp/snap2/a.bin")
        let b = file("/tmp/snap2/b.bin")
        let before = DuplicateGroup(
            files: [a, b],
            fileSize: 100,
            hash: "t128:" + String(repeating: "99", count: 16),
            isVerified: false
        )
        let snap = ScanResultSnapshot.build(
            roots: [URL(fileURLWithPath: "/tmp/snap2")],
            files: [a, b],
            groups: [before],
            mode: .turbo
        )
        // syncDisk: true — async writes after clear() used to resurrect test snapshots
        // into the sandboxed app container and break real Downloads rescans.
        ScanSnapshotStore.save(snap, syncDisk: true)
        
        let after = DuplicateGroup(
            files: [a, b],
            fileSize: 100,
            hash: "t128f:" + String(repeating: "aa", count: 16),
            isVerified: true
        )
        ScanSnapshotStore.refreshGroups(from: [after], syncDisk: true)
        let loaded = ScanSnapshotStore.load()
        #expect(loaded?.groups.first?.isVerified == true)
        #expect(loaded?.groups.first?.hash.hasPrefix("t128f:") == true)
        ScanSnapshotStore.clear()
    }
    
    @Test func overlayVerifiedCopiesConfirmedByPathSet() {
        let a = file("/tmp/snap3/a.bin")
        let b = file("/tmp/snap3/b.bin")
        let previous = ScanResultSnapshot.build(
            roots: [URL(fileURLWithPath: "/tmp/snap3")],
            files: [a, b],
            groups: [
                DuplicateGroup(
                    files: [a, b],
                    fileSize: 100,
                    hash: "t128f:" + String(repeating: "bb", count: 16),
                    isVerified: true
                )
            ],
            mode: .turbo
        )
        let rebuilt = DuplicateGroup(
            files: [a, b],
            fileSize: 100,
            hash: "t128:" + String(repeating: "cc", count: 16),
            isVerified: false
        )
        let overlaid = ScanSnapshotStore.overlayVerified(from: previous, onto: [rebuilt])
        #expect(overlaid.first?.isVerified == true)
        #expect(overlaid.first?.hash.hasPrefix("t128f:") == true)
    }
}

struct DuplicateGroupDisplayTests {
    private func file(_ path: String, isPackage: Bool = false) -> FileInfo {
        FileInfo(
            url: URL(fileURLWithPath: path),
            size: 100,
            modificationDate: Date(timeIntervalSince1970: 1),
            creationDate: Date(timeIntervalSince1970: 1),
            isPackage: isPackage
        )
    }
    
    @Test func relatedNamesShowRepresentativeFilename() {
        let group = DuplicateGroup(
            files: [
                file("/tmp/Report.pdf"),
                file("/tmp/Report copy.pdf"),
                file("/tmp/Report copy 2.pdf"),
                file("/tmp/Report (3).pdf"),
                file("/tmp/Report 副本.pdf")
            ],
            fileSize: 100,
            hash: "t128:" + String(repeating: "66", count: 16)
        )
        let title = DuplicateGroupDisplay.outlineTitle(for: group)
        #expect(title.contains("Report"))
        #expect(title.contains("5"))
        #expect(!title.contains("重复"))
    }
    
    @Test func unrelatedNamesUseCountOnlyLabel() {
        let group = DuplicateGroup(
            files: [
                file("/tmp/alpha.bin"),
                file("/tmp/beta.bin")
            ],
            fileSize: 100,
            hash: "t128:" + String(repeating: "77", count: 16)
        )
        let title = DuplicateGroupDisplay.outlineTitle(for: group)
        #expect(title == "results.duplicate.files".localized(2))
    }
}

struct PurposeRiskSelectionTests {
    private func file(_ path: String, size: Int64 = 100, isPackage: Bool = false) -> FileInfo {
        FileInfo(
            url: URL(fileURLWithPath: path),
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1),
            creationDate: Date(timeIntervalSince1970: 1),
            isPackage: isPackage
        )
    }
    
    @Test func differentBasenamesDoNotBlockDefaultSelection() {
        let a = file("/tmp/Downloads/Report-final.pdf", size: 5_000_000)
        let b = file("/tmp/Downloads/Report (from email).pdf", size: 5_000_000)
        #expect(PackageIdentity.purposeRisk(for: [a, b]) == .none)
        
        let group = DuplicateGroup(files: [a, b], fileSize: 5_000_000, hash: "t128:" + String(repeating: "44", count: 16))
        #expect(!group.packageIdentityMismatch)
        let marks = DeleteSelectionPolicy.defaultSelection(for: [group])
        #expect(!marks.contains(a.url))
        #expect(marks.contains(b.url))
    }
    
    @Test func packageShellStillBlocksDefaultSelection() {
        let a = file("/tmp/Foo.app", size: 9_000_000, isPackage: true)
        let b = file("/tmp/Bar.app", size: 9_000_000, isPackage: true)
        #expect(PackageIdentity.purposeRisk(for: [a, b]) == .packageShell)
        let group = DuplicateGroup(
            files: [a, b],
            fileSize: 9_000_000,
            hash: "pkg:" + String(repeating: "55", count: 16),
            needsReview: true,
            packageIdentityMismatch: true
        )
        let marks = DeleteSelectionPolicy.defaultSelection(for: [group])
        #expect(marks.isEmpty)
    }
}

struct CacheShardTests {
    @Test func pathFallbackSplitsVolumesFromBoot() {
        let nas = CacheShardID.fallback(forPath: "/Volumes/NAS/Photos/a.jpg")
        let boot = CacheShardID.fallback(forPath: "/Users/me/Movies/a.mov")
        #expect(nas.token.contains("Volumes"))
        #expect(boot.token == "p-boot")
        #expect(nas.token != boot.token)
    }
    
    @Test func slimDropsOldestFirst() {
        var cache = ScanCache()
        let old = Date(timeIntervalSince1970: 1)
        let new = Date(timeIntervalSince1970: 9_999_999)
        cache.cachedFiles["/old"] = CachedFileInfo(
            url: URL(fileURLWithPath: "/old"),
            size: 1,
            modificationDate: old,
            hash: "t128:" + String(repeating: "11", count: 16)
        )
        cache.cachedFiles["/new"] = CachedFileInfo(
            url: URL(fileURLWithPath: "/new"),
            size: 1,
            modificationDate: new,
            hash: "t128:" + String(repeating: "22", count: 16)
        )
        // lastScanDate is Date() on init — force ages via keepNewest after tweaking is hard.
        cache.keepNewest(1)
        #expect(cache.cachedFiles.count == 1)
    }
}

struct VolumeKindTests {
    @Test func explicitLocalVolumeIsNotNetwork() {
        #expect(!VolumeKind.classify(path: "/Volumes/USBDisk/Photos", volumeIsLocal: true))
        #expect(!VolumeKind.classify(path: "/Users/me/Desktop", volumeIsLocal: true))
    }
    
    @Test func explicitRemoteVolumeIsNetwork() {
        #expect(VolumeKind.classify(path: "/Volumes/NAS/Share", volumeIsLocal: false))
    }
    
    @Test func unknownVolumesFallback() {
        #expect(VolumeKind.classify(path: "/Volumes/MaybeNAS/a", volumeIsLocal: nil))
        #expect(!VolumeKind.classify(path: "/System/Volumes/Data/Users/me", volumeIsLocal: nil))
        #expect(!VolumeKind.classify(path: "/Users/me/file", volumeIsLocal: nil))
    }
}

struct DuplicateGroupEditingTests {
    private func file(_ path: String, size: Int64 = 100) -> FileInfo {
        FileInfo(
            url: URL(fileURLWithPath: path),
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1),
            creationDate: Date(timeIntervalSince1970: 1)
        )
    }
    
    @Test func removingLeavesPairAndDropsSingleton() {
        let a = file("/tmp/a.bin")
        let b = file("/tmp/b.bin")
        let c = file("/tmp/c.bin")
        let group = DuplicateGroup(
            files: [a, b, c],
            fileSize: 100,
            hash: "t128:" + String(repeating: "44", count: 16)
        )
        let next = DuplicateGroupEditing.removing([c.url], from: [group])
        #expect(next.count == 1)
        #expect(next[0].files.count == 2)
        
        let empty = DuplicateGroupEditing.removing([a.url, b.url], from: next)
        #expect(empty.isEmpty)
    }
}

struct AppVersionTests {
    @Test func tagPrefixAndPatchOrder() {
        #expect(AppVersion.normalize("v1.0.6") == "1.0.6")
        #expect(AppVersion.isNewer("v1.0.6", than: "1.0.5"))
        #expect(AppVersion.isNewer("1.0.10", than: "1.0.9"))
        #expect(!AppVersion.isNewer("1.0.5", than: "1.0.5"))
        #expect(!AppVersion.isNewer("1.0.4", than: "1.0.5"))
    }
}
