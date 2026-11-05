import Foundation
import Testing
@testable import StorebenchCore

// Synthetic vectors only. The password envelope was produced by the reference algorithm with fixed salt and nonce.
@Suite struct KeyEnvelopeTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func scryptMatchesRFC7914() throws {
        let derived = try Scrypt.derive(password: Data("password".utf8), salt: Data("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64)
        #expect(derived.map { String(format: "%02x", $0) }.joined() == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
    }

    @Test func syntheticPasswordEnvelopeUnwraps() throws {
        let json: [String: Any] = ["version": 1, "mode": "password", "salt": "BwcHBwcHBwcHBwcHBwcHBw", "nonce": "CQkJCQkJCQkJCQkJ",
                                   "ciphertext": "p6TqkK-a7_xai_0hZfOX2INQ9Q10lpsZSX6b1-W3L5A", "tag": "1LqW49F7nzVuiF6P_F9YSw"]
        let envelope = try KeyEnvelope(json: json)
        #expect(envelope.requiresPassword)
        #expect(try envelope.unwrap(password: "synthetic-swift-password") == Data(0..<32))
        #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try envelope.unwrap(password: "synthetic-wrong-password") }
        #expect(throws: KeyEnvelope.Failure.passwordRequired) { try envelope.unwrap() }
    }

    @Test func deviceEnvelopeAndRecordValidateTheirStoredFormat() throws {
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = try DatabaseKeyRecord(json: #"{"schemaVersion":1,"phase":"ready","envelope":{"version":1,"mode":"device","key":"\#(key)"}}"#)
        #expect(record.ready)
        #expect(try record.envelope.unwrap() == Data(0..<32))
        #expect(throws: KeyEnvelope.Failure.invalidEnvelope) { try KeyEnvelope(json: ["version": 1, "mode": "device", "key": key, "extra": 1]) }
        #expect(throws: KeyEnvelope.Failure.invalidEnvelope) { try KeyEnvelope(json: ["version": 1, "mode": "device", "key": "AAAA"]) }
    }

    @Test func vaultEntriesAndDatabaseAccountMatchSyntheticReferenceResults() throws {
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"apple:synthetic-account":"synthetic-key"}}"#.utf8))
        #expect(vault.entries["apple:synthetic-account"] == "synthetic-key")
        #expect(throws: CredentialVault.Failure.unreadable) { try CredentialVault(json: Data(#"{"version":1,"entries":{"unknown:x":"y"}}"#.utf8)) }
        // sha256("/synthetic/storebench") computed independently for the same root.
        #expect(CredentialVault.databaseEntry(root: URL(fileURLWithPath: "/synthetic/storebench")) == "database:db_ba3201ce2b3c9780dd8ca2f229806f2660d584a7")
    }
}
