import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct TransferEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case synthetic }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    private let scope = try! RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
    private var table: Delimited.Table { .init(columns: Transfer.columns[.languages]!, rows: [["1000000001", "synthetic-version", "en-US", "version", "description", "Synthetic imported text"]]) }
    private func selection() throws -> TransferSelection { .init(data: try Transfer.text(.languages, table, format: .csv).data(using: .utf8)!, format: .csv) }
    private func preview(_ table: Delimited.Table, saved: Bool = false, fingerprint: String? = nil) -> TransferPreview {
        .init(changes: [.init(id: "synthetic-change", label: "Synthetic description", before: String(repeating: "Synthetic saved text\n", count: 300), after: table.rows[0][5])],
            fingerprint: fingerprint ?? String(repeating: "a", count: 64), count: 1, added: 0, totalRows: table.rows.count, saved: saved)
    }
    private func owner(read: (@MainActor (Delimited.Table) async throws -> TransferPreview)? = nil,
                       save: (@MainActor (Delimited.Table, String) async throws -> TransferPreview)? = nil,
                       export: (@MainActor (Bool, Bool) async throws -> Delimited.Table)? = nil) -> TransferEditor {
        .init(scope: scope, kind: .languages, preview: read ?? { preview($0) }, save: save ?? { preview($0, saved: true, fingerprint: $1) }, export: export ?? { _, _ in table })
    }
    @Test func choosingPreviewsWithoutSavingAndRequiresAnExplicitApplyWithTheExactFingerprint() async throws {
        var saves = 0, fingerprint = "", savedTable: Delimited.Table?
        let model = owner(save: { value, expected in saves += 1; fingerprint = expected; savedTable = value; return preview(value, saved: true, fingerprint: expected) })
        #expect(await model.choose(read: { try selection() })); #expect(saves == 0 && model.dirty && model.canSave)
        let before = try #require(model.preview); #expect(await model.apply())
        #expect(saves == 1 && fingerprint == before.fingerprint && savedTable == table)
        #expect(model.lastSave?.preview.changes == before.changes && model.lastSave?.preview.saved == true)
        #expect(model.preview == nil && !model.dirty && !model.canSave)
        #expect(await model.apply() == false); #expect(saves == 1)
        #expect(await model.choose(read: { try selection() })); #expect(model.lastSave?.preview.changes == before.changes)
    }
    @Test func unsavedReviewsSurviveReadsAndExportsUntilTheUserDiscardsThem() async throws {
        let model = owner(); #expect(await model.choose(read: { try selection() })); let before = model.preview
        #expect(await model.choose(read: { throw Failure.synthetic }) == false)
        #expect(await model.readSavedData()); #expect(model.preview == before && model.savedData == table && model.dirty)
        var exported = ""; #expect(await model.export(template: false, apple: false, write: { value, _ in exported = value; return true }))
        #expect(try Transfer.parse(.languages, exported, format: .csv) == table); #expect(model.preview == before && model.dirty)
        model.discardPreview(); #expect(model.preview == nil && !model.dirty)
    }
    @Test func staleSavesNeverRetryOrRefreshTheFingerprintWithoutAnExplicitRecheck() async throws {
        var reads = 0, saves = 0
        let model = owner(read: { value in reads += 1; return preview(value, fingerprint: String(repeating: reads == 1 ? "a" : "b", count: 64)) }, save: { value, fingerprint in
            saves += 1; if fingerprint == String(repeating: "a", count: 64) { throw TransferFailure.changed }; return preview(value, saved: true, fingerprint: fingerprint)
        })
        #expect(await model.choose(read: { try selection() })); let before = model.preview
        #expect(await model.apply() == false); #expect(model.saveBlocked && model.preview == before && model.dirty && model.lastSave == nil)
        #expect(await model.apply() == false); #expect(reads == 1 && saves == 1)
        #expect(await model.readSavedData()); #expect(model.saveBlocked && model.preview == before)
        #expect(await model.recheck()); #expect(!model.saveBlocked && model.preview?.fingerprint == String(repeating: "b", count: 64))
        #expect(saves == 1); #expect(await model.apply()); #expect(saves == 2 && model.lastSave?.preview.fingerprint == String(repeating: "b", count: 64))
    }
    @Test func overlappingRetiredAndCancelledReadsNeverProvideANewReview() async throws {
        let gate = Gate(); var reads = 0
        let model = owner(read: { value in reads += 1; await gate.hold(); return preview(value) })
        let task = Task { await model.choose(read: { try selection() }) }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy); #expect(await model.choose(read: { try selection() }) == false); #expect(await model.readSavedData() == false)
        model.setFormat(.json); model.discardPreview(); #expect(model.format == .csv && model.preview == nil && reads == 1)
        model.retire(); #expect(model.busy && !model.active); gate.release(); #expect(await task.value == false); #expect(!model.busy && model.preview == nil)
        let cancelledGate = Gate(), cancelled = owner(read: { value in await cancelledGate.hold(); return preview(value) })
        let cancelledTask = Task { await cancelled.choose(read: { try selection() }) }; try await cancelledGate.wait(); defer { cancelledGate.release() }
        cancelledTask.cancel(); cancelledGate.release(); #expect(await cancelledTask.value == false); #expect(cancelled.preview == nil && !cancelled.busy)
    }
    @Test func anAcknowledgedCommitSurvivesCancellationAndCannotBeSubmittedAgain() async throws {
        let gate = Gate(); var saves = 0
        let model = owner(save: { value, fingerprint in saves += 1; await gate.hold(); return preview(value, saved: true, fingerprint: fingerprint) })
        #expect(await model.choose(read: { try selection() })); let task = Task { await model.apply() }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy); #expect(await model.apply() == false); task.cancel(); gate.release()
        #expect(await task.value); #expect(model.lastSave?.preview.saved == true && !model.dirty && !model.busy)
        #expect(await model.apply() == false); #expect(saves == 1)
    }
    @Test func malformedOrDifferentAcknowledgementsCannotInventASuccessfulSave() async throws {
        let model = owner(save: { value, _ in preview(value, saved: true, fingerprint: String(repeating: "b", count: 64)) })
        #expect(await model.choose(read: { try selection() })); let before = model.preview
        #expect(await model.apply() == false); #expect(model.lastSave == nil && model.preview == before && model.saveBlocked)
        for saved in [false, true] {
            let bad = owner(read: { value in .init(changes: preview(value).changes, fingerprint: "synthetic-invalid", count: 1, added: 0, totalRows: value.rows.count, saved: saved) })
            #expect(await bad.choose(read: { try selection() }) == false); #expect(bad.preview == nil && !bad.dirty)
        }
    }
    @Test func exportsCaptureTheExactFormatAndKeepBusyThroughThePhysicalWrite() async throws {
        let gate = Gate(), model = owner(); model.setFormat(.json)
        var used: TransferFormat?, output = ""
        let task = Task { await model.export(template: false, apple: false, write: { value, format in used = format; output = value; await gate.hold(); return true }) }
        try await gate.wait(); defer { gate.release() }; model.setFormat(.csv)
        #expect(model.busy && model.format == .json); #expect(await model.choose(read: { try selection() }) == false)
        gate.release(); #expect(await task.value); #expect(used == .json); #expect(try Transfer.parse(.languages, output, format: .json) == table)
        #expect(!model.busy); #expect(await model.export(template: true, apple: false, write: { _, _ in false }) == false); #expect(model.status.isEmpty)
    }
    @Test func failedPreviewKeepsItsExistingReviewAndOversizedSelectionsNeverReachTheParser() async throws {
        var reads = 0
        let model = owner(read: { value in reads += 1; if reads > 1 { throw Failure.synthetic }; return preview(value) })
        #expect(await model.choose(read: { try selection() })); let before = model.preview
        #expect(await model.recheck() == false); #expect(model.preview == before && model.dirty && !model.busy)
        model.discardPreview()
        #expect(await model.choose(read: { .init(data: Data(repeating: 65, count: 4_000_001), format: .csv) }) == false)
        #expect(reads == 2 && model.preview == nil && !model.busy)
    }
}
