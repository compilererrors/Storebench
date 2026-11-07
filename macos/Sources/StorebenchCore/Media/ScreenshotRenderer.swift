import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable decoded pixels. No UI, file, credential or networking APIs are used by the renderer.
public struct DecodedScreenshot: @unchecked Sendable {
    public let image: CGImage
    /// Dimensions verified in the source header, retained when preview pixels are downsampled.
    public let sourceWidth, sourceHeight: Int
    public var width: Int { image.width }
    public var height: Int { image.height }
    fileprivate init(image: CGImage, sourceWidth: Int, sourceHeight: Int) {
        self.image = image; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
    }
}

public struct ScreenshotPreview: @unchecked Sendable { public let image: CGImage }

public enum ScreenshotRenderer {
    public static func load(_ data: Data) throws -> DecodedScreenshot {
        try decode(data, maximumEdge: nil)
    }
    private static func decode(_ data: Data, maximumEdge: Int?) throws -> DecodedScreenshot {
        try Task.checkCancellation()
        let inspected = try ScreenshotEditing.inspect(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let kind = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier].contains(kind),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == inspected.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == inspected.height else { throw ScreenshotEditFailure.image }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximumEdge ?? max(inspected.width, inspected.height), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0, image.width <= ScreenshotEditing.maximumSide, image.height <= ScreenshotEditing.maximumSide,
              image.width * image.height <= ScreenshotEditing.maximumPixels,
              maximumEdge != nil || image.width * image.height == inspected.width * inspected.height else { throw ScreenshotEditFailure.image }
        try Task.checkCancellation()
        return DecodedScreenshot(image: image, sourceWidth: inspected.width, sourceHeight: inspected.height)
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let owned = Task.detached { try work() }
        return try await withTaskCancellationHandler(operation: { let value = try await owned.value; try Task.checkCancellation(); return value }, onCancel: { owned.cancel() })
    }
    public static func loadAsync(_ data: Data) async throws -> DecodedScreenshot { try await run { try load(data) } }
    /// A smaller decode whose longest side is at most `maximumEdge`, for drawing thumbnails. It keeps the original proportions.
    public static func loadAsync(_ data: Data, maximumEdge: Int) async throws -> DecodedScreenshot {
        try await run { try decode(data, maximumEdge: max(1, min(ScreenshotEditing.maximumSide, maximumEdge))) }
    }
    public static func thumbnailAsync(_ data: Data, maximumEdge: Int = 240) async throws -> ScreenshotPreview {
        try await run { ScreenshotPreview(image: try decode(data, maximumEdge: max(1, min(1024, maximumEdge))).image) }
    }
    public static func previewAsync(_ source: DecodedScreenshot, edits: ScreenshotEdits) async throws -> ScreenshotPreview {
        try await run { ScreenshotPreview(image: try render(source, edits: edits, preview: true)) }
    }
    public static func exportAsync(_ source: DecodedScreenshot, edits: ScreenshotEdits, png: Bool = false) async throws -> Data { try await run { try export(source, edits: edits, png: png) } }

    static func color(_ hex: String) throws -> CGColor {
        guard hex.utf8.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: space, components: [CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255, 1]) else { throw ScreenshotEditFailure.edits }
        return color
    }
    static func font(_ size: Double, _ bold: Bool) -> CTFont { CTFontCreateWithName((bold ? "Arial-BoldMT" : "ArialMT") as CFString, size, nil) }
    static func line(_ text: String, size: Double, bold: Bool, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold)]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    public static func textWidth(_ text: String, size: Double, bold: Bool) -> Double { CTLineGetTypographicBounds(line(text, size: size, bold: bold), nil, nil, nil) }

    /// Preview uses the same coordinates and caption measurements as full-size output.
    public static func render(_ source: DecodedScreenshot, edits: ScreenshotEdits, preview: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        guard ScreenshotEditing.valid(edits) else { throw ScreenshotEditFailure.edits }
        let ratio = preview ? min(1, 1200 / Double(edits.width), 1200 / Double(edits.height)) : 1
        let width = max(1, Int((Double(edits.width) * ratio).rounded())), height = max(1, Int((Double(edits.height) * ratio).rounded()))
        let layout = ScreenshotEditing.cardLayout(width: edits.width, height: edits.height, card: edits.card)
        let lines = try layout.caption.map { try ScreenshotEditing.cardText(card: edits.card, area: $0, shortSide: Double(min(edits.width, edits.height)), measure: textWidth) } ?? []
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ScreenshotEditFailure.render }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(width) / CGFloat(edits.width), y: -CGFloat(height) / CGFloat(edits.height))
        context.setFillColor(try color(edits.card.enabled ? edits.card.color : "#ffffff"))
        context.fill(CGRect(x: 0, y: 0, width: edits.width, height: edits.height))
        let geometry = ScreenshotEditing.geometry(width: source.width, height: source.height, edits: edits), area = layout.image
        context.saveGState()
        context.clip(to: CGRect(x: area.left, y: area.top, width: area.width, height: area.height))
        context.setFillColor(try color("#ffffff")); context.fill(CGRect(x: area.left, y: area.top, width: area.width, height: area.height))
        context.translateBy(x: area.left + geometry.left + geometry.drawnWidth / 2, y: area.top + geometry.top + geometry.drawnHeight / 2)
        context.scaleBy(x: edits.flip ? -1 : 1, y: 1); context.rotate(by: Double(edits.rotation) * .pi / 180)
        context.scaleBy(x: geometry.scale, y: -geometry.scale)
        let sourceWidth = CGFloat(source.width), sourceHeight = CGFloat(source.height)
        let sourceRect = CGRect(x: -sourceWidth / 2, y: -sourceHeight / 2, width: sourceWidth, height: sourceHeight)
        context.draw(source.image, in: sourceRect)
        context.restoreGState()
        if let caption = layout.caption {
            context.saveGState(); context.clip(to: CGRect(x: caption.left, y: caption.top, width: caption.width, height: caption.height))
            for text in lines {
                try Task.checkCancellation()
                let drawn = line(text.text, size: text.size, bold: text.bold, color: try color(text.color))
                context.saveGState()
                context.translateBy(x: caption.left + caption.width / 2, y: text.top + CTFontGetAscent(font(text.size, text.bold)))
                context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
                context.textPosition = CGPoint(x: -CTLineGetTypographicBounds(drawn, nil, nil, nil) / 2, y: 0)
                CTLineDraw(drawn, context); context.restoreGState()
            }
            context.restoreGState()
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw ScreenshotEditFailure.render }
        return image
    }

    /// Apple rejects screenshots with an alpha channel. Such a PNG is drawn on white and saved again without one;
    /// returns nil when the image has no alpha channel.
    public static func opaque(_ data: Data) throws -> Data? {
        guard (try? ScreenshotEditing.inspect(data))?.transparent == true else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ScreenshotEditFailure.image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(bounds); context.draw(image, in: bounds)
        let output = NSMutableData()
        guard let flat = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ScreenshotEditFailure.render }
        CGImageDestinationAddImage(destination, flat, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw ScreenshotEditFailure.render }
        return output as Data
    }

    public static func export(_ source: DecodedScreenshot, edits: ScreenshotEdits, png: Bool = false) throws -> Data {
        let image = try render(source, edits: edits), output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { throw ScreenshotEditFailure.render }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: edits.quality, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotEditFailure.render }
        try Task.checkCancellation()
        guard output.length > 0, output.length <= ScreenshotSpecs.maximumBytes else { throw ScreenshotEditFailure.exportSize }
        let data = output as Data, result = try ScreenshotSpecs.validate(data)
        guard result.width == edits.width, result.height == edits.height, result.contentType == (png ? "image/png" : "image/jpeg") else { throw ScreenshotEditFailure.render }
        return data
    }
}
