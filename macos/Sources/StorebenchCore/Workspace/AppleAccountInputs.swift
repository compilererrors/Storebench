import CryptoKit
import Darwin
import Foundation

/// The account form's limits and filename rules, shared by connection and reconnection.
public enum AppleAccountInputs {
    public static func validKeyId(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }
    public static func keyId(filename: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"^(?:[Aa][Pp][Ii][Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][Kk][Ee][Yy])_([^\u0000-\u001f\u007f]+)\.[Pp]8\z"#),
              let match = expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else { return nil }
        let value = String(filename[range]); return validKeyId(value) ? value : nil
    }
    public static func validatePrivateKey(_ pem: String) throws { _ = try privateKey(pem) }
    /// The key text to save: the original when it parses, or the same PKCS#8 body rewrapped when pasting added or removed line breaks.
    public static func privateKey(_ pem: String) throws -> String {
        guard !pem.isEmpty, pem.utf8.count <= 10_000 else { throw AccountFailure.keyContent }
        if (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil { return pem }
        let begin = "-----BEGIN PRIVATE KEY-----", end = "-----END PRIVATE KEY-----"
        guard let start = pem.range(of: begin), let finish = pem.range(of: end, range: start.upperBound..<pem.endIndex),
              TextSemantics.trim(String(pem[..<start.lowerBound])).isEmpty, TextSemantics.trim(String(pem[finish.upperBound...])).isEmpty else { throw AccountFailure.keyContent }
        let body = String(pem[start.upperBound..<finish.lowerBound].unicodeScalars.filter { !TextSemantics.whitespace.contains($0) })
        var lines: [Substring] = [], rest = Substring(body)
        while !rest.isEmpty { lines.append(rest.prefix(64)); rest = rest.dropFirst(64) }
        let rewrapped = ([begin] + lines.map(String.init) + [end]).joined(separator: "\n") + "\n"
        guard !lines.isEmpty, (try? P256.Signing.PrivateKey(pemRepresentation: rewrapped)) != nil else { throw AccountFailure.keyContent }
        return rewrapped
    }
    /// Read at most one byte beyond the form limit, including files whose metadata changes while reading.
    public static func privateKeyFile(_ url: URL) throws -> String {
        try TestIsolation.check(url)
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AccountFailure.invalid }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw AccountFailure.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var data = Data()
        while data.count <= 10_000 {
            guard let part = try handle.read(upToCount: 10_001 - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= 10_000, let pem = String(data: data, encoding: .utf8) else { throw AccountFailure.keyContent }
        // In-App Purchase keys are also P-256 .p8 files; only Apple's download name tells them apart.
        if url.lastPathComponent.range(of: #"\A[Ss][Uu][Bb][Ss][Cc][Rr][Ii][Pp][Tt][Ii][Oo][Nn][Kk][Ee][Yy]_"#, options: .regularExpression) != nil { throw AccountFailure.purchaseKey }
        return try privateKey(pem)
    }
    static func account(name: String, keyType: String, issuerId: String?, keyId: String, pem: String) throws -> Account {
        let key = TextSemantics.trim(keyId), label = TextSemantics.trim(name), issuer = issuerId.map(TextSemantics.trim)
        guard name.utf16.count <= 80, ["team", "individual"].contains(keyType), validKeyId(key) else { throw AccountFailure.invalid }
        guard keyType == "individual" || issuer?.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil else { throw AccountFailure.issuerRequired }
        try validatePrivateKey(pem)
        return Account(id: UUID().uuidString.lowercased(), name: label.isEmpty ? (keyType == "individual" ? "Individual key" : "Team Apple key") : label,
                       keyId: key, keyType: keyType, issuerId: keyType == "team" ? issuer : nil, appIds: [], appNames: nil)
    }
}
