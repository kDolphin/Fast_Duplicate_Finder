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
