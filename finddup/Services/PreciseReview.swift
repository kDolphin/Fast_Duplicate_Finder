import Foundation

/// Re-apply persisted whole-file fingerprints after a turbo scan.
enum PreciseReview: Sendable {
    static func apply(_ groups: [DuplicateGroup], cache: ScanCache) -> [DuplicateGroup] {
        guard !cache.preciseFiles.isEmpty else { return groups }
        var out: [DuplicateGroup] = []
        out.reserveCapacity(groups.count)
        for group in groups {
            out.append(contentsOf: refine(group, cache: cache))
        }
        return out.sorted { $0.duplicateSize > $1.duplicateSize }
    }
    
    private static func refine(_ group: DuplicateGroup, cache: ScanCache) -> [DuplicateGroup] {
        var byHash: [String: [FileInfo]] = [:]
        var missing = 0
        for file in group.files {
            guard let rec = cache.preciseFiles[file.pathKey],
                  ContentHasher.isPreciseHash(rec.hash),
                  !rec.hasChanged(comparedTo: file) else {
                missing += 1
                continue
            }
            byHash[rec.hash, default: []].append(file)
        }
        // Need a record for every member or we leave the turbo group as-is.
        if missing > 0 || byHash.isEmpty { return [group] }
        
        var refined: [DuplicateGroup] = []
        for (hash, files) in byHash where files.count > 1 {
            let sorted = files.sorted { $0.pathKey < $1.pathKey }
            let mismatch = PackageIdentity.hasIdentityMismatch(packages: sorted)
            refined.append(DuplicateGroup(
                files: sorted,
                fileSize: sorted[0].size,
                hash: hash,
                needsReview: mismatch,
                isVerified: !mismatch,
                packageIdentityMismatch: mismatch
            ))
        }
        return refined
    }
}
