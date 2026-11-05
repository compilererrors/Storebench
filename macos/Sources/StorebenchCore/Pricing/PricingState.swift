import Foundation

/// A pricing state document under its "current" key, replaced only against the revision that was read.
/// The caller holds the document's `PricingLock` and runs inside the session's store access.
enum PricingState {
    static func read(_ store: EncryptedDocumentStore, _ namespace: String) throws -> (document: EncryptedDocumentStore.Document?, value: JSONText?) {
        let document = try store.document(namespace: namespace, key: "current")
        return (document, try document.map { try JSONText.parse($0.payload) })
    }

    static func replace(_ store: EncryptedDocumentStore, _ namespace: String, previous: EncryptedDocumentStore.Document?, value: JSONText) throws {
        try store.transaction { current in
            guard try current(namespace, "current")?.revision == previous?.revision else { throw PricingFailure.stale }
            return [.put(namespace: namespace, key: "current", json: value.data)]
        }
    }
}
