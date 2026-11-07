import CoreText
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
        // The text area is kept before any text is written, so typing never moves the screenshot.
        var untitled = card(.textAbove); untitled.title = ""; untitled.subtitle = ""
        #expect(MediaCards.placement(untitled, width: target.width, height: target.height) == above)
    }

    @Test func everyCardTypePlacesALandscapeScreenshotSoTextFitsAndCropsRunPastTheEdge() throws {
        let mac = try #require(MediaCards.targets.first { $0.type == "APP_DESKTOP" && $0.width > $0.height })
        let h = Double(mac.height), wide = (3680, 2234)
        for layout in [MediaCard.Layout.textAbove, .textBelow] {
            var value = card(layout, shot: wide); value.style.screenshotWidth = 0.6
            let placement = MediaCards.placement(value, width: mac.width, height: mac.height)
            let text = try #require(placement.text), screen = try #require(placement.screen)
            // Text and screenshot sit together in the middle, with the same space above and below them.
            let first = min(text.top, screen.top), last = max(text.top + text.height, screen.top + screen.height)
            #expect(abs(first - (h - last)) < 1 && (layout == .textAbove ? text.top + text.height < screen.top : screen.top + screen.height < text.top))
            #expect(!placement.limited && abs(screen.width / screen.height - 3680.0 / 2234.0) < 0.001)
        }
        let bottom = try #require(MediaCards.placement(card(.bleedBottom, shot: wide), width: mac.width, height: mac.height).screen)
        #expect(bottom.top + bottom.height >= h + bottom.height * 0.1 - 0.5)
        let topPlacement = MediaCards.placement(card(.bleedTop, shot: wide), width: mac.width, height: mac.height)
        let top = try #require(topPlacement.screen), topText = try #require(topPlacement.text)
        #expect(top.top <= -top.height * 0.1 + 0.5 && topText.top > top.top + top.height && topText.top + topText.height <= h + 0.5)
        // A tall screenshot on a phone card is limited by its height, and says so.
        #expect(MediaCards.placement(card(.textAbove), width: target.width, height: target.height).limited)
    }

    @Test func textSizeReportsWhenSpaceForTextMakesItSmaller() throws {
        var value = card(.textAbove); value.body = String(repeating: "synthetic words ", count: 6)
        value.style.textSize = 1.5; value.style.textSpace = 0.12
        let squeezed = try #require(MediaCardRenderer.textShare(value, width: target.width, height: target.height))
        value.style.textSpace = 0.5; value.style.textSize = 0.6
        let roomy = try #require(MediaCardRenderer.textShare(value, width: target.width, height: target.height))
        #expect(squeezed < 1 && roomy == 1)
    }

    @Test func typefacesUseTheMacsDesignsAnInstalledFamilyOrAFontFile() throws {
        func name(_ style: MediaCardStyle, file: Data? = nil) -> String { CTFontCopyPostScriptName(MediaCardRenderer.font(style, .body, 40, file: file)) as String }
        var style = MediaCardStyle()
        let names = [MediaCardStyle.Typeface.standard, .rounded, .serif, .monospaced].map { face -> String in style.typeface = face; return name(style) }
        #expect(Set(names).count == 4)
        style.typeface = .installed; style.fontFamily = "Helvetica"
        #expect(name(style).hasPrefix("Helvetica"))
        let url = try #require(CTFontCopyAttribute(CTFontCreateWithName("Helvetica" as CFString, 12, nil), kCTFontURLAttribute) as? URL)
        let data = try Data(contentsOf: url)
        #expect(MediaCardRenderer.fontFamily(data) == "Helvetica" && MediaCardRenderer.fontFamily(Data("not a font".utf8)) == nil)
        style.typeface = .file; style.fontFile = .init(hash: String(repeating: "b", count: 64), name: "Synthetic.ttc", family: "Helvetica")
        #expect(name(style, file: data).hasPrefix("Helvetica"))
        var value = card(.textOnly, shot: nil); value.style = style
        #expect(throws: MediaCardFailure.font) { try MediaCardRenderer.render(value, width: target.width, height: target.height, screenshot: nil) }
        #expect(throws: Never.self) { try MediaCardRenderer.render(value, width: target.width, height: target.height, screenshot: nil, font: data) }
        style.fontFile = nil
        var missing = card(.textOnly, shot: nil); missing.style = style
        #expect(throws: MediaCardFailure.invalid) { try MediaCards.validate(missing) }
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

    @Test func aFinishedFileLoadAppliesOnlyToTheCardItWasChosenFor() throws {
        var set = MediaCardSet(name: "Synthetic set", target: target)
        let a = set.cards[0].id, b = try set.addCard(after: a).id
        // A screenshot is chosen for card A; card B is selected and moved first while the file loads.
        let load = MediaCardLoad(setId: set.id, cardId: a, kind: .screenshot)
        var newest = [load.key: load.ticket]
        set.cards.swapAt(0, 1)
        #expect(load.position(in: set, newest: newest) == 1 && set.cards[1].id == a && set.cards[0].id == b)
        // A newer choice for card A replaces the older one; a font choice for A is a separate kind.
        let newer = MediaCardLoad(setId: set.id, cardId: a, kind: .screenshot), font = MediaCardLoad(setId: set.id, cardId: a, kind: .font)
        newest[newer.key] = newer.ticket; newest[font.key] = font.ticket
        #expect(load.position(in: set, newest: newest) == nil && newer.position(in: set, newest: newest) == 1 && font.position(in: set, newest: newest) == 1)
        // Another open set, a closed editor or a removed card take nothing.
        let other = MediaCardSet(name: "Other synthetic set", target: target)
        #expect(newer.position(in: other, newest: newest) == nil && newer.position(in: nil, newest: newest) == nil)
        _ = set.removeCard(a)
        #expect(newer.position(in: set, newest: newest) == nil && font.position(in: set, newest: newest) == nil)
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

    @Test func fontFilesAreCheckedSavedEncryptedAndReadOnlyForCardsThatUseThem() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let url = try #require(CTFontCopyAttribute(CTFontCreateWithName("Helvetica" as CFString, 12, nil), kCTFontURLAttribute) as? URL)
        let data = try Data(contentsOf: url)
        await #expect(throws: MediaCardFailure.font) { try await session.stageMediaCardFont(accountId: account.id, appId: app, bytes: Data("not a font".utf8), name: "x.ttf") }
        let file = try await session.stageMediaCardFont(accountId: account.id, appId: app, bytes: data, name: "Synthetic\nFont.ttc")
        #expect(file.family == "Helvetica" && file.name == "SyntheticFont.ttc")
        await #expect(throws: MediaCardFailure.missing) { try await session.mediaCardFont(accountId: account.id, appId: app, hash: file.hash) }
        var set = MediaCardSet(name: "Synthetic fonts", target: target)
        set.cards[0].layout = .textOnly; set.cards[0].title = "Synthetic title"; set.cards[0].style.typeface = .file; set.cards[0].style.fontFile = file
        _ = try await session.saveMediaCardSet(accountId: account.id, appId: app, set: set, expected: 0)
        #expect(try await session.mediaCardFont(accountId: account.id, appId: app, hash: file.hash) == data)
        // A card saved before fonts existed decodes with the system typeface.
        let old = try JSONDecoder().decode(MediaCardStyle.self, from: Data(##"{"fill":"gradient","color":"#2f4fd8","secondColor":"#7b3fe4","angle":160,"titleColor":"#ffffff","subtitleColor":"#e8ecff","bodyColor":"#d9e0ff","typeface":"rounded","alignment":"center","textSize":1,"textSpace":0.26,"margin":6,"screenshotWidth":0.82,"cornerRadius":7,"borderWidth":0,"borderColor":"#111827","shadow":true}"##.utf8))
        #expect(old.typeface == .rounded && old.fontFamily == nil && old.fontFile == nil)
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
        func image(_ position: Int, _ bytes: Data) -> WorkspaceSession.CreatedLibraryImage {
            .init(sourceId: set.cards[position].id, bytes: bytes, fileName: MediaCards.fileName(set: set, index: position), referenceName: "Synthetic launch \(position + 1)")
        }
        let file = try #require(try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(0, png)]).files.first)
        #expect(file.category == .listing && file.width == 1320 && file.height == 2868 && !file.hasAlpha && file.fileName == "Synthetic-launch-01.png")
        #expect(try await session.assetLibraryFiles(accountId: account.id, appId: app).contains(file))

        // A batch with one unusable image saves none of them.
        try set.addCard(after: set.cards[0].id); set.cards[1].layout = .textOnly; set.cards[1].title = "Second synthetic card"
        let secondPNG = try MediaCardRenderer.export(set.cards[1], width: set.width, height: set.height, screenshot: nil)
        let before = try await session.assetLibraryFiles(accountId: account.id, appId: app)
        await #expect(throws: (any Error).self) {
            try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(1, secondPNG), image(0, try AssetLibraryTests().png(alpha: true))])
        }
        #expect(try await session.assetLibraryFiles(accountId: account.id, appId: app) == before)
        // Saving the same cards again keeps the existing entries; a changed card adds only itself; a removed entry is saved again.
        let all = try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(0, png), image(1, secondPNG)])
        #expect(all.added == 1 && all.files[0] == file && all.files.count == 2)
        let retry = try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(0, png), image(1, secondPNG)])
        let library = try await session.assetLibraryFiles(accountId: account.id, appId: app)
        #expect(retry.added == 0 && retry.files == all.files && library.count == before.count + 1)
        set.cards[1].title = "Changed synthetic card"
        let changed = try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id,
            images: [image(0, png), image(1, try MediaCardRenderer.export(set.cards[1], width: set.width, height: set.height, screenshot: nil))])
        #expect(changed.added == 1 && changed.files[0] == file && changed.files[1] != all.files[1])
        try await session.removeAssetLibraryFile(accountId: account.id, appId: app, id: file.id)
        let restored = try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(0, png)])
        #expect(restored.added == 1 && restored.files[0].id != file.id && restored.files[0].hash == file.hash)
        await #expect(throws: (any Error).self) { try await session.stageCreatedLibraryImages(accountId: account.id, appId: app, setId: set.id, images: [image(0, png), image(0, png)]) }

        await #expect(throws: MediaCardFailure.stale) { try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 1) }
        try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 2)
        #expect(try await session.mediaCardSets(accountId: account.id, appId: app).isEmpty)
        await #expect(throws: MediaCardFailure.missing) { try await session.deleteMediaCardSet(accountId: account.id, appId: app, id: set.id, expected: 2) }
    }
}

@Suite struct MediaCardImagesTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func thumbnailsUseSmallDecodesAndFullSizeScreenshotsStayWithinTheBudget() async throws {
        let bytes = try AssetLibraryTests().png(width: 1290, height: 2796)
        let small = try await ScreenshotRenderer.loadAsync(bytes, maximumEdge: MediaCardImages.thumbnailEdge)
        #expect(max(small.width, small.height) == MediaCardImages.thumbnailEdge && abs(Double(small.width) / Double(small.height) - 1290.0 / 2796.0) < 0.01)
        let full = try await ScreenshotRenderer.loadAsync(bytes)
        var images = MediaCardImages()
        images.keepThumbnail(small, "a")
        #expect(images.thumbnail("a")?.width == small.width && images.full("a") == nil)
        // A card with only a full-size decode still draws its thumbnail from it.
        images.keepFull(full, "b")
        #expect(images.thumbnail("b")?.width == 1290)
        // Each full decode is about 14 MB, so at most six fit; the selected one, used last, is kept.
        for key in ["c", "d", "e", "f", "g"] { images.keepFull(full, key) }
        images.touch("b")
        images.keepFull(full, "h")
        #expect(images.fullCount <= MediaCardImages.fullBudget.count && images.fullBytes <= MediaCardImages.fullBudget.bytes)
        #expect(images.full("b") != nil && images.full("c") == nil && images.full("h") != nil)
        images.removeAll()
        #expect(images.fullCount == 0 && images.thumbnail("a") == nil)
    }

    @Test func aScreenshotLargerThanTheWholeBudgetStillReachesThePreview() async throws {
        // 6,000 × 5,000 px decodes to 120,000,000 bytes, more than the 96 MiB budget but within the 40-megapixel limit.
        let bytes = try AssetLibraryTests().png(width: 6_000, height: 5_000)
        let full = try await ScreenshotRenderer.loadAsync(bytes)
        var images = MediaCardImages()
        images.keepFull(full, "large")
        #expect(images.full("large") == nil && images.fullBytes == 0 && images.fullCount == 0)
        var card = MediaCardSet(name: "Synthetic set", target: MediaCards.defaultTarget).cards[0]
        card.screenshot = .init(hash: String(repeating: "a", count: 64), name: "large.png", width: 6_000, height: 5_000)
        // A cache miss leaves the decoded result with the render operation, rather than looking it up again.
        let shown = try await MediaCardRenderer.previewAsync(card, width: MediaCards.defaultTarget.width, height: MediaCards.defaultTarget.height, screenshot: full, font: nil)
        let missing = try await MediaCardRenderer.previewAsync(card, width: MediaCards.defaultTarget.width, height: MediaCards.defaultTarget.height, screenshot: nil)
        #expect(shown.image.dataProvider?.data as Data? != missing.image.dataProvider?.data as Data?)
        #expect(images.fullBytes == 0)
    }

    @Test func evictionDuringAnotherExportDoesNotRemoveThePreviewsOwnedScreenshot() async throws {
        let full = try await ScreenshotRenderer.loadAsync(try AssetLibraryTests().png(width: 1290, height: 2796))
        var images = MediaCardImages()
        images.keepFull(full, "selected")
        let selected = try #require(images.full("selected"))
        var card = try MediaCardsTests().card(.textAbove, shot: (1290, 2796))
        for index in 0..<MediaCardImages.fullBudget.count { images.keepFull(full, "export-\(index)") }
        #expect(images.full("selected") == nil && images.fullBytes <= MediaCardImages.fullBudget.bytes)
        let target = MediaCards.defaultTarget
        let exported = try await MediaCardRenderer.exportAsync(card, width: target.width, height: target.height, screenshot: full)
        let preview = try await MediaCardRenderer.previewAsync(card, width: target.width, height: target.height, screenshot: selected)
        let expected = try await MediaCardRenderer.previewAsync(card, width: target.width, height: target.height, screenshot: full)
        #expect(preview.image.dataProvider?.data as Data? == expected.image.dataProvider?.data as Data?)
        let exportedImage = try await ScreenshotRenderer.loadAsync(exported)
        #expect(exportedImage.width == target.width && exportedImage.height == target.height)
        card.screenshot = nil
        let placeholder = try await MediaCardRenderer.previewAsync(card, width: target.width, height: target.height, screenshot: nil)
        #expect(preview.image.dataProvider?.data as Data? != placeholder.image.dataProvider?.data as Data?)
    }
}
