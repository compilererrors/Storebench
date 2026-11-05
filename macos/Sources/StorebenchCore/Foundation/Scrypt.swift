import CommonCrypto
import Foundation

/// scrypt (RFC 7914), used to derive the key that wraps a password-protected database key.
/// Apple's frameworks provide PBKDF2 but not scrypt, so the memory-hard mixing is implemented here.
public enum Scrypt {
    public enum Failure: Error { case invalidParameters, derivationFailed }

    public static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) throws -> Data {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, length > 0, p * r <= 1 << 20, n <= 1 << 22 else { throw Failure.invalidParameters }
        var blocks = try pbkdf2(password: password, salt: salt, length: p * 128 * r)
        let blockWords = 32 * r
        var words = [UInt32](repeating: 0, count: p * blockWords)
        blocks.withUnsafeBytes { raw in
            for index in 0..<words.count { words[index] = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian }
        }
        var scratch = [UInt32](repeating: 0, count: n * blockWords)
        for lane in 0..<p {
            words.withUnsafeMutableBufferPointer { all in
                let block = UnsafeMutableBufferPointer(rebasing: all[(lane * blockWords)..<((lane + 1) * blockWords)])
                scratch.withUnsafeMutableBufferPointer { romix(block, r: r, n: n, table: $0) }
            }
        }
        for index in 0..<words.count { withUnsafeBytes(of: words[index].littleEndian) { blocks.replaceSubrange((index * 4)..<(index * 4 + 4), with: $0) } }
        defer { blocks.resetBytes(in: 0..<blocks.count); scratch.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        return try pbkdf2(password: password, salt: blocks, length: length)
    }

    static func pbkdf2(password: Data, salt: Data, length: Int) throws -> Data {
        var output = Data(count: length)
        let status = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { secret in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed }
        return output
    }

    private static func romix(_ block: UnsafeMutableBufferPointer<UInt32>, r: Int, n: Int, table: UnsafeMutableBufferPointer<UInt32>) {
        let size = 32 * r
        var buffer = [UInt32](repeating: 0, count: size)
        for index in 0..<n {
            _ = UnsafeMutableBufferPointer(rebasing: table[(index * size)..<((index + 1) * size)]).update(fromContentsOf: block)
            blockMix(block, r: r, output: &buffer)
        }
        for _ in 0..<n {
            let j = Int(block[(2 * r - 1) * 16]) & (n - 1)
            for word in 0..<size { block[word] ^= table[j * size + word] }
            blockMix(block, r: r, output: &buffer)
        }
    }

    private static func blockMix(_ block: UnsafeMutableBufferPointer<UInt32>, r: Int, output: inout [UInt32]) {
        var x = [UInt32](block[((2 * r - 1) * 16)..<(2 * r * 16)])
        for index in 0..<(2 * r) {
            for word in 0..<16 { x[word] ^= block[index * 16 + word] }
            salsa20_8(&x)
            let destination = (index % 2 == 0 ? index / 2 : r + index / 2) * 16
            for word in 0..<16 { output[destination + word] = x[word] }
        }
        for word in 0..<(32 * r) { block[word] = output[word] }
    }

    private static func salsa20_8(_ state: inout [UInt32]) {
        var x = state
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
        for _ in 0..<4 {
            x[4] ^= rotate(x[0] &+ x[12], 7); x[8] ^= rotate(x[4] &+ x[0], 9); x[12] ^= rotate(x[8] &+ x[4], 13); x[0] ^= rotate(x[12] &+ x[8], 18)
            x[9] ^= rotate(x[5] &+ x[1], 7); x[13] ^= rotate(x[9] &+ x[5], 9); x[1] ^= rotate(x[13] &+ x[9], 13); x[5] ^= rotate(x[1] &+ x[13], 18)
            x[14] ^= rotate(x[10] &+ x[6], 7); x[2] ^= rotate(x[14] &+ x[10], 9); x[6] ^= rotate(x[2] &+ x[14], 13); x[10] ^= rotate(x[6] &+ x[2], 18)
            x[3] ^= rotate(x[15] &+ x[11], 7); x[7] ^= rotate(x[3] &+ x[15], 9); x[11] ^= rotate(x[7] &+ x[3], 13); x[15] ^= rotate(x[11] &+ x[7], 18)
            x[1] ^= rotate(x[0] &+ x[3], 7); x[2] ^= rotate(x[1] &+ x[0], 9); x[3] ^= rotate(x[2] &+ x[1], 13); x[0] ^= rotate(x[3] &+ x[2], 18)
            x[6] ^= rotate(x[5] &+ x[4], 7); x[7] ^= rotate(x[6] &+ x[5], 9); x[4] ^= rotate(x[7] &+ x[6], 13); x[5] ^= rotate(x[4] &+ x[7], 18)
            x[11] ^= rotate(x[10] &+ x[9], 7); x[8] ^= rotate(x[11] &+ x[10], 9); x[9] ^= rotate(x[8] &+ x[11], 13); x[10] ^= rotate(x[9] &+ x[8], 18)
            x[12] ^= rotate(x[15] &+ x[14], 7); x[13] ^= rotate(x[12] &+ x[15], 9); x[14] ^= rotate(x[13] &+ x[12], 13); x[15] ^= rotate(x[14] &+ x[13], 18)
        }
        for index in 0..<16 { state[index] &+= x[index] }
    }
}
