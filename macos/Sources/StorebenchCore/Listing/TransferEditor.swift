import Foundation
import Observation

public struct TransferSelection: Sendable {
    public let data: Data, format: TransferFormat
    public init(data: Data, format: TransferFormat) { self.data = data; self.format = format }
}
public struct TransferReceipt: Sendable {
    public let preview: TransferPreview, confirmedAt: String
}
/// Eight complete comparisons per page; every input change remains reachable.
public struct TransferReviewPage: Sendable {
    public let changes: [TransferChange], total, pages, current: Int
    public init(changes: [TransferChange], page: Int) {
        total = changes.count; pages = max(1, changes.count / 8 + (changes.count % 8 == 0 ? 0 : 1)); current = max(1, min(page, pages))
        self.changes = Array(changes.dropFirst((current - 1) * 8).prefix(8))
    }
}

/// Keeps an exact unsaved import and its last acknowledged save without adopting a new preview after a conflict.
@MainActor @Observable public final class TransferEditor {
    public let scope: RecoveryGuidance.Scope, kind: TransferKind
    public private(set) var format: TransferFormat = .csv
    public private(set) var preview: TransferPreview?
    public private(set) var lastSave: TransferReceipt?
    public private(set) var savedData: Delimited.Table?
    public private(set) var busy = false
    public private(set) var active = true
    public private(set) var saveBlocked = false
    public private(set) var status = ""
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private var table: Delimited.Table?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private let readPreview: @MainActor (Delimited.Table) async throws -> TransferPreview
    @ObservationIgnored private let save: @MainActor (Delimited.Table, String) async throws -> TransferPreview
    @ObservationIgnored private let readExport: @MainActor (Bool, Bool) async throws -> Delimited.Table
    public var ready: Bool { active && !busy }
    public var dirty: Bool { table != nil && preview?.changes.isEmpty == false }
    public var canSave: Bool { ready && dirty && !saveBlocked }
    public init(scope: RecoveryGuidance.Scope, kind: TransferKind,
                preview: @escaping @MainActor (Delimited.Table) async throws -> TransferPreview,
                save: @escaping @MainActor (Delimited.Table, String) async throws -> TransferPreview,
                export: @escaping @MainActor (Bool, Bool) async throws -> Delimited.Table) {
        self.scope = scope; self.kind = kind; readPreview = preview; self.save = save; readExport = export
    }
    public func setFormat(_ value: TransferFormat) { guard ready else { return }; format = value; didChange() }
    public func discardPreview() { guard ready else { return }; table = nil; preview = nil; saveBlocked = false; didChange() }
    public func retire() { guard active else { return }; active = false; table = nil; preview = nil; savedData = nil; didChange() }
    @discardableResult public func choose(read: @MainActor () async throws -> TransferSelection?) async -> Bool {
        guard ready, !dirty, !Task.isCancelled, let ticket = begin("Reading the selected import…") else { return false }
        defer { finish(ticket) }
        do {
            guard let selection = try await read() else { if accepts(ticket) { status = "" }; return false }
            try Task.checkCancellation(); guard accepts(ticket) else { return false }
            guard selection.data.count <= 4_000_000 else { throw SelectedFiles.Failure.fileSize }
            let parsed = try Transfer.parse(kind, SelectedFiles.text(selection.data), format: selection.format)
            let value = try await readPreview(parsed); try Task.checkCancellation(); guard accepts(ticket) else { return false }
            try check(value, saved: false)
            guard value.totalRows == parsed.rows.count else { throw TransferFailure.changed }
            table = parsed; preview = value; saveBlocked = false; status = ""; didChange(); return true
        } catch { failure(error, ticket: ticket); return false }
    }
    @discardableResult public func recheck() async -> Bool {
        guard ready, let table, !Task.isCancelled, let ticket = begin("Comparing this exact file with the latest saved data…") else { return false }
        defer { finish(ticket) }
        do {
            let value = try await readPreview(table); try Task.checkCancellation(); guard accepts(ticket) else { return false }
            try check(value, saved: false)
            guard value.totalRows == table.rows.count else { throw TransferFailure.changed }
            preview = value; saveBlocked = false
            status = "Read every updated comparison before choosing Import. Nothing was saved by this read."; didChange(); return true
        } catch { failure(error, ticket: ticket); return false }
    }
    @discardableResult public func apply() async -> Bool {
        guard canSave, let table, let before = preview, !Task.isCancelled, let ticket = begin("Saving the reviewed import locally…") else { return false }
        defer { finish(ticket) }
        do {
            let value = try await save(table, before.fingerprint)
            // Cancellation cannot turn an acknowledged atomic commit into an unsaved review.
            guard accepts(ticket) else { return false }
            try check(value, saved: true)
            guard value.fingerprint == before.fingerprint, value.changes == before.changes, value.count == before.count, value.added == before.added, value.totalRows == before.totalRows else { throw TransferFailure.changed }
            lastSave = .init(preview: value, confirmedAt: CustomerReview.isoString(Date())); self.table = nil; preview = nil; saveBlocked = false; savedData = nil
            status = "Imported \(value.changes.count) changes locally. The comparison records this save; later edits may differ. Nothing was sent to App Store Connect."; didChange(); return true
        } catch { if accepts(ticket) { saveBlocked = true }; failure(error, ticket: ticket); return false }
    }
    @discardableResult public func export(template: Bool, apple: Bool, write: @MainActor (String, TransferFormat) async throws -> Bool) async -> Bool {
        guard ready, !Task.isCancelled, let ticket = begin("Reading the export…") else { return false }
        let chosenFormat = format; defer { finish(ticket) }
        do {
            let value = try await readExport(template, apple); try Task.checkCancellation(); guard accepts(ticket) else { return false }
            let text = try Transfer.text(kind, value, format: chosenFormat)
            let written = try await write(text, chosenFormat)
            guard accepts(ticket) else { return false }
            guard written else { status = ""; didChange(); return false }
            status = "Exported \(value.rows.count) rows."; didChange(); return true
        } catch { failure(error, ticket: ticket); return false }
    }
    @discardableResult public func readSavedData() async -> Bool {
        guard ready, !Task.isCancelled, let ticket = begin("Reading the current saved data…") else { return false }
        defer { finish(ticket) }
        do {
            let value = try await readExport(false, false); try Task.checkCancellation(); guard accepts(ticket) else { return false }
            savedData = value; status = "This read shows current saved data. Import inputs and the last save comparison are kept."; didChange(); return true
        } catch { failure(error, ticket: ticket); return false }
    }
    private func check(_ value: TransferPreview, saved: Bool) throws {
        guard value.saved == saved, value.fingerprint.count == 64, value.fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              value.count >= 0, value.added >= 0, value.totalRows >= 0, Set(value.changes.map(\.id)).count == value.changes.count else { throw TransferFailure.invalid("The import review could not be confirmed.") }
    }
    private func begin(_ message: String) -> UUID? {
        guard ready else { return nil }; let ticket = UUID(); operation = ticket; busy = true; status = message; didChange(); return ticket
    }
    private func accepts(_ ticket: UUID) -> Bool { active && operation == ticket }
    private func finish(_ ticket: UUID) { if operation == ticket { operation = nil; busy = false; didChange() } }
    private func failure(_ error: Error, ticket: UUID) {
        guard accepts(ticket) else { return }
        if let value = error as? TransferFailure { status = value.message }
        else if let value = error as? Delimited.Failure { status = value.message }
        else if let value = error as? SessionFailure { status = value.message }
        else if let value = error as? AccountFailure { status = value.message }
        else if let value = error as? SelectedFiles.Failure { status = [.fileSize, .batchSize].contains(value) ? "Choose a file under 4 MB." : "Choose a readable UTF-8 CSV or JSON file." }
        else { status = "The operation could not be confirmed. Existing inputs and comparisons are kept. Read the current saved data before previewing again; nothing is retried automatically." }
        didChange()
    }
}

@MainActor private final class TransferImportContext {
    let account: Account, appId: String, kind: TransferKind, session: WorkspaceSession
    var currencies: [String: String] = [:]
    init(account: Account, appId: String, kind: TransferKind, session: WorkspaceSession) { self.account = account; self.appId = appId; self.kind = kind; self.session = session }
    func checkScope() async throws {
        let current = try await session.currentAccount(account)
        guard account.appIds.contains(appId), current.appIds.contains(appId) else { throw AccountFailure.stale }
    }
    func preview(_ table: Delimited.Table) async throws -> TransferPreview {
        try await checkScope()
        if kind == .prices {
            let client = try await session.client(for: account), territories = try await session.territories(account: account, client: client)
            currencies = Dictionary(territories.map { ($0.code, $0.currency) }, uniquingKeysWith: { first, _ in first })
            try await checkScope()
        }
        let value = try await session.importTransfer(account: account, appId: appId, kind: kind, table: table, currencies: currencies)
        try await checkScope(); return value
    }
    func save(_ table: Delimited.Table, fingerprint: String) async throws -> TransferPreview {
        try await checkScope()
        return try await session.importTransfer(account: account, appId: appId, kind: kind, table: table, currencies: currencies, fingerprint: fingerprint)
    }
    func export(template: Bool, apple: Bool) async throws -> Delimited.Table {
        try await checkScope()
        let prices = apple ? try await session.savedPricing(accountId: account.id, appId: appId)?.snapshot?.rows : nil
        guard !apple || prices != nil else { throw TransferFailure.invalid("Refresh prices in Pricing first.") }
        let value = try await session.exportTransfer(accountId: account.id, appId: appId, kind: kind, template: template, applePrices: prices)
        try await checkScope(); return value
    }
}
extension TransferEditor {
    public convenience init(account: Account, appId: String, kind: TransferKind, session: WorkspaceSession) throws {
        let context = TransferImportContext(account: account, appId: appId, kind: kind, session: session)
        self.init(scope: try RecoveryGuidance.Scope(accountId: account.id, appId: appId), kind: kind,
            preview: { try await context.preview($0) }, save: { try await context.save($0, fingerprint: $1) }, export: { try await context.export(template: $0, apple: $1) })
    }
}
