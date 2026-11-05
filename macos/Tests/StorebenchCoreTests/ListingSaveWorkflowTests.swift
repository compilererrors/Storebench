import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct ListingSaveWorkflowTests {
    init() throws { _ = try TestIsolation.require() }
    private enum SyntheticFailure: Error { case preparation, timeout }
    @MainActor private final class Input {
        var dirty = true, blocked = false, succeeds = true, calls = 0
        var signature = "Synthetic initial inputs"
        var state: ListingSaveWorkflow.State { .init(dirty: dirty, blocked: blocked, signature: signature) }
        func save() -> Bool { calls += 1; if succeeds { dirty = false }; return succeeds }
    }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation = $0; entered = true }
        }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered {
                guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func existingAtomicLayoutsFreeCapacityBeforePendingFilesAndPreparation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        let layout = try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: "set-1")
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), layoutInput = Input(), files = Input()
        var order: [String] = []
        workflow.register(priority: .file, state: { files.state }, save: {
            files.calls += 1; order.append("files")
            do {
                let count = try await session.addScreenshots(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1",
                    files: (0..<10).map { ("synthetic-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8($0))) })
                guard count == 10 else { return false }; files.dirty = false; return true
            } catch { return false }
        })
        workflow.register(priority: .layout, state: { layoutInput.state }, save: {
            layoutInput.calls += 1; order.append("layout")
            do {
                _ = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
                layoutInput.dirty = false; return true
            } catch { return false }
        })
        let result = await workflow.run(prepare: {
            let saved = try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: "set-1")
            #expect(saved.items.count == 11 && saved.items.filter { !saved.hidden.contains($0.id) }.count == 10)
            order.append("prepare")
        })
        #expect(result.saves == 2 && result.reviewReady && workflow.owns(result) && workflow.ready)
        #expect(order == ["layout", "files", "prepare"] && layoutInput.calls == 1 && files.calls == 1)
    }

    @Test func textThenLayoutsThenFilesRetainStableRegistrationOrder() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing")
        var order: [String] = []
        for (name, priority) in [("file-first", ListingSaveWorkflow.Priority.file), ("layout-first", .layout), ("text-first", .text), ("layout-second", .layout), ("text-second", .text)] {
            let input = Input()
            workflow.register(priority: priority, state: { input.state }, save: { order.append(name); return input.save() })
        }
        let result = await workflow.run()
        #expect(result.complete && result.saves == 5 && !result.prepared)
        #expect(order == ["text-first", "text-second", "layout-first", "layout-second", "file-first"])
    }

    @Test func blockedEditorsStopEveryWriteAndPreparation() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input()
        input.blocked = true; var prepares = 0
        workflow.register(priority: .layout, state: { input.state }, save: { input.save() })
        let result = await workflow.run(prepare: { prepares += 1 })
        #expect(result.failure == .blocked && input.dirty && input.calls == 0 && prepares == 0)
        #expect(!workflow.busy && !workflow.owns(result))
    }

    @Test func inputNotificationsInvalidateAnEarlierPreparedResultEvenWhenClean() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input()
        workflow.register(priority: .layout, state: { input.state }, save: { input.save() })
        let original = await workflow.run(prepare: {})
        #expect(original.reviewReady && workflow.ready && workflow.owns(original))
        workflow.changed()
        #expect(workflow.ready && !workflow.owns(original) && workflow.lastResult == nil)
        let replacement = await workflow.run(prepare: {})
        #expect(replacement.reviewReady && replacement.saves == 0 && workflow.owns(replacement))
    }

    @Test func partialFailureKeepsInputsAndRetryDoesNotResaveCompletedEditors() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), first = Input(), second = Input(), files = Input()
        var prepares = 0
        second.succeeds = false
        for (input, priority) in [(first, ListingSaveWorkflow.Priority.layout), (second, .layout), (files, .file)] {
            workflow.register(priority: priority, state: { input.state }, save: { input.save() })
        }
        let failed = await workflow.run(prepare: { prepares += 1 })
        #expect(failed.failure == .save && failed.saves == 1 && first.calls == 1 && second.calls == 1 && files.calls == 0)
        #expect(!first.dirty && second.dirty && files.dirty && prepares == 0 && workflow.dirty)
        second.succeeds = true
        let retried = await workflow.run(prepare: { prepares += 1 })
        #expect(retried.saves == 2 && retried.reviewReady && prepares == 1)
        #expect(first.calls == 1 && second.calls == 2 && files.calls == 1 && !workflow.owns(failed) && workflow.owns(retried))
    }

    @Test func changedInputsAreNotSilentlyAdoptedOrSavedUnderAnEarlierSnapshot() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), first = Input(), second = Input()
        second.signature = "é"; var prepares = 0
        workflow.register(priority: .text, state: { first.state }, save: { second.signature = "e\u{301}"; return first.save() })
        workflow.register(priority: .layout, state: { second.state }, save: { second.save() })
        let result = await workflow.run(prepare: { prepares += 1 })
        #expect(result.failure == .changed && result.saves == 1 && second.dirty && second.calls == 0 && prepares == 0)
    }

    @Test func aSecondStartCannotReplaceTheActiveOperation() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input(), gate = Gate()
        workflow.register(priority: .layout, state: { input.state }, save: { await gate.hold(); return input.save() })
        let first = Task { await workflow.run() }
        try await gate.wait(); defer { gate.release() }
        let second = await workflow.run()
        #expect(second.failure == .busy && input.calls == 0 && workflow.busy && !workflow.owns(second))
        gate.release(); let result = await first.value
        #expect(result.saves == 1 && result.complete && input.calls == 1 && workflow.owns(result))
    }

    @Test func retiredOwnersCannotFinishOrRemoveAReplacementContext() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic first context"), original = Input(), replacement = Input(), gate = Gate()
        let oldId = workflow.register(priority: .file, state: { original.state }, save: { await gate.hold(); return original.save() })
        let oldRun = Task { await workflow.run() }
        try await gate.wait(); defer { gate.release() }
        workflow.reset(identity: "Synthetic replacement context")
        workflow.register(priority: .file, state: { replacement.state }, save: { replacement.save() })
        workflow.unregister(oldId)
        let current = await workflow.run()
        gate.release(); let stale = await oldRun.value
        #expect(stale.failure == .cancelled && stale.savedAny && !workflow.owns(stale))
        #expect(current.complete && current.saves == 1 && replacement.calls == 1 && workflow.lastResult == current && workflow.owns(current))
    }

    @Test func removedRegistrationStopsPreparationAfterAnAlreadyCommittedSave() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input(), gate = Gate()
        var prepares = 0
        let id = workflow.register(priority: .file, state: { input.state }, save: { await gate.hold(); return input.save() })
        let operation = Task { await workflow.run(prepare: { prepares += 1 }) }
        try await gate.wait(); defer { gate.release() }
        workflow.unregister(id); gate.release(); let result = await operation.value
        #expect(result.failure == .changed && result.saves == 1 && prepares == 0 && !workflow.busy)
    }

    @Test func editsDuringASaveAreKeptAndPreventPreparation() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input()
        var prepares = 0
        workflow.register(priority: .text, state: { input.state }, save: { input.calls += 1; input.signature = "Synthetic later edit"; return true })
        let result = await workflow.run(prepare: { prepares += 1 })
        #expect(result.failure == .changed && result.saves == 1 && input.dirty && prepares == 0)
    }

    @Test func failedPreparationKeepsLocalSavesAndRetryOnlyPrepares() async {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input()
        var prepares = 0
        workflow.register(priority: .file, state: { input.state }, save: { input.save() })
        let failed = await workflow.run(prepare: { prepares += 1; throw SyntheticFailure.preparation })
        #expect(failed.failure == .preparation && failed.savedAny && !failed.prepared && !input.dirty)
        let retry = await workflow.run(prepare: { prepares += 1 })
        #expect(retry.reviewReady && retry.saves == 0 && input.calls == 1 && prepares == 2)
    }

    @Test func newInputsDuringPreparationWithholdTheReview() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), later = Input(), gate = Gate()
        let operation = Task { await workflow.run(prepare: { await gate.hold() }) }
        try await gate.wait(); defer { gate.release() }
        workflow.register(priority: .file, state: { later.state }, save: { later.save() })
        gate.release(); let result = await operation.value
        #expect(result.failure == .changed && result.prepared && !result.reviewReady && later.dirty && later.calls == 0)
    }

    @Test func taskCancellationAcknowledgesOnlyTheSaveThatAlreadyFinished() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic listing"), input = Input(), gate = Gate()
        var prepares = 0
        workflow.register(priority: .file, state: { input.state }, save: { await gate.hold(); return input.save() })
        let operation = Task { await workflow.run(prepare: { prepares += 1 }) }
        try await gate.wait(); defer { gate.release() }
        operation.cancel(); gate.release(); let result = await operation.value
        #expect(result.failure == .cancelled && result.saves == 1 && !result.reviewReady && !input.dirty && prepares == 0)
    }

    @Test func aCleanOwnerChangeDuringPreparationWithholdsTheOlderReview() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic clean listing"), input = Input(), gate = Gate(); input.dirty = false
        workflow.register(priority: .text, state: { input.state }, save: { input.save() })
        let task = Task { await workflow.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
        input.signature = "Synthetic already saved newer baseline"; workflow.changed(); gate.release(); let result = await task.value
        #expect(result.failure == .changed && result.prepared && !result.reviewReady && !input.dirty)
    }
    @Test func directLiveSignatureChangesDoNotNeedAViewNotificationToStopPreparation() async throws {
        let workflow = ListingSaveWorkflow(identity: "Synthetic live listing"), input = Input(), gate = Gate(); input.dirty = false
        workflow.register(priority: .layout, state: { input.state }, save: { input.save() })
        let task = Task { await workflow.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
        input.signature = "Synthetic changed live signature"; gate.release(); let result = await task.value
        #expect(result.failure == .changed && !result.reviewReady)
    }
    @Test func aCleanNewOwnerAndAReadWithoutDirtyInputsStillInvalidatePreparation() async throws {
        for addOwner in [false, true] {
            let workflow = ListingSaveWorkflow(identity: "Synthetic refreshed listing"), gate = Gate()
            let task = Task { await workflow.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
            if addOwner { workflow.register(priority: .text, state: { .init(dirty: false, blocked: false, signature: "Synthetic new clean owner") }, save: { true }) }
            else { workflow.changed() }
            gate.release(); let result = await task.value
            #expect(result.failure == .changed && result.prepared && !result.reviewReady)
        }
    }
}
