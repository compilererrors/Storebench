import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StorebenchCore

/// Generated quadrants with no device capture, file metadata or external image assets.
func syntheticEditableScreenshot(width: Int = 16, height: Int = 8, transparent: Bool = false, orientation: Int = 1, jpeg: Bool = false) throws -> Data {
    var bytes: [UInt8] = []
    for y in 0..<height { for x in 0..<width {
        if transparent { bytes += [0, 0, 0, 0] }
        else { bytes += y < height / 2 ? (x < width / 2 ? [240, 10, 10, 255] : [10, 240, 10, 255]) : (x < width / 2 ? [10, 10, 240, 255] : [240, 240, 10, 255]) }
    } }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB)), provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let output = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(output, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination)); return output as Data
}

@Suite(.serialized) struct ScreenshotEditingTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func largerAssetThumbnailsRemainBoundedAndKeepPortraitAndLandscapeProportions() async throws {
        for (width, height) in [(1280, 640), (640, 1280)] {
            let bytes = try syntheticEditableScreenshot(width: width, height: height)
            let original = bytes
            let ordinary = try await ScreenshotRenderer.thumbnailAsync(bytes)
            let card = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: 640)
            let oversized = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: Int.max)
            #expect(max(ordinary.image.width, ordinary.image.height) == 240)
            #expect(max(card.image.width, card.image.height) == 640)
            #expect(max(oversized.image.width, oversized.image.height) == 1024)
            #expect(Double(card.image.width) / Double(card.image.height) == Double(width) / Double(height))
            #expect(bytes == original)
        }
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func expectColor(_ image: CGImage, x: Int, y: Int, rgb: [UInt8], tolerance: Int = 3) throws {
        let bytes = try pixels(image), offset = (y * image.width + x) * 4
        for channel in 0..<3 { #expect(abs(Int(bytes[offset + channel]) - Int(rgb[channel])) <= tolerance) }
        #expect(bytes[offset + 3] == 255)
    }

    @Test func recommendationsAndAllTargetsMatchExistingScreenshotRules() throws {
        for (width, height, expectedWidth, expectedHeight) in [(1440, 900, 1440, 900), (4000, 2500, 2880, 1800), (1600, 1000, 1440, 900), (800, 500, 1280, 800)] {
            let edits = try ScreenshotEditing.initial(platform: "MAC_OS", width: width, height: height)
            #expect(edits.width == expectedWidth && edits.height == expectedHeight)
        }
        for platform in ["MAC_OS", "IOS", "TV_OS", "VISION_OS"] {
            for target in ScreenshotEditing.targets(platform: platform) {
                #expect(ScreenshotSpecs.type(platform: platform, width: target.width, height: target.height) != nil)
                #expect(ScreenshotSpecs.fits(target.type, width: target.width, height: target.height))
            }
        }
        #expect(ScreenshotEditing.targets(platform: "MAC_OS").count == 4)
        #expect(throws: ScreenshotEditFailure.targets) { try ScreenshotEditing.initial(platform: "UNKNOWN", width: 1000, height: 1000) }
        let fixed = try ScreenshotEditing.initial(platform: "IOS", width: 2000, height: 1000, displayType: "APP_IPHONE_67")
        #expect(ScreenshotSpecs.fits("APP_IPHONE_67", width: fixed.width, height: fixed.height))
        #expect(ScreenshotEditing.targets(platform: "MAC_OS", displayType: "APP_IPHONE_67").isEmpty)
    }

    @Test func cropGeometryNeverStretchesOrLeavesUnfilledEdges() {
        for (width, height) in [(1280, 800), (1242, 2208), (312, 390)] {
            for rotation in [0, 90, 180, 270] { for zoom in [0.1, 1, 2, 4] { for position in [-1.0, 0, 0.5, 1, 2] { for frame in [0.0, 5, 20] {
                var edits = ScreenshotEdits(width: width, height: height); edits.rotation = rotation; edits.zoom = zoom; edits.x = position; edits.y = position
                edits.card.enabled = true; edits.card.frame = frame; edits.card.title = "Synthetic title"
                let area = ScreenshotEditing.cardLayout(width: width, height: height, card: edits.card).image
                let geometry = ScreenshotEditing.geometry(width: 2000, height: 1000, edits: edits)
                #expect(geometry.drawnWidth + 0.000001 >= area.width && geometry.drawnHeight + 0.000001 >= area.height)
                #expect(geometry.left <= 0 && geometry.top <= 0)
                #expect(geometry.left + geometry.drawnWidth + 0.000001 >= area.width && geometry.top + geometry.drawnHeight + 0.000001 >= area.height)
                #expect(abs(geometry.drawnWidth / geometry.drawnHeight - (rotation % 180 == 0 ? 2 : 0.5)) < 0.000001)
            } } } }
        }
    }

    @Test func cardGeometryAndUnicodeWrappingKeepTextInItsAssignedArea() throws {
        #expect(ScreenshotEditing.wrapText("One two\r\nThree\n\nFour", width: 7, measure: { Double($0.count) }) == ["One two", "Three", "", "Four"])
        #expect(ScreenshotEditing.wrapText("longword", width: 3, measure: { Double($0.count) }) == ["lon", "gwo", "rd"])
        #expect(ScreenshotEditing.wrapText("\u{feff}One\u{00a0}two\u{feff}", width: 7, measure: { Double($0.count) }) == ["One two"])
        #expect(ScreenshotEditing.wrapText("One\u{200b}two", width: 7, measure: { Double($0.count) }) == ["One\u{200b}two"])
        #expect(ScreenshotEditing.wrapText(" \u{301}A\u{202f}B\r", width: 7, measure: { Double($0.count) }) == ["\u{301}A B", ""])
        #expect(ScreenshotEditing.wrapText("", width: 7, measure: { Double($0.count) }) == [""])
        #expect(ScreenshotEditing.wrapText("e\u{301}e\u{301}👩‍🔬👩‍🔬", width: 1, measure: { Double($0.count) }) == ["e\u{301}", "e\u{301}", "👩‍🔬", "👩‍🔬"])
        for placement in ScreenshotCard.Placement.allCases { for frame in [0.0, 5, 20] {
            var card = ScreenshotCard(); card.enabled = true; card.frame = frame; card.placement = placement
            card.title = "Synthetic title"; card.body = "Synthetic text with an explicit\nsecond line."; card.titleColor = "#ffcc00"; card.bodyColor = "#ff66cc"
            let layout = ScreenshotEditing.cardLayout(width: 1440, height: 900, card: card), area = try #require(layout.caption)
            #expect(layout.image.left >= 0 && layout.image.top >= 0 && layout.image.left + layout.image.width <= 1440 && layout.image.top + layout.image.height <= 900)
            #expect(placement == .above ? area.top + area.height < layout.image.top : layout.image.top + layout.image.height < area.top)
            let lines = try ScreenshotEditing.cardText(card: card, area: area, shortSide: 900, measure: ScreenshotRenderer.textWidth)
            #expect(lines.filter(\.bold).map(\.text).joined(separator: " ") == card.title)
            #expect(lines.filter { !$0.bold }.map(\.text).joined(separator: " ") == card.body.replacingOccurrences(of: "\n", with: " "))
            for line in lines {
                #expect(line.top >= area.top && line.top + line.size <= area.top + area.height)
                #expect(line.color == (line.bold ? card.titleColor : card.bodyColor))
            }
            card.body = String(repeating: "line\n", count: 80)
            #expect(throws: ScreenshotEditFailure.text) { try ScreenshotEditing.cardText(card: card, area: area, shortSide: 900, measure: ScreenshotRenderer.textWidth) }
        } }
    }

    @Test func dragUsesTheImageTrackAndClampsItsExactStartingPosition() {
        var edits = ScreenshotEdits(width: 1280, height: 800); edits.card.enabled = true; edits.card.title = "Synthetic caption"; edits.zoom = 2
        let area = ScreenshotEditing.cardLayout(width: edits.width, height: edits.height, card: edits.card).image
        #expect(ScreenshotEditing.drag(width: 2000, height: 1000, edits: edits, startX: 0, startY: 0, deltaX: 900, deltaY: 900) == edits)
        let moved = ScreenshotEditing.drag(width: 2000, height: 1000, edits: edits, startX: area.left + 10, startY: area.top + 10, deltaX: 100000, deltaY: -100000)
        #expect(moved.x == 0 && moved.y == 1 && moved.card == edits.card)
    }

    @Test func inspectionBoundsPixelsBeforeDecodingAndAllowsCorrectionOfTransparency() throws {
        let png = try syntheticEditableScreenshot(transparent: true)
        #expect(try ScreenshotEditing.inspect(png).transparent)
        #expect(throws: ScreenshotFailure.self) { try ScreenshotSpecs.validate(png) }
        #expect(try ScreenshotEditing.inspect(png + Data(repeating: 0, count: 20_000_001)).width == 16)
        #expect(throws: ScreenshotEditFailure.bytes) { try ScreenshotEditing.inspect(Data()) }
        #expect(throws: ScreenshotEditFailure.image) { try ScreenshotEditing.inspect(Data("Synthetic invalid image".utf8)) }
        #expect(throws: ScreenshotEditFailure.pixels) { try ScreenshotEditing.inspect(syntheticPNG(width: 12001, height: 1)) }
        #expect(throws: ScreenshotEditFailure.pixels) { try ScreenshotEditing.inspect(syntheticPNG(width: 7000, height: 7000)) }
        #expect(throws: ScreenshotEditFailure.image) { try ScreenshotRenderer.load(syntheticPNG(width: 100, height: 100)) }
        #expect(SelectedFiles.Purpose.screenshotEditing.limits.fileBytes == 80_000_000 && SelectedFiles.Purpose.screenshotEditing.limits.totalBytes == 800_000_000)
        #expect(SelectedFiles.Purpose.screenshots.limits.fileBytes == 20_000_000 && SelectedFiles.Purpose.screenshots.limits.totalBytes == 50_000_000)
    }

    @Test func renderedPixelsVerifyCropRotationAndHorizontalMirroring() throws {
        let source = try ScreenshotRenderer.load(syntheticEditableScreenshot(width: 16, height: 16))
        var edits = ScreenshotEdits(width: 16, height: 16)
        try expectColor(ScreenshotRenderer.render(source, edits: edits), x: 2, y: 2, rgb: [240, 10, 10])
        edits.flip = true
        try expectColor(ScreenshotRenderer.render(source, edits: edits), x: 2, y: 2, rgb: [10, 240, 10])
        edits.flip = false; edits.rotation = 90
        try expectColor(ScreenshotRenderer.render(source, edits: edits), x: 2, y: 2, rgb: [10, 10, 240])
        edits.rotation = 180
        try expectColor(ScreenshotRenderer.render(source, edits: edits), x: 2, y: 2, rgb: [240, 240, 10])
        edits.rotation = 270
        try expectColor(ScreenshotRenderer.render(source, edits: edits), x: 2, y: 2, rgb: [10, 240, 10])
        let wide = try ScreenshotRenderer.load(syntheticEditableScreenshot())
        edits = ScreenshotEdits(width: 8, height: 8); edits.x = 0
        try expectColor(ScreenshotRenderer.render(wide, edits: edits), x: 6, y: 1, rgb: [240, 10, 10])
        edits.x = 1
        try expectColor(ScreenshotRenderer.render(wide, edits: edits), x: 1, y: 1, rgb: [10, 240, 10])
    }

    @Test func transparentInputExportsWhiteAndCardsDrawIndependentTextColors() throws {
        let source = try ScreenshotRenderer.load(syntheticEditableScreenshot(transparent: true))
        var edits = ScreenshotEdits(width: 1280, height: 800); edits.card.enabled = true; edits.card.frame = 10; edits.card.color = "#123456"
        edits.card.title = "Synthetic Title"; edits.card.body = "Synthetic caption"; edits.card.titleColor = "#ffcc00"; edits.card.bodyColor = "#ff66cc"
        let image = try ScreenshotRenderer.render(source, edits: edits)
        try expectColor(image, x: 5, y: 5, rgb: [18, 52, 86])
        try expectColor(image, x: 640, y: 600, rgb: [255, 255, 255])
        let bytes = try pixels(image), caption = try #require(ScreenshotEditing.cardLayout(width: 1280, height: 800, card: edits.card).caption)
        let textColors: [[UInt8]] = [[255, 204, 0], [255, 102, 204]]
        for rgb in textColors {
            let contains = (Int(caption.top)..<Int(caption.top + caption.height)).contains { y in
                (Int(caption.left)..<Int(caption.left + caption.width)).contains { x in
                    let at = (y * 1280 + x) * 4; return (0..<3).allSatisfy { abs(Int(bytes[at + $0]) - Int(rgb[$0])) <= 3 }
                }
            }
            #expect(contains)
        }
        let jpeg = try ScreenshotRenderer.export(source, edits: edits), output = try ScreenshotSpecs.validate(jpeg)
        #expect(output.contentType == "image/jpeg" && output.width == 1280 && output.height == 800 && jpeg.count < ScreenshotSpecs.maximumBytes)
        let preview = try ScreenshotRenderer.render(source, edits: edits, preview: true)
        #expect(preview.width == 1200 && preview.height == 750)
        try expectColor(preview, x: 4, y: 4, rgb: [18, 52, 86])
    }

    @Test func exifOrientationIsNormalizedBeforeEditingAndExport() throws {
        for orientation in 1...8 {
            let data = try syntheticEditableScreenshot(width: 32, height: 16, orientation: orientation, jpeg: true)
            let source = try ScreenshotRenderer.load(data)
            #expect(source.width == (orientation >= 5 ? 16 : 32) && source.height == (orientation >= 5 ? 32 : 16))
            let output = try ScreenshotRenderer.export(source, edits: ScreenshotEdits(width: source.width, height: source.height))
            #expect(try ScreenshotSpecs.validate(output).width == source.width)
        }
    }

    @Test func selectionsKeepOriginalsAdjustmentsAndOrderUntilAtomicLocalSave() async throws {
        let original = try syntheticEditableScreenshot(width: 32, height: 64, transparent: true)
        let first = ScreenshotSelection.Item(name: "synthetic-original.png", data: original), second = ScreenshotSelection.Item(name: "synthetic-second.png", data: original)
        var selection = ScreenshotSelection(items: [first, second])
        #expect(selection.problem(platform: "IOS") != nil)
        var edits = ScreenshotEdits(width: 1290, height: 2796); edits.zoom = 1.1
        let encoded = try await ScreenshotRenderer.exportAsync(ScreenshotRenderer.load(original), edits: edits)
        try selection.apply(first.id, data: encoded, edits: edits)
        #expect(selection.items[0].original == original && selection.items[0].edits == edits && selection.items[0].name == "synthetic-original-edited.jpg")
        let revision = selection.revision
        #expect(throws: ScreenshotEditFailure.image) { try selection.apply(first.id, data: original, edits: edits) }
        #expect(selection.revision == revision && selection.items[0].data == encoded)
        selection.move(first.id, by: 1); #expect(selection.items.map(\.id) == [second.id, first.id])
        selection.remove(second.id); #expect(selection.problem(platform: "IOS", displayType: "APP_IPHONE_67") == nil)
        #expect(selection.problem(platform: "IOS", displayType: "APP_IPAD_97") != nil)
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let count = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", localizationId: "version-locale-1", setId: "set-1", files: selection.items.map { ($0.name, $0.data) })
        #expect(count == 1)
        let saved = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", setId: "set-1")
        #expect(try await session.mediaBytes(try #require(saved.items.last?.sha256)) == encoded)
        selection.restore(first.id); #expect(selection.items[0].data == original && selection.items[0].edits == nil && selection.items[0].name == first.originalName)
    }

    @Test func invalidEditsAndCancelledWorkCannotYieldAnExport() async throws {
        let bytes = try syntheticEditableScreenshot(), source = try ScreenshotRenderer.load(bytes)
        var edits = ScreenshotEdits(width: 1280, height: 800); edits.zoom = .nan
        #expect(throws: ScreenshotEditFailure.edits) { try ScreenshotRenderer.render(source, edits: edits) }
        edits.zoom = 1; edits.card.color = "invalid"
        #expect(throws: ScreenshotEditFailure.edits) { try ScreenshotRenderer.export(source, edits: edits) }
        edits.card.color = "#edf2fb"; edits.card.title = String(repeating: "🧪", count: 61)
        #expect(throws: ScreenshotEditFailure.edits) { try ScreenshotRenderer.render(source, edits: edits) }
        let owned = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenshotRenderer.exportAsync(source, edits: ScreenshotEdits(width: 1280, height: 800))
        }
        await #expect(throws: CancellationError.self) { try await owned.value }
        #expect(try await ScreenshotRenderer.loadAsync(bytes).width == 16)
    }

    @Test func dragReorderKeepsOriginalsAndRejectsForeignOrRemovedIds() {
        let first = ScreenshotSelection.Item(name: "synthetic-one.png", data: Data([1])), second = ScreenshotSelection.Item(name: "synthetic-two.png", data: Data([2])), third = ScreenshotSelection.Item(name: "synthetic-three.png", data: Data([3]))
        var selection = ScreenshotSelection(items: [first, second, third])
        let moved = selection.move(first.id, to: third.id)
        #expect(moved && selection.items.map(\.id) == [second.id, third.id, first.id])
        #expect(selection.items.last?.original == first.original)
        let revision = selection.revision, rejected = selection.move("synthetic-foreign", to: second.id)
        #expect(!rejected && selection.revision == revision)
        selection.remove(third.id)
        let removed = selection.move(first.id, to: third.id)
        #expect(!removed && selection.items.map(\.id) == [second.id, first.id])
    }
}
