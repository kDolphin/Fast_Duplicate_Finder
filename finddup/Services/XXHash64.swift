import Foundation

/// Minimal xxHash64 (non-cryptographic) for fast content fingerprints.
/// Spec: https://github.com/Cyan4973/xxHash
struct XXHash64: Sendable {
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5
    
    private var seed: UInt64
    private var totalLen: UInt64 = 0
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var mem = [UInt8](repeating: 0, count: 32)
    private var memSize = 0
    private var largeLen = false
    
    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.prime1 &+ Self.prime2
        v2 = seed &+ Self.prime2
        v3 = seed
        v4 = seed &- Self.prime1
    }
    
    mutating func update(_ data: Data) {
        data.withUnsafeBytes { buf in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            update(bytes: base, count: buf.count)
        }
    }
    
    mutating func update(bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        totalLen &+= UInt64(count)
        var p = bytes
        var remaining = count
        
        if memSize + remaining < 32 {
            for i in 0..<remaining {
                mem[memSize + i] = p[i]
            }
            memSize += remaining
            return
        }
        
        if memSize > 0 {
            let fill = 32 - memSize
            for i in 0..<fill {
                mem[memSize + i] = p[i]
            }
            mem.withUnsafeBytes { mbuf in
                let mp = mbuf.bindMemory(to: UInt8.self).baseAddress!
                processStripe(mp)
            }
            p += fill
            remaining -= fill
            memSize = 0
            largeLen = true
        }
        
        while remaining >= 32 {
            processStripe(p)
            p += 32
            remaining -= 32
            largeLen = true
        }
        
        if remaining > 0 {
            for i in 0..<remaining {
                mem[i] = p[i]
            }
            memSize = remaining
        }
    }
    
    mutating func digest() -> UInt64 {
        var h: UInt64
        if largeLen {
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1)
            h = merge(h, v2)
            h = merge(h, v3)
            h = merge(h, v4)
        } else {
            h = seed &+ Self.prime5
        }
        h &+= totalLen
        
        var p = 0
        var remaining = memSize
        while remaining >= 8 {
            var k1 = read64(mem, p)
            k1 &*= Self.prime2
            k1 = rotl(k1, 31)
            k1 &*= Self.prime1
            h ^= k1
            h = rotl(h, 27) &* Self.prime1 &+ Self.prime4
            p += 8
            remaining -= 8
        }
        if remaining >= 4 {
            h ^= UInt64(read32(mem, p)) &* Self.prime1
            h = rotl(h, 23) &* Self.prime2 &+ Self.prime3
            p += 4
            remaining -= 4
        }
        while remaining > 0 {
            h ^= UInt64(mem[p]) &* Self.prime5
            h = rotl(h, 11) &* Self.prime1
            p += 1
            remaining -= 1
        }
        
        h ^= h >> 33
        h &*= Self.prime2
        h ^= h >> 29
        h &*= Self.prime3
        h ^= h >> 32
        return h
    }
    
    static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        var h = XXHash64(seed: seed)
        h.update(data)
        return h.digest()
    }
    
    // MARK: - Internals
    
    private mutating func processStripe(_ p: UnsafePointer<UInt8>) {
        v1 = round(v1, read64(p, 0))
        v2 = round(v2, read64(p, 8))
        v3 = round(v3, read64(p, 16))
        v4 = round(v4, read64(p, 24))
    }
    
    private func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ input &* Self.prime2
        a = rotl(a, 31)
        return a &* Self.prime1
    }
    
    private func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        var v = val
        v &*= Self.prime2
        v = rotl(v, 31)
        v &*= Self.prime1
        var a = acc ^ v
        a = a &* Self.prime1 &+ Self.prime4
        return a
    }
    
    private func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }
    
    private func read64(_ p: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        memcpy(&value, p + offset, 8)
        return UInt64(littleEndian: value)
    }
    
    private func read64(_ buffer: [UInt8], _ offset: Int) -> UInt64 {
        buffer.withUnsafeBytes { buf in
            read64(buf.bindMemory(to: UInt8.self).baseAddress!, offset)
        }
    }
    
    private func read32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = buffer.withUnsafeBytes { buf in
            memcpy(&value, buf.bindMemory(to: UInt8.self).baseAddress! + offset, 4)
        }
        return UInt32(littleEndian: value)
    }
}
