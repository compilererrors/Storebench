import AppKit
import StorebenchCore
import SwiftUI

/// Draws registered 24-unit SVG geometry, with a round stroke or a filled closed shape.
struct StorebenchIcon: View {
    let name: String
    var size: CGFloat = 18
    var filled = false
    private var paths: [Path] {
        guard let primitives = StorebenchDesign.shared.icons[name] else { preconditionFailure("Shared icon is missing.") }
        return primitives.map { primitive in
            guard let path = try? primitive.path() else { preconditionFailure("Shared icon is invalid.") }
            return Path(path)
        }
    }
    var body: some View {
        ZStack {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                let shape = path.applying(CGAffineTransform(scaleX: size / 24, y: size / 24))
                if filled { shape.fill() }
                else { shape.stroke(style: StrokeStyle(lineWidth: 1.8 * size / 24, lineCap: .round, lineJoin: .round)) }
            }
        }.frame(width: size, height: size).fixedSize().accessibilityHidden(true)
    }
    /// `inset` adds transparent room on every side, so round stroke caps and toolbar press effects never meet the image edge.
    @MainActor static func templateImage(name: String, size: CGFloat, inset: CGFloat = 0) -> NSImage {
        guard let primitives = StorebenchDesign.shared.icons[name] else { preconditionFailure("Shared icon is missing.") }
        let paths = primitives.map { primitive in
            guard let path = try? primitive.path() else { preconditionFailure("Shared icon is invalid.") }
            return path
        }
        let image = NSImage(size: NSSize(width: size + 2 * inset, height: size + 2 * inset), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            let drawing = bounds.insetBy(dx: bounds.width * inset / (size + 2 * inset), dy: bounds.height * inset / (size + 2 * inset))
            context.translateBy(x: drawing.minX, y: drawing.maxY)
            context.scaleBy(x: drawing.width / 24, y: -drawing.height / 24)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.8); context.setLineCap(.round); context.setLineJoin(.round)
            for path in paths { context.addPath(path); context.strokePath() }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct StorebenchLabel: View {
    let title: String, icon: String
    var size: CGFloat = 18
    var busy = false
    init(_ title: String, icon: String, size: CGFloat = 18, busy: Bool = false) { self.title = title; self.icon = icon; self.size = size; self.busy = busy }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            StorebenchActivityIcon(name: busy ? "refresh" : icon, size: size, active: busy).frame(width: size, height: size)
            Text(title).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
            .accessibilityElement(children: .combine).accessibilityValue(busy ? "Working" : "")
    }
}

/// Animation follows presentation state; it never starts, retries or cancels a job.
struct StorebenchActivityIcon: View {
    var name = "refresh"
    var size: CGFloat = 18
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                StorebenchIcon(name: name, size: size)
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
            }.frame(width: size, height: size).accessibilityHidden(true)
        } else { StorebenchIcon(name: name, size: size) }
    }
}
