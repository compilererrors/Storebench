import CommonCrypto
import CryptoKit
import Foundation

/// An unsigned big integer in 32-bit limbs, least significant first, with the few operations Apple's sign-in proof needs.
struct ProofNumber: Equatable, Sendable {
    var limbs: [UInt32]
    init(limbs: [UInt32]) { self.limbs = limbs; trim() }
    init(_ value: UInt32) { self.init(limbs: [value]) }
    /// Big-endian bytes, as Apple sends them.
    init(bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() { limbs[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4)) }
        self.init(limbs: limbs)
    }
    init(hex: String) {
        var bytes: [UInt8] = [], text = Substring(hex)
        if text.count % 2 == 1 { text = "0" + text }
        while !text.isEmpty { bytes.append(UInt8(text.prefix(2), radix: 16)!); text = text.dropFirst(2) }
        self.init(bytes: bytes)
    }
    private mutating func trim() { while limbs.count > 1, limbs.last == 0 { limbs.removeLast() }; if limbs.isEmpty { limbs = [0] } }
    var isZero: Bool { limbs == [0] }
    /// Big-endian bytes without leading zeros; zero is one byte.
    var bytes: [UInt8] {
        var result: [UInt8] = []
        for limb in limbs.reversed() { result += [UInt8(limb >> 24), UInt8(limb >> 16 & 0xff), UInt8(limb >> 8 & 0xff), UInt8(limb & 0xff)] }
        let first = result.firstIndex { $0 != 0 } ?? (result.count - 1)
        return Array(result[first...])
    }
    func padded(_ length: Int) -> [UInt8] { let value = bytes; return [UInt8](repeating: 0, count: max(0, length - value.count)) + value }
    var bitWidth: Int { (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }
    func bit(_ index: Int) -> Bool { index / 32 < limbs.count && limbs[index / 32] >> UInt32(index % 32) & 1 == 1 }

    static func < (a: ProofNumber, b: ProofNumber) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for index in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[index] != b.limbs[index] { return a.limbs[index] < b.limbs[index] }
        return false
    }
    static func + (a: ProofNumber, b: ProofNumber) -> ProofNumber {
        var result = [UInt32](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1), carry: UInt64 = 0
        for index in 0..<(result.count - 1) {
            let sum = UInt64(index < a.limbs.count ? a.limbs[index] : 0) + UInt64(index < b.limbs.count ? b.limbs[index] : 0) + carry
            result[index] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32
        }
        result[result.count - 1] = UInt32(carry)
        return ProofNumber(limbs: result)
    }
    /// `a - b` for `a >= b`.
    static func - (a: ProofNumber, b: ProofNumber) -> ProofNumber {
        var result = a.limbs, borrow: Int64 = 0
        for index in 0..<result.count {
            let difference = Int64(result[index]) - Int64(index < b.limbs.count ? b.limbs[index] : 0) - borrow
            if difference < 0 { result[index] = UInt32(truncatingIfNeeded: difference + (1 << 32)); borrow = 1 } else { result[index] = UInt32(difference); borrow = 0 }
        }
        return ProofNumber(limbs: result)
    }
    static func * (a: ProofNumber, b: ProofNumber) -> ProofNumber {
        var result = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let product = UInt64(a.limbs[i]) * UInt64(b.limbs[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: product); carry = product >> 32
            }
            result[i + b.limbs.count] = UInt32(carry)
        }
        return ProofNumber(limbs: result)
    }
}

/// Modular arithmetic for one odd modulus in Montgomery form.
struct ProofModulus: Sendable {
    let modulus: ProofNumber
    private let size: Int, inverse: UInt32, rSquared: ProofNumber
    init(_ modulus: ProofNumber) {
        self.modulus = modulus; size = modulus.limbs.count
        var value: UInt32 = 1
        for _ in 0..<5 { value = value &* (2 &- modulus.limbs[0] &* value) }
        inverse = 0 &- value
        var r = ProofNumber(1)
        for _ in 0..<(2 * 32 * modulus.limbs.count) { r = r + r; if !(r < modulus) { r = r - modulus } }
        rSquared = r
    }
    /// `a * b / R mod N` for `a, b < N`.
    func multiply(_ a: ProofNumber, _ b: ProofNumber) -> ProofNumber {
        var t = [UInt32](repeating: 0, count: size + 2)
        for i in 0..<size {
            let ai = UInt64(i < a.limbs.count ? a.limbs[i] : 0)
            var carry: UInt64 = 0
            for j in 0..<size {
                let sum = UInt64(t[j]) + ai * UInt64(j < b.limbs.count ? b.limbs[j] : 0) + carry
                t[j] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32
            }
            var sum = UInt64(t[size]) + carry; t[size] = UInt32(truncatingIfNeeded: sum); t[size + 1] = UInt32(sum >> 32)
            let m = UInt64(t[0] &* inverse)
            carry = (UInt64(t[0]) + m * UInt64(modulus.limbs[0])) >> 32
            for j in 1..<size {
                sum = UInt64(t[j]) + m * UInt64(modulus.limbs[j]) + carry
                t[j - 1] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32
            }
            sum = UInt64(t[size]) + carry; t[size - 1] = UInt32(truncatingIfNeeded: sum)
            t[size] = t[size + 1] + UInt32(sum >> 32); t[size + 1] = 0
        }
        var result = ProofNumber(limbs: Array(t[0...size]))
        if !(result < modulus) { result = result - modulus }
        return result
    }
    /// `base ^ exponent mod N` for `base < N`.
    func power(_ base: ProofNumber, _ exponent: ProofNumber) -> ProofNumber {
        let montgomeryBase = multiply(base, rSquared)
        var result = multiply(ProofNumber(1), rSquared)
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = multiply(result, result)
            if exponent.bit(index) { result = multiply(result, montgomeryBase) }
        }
        return multiply(result, ProofNumber(1))
    }
    func product(_ a: ProofNumber, _ b: ProofNumber) -> ProofNumber { multiply(multiply(a, rSquared), b) }
}

/// Apple's sign-in proof: SRP-6a over the RFC 5054 2048-bit group with SHA-256, a PBKDF2-derived password and no account name in x.
/// The password and its derived key never leave this type.
struct AppleIDProof: Sendable {
    static let modulus = ProofModulus(ProofNumber(hex: "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"))
    static let generator = ProofNumber(2)
    enum Failure: Error, Equatable { case invalidChallenge, unsupportedProtocol }

    let account: String
    private let secret: ProofNumber
    /// The public value A sent to Apple.
    let publicValue: ProofNumber
    init(account: String, secret: [UInt8]? = nil) {
        self.account = account
        var bytes = secret ?? [UInt8](repeating: 0, count: 32)
        if secret == nil { _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) }
        self.secret = ProofNumber(bytes: bytes)
        publicValue = Self.modulus.power(Self.generator, self.secret)
    }

    static func hash(_ parts: [UInt8]...) -> [UInt8] { var hasher = SHA256(); for part in parts { hasher.update(data: part) }; return Array(hasher.finalize()) }
    static func derive(password: String, salt: [UInt8], iterations: Int, protocol name: String) throws -> [UInt8] {
        guard ["s2k", "s2k_fo"].contains(name), (1...10_000_000).contains(iterations) else { throw Failure.unsupportedProtocol }
        var digest = hash(Array(password.utf8))
        if name == "s2k_fo" { digest = Array(digest.map { String(format: "%02x", $0) }.joined().utf8) }
        var key = [UInt8](repeating: 0, count: 32)
        let status = digest.withUnsafeBufferPointer { password in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(password.baseAddress!).assumingMemoryBound(to: Int8.self), password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count)
        }
        guard status == kCCSuccess else { throw Failure.unsupportedProtocol }
        return key
    }

    /// The client proof M1 and the expected server proof M2 for Apple's challenge.
    func respond(password: String, salt: [UInt8], iterations: Int, protocol name: String, serverValue: [UInt8]) throws -> (m1: [UInt8], m2: [UInt8]) {
        let n = Self.modulus.modulus, g = Self.generator, length = n.bytes.count
        let b = ProofNumber(bytes: serverValue)
        guard !b.isZero, b < n else { throw Failure.invalidChallenge }
        let key = try Self.derive(password: password, salt: salt, iterations: iterations, protocol: name)
        let saltBytes = ProofNumber(bytes: salt).bytes
        let k = ProofNumber(bytes: Self.hash(n.bytes, g.padded(length)))
        let x = ProofNumber(bytes: Self.hash(saltBytes, Self.hash(Array(":".utf8), key)))
        let u = ProofNumber(bytes: Self.hash(publicValue.padded(length), b.padded(length)))
        guard !u.isZero else { throw Failure.invalidChallenge }
        let kv = Self.modulus.product(k < n ? k : k - n, Self.modulus.power(g, x))
        let base = b < kv ? b + n - kv : b - kv
        let shared = Self.modulus.power(base, secret + u * x)
        let sessionKey = Self.hash(shared.bytes)
        let hn = Self.hash(n.bytes), hg = Self.hash(g.padded(length))
        let m1 = Self.hash(zip(hn, hg).map { $0 ^ $1 }, Self.hash(Array(account.utf8)), saltBytes, publicValue.bytes, b.bytes, sessionKey)
        return (m1, Self.hash(publicValue.bytes, m1, sessionKey))
    }

    /// Apple's hashcash stamp: a SHA-1 with `bits` leading zero bits over "1:bits:date:challenge::counter".
    static func hashcash(bits: Int, challenge: String, date: Date = Date()) -> String? {
        guard (1...32).contains(bits), challenge.range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil else { return nil }
        let format = DateFormatter(); format.dateFormat = "yyyyMMddHHmmss"; format.locale = Locale(identifier: "en_US_POSIX")
        let prefix = "1:\(bits):\(format.string(from: date)):\(challenge)::"
        for counter in 0..<50_000_000 {
            let stamp = prefix + String(counter)
            let digest = Array(Insecure.SHA1.hash(data: Data(stamp.utf8)))
            var zeros = 0
            for byte in digest { if byte == 0 { zeros += 8 } else { zeros += byte.leadingZeroBitCount; break } }
            if zeros >= bits { return stamp }
        }
        return nil
    }
}
