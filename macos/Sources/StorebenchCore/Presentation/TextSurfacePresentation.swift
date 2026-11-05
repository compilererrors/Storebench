import Foundation

/// Reading and editing use the same bounded text track; resizing never changes the text.
public enum TextSurfacePresentation {
    public static let minimum = 70.0, maximum = 800.0
    public static func height(_ value: Double) -> Double {
        value.isFinite ? min(maximum, max(minimum, value)) : 140
    }
    public static func initialHeight(field: String) -> Double {
        switch field.lowercased() {
        case "description", "privacypolicytext": 180
        case "whatsnew", "promotionaltext", "notes": 112
        case "keywords": 76
        default: 70
        }
    }
    public static func resized(start: Double, translation: Double) -> Double {
        translation.isFinite ? height(start + translation) : height(start)
    }
}

/// Fit and explicit zoom share one finite coordinate system, including very narrow windows.
public enum MediaViewport {
    public static func scale(imageWidth: Double, imageHeight: Double, width: Double, height: Double, zoom: Double?) -> Double {
        guard [imageWidth, imageHeight, width, height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return 1 }
        if let zoom, zoom.isFinite { return min(8, max(0.05, zoom)) }
        return min(1, width / imageWidth, height / imageHeight)
    }
}
