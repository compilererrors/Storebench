import Foundation
import ImageIO
import Testing
@testable import StorebenchCore

@Suite struct MediaCardsTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    let target = MediaCards.defaultTarget

    func card(_ layout: MediaCard.Layout, shot: (Int, Int)? = (1206, 2622)) -> MediaCard {
        var card = MediaCard(); card.layout = layout; card.title = "Synthetic planner title"; card.subtitle = "Synthetic subtitle"
        if let shot { card.screenshot = .init(hash: String(repeating: "a", count: 64), name: "synthetic.png", width: shot.0, height: shot.1) }
        return card
    }

    @Test func layoutsPlaceTextAndScreenshotInsideOrAcrossTheCardEdge() throws {
        #expect(target.width == 1320 && target.height == 2868)
        let above = MediaCards.placement(card(.textAbove), width: target.width, height: target.height)
        let text = try #require(above.text), screen = try #require(above.screen)
        #expect(screen.top > text.top + text.height && screen.top + screen.height <= Double(target.height) + 0.5)
        #expect(abs(screen.width / screen.height - 1206.0 / 2622.0) < 0.001 && abs(screen.left + screen.width / 2 - Double(target.width) / 2) < 0.5)
        let below = MediaCards.placement(card(.textBelow), width: target.width, height: target.height)
        let belowScreen = try #require(below.screen), belowText = try #require(below.text)
        #expect(belowScreen.top + belowScreen.height < belowText.top)
        // The cropped layouts let a tall screenshot run past the card's bottom or top edge.
        let bleed = try #require(MediaCards.placement(card(.bleedBottom), width: target.width, height: target.height).screen)
        #expect(bleed.top + bleed.height > Double(target.height))
        let top = try #require(MediaCards.placement(card(.bleedTop), width: target.width, height: target.height).screen)
        #expect(top.top < 0)
        let focus = MediaCards.placement(card(.focus), width: target.width, height: target.height)
        let focusScreen = try #require(focus.screen)
        #expect(focusScreen.top + focusScreen.height <= Double(target.height) + 0.5)
        let only = MediaCards.placement(card(.textOnly, shot: nil), width: target.width, height: target.height)
        #expect(only.screen == nil && only.text != nil)
        var untitled = card(.textAbove); untitled.title = ""; untitled.subtitle = ""
        #expect(MediaCards.placement(untitled, width: target.width, height: target.height).text == nil)
    }

    @Test func textShrinksToFitOrFailsInsteadOfClipping() throws {
        let measure: (String, Double, MediaCards.Weight) -> Double = { text, size, _ in Double(text.count) * size * 0.55 }
        var long = card(.textAbove); long.body = String(repeating: "synthetic words ", count: 18)
        let area = MediaCards.Area(left: 0, top: 0, width: 1100, height: 700)
        let lines = try MediaCards.lines(long, area: area, shortSide: 1320, measure: measure)
        #expect(!lines.isEmpty && lines.allSatisfy { measure($0.text, $0.size, $0.weight) <= area.width + 0.5 && $0.top >= area.top })
        #expect(lines.last.map { $0.top + $0.size * 1.4 <= area.height + 0.5 } == true)
        #expect(throws: MediaCardFailure.text) { try MediaCards.lines(long, area: .init(left: 0, top: 0, width: 300, height: 80), shortSide: 1320, measure: measure) }
        var trailing = card(.textOnly, shot: nil); trailing.style.alignment = .trailing
        let right = try MediaCards.lines(trailing, area: area, shortSide: 1320, measure: measure)
        #expect(right.allSatisfy { abs($0.left + measure($0.text, $0.size, $0.weight) - area.width) < 0.5 })
    }

    @Test func exportsOpaquePNGsAtTheExactAppStoreSize() throws {
        let bytes = try AssetLibraryTests().png(width: 603, height: 1311)
        let source = try ScreenshotRenderer.load(bytes)
        var value = card(.bleedBottom, shot: (603, 1311)); value.style.borderWidth = 2; value.zoom = 1.4; value.x = 0.2
        let png = try MediaCardRenderer.export(value, width: target.width, height: target.height, screenshot: source)
        let info = try ScreenshotEditing.inspect(png)
        #expect(info.width == target.width && info.height == target.height && !info.transparent)
        #expect(try ScreenshotSpecs.validate(png).contentType == "image/png")
        // Export never invents a screenshot; a preview shows a placeholder instead.
        #expect(throws: MediaCardFailure.screenshot) { try MediaCardRenderer.export(card(.textAbove, shot: nil), width: target.width, height: target.height, screenshot: nil) }
        #expect(throws: MediaCardFailure.screenshot) { try MediaCardRenderer.export(card(.textAbove), width: target.width, height: target.height, screenshot: source) }
        let placeholder = try MediaCardRenderer.render(card(.textAbove, shot: nil), width: target.width, height: target.height, screenshot: nil, edge: 600)
        #expect(max(placeholder.width, placeholder.height) == 600)
        var solid = card(.textOnly, shot: nil); solid.style.fill = .solid; solid.body = "Synthetic body text"
        #expect(try ScreenshotEditing.inspect(MediaCardRenderer.export(solid, width: 2064, height: 2752, screenshot: nil)).width == 2064)
    }

    @Test func dragMovesTheCropOnlyFromInsideTheScreenshot() throws {
        var value = card(.focus); value.zoom = 2
        let screen = try #require(MediaCards.placement(value, width: target.width, height: target.height).screen)
        let moved = MediaCards.drag(value, width: target.width, height: target.height, startX: screen.left + 10, startY: screen.top + 10, deltaX: 100, deltaY: 0)
        #expect(moved.x < value.x && moved.y == value.y)
        #expect(MediaCards.drag(value, width: target.width, height: target.height, startX: 1, startY: 1, deltaX: 100, deltaY: 100) == value)
        let fitted = MediaCards.drag(card(.textAbove), width: target.width, height: target.height, startX: screen.left + 10, startY: Double(target.height) / 2, deltaX: 100, deltaY: 100)
        #expect(fitted.x == 0.5 && fitted.y == 0.5)
    }

    @Test func validationRejectsUnknownSizesColorsLimitsAndDuplicates() throws {
        var set = MediaCardSet(name: "Synthetic set", target: target)
        try MediaCards.validate(set)
        var wrong = set; wrong.width = 1000; #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        wrong = set; wrong.cards[0].style.color = "blue"; #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        wrong = set; wrong.cards[0].title = String(repeating: "x", count: MediaCards.titleLimit + 1); #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        wrong = set; wrong.cards[0].style.margin = .nan; #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        wrong = set; wrong.cards.append(set.cards[0]); #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        wrong = set; wrong.name = "  "; #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(wrong) }
        for _ in 1..<MediaCards.maximumCards { try set.addCard(after: nil) }
        #expect(throws: MediaCardFailure.full) { try set.addCard(after: nil) }
        #expect(MediaCards.fileName(set: set, index: 2) == "Synthetic-set-03.png")
    }

    @Test func cardOperationsKeepTheSetsLookAndNeverRemoveTheLastCard() throws {
        var set = MediaCardSet(name: "Synthetic set", target: target)
        set.cards[0].style.color = "#123456"; set.cards[0].layout = .bleedBottom
        let first = set.cards[0].id
        #expect(set.removeCard(first) == nil && set.cards.count == 1)
        let added = try set.addCard(after: first)
        #expect(added.style.color == "#123456" && added.layout == .bleedBottom && set.cards.map(\.id) == [first, added.id])
        set.cards[0].title = "Synthetic first"
        let copy = try set.duplicateCard(first)
        #expect(copy.id != first && copy.title == "Synthetic first" && set.cards[1].id == copy.id)
        set.moveCard(first, by: 1); #expect(set.cards[1].id == first)
        set.moveCard(first, by: 5); #expect(set.cards[1].id == first)
        set.cards[2].style.titleColor = "#abcdef"; set.applyStyle(from: set.cards[2].id)
        #expect(set.cards.allSatisfy { $0.style.titleColor == "#abcdef" } && set.cards[0].title == "Synthetic first")
        #expect(set.removeCard(first) == set.cards[1].id)
    }

    @Test func historyCoalescesQuickChangesToOneControlAndRedoes() throws {
        var history = MediaCardHistory(MediaCardSet(name: "Synthetic set", target: target))
        let original = history.set
        history.change("zoom", now: 1) { $0.cards[0].zoom = 1.5 }
        history.change("zoom", now: 1.5) { $0.cards[0].zoom = 2 }
        history.change("title", now: 1.6) { $0.cards[0].title = "Synthetic" }
        history.change("title", now: 4) { $0.cards[0].title = "Synthetic title" }
        history.change("noop", now: 5) { _ in }
        #expect(history.set.cards[0].title == "Synthetic title" && history.canUndo && !history.canRedo)
        history.undo(); #expect(history.set.cards[0].title == "Synthetic")
        history.undo(); #expect(history.set.cards[0].title == "" && history.set.cards[0].zoom == 2)
        history.undo(); #expect(history.set == original && !history.canUndo)
        history.redo(); history.redo(); #expect(history.set.cards[0].title == "Synthetic" && history.canRedo)
        history.change("zoom", now: 6) { $0.cards[0].zoom = 3 }
        #expect(!history.canRedo)
    }

    @Test func colorSuggestionsComeFromTheScreenshot() throws {
        let source = try ScreenshotRenderer.load(try AssetLibraryTests().png(width: 120, height: 240))
        let colors = MediaCardColors.suggestions(source)
        #expect(colors.count == 1 && colors[0].hasPrefix("#") && colors[0].count == 7)
    }

    @Test func cardSetsSaveOnTheLoadedRevisionAndLibraryCopiesStayLocal() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let bytes = try AssetLibraryTests().png(width: 603, height: 1311)
        let shot = try await session.stageMediaCardScreenshot(accountId: account.id, appId: app, bytes: bytes, name: "synthetic\nscreen.png")
        #expect(shot.width == 603 && shot.height == 1311 && shot.name == "syntheticscreen.png")
        await #expect(throws: MediaCardFailure.missing) { try await session.mediaCardScreenshot(accountId: account.id, appId: app, hash: shot.hash) }

        var set = MediaCardSet(name: "Synthetic launch", target: target)
        set.cards[0].screenshot = shot; set.cards[0].title = "Synthetic title"
        let first = try await session.saveMediaCardSet(accountId: account.id, appId: app, set: set, expected: 0)
        #expect(first == 1)
        await #expect(throws: MediaCardFailure.stale) { try await session.saveMediaCardSet(accountId: account.id, appId: app, set: set, expected: 0) }
        set.cards[0].subtitle = "Synthetic subtitle"
        let second = try await session.saveMediaCardSet(accountId: account.id, appId: app, set: set, expected: first)
        #expect(second == 2)
        let loaded = try await session.mediaCardSets(accountId: account.id, appId: app)
        #expect(loaded == [.init(revision: 2, set: set)])
        #expect(try await session.mediaCardScreenshot(accountId: account.id, appId: app, hash: shot.hash) == bytes)
        await #expect(throws: (any Error).self) { try await session.mediaCardSets(accountId: account.id, appId: "1999999999") }

        let png = try MediaCardRenderer.export(set.cards[0], width: set.width, height: set.height, screenshot: try ScreenshotRenderer.load(bytes))
        let file = try await session.stageCreatedLibraryImage(accountId: account.id, appId: app, bytes: png, fileName: MediaCards.fileName(set: set, index: 0), referenceName: "Synthetic launch 1")
        #expect(file.category == .listing && file.width == 1320 && file.height == 2868 && !file.hasAlpha && file.fileName == "Synthetic-launch-01.png")
        #expect(try await session.assetLibraryFiles(accountId: account.id, appId: app).contains(file))
        await #expect(throws: (any Error).self) { try await session.stageCreatedLibraryImage(accountId: account.id, appId: app, bytes: try AssetLibraryTests().png(alpha: true), fileName: "x.png", referenceName: "") }

        await #expect(throws: MediaCardFailure.stale) { try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 1) }
        try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 2)
        #expect(try await session.mediaCardSets(accountId: account.id, appId: app).isEmpty)
        await #expect(throws: MediaCardFailure.missing) { try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 2) }
    }
}
