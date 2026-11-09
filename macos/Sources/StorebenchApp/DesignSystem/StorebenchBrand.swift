import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchAppIcon: View {
    var size: CGFloat = 64
    private static let image = NSImage(data: StorebenchDesign.shared.brandIcon)

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct StorebenchBrand: View {
    var onDark = false
    private static let icon = NSImage(data: StorebenchDesign.shared.brandIcon)
    private static let mark = NSImage(data: StorebenchDesign.shared.brandMark)
    private static let wordmark = NSImage(data: StorebenchDesign.shared.wordmark)

    var body: some View {
        HStack(spacing: 10) {
            if let image = onDark ? Self.icon : Self.mark {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 34, height: 32)
            }
            if onDark {
                Text("Storebench").font(.system(size: 21).bold()).tracking(-0.7).foregroundStyle(.white)
            } else if let image = Self.wordmark {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 160, height: 24)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Storebench")
    }
}
