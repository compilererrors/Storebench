import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The look of one card. New cards copy the current card's style, and Apply Style to All copies it to the whole set.
public struct MediaCardStyle: Equatable, Sendable, Codable {
    public enum Fill: String, CaseIterable, Sendable, Codable {
        case solid, gradient
        public var label: String { self == .solid ? "Solid Color" : "Gradient" }
    }
    /// The Mac's system font and its rounded, serif and monospaced designs, an installed font family, or a font file you added.
    public enum Typeface: String, CaseIterable, Sendable, Codable {
        case standard, rounded, serif, monospaced, installed, file
        public var label: String {
            switch self { case .standard: "System"; case .rounded: "Rounded"; case .serif: "Serif"; case .monospaced: "Monospaced"; case .installed: "Installed Font"; case .file: "Font File" }
        }
    }
    /// A font file saved in this Mac's encrypted media store, referenced by its content hash.
    public struct FontFile: Equatable, Sendable, Codable {
        public let hash: String, name: String, family: String
        public init(hash: String, name: String, family: String) { self.hash = hash; self.name = name; self.family = family }
    }
    public enum Alignment: String, CaseIterable, Sendable, Codable {
        case leading, center, trailing
        public var label: String { switch self { case .leading: "Left"; case .center: "Center"; case .trailing: "Right" } }
    }
    public var fill: Fill = .gradient
    public var color = "#2f4fd8", secondColor = "#7b3fe4", angle = 160.0
    public var titleColor = "#ffffff", subtitleColor = "#e8ecff", bodyColor = "#d9e0ff"
    public var typeface: Typeface = .standard, alignment: Alignment = .center
    /// The installed font family used by Installed Font.
    public var fontFamily: String? = nil
    /// The font file used by Font File.
    public var fontFile: FontFile? = nil
    /// Text size factor; long text is reduced automatically until it fits.
    public var textSize = 1.0
    /// Share of the inner height reserved for text.
    public var textSpace = 0.26
    /// Outer margin as a percentage of the card's short side.
    public var margin = 6.0
    /// Screenshot width as a share of the inner width.
    public var screenshotWidth = 0.82
    /// Corner radius and border as percentages of the screenshot width.
    public var cornerRadius = 7.0, borderWidth = 0.0
    public var borderColor = "#111827"
    public var shadow = true
    public init() {}
}

public struct MediaCard: Equatable, Sendable, Codable, Identifiable {
    public enum Layout: String, CaseIterable, Sendable, Codable {
        case textAbove, textBelow, bleedBottom, bleedTop, focus, textOnly
        public var label: String {
            switch self {
            case .textAbove: "Text Above"
            case .textBelow: "Text Below"
            case .bleedBottom: "Cropped at Bottom"
            case .bleedTop: "Cropped at Top"
            case .focus: "Zoomed Detail"
            case .textOnly: "Text Only"
            }
        }
        public var usesScreenshot: Bool { self != .textOnly }
        var textOnTop: Bool { ![.textBelow, .bleedTop].contains(self) }
    }
    /// A screenshot saved in this Mac's encrypted media store, referenced by its content hash.
    public struct Screenshot: Equatable, Sendable, Codable {
        public let hash: String, name: String
        public let width: Int, height: Int
        public init(hash: String, name: String, width: Int, height: Int) { self.hash = hash; self.name = name; self.width = width; self.height = height }
    }
    public var id: String
    public var layout: Layout = .textAbove
    public var title = "", subtitle = "", body = ""
    public var screenshot: Screenshot?
    /// Crop inside the screenshot frame, with the same meaning as the screenshot editor's zoom and position.
    public var zoom = 1.0, x = 0.5, y = 0.5
    public var style = MediaCardStyle()
    public init(id: String = UUID().uuidString.lowercased(), style: MediaCardStyle = .init()) { self.id = id; self.style = style }
}

public struct MediaCardSet: Equatable, Sendable, Codable, Identifiable {
    public var id: String, name: String
    public var displayType: String, width: Int, height: Int
    public var cards: [MediaCard]
    /// The App Store language the card text is written in; nil until it is chosen.
    public var language: String? = nil
    /// The cards as they were when all of them were last saved to Asset Library; nil before the first save.
    public var savedCards: [MediaCard]? = nil
    public init(id: String = UUID().uuidString.lowercased(), name: String, target: ScreenshotEditing.Target) {
        self.id = id; self.name = name; displayType = target.type; width = target.width; height = target.height
        cards = [MediaCard()]
    }
}

public enum MediaCardFailure: Error, Equatable {
    case invalid, text, screenshot, render, exportSize, stale, missing, full, translationLength, translation, font
    public var message: String {
        switch self {
        case .invalid: "Choose valid card sizes, colors, text and values."
        case .text: "The text does not fit. Shorten it, reduce the text size or give the text more space."
        case .screenshot: "Choose a screenshot for this card, or choose Text Only."
        case .render: "The card could not be created. Your saved card set is unchanged."
        case .exportSize: "The card is over 20 MB as a PNG. Choose a smaller size."
        case .stale: "This card set was changed in another window. Reload it before editing again."
        case .missing: "This card set is no longer saved on this Mac."
        case .full: "A card set holds up to 10 cards, the App Store maximum per display size."
        case .translationLength: "A translated text is longer than a card allows. Shorten that text in this card set and translate again."
        case .translation: "The translation could not be finished. This card set is unchanged; try again."
        case .font: "The card's font file could not be read. Choose the font file again, or choose another typeface."
        }
    }
}

/// Pure card layout and text fitting, shared by previews and full-size export.
public enum MediaCards {
    public static let maximumCards = ScreenshotSpecs.maximum
    public static let titleLimit = 80, subtitleLimit = 120, bodyLimit = 300, nameLimit = 80
    public typealias Area = ScreenshotEditing.Area
    public enum Weight: Sendable, Equatable { case title, subtitle, body }
    public struct Line: Equatable, Sendable { public let text: String, size: Double, weight: Weight, color: String, left: Double, top: Double }
    public struct Placement: Equatable, Sendable {
        public let text: Area?, screen: Area?
        public let radius: Double, border: Double
        /// True when the screenshot is as tall as its space allows, so a larger screenshot width cannot make it bigger.
        public let limited: Bool
    }

    /// Every size the App Store accepts for screenshots, in Apple's display size order.
    public static var targets: [ScreenshotEditing.Target] {
        var seen: Set<String> = []
        return ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].flatMap { ScreenshotEditing.targets(platform: $0) }.filter { seen.insert($0.id).inserted }
    }
    public static var defaultTarget: ScreenshotEditing.Target {
        targets.first { $0.type == "APP_IPHONE_67" && $0.width == 1320 && $0.height == 2868 } ?? targets[0]
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
    /// Text without surrounding whitespace, as names and card text are compared and saved.
    public static func trimmed(_ text: String) -> String { TextSemantics.trim(text) }
    static func hasText(_ card: MediaCard) -> Bool { [card.title, card.subtitle, card.body].contains { !TextSemantics.trim($0).isEmpty } }

    /// Where text and screenshot go. Without a screenshot the frame keeps the card's own proportions as a placeholder.
    /// The text area is kept whether or not text is written yet, so the screenshot does not move while typing. A screenshot that
    /// cannot fill its space keeps text and screenshot together in the middle of the card; a cropped screenshot always runs past its
    /// card edge, and the text is centered in the space left beside it.
    public static func placement(_ card: MediaCard, width: Int, height: Int) -> Placement {
        let style = card.style, w = Double(width), h = Double(height), short = min(w, h)
        let margin = (short * clamp(style.margin, 0, 15) / 100).rounded()
        let innerWidth = w - margin * 2, innerHeight = h - margin * 2
        guard card.layout.usesScreenshot else { return Placement(text: Area(left: margin, top: margin, width: innerWidth, height: innerHeight), screen: nil, radius: 0, border: 0, limited: false) }
        let space = innerHeight * clamp(style.textSpace, 0.12, 0.5), gap = short * 0.03
        let aspect = card.screenshot.map { Double($0.width) / Double($0.height) } ?? w / h
        var frameWidth = innerWidth * clamp(style.screenshotWidth, 0.4, 1), frameHeight = frameWidth / aspect
        let regionHeight = innerHeight - space - gap
        var textTop = card.layout.textOnTop ? margin : h - margin - space, textHeight = space, top: Double, limited = false
        switch card.layout {
        case .textAbove, .textBelow:
            if frameHeight > regionHeight { frameHeight = regionHeight; frameWidth = frameHeight * aspect; limited = true }
            let offset = (regionHeight - frameHeight) / 2
            if card.layout == .textAbove { textTop = margin + offset; top = textTop + space + gap }
            else { top = margin + offset; textTop = top + frameHeight + gap }
        case .bleedBottom:
            // At least a tenth of the screenshot runs past the bottom edge.
            top = max(margin + space + gap, h - frameHeight * 0.9)
            textHeight = top - gap - margin
        case .bleedTop:
            let bottom = min(h - margin - space - gap, frameHeight * 0.9)
            top = bottom - frameHeight
            textTop = bottom + gap; textHeight = h - margin - textTop
        case .focus: frameHeight = regionHeight; top = margin + space + gap
        case .textOnly: top = 0
        }
        let text = Area(left: margin, top: textTop, width: innerWidth, height: textHeight)
        let screen = Area(left: (w - frameWidth) / 2, top: top, width: frameWidth, height: frameHeight)
        return Placement(text: text, screen: screen, radius: frameWidth * clamp(style.cornerRadius, 0, 20) / 100, border: frameWidth * clamp(style.borderWidth, 0, 6) / 100, limited: limited)
    }

    /// The image area inside the border, and where the cropped screenshot is drawn relative to the card.
    public static func image(_ card: MediaCard, in screen: Area, border: Double) -> (clip: Area, drawn: Area) {
        let clip = Area(left: screen.left + border, top: screen.top + border, width: max(1, screen.width - border * 2), height: max(1, screen.height - border * 2))
        guard let shot = card.screenshot else { return (clip, clip) }
        let scale = max(clip.width / Double(shot.width), clip.height / Double(shot.height)) * clamp(card.zoom, 1, 4)
        let drawnWidth = Double(shot.width) * scale, drawnHeight = Double(shot.height) * scale
        return (clip, Area(left: clip.left + (clip.width - drawnWidth) * clamp(card.x, 0, 1), top: clip.top + (clip.height - drawnHeight) * clamp(card.y, 0, 1), width: drawnWidth, height: drawnHeight))
    }

    /// Dragging moves the crop inside the screenshot frame; a drag that starts elsewhere changes nothing.
    public static func drag(_ card: MediaCard, width: Int, height: Int, startX: Double, startY: Double, deltaX: Double, deltaY: Double) -> MediaCard {
        let placement = placement(card, width: width, height: height)
        guard card.screenshot != nil, let screen = placement.screen, startX >= screen.left, startX <= screen.left + screen.width, startY >= screen.top, startY <= screen.top + screen.height else { return card }
        let (clip, drawn) = image(card, in: screen, border: placement.border)
        var changed = card
        changed.x = drawn.width > clip.width + 0.5 ? clamp(card.x - deltaX / (drawn.width - clip.width), 0, 1) : 0.5
        changed.y = drawn.height > clip.height + 0.5 ? clamp(card.y - deltaY / (drawn.height - clip.height), 0, 1) : 0.5
        return changed
    }

    /// Text shrinks in 5 % steps down to half its size. Text that still does not fit is an error, never silently clipped.
    public static func lines(_ card: MediaCard, area: Area, shortSide: Double, measure: (String, Double, Weight) -> Double) throws -> [Line] {
        try fitted(card, area: area, shortSide: shortSide, measure: measure).lines
    }
    /// The fitted lines and the share of the chosen text size they are drawn at: 1 when the text fits as chosen.
    public static func fitted(_ card: MediaCard, area: Area, shortSide: Double, measure: (String, Double, Weight) -> Double) throws -> (lines: [Line], share: Double) {
        let style = card.style, factor = clamp(style.textSize, 0.6, 1.5) * (card.layout == .textOnly ? 1.25 : 1)
        struct Part { let text: String, weight: Weight, color: String, size: Double, leading: Double }
        let parts = [Part(text: card.title, weight: .title, color: style.titleColor, size: 0.072, leading: 1.18),
                     Part(text: card.subtitle, weight: .subtitle, color: style.subtitleColor, size: 0.044, leading: 1.28),
                     Part(text: card.body, weight: .body, color: style.bodyColor, size: 0.034, leading: 1.4)]
            .map { Part(text: TextSemantics.trim($0.text), weight: $0.weight, color: $0.color, size: $0.size, leading: $0.leading) }.filter { !$0.text.isEmpty }
        for step in 0...10 {
            let scale = factor * (1 - Double(step) * 0.05)
            var blocks: [(lines: [String], weight: Weight, color: String, size: Double, leading: Double)] = []
            for part in parts {
                let size = shortSide * part.size * scale
                blocks.append((ScreenshotEditing.wrapText(part.text, width: area.width) { measure($0, size, part.weight) }, part.weight, part.color, size, part.leading))
            }
            let gap = shortSide * 0.02 * scale
            let total = blocks.reduce(0) { $0 + Double($1.lines.count) * $1.size * $1.leading } + Double(max(0, blocks.count - 1)) * gap
            guard total <= area.height, blocks.allSatisfy({ block in block.lines.allSatisfy { measure($0, block.size, block.weight) <= area.width + 0.5 } }) else { continue }
            var top = area.top + (area.height - total) / 2, result: [Line] = []
            for block in blocks {
                for text in block.lines {
                    let width = measure(text, block.size, block.weight)
                    let left = switch style.alignment { case .leading: area.left; case .center: area.left + (area.width - width) / 2; case .trailing: area.left + area.width - width }
                    result.append(Line(text: text, size: block.size, weight: block.weight, color: block.color, left: left, top: top)); top += block.size * block.leading
                }
                top += gap
            }
            return (result, 1 - Double(step) * 0.05)
        }
        throw MediaCardFailure.text
    }

    static func color(_ text: String) -> Bool { text.utf8.count == 7 && text.first == "#" && text.dropFirst().allSatisfy(\.isHexDigit) }
    static func validID(_ text: String) -> Bool { text.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil }
    static func validText(_ text: String, _ limit: Int) -> Bool {
        text.utf16.count <= limit && !text.unicodeScalars.contains { ($0.value < 32 && $0 != "\n") || $0.value == 127 }
    }

    public static func validate(_ card: MediaCard) throws {
        let style = card.style
        let ranges: [(Double, ClosedRange<Double>)] = [(card.zoom, 1...4), (card.x, 0...1), (card.y, 0...1), (style.angle, 0...360), (style.textSize, 0.6...1.5), (style.textSpace, 0.12...0.5),
                                                       (style.margin, 0...15), (style.screenshotWidth, 0.4...1), (style.cornerRadius, 0...20), (style.borderWidth, 0...6)]
        guard validID(card.id), ranges.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              [style.color, style.secondColor, style.titleColor, style.subtitleColor, style.bodyColor, style.borderColor].allSatisfy(color),
              validText(card.title, titleLimit), validText(card.subtitle, subtitleLimit), validText(card.body, bodyLimit) else { throw MediaCardFailure.invalid }
        switch style.typeface {
        case .installed: guard let family = style.fontFamily, !TextSemantics.trim(family).isEmpty, validText(family, 200), !family.contains("\n") else { throw MediaCardFailure.invalid }
        case .file:
            guard let file = style.fontFile, file.hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, !file.name.isEmpty, validText(file.name, 200), !file.name.contains("\n"),
                  validText(file.family, 200), !file.family.contains("\n") else { throw MediaCardFailure.invalid }
        default: break
        }
        if let shot = card.screenshot {
            guard shot.hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, !shot.name.isEmpty, validText(shot.name, 200), !shot.name.contains("\n"),
                  shot.width > 0, shot.height > 0, shot.width <= ScreenshotEditing.maximumSide, shot.height <= ScreenshotEditing.maximumSide else { throw MediaCardFailure.invalid }
        }
    }

    public static func validate(_ set: MediaCardSet) throws {
        let name = TextSemantics.trim(set.name)
        guard validID(set.id), !name.isEmpty, validText(set.name, nameLimit), !set.name.contains("\n"), set.language.map(StoreLocales.codes.contains) ?? true,
              targets.contains(where: { $0.type == set.displayType && $0.width == set.width && $0.height == set.height }) else { throw MediaCardFailure.invalid }
        guard set.cards.count <= maximumCards else { throw MediaCardFailure.full }
        guard Set(set.cards.map(\.id)).count == set.cards.count else { throw MediaCardFailure.invalid }
        for card in set.cards { try validate(card) }
    }

    /// The file name for an exported card: the set name and the card's position, without path characters.
    public static func fileName(set: MediaCardSet, index: Int) -> String {
        let base = String(TextSemantics.trim(set.name).unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return "\(base.isEmpty ? "card" : String(base.prefix(60)))-\(String(format: "%02d", index + 1)).png"
    }
}

/// Draws cards with Core Graphics. No UI, file, credential or networking APIs are used.
public enum MediaCardRenderer {
    static func system(_ size: Double, bold: Bool, design: String?) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        guard let design else { return base }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: ["NSCTFontUIFontDesignTrait": design]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return bold ? CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font : font
    }
    /// A font from a font file's data, or nil when the data holds no font. Titles use a bold face when the file has one.
    public static func fileFont(_ data: Data, size: Double, bold: Bool) -> CTFont? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let first = descriptors.first else { return nil }
        let isBold = { (descriptor: CTFontDescriptor) -> Bool in
            ((CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontSymbolicTrait] as? UInt32).map { $0 & CTFontSymbolicTraits.traitBold.rawValue != 0 } ?? false
        }
        let chosen = bold ? descriptors.first(where: isBold) ?? first : descriptors.first { !isBold($0) } ?? first
        return CTFontCreateWithFontDescriptor(chosen, size, nil)
    }
    /// The family name a font file shows, or nil when the data holds no font.
    public static func fontFamily(_ data: Data) -> String? { fileFont(data, size: 12, bold: false).map { CTFontCopyFamilyName($0) as String } }
    /// The installed font families, sorted by name.
    public static var installedFamilies: [String] {
        ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func font(_ style: MediaCardStyle, _ weight: MediaCards.Weight, _ size: Double, file: Data?) -> CTFont {
        let bold = weight == .title
        switch style.typeface {
        case .standard: return system(size, bold: bold, design: nil)
        case .rounded: return system(size, bold: bold, design: "NSCTFontUIFontDesignRounded")
        case .serif: return system(size, bold: bold, design: "NSCTFontUIFontDesignSerif")
        case .monospaced: return system(size, bold: bold, design: "NSCTFontUIFontDesignMonospaced")
        case .installed:
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: style.fontFamily ?? ""] as CFDictionary), size, nil)
            return bold ? CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font : font
        case .file: return file.flatMap { fileFont($0, size: size, bold: bold) } ?? system(size, bold: bold, design: nil)
        }
    }
    static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    /// Line breaking measures many prefixes at a few sizes, so one measurer keeps each font and each measured width it has made.
    public static func measure(_ style: MediaCardStyle, file: Data? = nil) -> (String, Double, MediaCards.Weight) -> Double {
        final class Cache { var fonts: [String: CTFont] = [:], widths: [String: Double] = [:] }
        let cache = Cache()
        return { text, size, weight in
            let fontKey = "\(weight)\u{0}\(size)", key = fontKey + "\u{0}" + text
            if let width = cache.widths[key] { return width }
            let made = cache.fonts[fontKey] ?? MediaCardRenderer.font(style, weight, size, file: file)
            cache.fonts[fontKey] = made
            let width = CTLineGetTypographicBounds(line(text, font: made), nil, nil, nil)
            cache.widths[key] = width
            return width
        }
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let owned = Task.detached { try work() }
        return try await withTaskCancellationHandler(operation: { let value = try await owned.value; try Task.checkCancellation(); return value }, onCancel: { owned.cancel() })
    }
    /// A preview fits within `edge` pixels on its long side, with the same layout as the full-size card.
    public static func previewAsync(_ card: MediaCard, width: Int, height: Int, screenshot: DecodedScreenshot?, font: Data? = nil, edge: Double = 1200) async throws -> ScreenshotPreview {
        try await run { ScreenshotPreview(image: try render(card, width: width, height: height, screenshot: screenshot, font: font, edge: edge)) }
    }
    public static func exportAsync(_ card: MediaCard, width: Int, height: Int, screenshot: DecodedScreenshot?, font: Data? = nil) async throws -> Data {
        try await run { try export(card, width: width, height: height, screenshot: screenshot, font: font) }
    }
    /// The share of the chosen text size the card's text is drawn at; below 1 when Space for text makes it smaller. Nil when it does not fit.
    public static func textShare(_ card: MediaCard, width: Int, height: Int, font: Data? = nil) -> Double? {
        guard let area = MediaCards.placement(card, width: width, height: height).text else { return 1 }
        return try? MediaCards.fitted(card, area: area, shortSide: Double(min(width, height)), measure: measure(card.style, file: font)).share
    }

    static func path(_ area: MediaCards.Area, radius: Double) -> CGPath {
        let rect = CGRect(x: area.left, y: area.top, width: area.width, height: area.height), corner = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    /// Without `edge` the card is drawn at its exact pixel size. A missing screenshot draws a placeholder in previews only.
    public static func render(_ card: MediaCard, width: Int, height: Int, screenshot: DecodedScreenshot?, font: Data? = nil, edge: Double? = nil) throws -> CGImage {
        try Task.checkCancellation()
        try MediaCards.validate(card)
        guard width > 0, height > 0, width <= ScreenshotEditing.maximumSide, height <= ScreenshotEditing.maximumSide, width * height <= ScreenshotEditing.maximumPixels else { throw MediaCardFailure.invalid }
        if card.layout.usesScreenshot, edge == nil, screenshot == nil || card.screenshot == nil { throw MediaCardFailure.screenshot }
        if card.style.typeface == .file, font.flatMap(fontFamily) == nil { throw MediaCardFailure.font }
        if let screenshot, let shot = card.screenshot, screenshot.width != shot.width || screenshot.height != shot.height { throw MediaCardFailure.screenshot }
        let ratio = edge.map { min(1, $0 / Double(max(width, height))) } ?? 1
        let pixelWidth = max(1, Int((Double(width) * ratio).rounded())), pixelHeight = max(1, Int((Double(height) * ratio).rounded()))
        let placement = MediaCards.placement(card, width: width, height: height), short = Double(min(width, height)), style = card.style
        let lines = try placement.text.map { try MediaCards.lines(card, area: $0, shortSide: short, measure: measure(style, file: font)) } ?? []
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MediaCardFailure.render }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(pixelHeight)); context.scaleBy(x: CGFloat(pixelWidth) / CGFloat(width), y: -CGFloat(pixelHeight) / CGFloat(height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let first = try ScreenshotRenderer.color(style.color)
        if style.fill == .gradient, let gradient = CGGradient(colorsSpace: space, colors: [first, try ScreenshotRenderer.color(style.secondColor)] as CFArray, locations: [0, 1]) {
            // 0° points up and 90° to the right, as in CSS, in this top-left coordinate space.
            let radians = style.angle * .pi / 180, dx = sin(radians), dy = -cos(radians)
            let length = abs(Double(width) * dx) + abs(Double(height) * dy), center = CGPoint(x: bounds.midX, y: bounds.midY)
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2), end: CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else { context.setFillColor(first); context.fill(bounds) }
        if let screen = placement.screen {
            let outer = path(screen, radius: placement.radius)
            if style.shadow {
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: short * 0.012), blur: short * 0.045, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32))
                context.addPath(outer); context.setFillColor(try ScreenshotRenderer.color(style.borderColor)); context.fillPath()
                context.restoreGState()
            }
            if placement.border > 0 { context.addPath(outer); context.setFillColor(try ScreenshotRenderer.color(style.borderColor)); context.fillPath() }
            let (clip, drawn) = MediaCards.image(card, in: screen, border: placement.border)
            context.saveGState()
            context.addPath(path(clip, radius: max(0, placement.radius - placement.border))); context.clip()
            if let screenshot {
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: clip.left, y: clip.top, width: clip.width, height: clip.height))
                context.translateBy(x: drawn.left, y: drawn.top + drawn.height); context.scaleBy(x: 1, y: -1)
                context.draw(screenshot.image, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
            } else {
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)); context.fill(CGRect(x: clip.left, y: clip.top, width: clip.width, height: clip.height))
            }
            context.restoreGState()
        }
        for text in lines {
            try Task.checkCancellation()
            let typeface = self.font(style, text.weight, text.size, file: font)
            let drawn = line(text.text, font: typeface, color: try ScreenshotRenderer.color(text.color))
            context.saveGState()
            context.translateBy(x: text.left, y: text.top + CTFontGetAscent(typeface)); context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.textPosition = .zero
            CTLineDraw(drawn, context); context.restoreGState()
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw MediaCardFailure.render }
        return image
    }

    /// An opaque PNG at the exact App Store size, checked again after encoding.
    public static func export(_ card: MediaCard, width: Int, height: Int, screenshot: DecodedScreenshot?, font: Data? = nil) throws -> Data {
        let image = try render(card, width: width, height: height, screenshot: screenshot, font: font), output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw MediaCardFailure.render }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaCardFailure.render }
        try Task.checkCancellation()
        guard output.length > 0, output.length <= ScreenshotSpecs.maximumBytes else { throw MediaCardFailure.exportSize }
        let data = output as Data
        guard let result = try? ScreenshotSpecs.validate(data), result.width == width, result.height == height, result.contentType == "image/png",
              (try? ScreenshotEditing.inspect(data))?.transparent == false else { throw MediaCardFailure.render }
        return data
    }
}

extension MediaCardSet {
    /// Adds a card after `afterId` with that card's style and type, so a set keeps one look.
    @discardableResult public mutating func addCard(after afterId: String?) throws -> MediaCard {
        guard cards.count < MediaCards.maximumCards else { throw MediaCardFailure.full }
        let index = cards.firstIndex { $0.id == afterId }
        var card = MediaCard(style: index.map { cards[$0].style } ?? cards.last?.style ?? .init())
        card.layout = index.map { cards[$0].layout } ?? .textAbove
        cards.insert(card, at: index.map { $0 + 1 } ?? cards.endIndex); return card
    }
    @discardableResult public mutating func duplicateCard(_ id: String) throws -> MediaCard {
        guard cards.count < MediaCards.maximumCards else { throw MediaCardFailure.full }
        guard let index = cards.firstIndex(where: { $0.id == id }) else { throw MediaCardFailure.missing }
        var card = cards[index]; card.id = UUID().uuidString.lowercased()
        cards.insert(card, at: index + 1); return card
    }
    /// Removes a card and returns the id to select next. The last card cannot be removed.
    public mutating func removeCard(_ id: String) -> String? {
        guard cards.count > 1, let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        cards.remove(at: index); return cards[min(index, cards.count - 1)].id
    }
    public mutating func moveCard(_ id: String, by offset: Int) {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards.indices.contains(index + offset) else { return }
        cards.swapAt(index, index + offset)
    }
    public mutating func applyStyle(from id: String) {
        guard let style = cards.first(where: { $0.id == id })?.style else { return }
        for index in cards.indices { cards[index].style = style }
    }
}

/// Undo and redo for one card set. Quick repeated changes to the same control, such as a slider drag or typing,
/// become one step so Undo returns to the value before the gesture.
public struct MediaCardHistory: Sendable, Equatable {
    public private(set) var set: MediaCardSet
    private var undoStack: [MediaCardSet] = [], redoStack: [MediaCardSet] = []
    private var lastKey: String?, lastTime = -Double.infinity
    public static let limit = 100, coalescing = 1.0
    public init(_ set: MediaCardSet) { self.set = set }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func change(_ key: String, now: Double, _ body: (inout MediaCardSet) throws -> Void) rethrows {
        var next = set
        try body(&next)
        guard next != set else { return }
        if key != lastKey || now - lastTime > Self.coalescing || undoStack.isEmpty {
            undoStack.append(set); if undoStack.count > Self.limit { undoStack.removeFirst() }
        }
        set = next; redoStack = []; lastKey = key; lastTime = now
    }
    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(set); set = previous; lastKey = nil
    }
    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(set); set = next; lastKey = nil
    }
}

/// Background suggestions taken from a screenshot's own colors: its most common saturated tones, distinct from each other.
public enum MediaCardColors {
    public static func suggestions(_ screenshot: DecodedScreenshot, limit: Int = 5) -> [String] {
        let width = 32, height = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(screenshot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var counts: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            let high = max(red, green, blue), low = min(red, green, blue)
            // Near-white, near-black and grey pixels are usually interface chrome, not the app's color.
            guard high > 40, low < 235, high - low > 48 else { continue }
            let key = (red >> 5) << 6 | (green >> 5) << 3 | blue >> 5
            let entry = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (entry.count + 1, entry.red + red, entry.green + green, entry.blue + blue)
        }
        var chosen: [(Int, Int, Int)] = []
        for entry in counts.values.sorted(by: { $0.count == $1.count ? $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue : $0.count > $1.count }) where entry.count >= 3 {
            let color = (entry.red / entry.count, entry.green / entry.count, entry.blue / entry.count)
            guard chosen.allSatisfy({ abs($0.0 - color.0) + abs($0.1 - color.1) + abs($0.2 - color.2) > 90 }) else { continue }
            chosen.append(color)
            if chosen.count == limit { break }
        }
        return chosen.map { String(format: "#%02x%02x%02x", $0.0, $0.1, $0.2) }
    }
}
