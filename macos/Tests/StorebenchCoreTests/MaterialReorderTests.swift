import Foundation
import Testing
@testable import StorebenchCore

@Suite @MainActor struct MaterialReorderTests {
    init() throws { _ = try TestIsolation.require() }
    let order = ["synthetic-one", "synthetic-two", "synthetic-three"]
    @Test func edgeScrollingIsBoundedAndStopsOutsideTheViewport() {
        #expect(MaterialReorder.scrollStep(position: 0, length: 600) == -12)
        #expect(MaterialReorder.scrollStep(position: 24, length: 600) == -6)
        #expect(MaterialReorder.scrollStep(position: 600, length: 600) == 12)
        #expect(MaterialReorder.scrollStep(position: 300, length: 600) == 0)
        for position in [-1.0, 601, .infinity, .nan] { #expect(MaterialReorder.scrollStep(position: position, length: 600) == 0) }
        #expect(MaterialReorder.scrollStep(position: 1, length: 0) == 0)
        #expect(MaterialReorder.scrollStep(position: 1, length: .infinity) == 0)
        #expect(abs(MaterialReorder.scrollStep(position: 1, length: 6)) <= 12)
    }
    @Test func hoverCancelAndForeignTicketsNeverChangeTheOrder() throws {
        let session = MaterialReorder(), context = "synthetic-language-size"
        let token = try #require(session.begin(order[0], order: order, context: context, enabled: true))
        session.hover(order[2], after: true, order: order, context: context, enabled: true)
        #expect(session.drag?.baseline == order)
        #expect(session.commit(token: UUID(), order: order, context: context, enabled: true) == nil)
        #expect(session.active)
        #expect(session.commit(token: token, order: order, context: "another-synthetic-language", enabled: true) == nil)
        #expect(!session.active)
        let second = try #require(session.begin(order[0], order: order, context: context, enabled: true))
        session.hover(order[2], after: true, order: order, context: context, enabled: true)
        session.cancel(token: second)
        #expect(session.commit(token: second, order: order, context: context, enabled: true) == nil)
        #expect(!session.active)
    }
    @Test func dropMovesExactlyOnceAndACompletedSourceCannotCancelANewerDrag() throws {
        let session = MaterialReorder(), context = "synthetic-scope"
        let first = try #require(session.begin(order[0], order: order, context: context, enabled: true))
        session.hover(order[2], after: true, order: order, context: context, enabled: true)
        let next = try #require(session.commit(token: first, order: order, context: context, enabled: true))
        #expect(next == [order[1], order[2], order[0]])
        #expect(session.commit(token: first, order: next, context: context, enabled: true) == nil)
        let second = try #require(session.begin(order[0], order: next, context: context, enabled: true))
        session.cancel(token: first); #expect(session.drag?.token == second)
        session.cancel(token: second)
    }
    @Test func staleCatalogAndBusyOrRetiredScopesRejectTheDrop() throws {
        for scenario in 0...2 {
            let session = MaterialReorder(), token = try #require(session.begin(order[0], order: order, context: "synthetic-scope", enabled: true))
            session.hover(order[2], after: true, order: order, context: "synthetic-scope", enabled: true)
            #expect(session.commit(token: token, order: scenario == 0 ? Array(order.reversed()) : order, context: scenario == 1 ? "retired-synthetic-scope" : "synthetic-scope", enabled: scenario != 2) == nil)
            #expect(!session.active)
        }
        #expect(MaterialReorder().begin("one", order: ["one", "one"], context: "synthetic", enabled: true) == nil)
        #expect(MaterialReorder().begin("foreign", order: order, context: "synthetic", enabled: true) == nil)
    }
    @Test func beforeAfterAndKeyboardMovesPreserveEveryIdentity() {
        #expect(MaterialReorder.placing(order, source: order[2], target: order[0], after: false) == [order[2], order[0], order[1]])
        #expect(MaterialReorder.placing(order, source: order[0], target: order[2], after: true) == [order[1], order[2], order[0]])
        #expect(MaterialReorder.moving(order, source: order[0], to: 2) == [order[1], order[2], order[0]])
        #expect(MaterialReorder.moving(order, source: order[0], to: -1) == nil)
        #expect(MaterialReorder.moving(order, source: order[0], to: 3) == nil)
    }
    @Test func selectedOriginalsAndEditsSurviveOrderChangesAndStaleReplaysFail() throws {
        let items = [ScreenshotSelection.Item(name: "synthetic-one.png", data: Data([1, 2, 3])), ScreenshotSelection.Item(name: "synthetic-two.png", data: Data([4, 5, 6]))]
        var selection = ScreenshotSelection(items: items)
        let revision = selection.revision
        let changed = selection.reorder(Array(items.map(\.id).reversed()), expectedRevision: revision); #expect(changed)
        #expect(selection.items[1].original == items[0].original && selection.items[0].data == items[1].data)
        let stale = selection.reorder(items.map(\.id), expectedRevision: revision); #expect(!stale)
        let invalid = selection.reorder([items[0].id, items[0].id], expectedRevision: selection.revision); #expect(!invalid)
    }

    /// A three-column grid of 300 × 400 cards with 20 pt gaps; the last row holds only "synthetic-four".
    @Test func dropsInGapsAndAfterTheLastCardLandBesideTheNearestCardInThatRow() throws {
        let frames = ["synthetic-one", "synthetic-two", "synthetic-three", "synthetic-four"].enumerated().map { index, id in
            (id: id, frame: CGRect(x: Double(index % 3) * 320, y: Double(index / 3) * 420, width: 300, height: 400))
        }
        // The empty space right of the last card, even below the previous row's last column, places after it: the last position.
        let end = try #require(MaterialReorder.slot(at: CGPoint(x: 800, y: 600), frames: frames))
        #expect(end.target == "synthetic-four" && end.after)
        let below = try #require(MaterialReorder.slot(at: CGPoint(x: 100, y: 900), frames: frames))
        #expect(below.target == "synthetic-four" && !below.after)
        // A gap between two cards belongs to the nearer one.
        let gap = try #require(MaterialReorder.slot(at: CGPoint(x: 305, y: 200), frames: frames))
        #expect(gap.target == "synthetic-one" && gap.after)
        let leading = try #require(MaterialReorder.slot(at: CGPoint(x: 330, y: 200), frames: frames))
        #expect(leading.target == "synthetic-two" && !leading.after)
        #expect(MaterialReorder.slot(at: CGPoint(x: 10, y: 10), frames: []) == nil)

        let session = MaterialReorder(), order = frames.map(\.id)
        let token = try #require(session.begin("synthetic-two", order: order, context: "synthetic", enabled: true))
        session.hover(end.target, after: end.after, order: order, context: "synthetic", enabled: true)
        #expect(session.commit(token: token, order: order, context: "synthetic", enabled: true) == ["synthetic-one", "synthetic-three", "synthetic-four", "synthetic-two"])
    }
}
