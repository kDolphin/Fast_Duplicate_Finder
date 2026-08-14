import Foundation
import CryptoKit

/// Layered content fingerprinting (P1 + P2 modes):
/// - `partial`: xxHash64 of tiny samples (fast reject)
/// - `standard`: SHA-256 samples / full small files (Default + Verify)
/// - `turboFinal`: dual-seed xxHash of larger samples (Turbo mode final)
/// - `full`: entire-file SHA-256 (Verify pass)
enum ContentHasher: Sendable {
    
    /// Files at or below this size: one full read (skip partial round-trip).
    static let smallFileThreshold: Int64 = 512 * 1024
    /// Full-file read instead of multi-point sample up to this size.
    static let fullHashThreshold: Int64 = 2 * 1024 * 1024
    
    enum Mode: Sendable {
        case partial
        case standard
        case turboFinal
        case full
    }
    
    /// Digest string suitable for grouping / cache.
    /// - partial: `x64:` + 16 hex
    /// - turboFinal: `t128:` + 32 hex (two xxHash64 seeds)
    /// - standard/full: 64 hex SHA-256
    static func hashFile(at url: URL, size: Int64, mode: Mode) -> String? {
        let isNetwork = VolumeKind.isNetwork(url)
        
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            
            let fileSize = size > 0 ? Int(size) : (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard fileSize >= 0 else { return nil }
            
            if fileSize == 0 {
                switch mode {
                case .partial:
                    return formatXXH(0)
                case .turboFinal:
                    return formatTurbo(0, 0)
                case .standard, .full:
                    var h = SHA256()
                    withUnsafeBytes(of: Int64(0).bigEndian) { h.update(bufferPointer: $0) }
                    return hexSHA(h.finalize())
                }
            }
            
            switch mode {
            case .partial:
                return try hashPartial(handle: handle, fileSize: fileSize, isNetwork: isNetwork)
            case .turboFinal:
                return try hashTurboFinal(handle: handle, fileSize: fileSize, isNetwork: isNetwork)
            case .standard:
                if Int64(fileSize) <= fullHashThreshold {
                    return try hashSHAFull(handle: handle, fileSize: fileSize)
                }
                if isNetwork {
                    return try hashSHANetworkStandard(handle: handle, fileSize: fileSize)
                }
                return try hashSHALocalStandard(handle: handle, fileSize: fileSize)
            case .full:
                return try hashSHAFull(handle: handle, fileSize: fileSize)
            }
        } catch {
            return nil
        }
    }
    
    static func isRealContentHash(_ hash: String) -> Bool {
        if hash.hasPrefix("UNIQUE_") || hash.hasPrefix("PREFILTERED_") { return false }
        if hash.hasPrefix("x64:") {
            let body = hash.dropFirst(4)
            return body.count == 16 && body.allSatisfy(\.isHexDigit)
        }
        if hash.hasPrefix("t128:") {
            let body = hash.dropFirst(5)
            return body.count == 32 && body.allSatisfy(\.isHexDigit)
        }
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit)
    }
    
    /// Turbo grouping / durable cache keys. SHA-256 from precise verify must not
    /// share this space or a later turbo scan will split the same content.
    static func isFinalHash(_ hash: String, for mode: ScanMode = .turbo) -> Bool {
        _ = mode
        return isTurboGroupHash(hash)
    }
    
    static func isTurboGroupHash(_ hash: String) -> Bool {
        if hash.hasPrefix("t128:") {
            let body = hash.dropFirst(5)
            return body.count == 32 && body.allSatisfy(\.isHexDigit)
        }
        if hash.hasPrefix("pkg:") || hash.hasPrefix("pkgv:") {
            let body = hash.split(separator: ":").last.map(String.init) ?? ""
            return body.count == 32 && body.allSatisfy(\.isHexDigit)
        }
        return false
    }
    
    /// Full-file SHA-256 from the verify pass (session grouping only, not turbo cache).
    static func isPreciseHash(_ hash: String) -> Bool {
        if hash.hasPrefix("sha256:") {
            let body = hash.dropFirst(7)
            return body.count == 64 && body.allSatisfy(\.isHexDigit)
        }
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit)
    }
    
    /// Final hash mode after partial (product = turbo).
    static func finalMode(for scanMode: ScanMode = .turbo) -> Mode {
        _ = scanMode
        return .turboFinal
    }
    
    // MARK: - Partial (xxHash64)
    
    private static func hashPartial(handle: FileHandle, fileSize: Int, isNetwork: Bool) throws -> String {
        var xxh = XXHash64(seed: 0)
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { raw in
            xxh.update(Data(raw))
        }
        
        if isNetwork {
            let sample = min(4096, fileSize)
            try feedSample(handle: handle, offset: fileSize / 2, length: sample, into: &xxh)
        } else {
            let sample = min(8192, fileSize)
            try feedSample(handle: handle, offset: 0, length: sample, into: &xxh)
            if fileSize > sample * 2 {
                try feedSample(handle: handle, offset: fileSize / 2, length: sample, into: &xxh)
                try feedSample(handle: handle, offset: max(0, fileSize - sample), length: sample, into: &xxh)
            }
        }
        return formatXXH(xxh.digest())
    }
    
    /// Turbo final: dual-seed xxHash over larger samples (or whole small file).
    private static func hashTurboFinal(handle: FileHandle, fileSize: Int, isNetwork: Bool) throws -> String {
        var h0 = XXHash64(seed: 0)
        var h1 = XXHash64(seed: 1)
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { raw in
            let d = Data(raw)
            h0.update(d)
            h1.update(d)
        }
        
        if Int64(fileSize) <= fullHashThreshold {
            try handle.seek(toOffset: 0)
            // Slightly larger chunks on network to amortize RTT
            let chunk = isNetwork ? 256 * 1024 : 1024 * 1024
            var remaining = fileSize
            while remaining > 0 {
                let n = min(chunk, remaining)
                let data = handle.readData(ofLength: n)
                if data.isEmpty { break }
                h0.update(data)
                h1.update(data)
                remaining -= data.count
            }
            return formatTurbo(h0.digest(), h1.digest())
        }
        
        if isNetwork {
            // Head → mid → tail only, ascending seeks (HDD/NAS-friendly).
            // 12KB windows: Lr.Pics SMB bench ~1.5× vs 24KB with same grouping on sample.
            try feedNetworkThreePoint(handle: handle, fileSize: fileSize, sample: min(12 * 1024, fileSize)) { data in
                h0.update(data)
                h1.update(data)
            }
            return formatTurbo(h0.digest(), h1.digest())
        }
        
        let sample = min(128 * 1024, fileSize)
        let points = [0, fileSize / 4, fileSize / 2, (fileSize * 3) / 4, max(0, fileSize - sample)]
        var seen = Set<Int>()
        for offset in points {
            let o = min(max(0, offset), max(0, fileSize - 1))
            guard seen.insert(o).inserted else { continue }
            try handle.seek(toOffset: UInt64(o))
            let data = handle.readData(ofLength: sample)
            if !data.isEmpty {
                h0.update(data)
                h1.update(data)
            }
        }
        return formatTurbo(h0.digest(), h1.digest())
    }
    
    /// Single ascending pass: head, mid, tail — minimizes reverse seeks on NAS/HDD.
    private static func feedNetworkThreePoint(
        handle: FileHandle,
        fileSize: Int,
        sample: Int,
        into consume: (Data) -> Void
    ) throws {
        let s = max(1, min(sample, fileSize))
        let offsets = [0, max(0, fileSize / 2 - s / 2), max(0, fileSize - s)]
        var lastEnd = -1
        for offset in offsets {
            let o = min(offset, max(0, fileSize - 1))
            // Skip duplicate/overlapping windows on tiny files
            if o <= lastEnd && lastEnd >= 0 { continue }
            try handle.seek(toOffset: UInt64(o))
            let data = handle.readData(ofLength: s)
            if !data.isEmpty {
                consume(data)
                lastEnd = o + data.count - 1
            }
        }
    }
    
    // MARK: - Standard / full (SHA-256)
    
    private static func hashSHAFull(handle: FileHandle, fileSize: Int) throws -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { hasher.update(bufferPointer: $0) }
        try handle.seek(toOffset: 0)
        // Larger sequential chunks for SSD throughput
        let chunk = 1024 * 1024
        var remaining = fileSize
        while remaining > 0 {
            let n = min(chunk, remaining)
            let data = handle.readData(ofLength: n)
            if data.isEmpty { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hexSHA(hasher.finalize())
    }
    
    /// Local large file: 3×256KB sequential-ish samples (head / mid / tail)
    private static func hashSHALocalStandard(handle: FileHandle, fileSize: Int) throws -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { hasher.update(bufferPointer: $0) }
        let sample = min(256 * 1024, fileSize)
        try sampleAt(handle: handle, offset: 0, length: sample, into: &hasher)
        if fileSize > sample * 2 {
            try sampleAt(handle: handle, offset: (fileSize - sample) / 2, length: sample, into: &hasher)
            try sampleAt(handle: handle, offset: max(0, fileSize - sample), length: sample, into: &hasher)
        }
        return hexSHA(hasher.finalize())
    }
    
    /// Network: 3×16KB (head / mid / tail) — balance accuracy vs latency
    private static func hashSHANetworkStandard(handle: FileHandle, fileSize: Int) throws -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { hasher.update(bufferPointer: $0) }
        let sample = min(16 * 1024, fileSize)
        try sampleAt(handle: handle, offset: 0, length: sample, into: &hasher)
        if fileSize > sample * 2 {
            try sampleAt(handle: handle, offset: fileSize / 2, length: sample, into: &hasher)
            try sampleAt(handle: handle, offset: max(0, fileSize - sample), length: sample, into: &hasher)
        }
        return hexSHA(hasher.finalize())
    }
    
    // MARK: - IO helpers
    
    private static func feedSample(
        handle: FileHandle,
        offset: Int,
        length: Int,
        into xxh: inout XXHash64
    ) throws {
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = handle.readData(ofLength: length)
        if !data.isEmpty {
            xxh.update(data)
        }
    }
    
    private static func sampleAt(
        handle: FileHandle,
        offset: Int,
        length: Int,
        into hasher: inout SHA256
    ) throws {
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = handle.readData(ofLength: length)
        if !data.isEmpty {
            hasher.update(data: data)
        }
    }
    
    private static func formatXXH(_ value: UInt64) -> String {
        "x64:" + String(format: "%016llx", value)
    }
    
    private static func formatTurbo(_ a: UInt64, _ b: UInt64) -> String {
        "t128:" + String(format: "%016llx%016llx", a, b)
    }
    
    private static func hexSHA(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Storage-aware concurrency

enum StorageConcurrency: Sendable {
    static func isNetworkPath(_ path: String) -> Bool {
        VolumeKind.isNetwork(URL(fileURLWithPath: path))
    }
    
    static func isNetworkScan(roots: [URL], sample: [FileInfo]) -> Bool {
        if roots.contains(where: { VolumeKind.isNetwork($0) }) { return true }
        let n = min(32, sample.count)
        guard n > 0 else { return false }
        let networkHits = sample.prefix(n).filter { VolumeKind.isNetwork($0.url) }.count
        return networkHits * 2 >= n // ≥50% sample on network
    }
    
    /// Network hash concurrency (SMB Lr.Pics bench: 6 ≈ 2–3× throughput vs 3).
    static let networkConcurrency = 6
    /// Network directory listing concurrency (parallel first-level subtrees).
    static let networkEnumConcurrency = 6
    
    static func level(for roots: [URL], candidateSample: [FileInfo]) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if isNetworkScan(roots: roots, sample: candidateSample) {
            return networkConcurrency
        }
        
        var sawSSD = false
        var sawHDD = false
        let ssdKey = URLResourceKey("NSURLVolumeIsSolidStateKey")
        for root in roots.prefix(3) {
            if let vals = try? root.resourceValues(forKeys: [.volumeIsLocalKey, ssdKey]) {
                if vals.volumeIsLocal == false {
                    return networkConcurrency
                }
                if let isSSD = vals.allValues[ssdKey] as? Bool {
                    if isSSD { sawSSD = true } else { sawHDD = true }
                }
            }
        }
        if sawHDD && !sawSSD {
            return min(4, max(2, cores))
        }
        return min(48, max(8, cores * 3))
    }
}
