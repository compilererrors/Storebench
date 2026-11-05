import Foundation
import Observation

extension AssetLibrary {
    public struct OrderScope: Equatable, Sendable {
        public let accountId: String, appId: String, surface: Surface, targetId: String, group: String
        public init(accountId: String, appId: String, surface: Surface, targetId: String, group: String) throws {
            guard surface != .events, [accountId, appId, targetId, group].allSatisfy(AssetLibrary.validID) else { throw AssetLibrary.failure("Choose an ordered placement group.") }
            self.accountId = accountId; self.appId = appId; self.surface = surface; self.targetId = targetId; self.group = group
        }
        public var key: String { [accountId, appId, surface.rawValue, targetId, group].joined(separator: ":") }
    }
    public struct OrderDraft: Equatable, Sendable {
        public let revision: Int, baseline: [String], baselineDigest: String, order: [String]
        public init(revision: Int, baseline: [String], baselineDigest: String, order: [String]) throws {
            guard revision > 0, baselineDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  !baseline.isEmpty, baseline.count <= 50, baseline.allSatisfy(AssetLibrary.validID), Set(baseline).count == baseline.count,
                  order.count == baseline.count, Set(order) == Set(baseline) else { throw AssetLibrary.failure("The saved placement order is invalid.") }
            self.revision = revision; self.baseline = baseline; self.baselineDigest = baselineDigest; self.order = order
        }
        var json: JSONText { .object([("schemaVersion", .number(1)), ("baseline", .array(baseline.map(JSONText.string))), ("baselineDigest", .string(baselineDigest)), ("order", .array(order.map(JSONText.string)))]) }
        static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self? {
            guard let document else { return nil }
            let value = try JSONText.parse(document.payload)
            guard value["schemaVersion"] == .number(1), case .array(let before)? = value["baseline"], before.allSatisfy({ $0.text != nil }),
                  case .array(let after)? = value["order"], after.allSatisfy({ $0.text != nil }), let digest = value["baselineDigest"]?.text else { throw AssetLibrary.failure("The saved placement order could not be confirmed.") }
            return try Self(revision: document.revision, baseline: before.compactMap(\.text), baselineDigest: digest, order: after.compactMap(\.text))
        }
    }
    public static func orderDigest(_ placements: [Placement]) -> String { JSONText.array(placements.map(\.value)).sha256 }
}

extension WorkspaceSession {
    public func assetLibraryOrder(_ scope: AssetLibrary.OrderScope) throws -> AssetLibrary.OrderDraft? {
        try requireHistoryScope(accountId: scope.accountId, appId: scope.appId); try Task.checkCancellation()
        return try storeAccess { try AssetLibrary.OrderDraft.stored($0.document(namespace: "asset_library_orders", key: scope.key)) }
    }
    /// This only saves an encrypted local draft. Apple changes still require a fresh Publish review.
    public func saveAssetLibraryOrder(_ scope: AssetLibrary.OrderScope, baseline: [String], baselineDigest: String, order: [String], expectedRevision: Int?) throws -> AssetLibrary.OrderDraft {
        try requireHistoryScope(accountId: scope.accountId, appId: scope.appId)
        guard expectedRevision.map({ $0 > 0 && $0 < Int.max }) ?? true else { throw AssetLibrary.failure("Read the latest local placement order before saving.") }
        let draft = try AssetLibrary.OrderDraft(revision: (expectedRevision ?? 0) + 1, baseline: baseline, baselineDigest: baselineDigest, order: order)
        return try storeAccess { store in
            let mutex = "asset_library_order_" + JSONText.string(scope.key).rawSHA256.prefix(40) + ".mutex"
            return try FileMutex.withLock(store.directory.appendingPathComponent(mutex)) {
                try requireHistoryScope(accountId: scope.accountId, appId: scope.appId); try Task.checkCancellation()
                try store.transaction { current in
                    guard try current("asset_library_orders", scope.key)?.revision == expectedRevision else { throw AssetLibrary.failure("The local placement order was saved elsewhere. Read and compare the latest save; your edits are kept.") }
                    try requireHistoryScope(accountId: scope.accountId, appId: scope.appId); try Task.checkCancellation()
                    return [.put(namespace: "asset_library_orders", key: scope.key, json: draft.json.data)]
                }
                return draft
            }
        }
    }
}

@MainActor @Observable public final class AssetLibraryOrderEditor {
    public let scope: AssetLibrary.OrderScope, baseline: [String], baselineDigest: String
    public private(set) var saved: AssetLibrary.OrderDraft?
    public private(set) var order: [String]
    public private(set) var busy = false
    public private(set) var needsComparison = false
    public private(set) var status = ""
    public private(set) var localConflict = false
    public private(set) var latestLocal: AssetLibrary.OrderDraft?
    public private(set) var latestRead = false
    public private(set) var active = true
    private var baselineNeedsSave = false
    public init(scope: AssetLibrary.OrderScope, placements: [AssetLibrary.Placement], saved: AssetLibrary.OrderDraft?) throws {
        guard placements.allSatisfy({ $0.group == scope.group }), Set(placements.map(\.id)).count == placements.count else { throw AssetLibrary.failure("The placement group could not be confirmed.") }
        self.scope = scope; baseline = placements.map(\.id); baselineDigest = AssetLibrary.orderDigest(placements); self.saved = saved
        order = saved?.order ?? baseline
        needsComparison = saved.map { $0.baselineDigest != baselineDigest && $0.order != baseline } ?? false
    }
    public var context: String { scope.key + ":" + baselineDigest + ":" + String(saved?.revision ?? 0) }
    public var dirty: Bool { baselineNeedsSave || order != (saved?.order ?? baseline) }
    public var pendingUpload: Bool { order != baseline }
    public var blocked: Bool { !active || busy || needsComparison || localConflict || order.isEmpty || order.count != baseline.count || Set(order) != Set(baseline) }
    public var canReview: Bool { !blocked && !dirty && pendingUpload && saved != nil }
    public var summary: String {
        if needsComparison { return "Apple's placements changed. Compare them before saving or uploading this order." }
        if localConflict { return "Another window saved this order. Read and compare the latest local save; your edits are kept." }
        if dirty { return "Unsaved order · Save Order keeps it on this Mac." }
        if pendingUpload { return "Saved locally · Review Upload to send the new order to Apple." }
        return "Order matches Apple · Drag an asset or its handle to rearrange this group."
    }
    @discardableResult public func reorder(_ next: [String], expected: [String], context: String) -> Bool {
        guard !blocked, self.context == context, order == expected, next.count == baseline.count, Set(next) == Set(baseline) else { return false }
        order = next; status = ""; return true
    }
    public func revert() {
        guard !blocked else { return }
        let savedOrder = saved?.order ?? baseline
        order = Set(savedOrder) == Set(baseline) ? savedOrder : baseline
        status = "Local edits reverted."
    }
    public func acceptLatest(keepEdits: Bool) {
        guard !busy, needsComparison, !localConflict else { return }
        let available = Set(baseline), kept = order.filter { available.contains($0) }
        order = keepEdits ? kept + baseline.filter { !kept.contains($0) } : baseline
        baselineNeedsSave = saved?.baselineDigest != baselineDigest
        needsComparison = false; status = "Apple's latest order compared. Choose Save Order to keep this new baseline locally."
    }
    public func retire() { active = false }
    public func readLatest(_ read: @MainActor () async throws -> AssetLibrary.OrderDraft?) async {
        guard active, !busy else { return }; busy = true; latestRead = false; latestLocal = nil; defer { busy = false }
        do { let result = try await read(); guard active else { return }; latestLocal = result; latestRead = true; status = "Latest local order read. Compare and choose a baseline; nothing was saved." }
        catch { if active { status = "The latest local order could not be read. Your edits are kept." } }
    }
    public func acceptLocalLatest(keepEdits: Bool) {
        guard active, !busy, latestRead else { return }
        if !keepEdits { order = latestLocal?.order ?? baseline }
        saved = latestLocal; latestLocal = nil; latestRead = false; localConflict = false
        baselineNeedsSave = false
        needsComparison = saved.map { $0.baselineDigest != baselineDigest && $0.order != baseline } ?? false
        status = "Latest local order compared. Choose Save Order to keep your edits."
    }
    public func save(_ write: @MainActor (AssetLibrary.OrderDraft?) async throws -> AssetLibrary.OrderDraft) async -> Bool {
        guard !blocked, dirty else { return !blocked }
        busy = true; defer { busy = false }
        let order = self.order
        do {
            let result = try await write(saved)
            guard result.order == order, result.baseline == baseline, result.baselineDigest == baselineDigest else { throw AssetLibrary.failure("The local save could not be confirmed.") }
            guard active else { return true }
            saved = result; baselineNeedsSave = false; status = "Order saved on this Mac. Review Upload opens the exact Apple change for approval."; return true
        } catch {
            guard active else { return false }
            localConflict = true; status = (error as? PublishFailure)?.message ?? "Order could not be saved. Your edits are kept; read the latest local save before retrying."; return false
        }
    }
}
