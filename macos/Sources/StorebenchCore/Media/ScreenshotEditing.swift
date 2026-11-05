import Foundation

public struct ScreenshotCard: Equatable, Sendable {
    public enum Placement: String, CaseIterable, Sendable { case above, below }
    public var enabled = false, frame = 5.0, color = "#edf2fb"
    public var title = "", titleColor = "#17243b", body = "", bodyColor = "#526582"
    public var placement: Placement = .above
    public init() {}
}

public struct ScreenshotEdits: Equatable, Sendable {
    public var width: Int, height: Int
    public var rotation = 0, flip = false, zoom = 1.0, x = 0.5, y = 0.5, quality = 0.92
    public var card = ScreenshotCard()
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum ScreenshotEditFailure: Error, Equatable {
    case bytes, image, pixels, targets, edits, text, render, exportSize
    public var message: String {
        switch self {
        case .bytes: "Choose a PNG or JPEG up to 80 MB for editing."
        case .image: "This image could not be decoded. Choose a valid PNG or JPEG."
        case .pixels: "For editing, use an image up to 12,000 px per side and 40 megapixels."
        case .targets: "No screenshot sizes are available for this platform."
        case .edits: "Choose valid screenshot dimensions, colors and editing values."
        case .text: "The card text does not fit. Shorten the title or body text, remove extra line breaks, or reduce the frame width."
        case .render: "The edited image could not be created. Your original is kept."
        case .exportSize: "The edited image is still over 20 MB. Choose a smaller size or lower JPEG quality."
        }
    }
}

/// Pure crop and card policy, shared by the native preview and JPEG renderer.
public enum ScreenshotEditing {
    public static let maximumSourceBytes = 80_000_000, maximumSide = 12_000, maximumPixels = 40_000_000
    public struct Target: Identifiable, Equatable, Sendable {
        public let type: String, width: Int, height: Int
        public init(type: String, width: Int, height: Int) { self.type = type; self.width = width; self.height = height }
        public var id: String { "\(type):\(width)x\(height)" }
        public var label: String { "\(StoreLocales.displayTypeName(type)) · \(width) × \(height) px" }
    }
    public struct Info: Equatable, Sendable { public let width: Int, height: Int; public let transparent: Bool }
    public struct Area: Equatable, Sendable {
        public let left: Double, top: Double, width: Double, height: Double
        public init(left: Double, top: Double, width: Double, height: Double) { self.left = left; self.top = top; self.width = width; self.height = height }
    }
    public struct CardLayout: Equatable, Sendable { public let image: Area, caption: Area?; public let margin: Double }
    public struct Geometry: Equatable, Sendable { public let scale: Double, drawnWidth: Double, drawnHeight: Double, left: Double, top: Double }
    public struct TextLine: Equatable, Sendable { public let text: String, size: Double, bold: Bool, color: String, top: Double }

    public static func targets(platform: String, displayType: String? = nil) -> [Target] {
        let types = StoreLocales.screenshotTypes(platform: platform)
        return types.filter { displayType == nil || $0 == displayType }.flatMap { type in
            (ScreenshotSpecs.sizes[type] ?? []).flatMap { width, height -> [Target] in
                let target = Target(type: type, width: width, height: height)
                return ScreenshotSpecs.rotationAllowed(type) ? [target, Target(type: type, width: height, height: width)] : [target]
            }
        }
    }

    public static func initial(platform: String, width: Int, height: Int, displayType: String? = nil) throws -> ScreenshotEdits {
        guard width > 0, height > 0 else { throw ScreenshotEditFailure.pixels }
        let ratio = Double(width) / Double(height), area = Double(width) * Double(height)
        func score(_ target: Target) -> Double {
            abs(log((Double(target.width) / Double(target.height)) / ratio)) * 20
                + (target.width > width || target.height > height ? 10 : 0)
                + abs(log(Double(target.width) * Double(target.height) / area))
        }
        guard let target = targets(platform: platform, displayType: displayType).enumerated().min(by: {
            let first = score($0.element), second = score($1.element)
            return first == second ? $0.offset < $1.offset : first < second
        })?.element else { throw ScreenshotEditFailure.targets }
        return ScreenshotEdits(width: target.width, height: target.height)
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
    public static func cardLayout(width: Int, height: Int, card: ScreenshotCard = .init()) -> CardLayout {
        let width = Double(width), height = Double(height), short = min(width, height)
        guard card.enabled else { return CardLayout(image: Area(left: 0, top: 0, width: width, height: height), caption: nil, margin: 0) }
        let margin = (short * clamp(card.frame, 0, 20) / 100).rounded(.toNearestOrAwayFromZero)
        let innerWidth = width - margin * 2, innerHeight = height - margin * 2
        let hasText = !TextSemantics.trim(card.title).isEmpty || !TextSemantics.trim(card.body).isEmpty
        let captionHeight = hasText ? min(innerHeight * 0.4, short * 0.32) : 0, gap = hasText ? short * 0.025 : 0
        let inset = max(margin, short * 0.04)
        return CardLayout(image: Area(left: margin, top: margin + (card.placement == .above ? captionHeight + gap : 0), width: innerWidth, height: innerHeight - captionHeight - gap),
                          caption: hasText ? Area(left: inset, top: card.placement == .above ? margin : height - margin - captionHeight, width: width - inset * 2, height: captionHeight) : nil, margin: margin)
    }

    public static func geometry(width: Int, height: Int, edits: ScreenshotEdits) -> Geometry {
        let rotated = edits.rotation % 180 != 0, sourceWidth = Double(rotated ? height : width), sourceHeight = Double(rotated ? width : height)
        let area = cardLayout(width: edits.width, height: edits.height, card: edits.card).image
        let scale = max(area.width / sourceWidth, area.height / sourceHeight) * clamp(edits.zoom, 1, 4)
        let drawnWidth = sourceWidth * scale, drawnHeight = sourceHeight * scale
        return Geometry(scale: scale, drawnWidth: drawnWidth, drawnHeight: drawnHeight,
                        left: (area.width - drawnWidth) * clamp(edits.x, 0, 1), top: (area.height - drawnHeight) * clamp(edits.y, 0, 1))
    }

    /// Dragging is relative to the image area; a gesture starting on a caption never moves the image.
    public static func drag(width: Int, height: Int, edits: ScreenshotEdits, startX: Double, startY: Double, deltaX: Double, deltaY: Double) -> ScreenshotEdits {
        let area = cardLayout(width: edits.width, height: edits.height, card: edits.card).image
        guard startX >= area.left, startX <= area.left + area.width, startY >= area.top, startY <= area.top + area.height else { return edits }
        let geometry = geometry(width: width, height: height, edits: edits)
        var changed = edits
        changed.x = geometry.drawnWidth > area.width ? clamp(edits.x - deltaX / (geometry.drawnWidth - area.width), 0, 1) : 0.5
        changed.y = geometry.drawnHeight > area.height ? clamp(edits.y - deltaY / (geometry.drawnHeight - area.height), 0, 1) : 0.5
        return changed
    }

    public static func wrapText(_ text: String, width: Double, measure: (String) -> Double) -> [String] {
        let normalized = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).flatMap { paragraph in
            var lines: [String] = [], line = ""
            for scalars in paragraph.unicodeScalars.split(whereSeparator: { TextSemantics.whitespace.contains($0) }) {
                let word = String(String.UnicodeScalarView(scalars))
                let candidate = line.isEmpty ? word : "\(line) \(word)"
                if measure(candidate) <= width { line = candidate; continue }
                if !line.isEmpty { lines.append(line); line = "" }
                for character in word {
                    if !line.isEmpty, measure(line + String(character)) > width { lines.append(line); line = "" }
                    line.append(character)
                }
            }
            lines.append(line); return lines
        }
    }

    public static func cardText(card: ScreenshotCard, area: Area, shortSide: Double, measure: (String, Double, Bool) -> Double) throws -> [TextLine] {
        let title = TextSemantics.trim(card.title), body = TextSemantics.trim(card.body)
        let gap = !title.isEmpty && !body.isEmpty ? shortSide * 0.018 : 0
        for step in 0...8 {
            let factor = 1 - Double(step) * 0.05, titleSize = shortSide * 0.05 * factor, bodySize = shortSide * 0.028 * factor
            let titles = title.isEmpty ? [] : wrapText(title, width: area.width) { measure($0, titleSize, true) }
            let bodies = body.isEmpty ? [] : wrapText(body, width: area.width) { measure($0, bodySize, false) }
            let total = Double(titles.count) * titleSize * 1.35 + Double(bodies.count) * bodySize * 1.4 + gap
            guard total <= area.height, titles.allSatisfy({ measure($0, titleSize, true) <= area.width }), bodies.allSatisfy({ measure($0, bodySize, false) <= area.width }) else { continue }
            var top = area.top + (area.height - total) / 2, lines: [TextLine] = []
            for text in titles { lines.append(TextLine(text: text, size: titleSize, bold: true, color: card.titleColor, top: top)); top += titleSize * 1.35 }
            top += gap
            for text in bodies { lines.append(TextLine(text: text, size: bodySize, bold: false, color: card.bodyColor, top: top)); top += bodySize * 1.4 }
            return lines
        }
        throw ScreenshotEditFailure.text
    }

    /// Only a bounded header is copied before ImageIO is allowed to decode any pixels.
    public static func inspect(_ data: Data) throws -> Info {
        guard !data.isEmpty, data.count <= maximumSourceBytes else { throw ScreenshotEditFailure.bytes }
        let bytes = [UInt8](data.prefix(1_048_576))
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        var width = 0, height = 0, transparent = false
        if bytes.count >= 33, Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], u32(8) == 13, Array(bytes[12..<16]) == Array("IHDR".utf8) {
            width = u32(16); height = u32(20); transparent = bytes[25] == 4 || bytes[25] == 6
            var offset = 8
            while offset + 12 <= bytes.count {
                let length = u32(offset), type = Array(bytes[offset + 4..<offset + 8])
                if type == Array("tRNS".utf8) { transparent = true }
                if type == Array("IDAT".utf8) || length > bytes.count - offset - 12 { break }
                offset += length + 12
            }
        } else if bytes.count >= 4, bytes[0] == 255, bytes[1] == 216 {
            var offset = 2
            while offset + 4 < bytes.count, bytes[offset] == 255 {
                while offset < bytes.count, bytes[offset] == 255 { offset += 1 }
                guard offset < bytes.count else { break }
                let marker = bytes[offset]; offset += 1
                if marker == 217 || marker == 218 { break }
                if marker == 1 || (208...215).contains(marker) { continue }
                guard offset + 2 <= bytes.count else { break }
                let length = u16(offset)
                guard length >= 2, length <= bytes.count - offset else { break }
                if [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].contains(marker), length >= 7 { height = u16(offset + 3); width = u16(offset + 5); break }
                offset += length
            }
        }
        guard width > 0, height > 0 else { throw ScreenshotEditFailure.image }
        guard width <= maximumSide, height <= maximumSide, width * height <= maximumPixels else { throw ScreenshotEditFailure.pixels }
        return Info(width: width, height: height, transparent: transparent)
    }

    static func valid(_ edits: ScreenshotEdits) -> Bool {
        let colors = [edits.card.color, edits.card.titleColor, edits.card.bodyColor]
        return edits.width > 0 && edits.height > 0 && edits.width <= maximumSide && edits.height <= maximumSide && edits.width * edits.height <= maximumPixels
            && [0, 90, 180, 270].contains(edits.rotation) && [edits.zoom, edits.x, edits.y, edits.quality, edits.card.frame].allSatisfy(\.isFinite)
            && (0.5...1).contains(edits.quality) && (0...20).contains(edits.card.frame)
            && edits.card.title.utf16.count <= 120 && edits.card.body.utf16.count <= 500
            && colors.allSatisfy { $0.utf8.count == 7 && $0.first == "#" && $0.dropFirst().allSatisfy(\.isHexDigit) }
    }
}
