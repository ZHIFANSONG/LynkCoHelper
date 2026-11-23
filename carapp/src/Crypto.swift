//
//  Crypto.swift
//  纯 Swift 实现 SHA-256 / HMAC-SHA256 / MD5，避免依赖 CommonCrypto 或 CryptoKit。
//  只用于领克网关的 X-API-SIGNATURE 计算。
//

import Foundation

// MARK: - SHA-256

struct SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ input: Data) -> Data {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](input)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(i)) & 0xff))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var off = 0
        while off < msg.count {
            for i in 0..<16 {
                let j = off + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16)
                     | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            off += 64
        }

        var out = Data()
        for v in h {
            out.append(UInt8((v >> 24) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8(v & 0xff))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - HMAC-SHA256

enum HMAC {
    static func sha256(key: Data, message: Data) -> Data {
        var k = key
        if k.count > 64 { k = SHA256.hash(k) }
        if k.count < 64 { k.append(Data(repeating: 0, count: 64 - k.count)) }

        var ipad = Data(count: 64)
        var opad = Data(count: 64)
        for i in 0..<64 {
            ipad[i] = k[i] ^ 0x36
            opad[i] = k[i] ^ 0x5c
        }
        var inner = Data()
        inner.append(ipad)
        inner.append(message)
        let ih = SHA256.hash(inner)

        var outer = Data()
        outer.append(opad)
        outer.append(ih)
        return SHA256.hash(outer)
    }
}

// MARK: - MD5

struct MD5 {
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private static let k: [UInt32] = (0..<64).map { i in
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4294967296.0))
    }

    static func hash(_ input: Data) -> Data {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        var msg = [UInt8](input)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 {
            msg.append(UInt8((bitLen >> UInt64(8 * i)) & 0xff))
        }

        var off = 0
        while off < msg.count {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = off + i * 4
                m[i] = UInt32(msg[j]) | (UInt32(msg[j + 1]) << 8)
                     | (UInt32(msg[j + 2]) << 16) | (UInt32(msg[j + 3]) << 24)
            }
            var A = a0, B = b0, C = c0, D = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (B & C) | (~B & D); g = i
                case 16..<32: f = (D & B) | (~D & C); g = (5 * i + 1) % 16
                case 32..<48: f = B ^ C ^ D; g = (3 * i + 5) % 16
                default: f = C ^ (B | ~D); g = (7 * i) % 16
                }
                let tmp = D
                D = C
                C = B
                let sum = A &+ f &+ k[i] &+ m[g]
                B = B &+ rotl(sum, s[i])
                A = tmp
            }
            a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
            off += 64
        }

        var out = Data()
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}

// MARK: - 便捷

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    var base64: String { base64EncodedString() }
}

extension String {
    var utf8Data: Data { Data(utf8) }
}
