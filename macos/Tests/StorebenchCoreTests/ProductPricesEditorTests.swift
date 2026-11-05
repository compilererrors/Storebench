import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct ProductPricesEditorTests {
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
    private func product(_ kind: PriceProduct.Kind = .purchase) -> PriceProduct { .init(id: "synthetic-product", kind: kind, productId: "example.synthetic.product", name: "Synthetic product", state: "APPROVED", type: "CONSUMABLE", group: nil) }
    private func material(_ kind: PriceProduct.Kind = .purchase, foreign: Bool = false) throws -> ProductPriceMaterial {
        .init(scope: try foreign ? RecoveryGuidance.Scope(accountId: "synthetic-other", appId: "1000000001") : scope, product: product(kind),
            schedule: .init(baseTerritory: nil, rows: [], available: false, scheduleId: nil), activeTerritories: ["SWE", "USA"])
    }
    private var points: [ProductPricePoint] { [.init(id: "synthetic-unknown", territory: "USA", currency: nil, customerPrice: nil), .init(id: "synthetic-point", territory: "USA", currency: "USD", customerPrice: "1.99")] }
    private func review(_ request: PublishRequest) -> PublishReview {
        .init(plan: .init(title: "Synthetic price review", request: request, fingerprint: "synthetic-fingerprint", steps: [], notes: []), id: "synthetic-review", now: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func owner(material: (@MainActor (PriceProduct) async throws -> ProductPriceMaterial)? = nil,
                       points: (@MainActor (PriceProduct, String) async throws -> [ProductPricePoint])? = nil,
                       prepare: (@MainActor (PublishRequest) async throws -> PublishReview)? = nil) -> ProductPricesEditor {
        ProductPricesEditor(scope: scope, catalog: { .init(purchases: [product()], subscriptions: [product(.subscription)]) },
            material: material ?? { try self.material($0.kind) }, points: points ?? { _, _ in self.points }, prepare: prepare ?? { self.review($0) })
    }
    private func loaded(_ model: ProductPricesEditor) async throws {
        #expect(await model.refreshCatalog()); #expect(await model.select("purchase:synthetic-product")); #expect(await model.selectTerritory("USA"))
    }
    @Test func separateFamiliesRetainEqualIdsAndOnlyKnownLevelsAreInitiallySelected() async throws {
        let model = owner(); try await loaded(model)
        #expect(model.products.count == 2 && Set(model.products.map(\.selectionKey)).count == 2)
        #expect(model.inputs.pointId == "synthetic-point" && !model.dirty)
        #expect(await model.prepare()); #expect(model.review?.request.purchasePrice?.startDate == nil)
        #expect(model.review?.request.subscriptionPrice == nil)
        #expect(await model.select("subscription:synthetic-product")); #expect(model.material?.product.kind == .subscription && model.points == nil && model.review == nil)
    }
    @Test func unsavedChoicesBlockRefreshAndSelectionUntilAnExplicitDiscard() async throws {
        let model = owner(); try await loaded(model)
        var values = model.inputs; values.startDate = "2026-11-01"; model.update(values)
        #expect(model.dirty); #expect(await model.refreshCatalog() == false); #expect(await model.select("subscription:synthetic-product") == false)
        #expect(await model.selectTerritory("SWE") == false); #expect(model.inputs == values && model.territory == "USA")
        model.discardInputs(); #expect(!model.dirty); #expect(await model.select("subscription:synthetic-product"))
    }
    @Test func overlappingAndRetiredReadsCannotReplaceAnotherSelectionAndStayBusyUntilAcknowledged() async throws {
        let gate = Gate(); var reads = 0
        let model = owner(material: { selected in reads += 1; await gate.hold(); return try material(selected.kind) })
        #expect(await model.refreshCatalog())
        let task = Task { await model.select("purchase:synthetic-product") }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy); #expect(await model.select("subscription:synthetic-product") == false); #expect(reads == 1)
        var attempted = model.inputs; attempted.startDate = "2026-11-01"; model.update(attempted); #expect(model.inputs.startDate.isEmpty)
        model.retire(); #expect(model.busy && !model.active && model.material == nil)
        gate.release(); #expect(await task.value == false); #expect(!model.busy && model.material == nil)
    }
    @Test func cancellationForeignMaterialAndMalformedLevelsKeepUnknownDataUnknown() async throws {
        let foreign = owner(material: { _ in try material(foreign: true) }); #expect(await foreign.refreshCatalog())
        #expect(await foreign.select("purchase:synthetic-product") == false); #expect(foreign.material == nil)
        let wrongFamily = owner(material: { _ in try material(.subscription) }); #expect(await wrongFamily.refreshCatalog())
        #expect(await wrongFamily.select("purchase:synthetic-product") == false); #expect(wrongFamily.material == nil)
        let invalid = owner(points: { _, _ in [.init(id: "synthetic-point", territory: "SWE", currency: "SEK", customerPrice: "9.99")] })
        #expect(await invalid.refreshCatalog()); #expect(await invalid.select("purchase:synthetic-product"))
        #expect(await invalid.selectTerritory("USA") == false); #expect(invalid.material != nil && invalid.points == nil)
        let gate = Gate(), cancelled = owner(material: { selected in await gate.hold(); return try material(selected.kind) })
        #expect(await cancelled.refreshCatalog()); let task = Task { await cancelled.select("purchase:synthetic-product") }
        try await gate.wait(); defer { gate.release() }; task.cancel(); gate.release()
        #expect(await task.value == false); #expect(cancelled.material == nil && !cancelled.busy)
    }
    @Test func pointFailuresPreserveTheScheduleAndPrepareFailuresPreserveAllUnsavedInputs() async throws {
        let failure = owner(points: { _, _ in throw Failure.synthetic }); #expect(await failure.refreshCatalog()); #expect(await failure.select("purchase:synthetic-product"))
        #expect(await failure.selectTerritory("USA") == false); #expect(failure.material != nil && failure.points == nil)
        let model = owner(prepare: { _ in throw Failure.synthetic }); try await loaded(model)
        var values = model.inputs; values.planType = "MONTHLY"; values.subscriberPolicy = "no"; model.update(values)
        #expect(await model.prepare() == false); #expect(model.inputs == values && model.dirty && model.review == nil && !model.busy)
    }
    @Test func anAlreadyCancelledSelectionCannotEraseTheConfirmedProductAndPriceLevel() async throws {
        let model = owner(); try await loaded(model)
        let before = model.inputs, gate = Gate()
        let task = Task { await gate.hold(); return await model.select("subscription:synthetic-product") }
        try await gate.wait(); defer { gate.release() }; task.cancel(); gate.release()
        #expect(await task.value == false); #expect(model.selectionKey == "purchase:synthetic-product" && model.inputs == before && model.points != nil)
        let territoryGate = Gate(), territoryTask = Task { await territoryGate.hold(); return await model.selectTerritory("SWE") }
        try await territoryGate.wait(); defer { territoryGate.release() }; territoryTask.cancel(); territoryGate.release()
        #expect(await territoryTask.value == false); #expect(model.territory == "USA" && model.inputs == before && model.points != nil)
    }
    @Test func subscriptionPoliciesAndBillingPlansRemainExplicitInEveryRequest() throws {
        let subscription = product(.subscription), schedule = try material(.subscription).schedule
        var values = ProductPriceInputs(); values.pointId = "synthetic-point"
        #expect(throws: PublishFailure.self) { try values.request(accountId: scope.accountId, appId: scope.appId, product: subscription, schedule: schedule, territory: "USA", points: points, today: "2026-10-10") }
        for plan in ["", "MONTHLY", "UPFRONT"] {
            for policy in ["yes", "no"] {
                values.planType = plan; values.subscriberPolicy = policy
                let request = try values.request(accountId: scope.accountId, appId: scope.appId, product: subscription, schedule: schedule, territory: "USA", points: points, today: "2026-10-10")
                #expect(request.subscriptionPrice?.preserveCurrentPrice == (policy == "yes")); #expect(request.subscriptionPrice?.planType == (plan.isEmpty ? nil : plan))
                #expect(request.subscriptionPrice?.startDate == nil && request.purchasePrice == nil)
            }
        }
        values.startDate = "2026-11-01"
        #expect(try values.request(accountId: scope.accountId, appId: scope.appId, product: subscription, schedule: schedule, territory: "USA", points: points, today: "2026-10-10").subscriptionPrice?.startDate == "2026-11-01")
    }
    @Test func aCompletedPublishingReceiptRemainsVisibleAfterReadingTheUpdatedScheduleAndEditingAgain() async throws {
        let model = owner(); try await loaded(model); #expect(await model.prepare())
        var completed = try #require(model.review); completed.state = "complete"; model.replaceReview(completed)
        #expect(await model.select(model.selectionKey)); #expect(model.review?.id == completed.id && model.review?.state == "complete")
        #expect(await model.selectTerritory("USA")); #expect(model.review?.request.purchasePrice == completed.request.purchasePrice)
        var values = model.inputs; values.startDate = "2026-11-01"; model.update(values)
        #expect(model.review?.state == "complete" && model.dirty)
        model.discardInputs(); #expect(model.review?.state == "complete" && !model.dirty)
        #expect(await model.prepare()); #expect(model.review?.state == "prepared")
    }
    @Test func datesIncompleteSchedulesAndUnknownOrForeignLevelsCannotPrepareChanges() throws {
        let purchase = product(), schedule = ProductPriceSchedule(baseTerritory: "USA", rows: [], available: true, scheduleId: "synthetic-schedule")
        var values = ProductPriceInputs(); values.pointId = "synthetic-point"
        for date in ["", "2026-10-09", "2026-02-30", "2028-01-01", "2026-11-01\n"] {
            values.startDate = date
            #expect(throws: PublishFailure.self) { try values.request(accountId: scope.accountId, appId: scope.appId, product: purchase, schedule: schedule, territory: "USA", points: points, today: "2026-10-10") }
        }
        for date in ["2026-10-10", "2027-12-31"] {
            values.startDate = date
            #expect(try values.request(accountId: scope.accountId, appId: scope.appId, product: purchase, schedule: schedule, territory: "USA", points: points, today: "2026-10-10").purchasePrice?.startDate == date)
        }
        values.pointId = "synthetic-unknown"
        #expect(throws: PublishFailure.self) { try values.request(accountId: scope.accountId, appId: scope.appId, product: purchase, schedule: schedule, territory: "USA", points: points, today: "2026-10-10") }
        values.pointId = "synthetic-point"
        #expect(throws: PublishFailure.self) { try values.request(accountId: scope.accountId, appId: scope.appId, product: purchase, schedule: schedule, territory: "SWE", points: points, today: "2026-10-10") }
        #expect(throws: PublishFailure.self) { try values.request(accountId: scope.accountId, appId: scope.appId, product: purchase, schedule: .init(baseTerritory: nil, rows: [], available: false, scheduleId: "synthetic-schedule"), territory: "USA", points: points, today: "2026-10-10") }
    }
    @Test func preparingDoesNotAuthorizePublishingAndKeepsTheOwnerBusyUntilItReturns() async throws {
        let gate = Gate(); var prepared: PublishRequest?
        let model = owner(prepare: { request in prepared = request; await gate.hold(); return review(request) }); try await loaded(model)
        let task = Task { await model.prepare() }; try await gate.wait(); defer { gate.release() }
        #expect(model.busy && model.review == nil); #expect(await model.prepare() == false)
        model.publishingChanged(true); gate.release(); #expect(await task.value); #expect(model.busy && model.review?.state == "prepared")
        #expect(prepared?.purchasePrice?.productId == "synthetic-product")
        model.publishingChanged(false); #expect(model.ready)
    }
}
