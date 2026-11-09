import CryptoKit
import Foundation
import Security

public struct ChatGPTProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var label: String, clientID: String?, subject: String?, credentialID: String?, model: String
    public var planEnabled: Bool, revision: Int
}

public struct ChatGPTSignIn: Sendable {
    public let id: String, authorizationURL: URL
    public let profile: ChatGPTProfile
    let connection: AIConnection?, redirect: URL, state: String, nonce: String, verifier: String, created: ContinuousClock.Instant
}

public struct ChatGPTSignInResult: Sendable {
    public let profile: ChatGPTProfile, models: [AIClient.Model], active: Bool
}

struct ChatGPTTokens: Codable, Sendable {
    let clientID: String, subject: String, access: String, refresh: String?, identity: String, expires: Date, scopes: [String]
    var encoded: String { get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) } }
    static func read(_ text: String) throws -> Self {
        guard text.utf8.count <= 10_240, let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              value.clientID.hasPrefix("oaiapp_"), !value.subject.isEmpty, valid(value.access), value.refresh.map(valid) ?? true,
              !value.identity.isEmpty else { throw AIFailure.signIn }
        return value
    }
    static func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 } }
    static func response(_ json: JSONText, client: String, subject: String, identity: String, previous: Self? = nil) throws -> Self {
        guard let access = json["access_token"]?.text, valid(access), json["token_type"]?.text?.lowercased() == "bearer",
              case .number(let lifetime)? = json["expires_in"], lifetime.isFinite, lifetime > 0, lifetime <= 31_536_000 else { throw AIFailure.identity }
        let scopes = json["scope"]?.text.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        let value = Self(clientID: client, subject: subject, access: access, refresh: json["refresh_token"]?.text ?? previous?.refresh,
                         identity: identity, expires: Date().addingTimeInterval(lifetime), scopes: scopes)
        _ = try read(value.encoded); return value
    }
}

public enum ChatGPTOAuth {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AIFailure.unavailable }
        return AppleToken.base64url(Data(bytes))
    }
    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    static func validRedirect(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port.map { (1024...65535).contains($0) } == true && url.path == "/auth/callback" && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    static func authorize(profile: ChatGPTProfile, host: String, redirect: URL, state: String, nonce: String, verifier: String, hint: String?) throws -> URL {
        guard validRedirect(redirect), state.utf8.count >= 32 else { throw AIFailure.identity }
        var items = ["client_id": profile.clientID ?? "dynamic_agent_client", "ext_agent_host_id": host, "redirect_uri": redirect.absoluteString,
                     "response_type": "code", "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                     "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce, "code_challenge_method": "S256",
                     "code_challenge": AppleToken.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if profile.clientID == nil { items["agent_name_hint"] = "Storebench" }
        if let hint { items["id_token_hint"] = hint }
        if profile.credentialID != nil && !profile.planEnabled { items["prompt"] = "consent" }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let result = url.url else { throw AIFailure.identity }; return result
    }
    static func callback(_ url: URL, attempt: ChatGPTSignIn) throws -> (code: String, client: String) {
        guard url.scheme == attempt.redirect.scheme, url.host == attempt.redirect.host, url.port == attempt.redirect.port,
              url.path == attempt.redirect.path, url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count <= 12,
              Set(items.map(\.name)).count == items.count else { throw AIFailure.identity }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard query["state"] == attempt.state else { throw AIFailure.identity }
        guard query["error"] == nil else { throw AIFailure.cancelled }
        let client = query["client_id"] ?? attempt.profile.clientID ?? ""
        guard client.hasPrefix("oaiapp_"), AIConnection.validModel(client), attempt.profile.clientID == nil || attempt.profile.clientID == client,
              let code = query["code"], ChatGPTTokens.valid(code) else { throw AIFailure.identity }
        return (code, client)
    }

    /// Verify the signed issuer, registration, nonce and expiry before any token set can replace a connection.
    static func verifyIdentity(_ token: String, jwks: JSONText, client: String, nonce: String, now: Date = Date()) throws -> String {
        guard token.utf8.count <= 16_384 else { throw AIFailure.identity }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, let header = decode(segments[0]).flatMap({ try? JSONText.parse($0) }),
              let body = decode(segments[1]).flatMap({ try? JSONText.parse($0) }), let signature = decode(segments[2]),
              let kid = header["kid"]?.text, case .array(let keys)? = jwks["keys"] else { throw AIFailure.identity }
        let matches = keys.filter { $0["kid"]?.text == kid }
        guard matches.count == 1, let key = matches.first, key["use"] == nil || key["use"] == .string("sig"),
              key["alg"] == nil || key["alg"] == header["alg"] else { throw AIFailure.identity }
        let message = Data((segments[0] + "." + segments[1]).utf8)
        switch header["alg"]?.text {
        case "ES256":
            guard key["kty"] == .string("EC"), key["crv"] == .string("P-256"),
                  let x = key["x"]?.text.flatMap(decode), let y = key["y"]?.text.flatMap(decode), x.count == 32, y.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let signed = try? P256.Signing.ECDSASignature(rawRepresentation: signature), publicKey.isValidSignature(signed, for: message) else { throw AIFailure.identity }
        case "RS256":
            guard key["kty"] == .string("RSA"), let n = key["n"]?.text.flatMap(decode), let e = key["e"]?.text.flatMap(decode),
                  (256...1024).contains(n.count), (1...8).contains(e.count),
                  let publicKey = SecKeyCreateWithData(der(0x30, derInteger(n) + derInteger(e)) as CFData,
                    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else { throw AIFailure.identity }
        default: throw AIFailure.identity
        }
        let audiences: [String]
        if case .array(let list)? = body["aud"] { audiences = list.compactMap(\.text) } else { audiences = body["aud"]?.text.map { [$0] } ?? [] }
        guard body["iss"] == .string("https://auth.openai.com"), body["nonce"] == .string(nonce), audiences.contains(client),
              audiences.count == 1 || body["azp"] == .string(client), let subject = body["sub"]?.text, !subject.isEmpty, subject.utf8.count <= 512,
              case .number(let expiry)? = body["exp"], expiry > now.timeIntervalSince1970,
              case .number(let issued)? = body["iat"], issued <= now.timeIntervalSince1970 + 30, issued < expiry else { throw AIFailure.identity }
        if case .number(let before)? = body["nbf"], before > now.timeIntervalSince1970 + 30 { throw AIFailure.identity }
        return subject
    }
    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var count = bytes.count, length: [UInt8] = []
        repeat { length.insert(UInt8(count & 255), at: 0); count >>= 8 } while count > 0
        return Data([tag] + (bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(length.count)] + length)) + bytes
    }
    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value[0] >= 128 { value.insert(0, at: 0) }
        return der(2, value)
    }
}
