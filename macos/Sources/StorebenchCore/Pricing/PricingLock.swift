import Foundation

/// The pricing state mutexes in their one acquisition order: shared profiles, price protection, country drafts, then the chosen pricing model.
/// Callers name the locks a write needs; this type only takes them in that order, so no caller can nest them the other way round.
/// Remote reads belong before this call, never inside it.
enum PricingLock: Int, Comparable, Sendable {
    case profiles, protection, drafts, setup

    var file: String {
        switch self {
        case .profiles: "pricing_profiles.mutex"
        case .protection: "price_protection.mutex"
        case .drafts: "pricing_drafts.mutex"
        case .setup: "pricing_setup.mutex"
        }
    }

    static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }

    static func holding<T>(_ locks: Set<PricingLock>, in store: EncryptedDocumentStore, _ body: () throws -> T) throws -> T {
        try acquire(locks.sorted()[...], directory: store.directory, body)
    }

    private static func acquire<T>(_ locks: ArraySlice<PricingLock>, directory: URL, _ body: () throws -> T) throws -> T {
        guard let first = locks.first else { return try body() }
        return try FileMutex.withLock(directory.appendingPathComponent(first.file)) { try acquire(locks.dropFirst(), directory: directory, body) }
    }
}
