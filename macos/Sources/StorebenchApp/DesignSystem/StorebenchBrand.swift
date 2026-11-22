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

/// The short start screen while saved data opens: the Storebench graphic, the bench mark above the wordmark, with a
/// spinner and one line naming the step below it, centred on the window's sunken surface. In Dark Mode the app icon and a
/// white name stand in for the dark graphic. The line keeps one fixed track, so moving from opening to unlocking never moves the graphic.
struct StorebenchLaunchScreen: View {
    let message: String
    @Environment(\.colorScheme) private var scheme
    private static let mark = NSImage(data: StorebenchDesign.shared.brandMark)
    private static let wordmark = NSImage(data: StorebenchDesign.shared.wordmark)
    var body: some View {
        VStack(spacing: StorebenchTheme.space(5)) {
            VStack(spacing: StorebenchTheme.space(3)) {
                if scheme == .dark {
                    StorebenchAppIcon(size: 120)
                    Text("Storebench").font(.system(size: 34).bold()).tracking(-1).foregroundStyle(.white)
                } else {
                    if let mark = Self.mark { Image(nsImage: mark).resizable().interpolation(.high).scaledToFit().frame(width: 154, height: 120) }
                    if let wordmark = Self.wordmark { Image(nsImage: wordmark).resizable().interpolation(.high).scaledToFit().frame(width: 232, height: 34) }
                }
            }.frame(height: 176)
            HStack(spacing: StorebenchTheme.space(2)) {
                StorebenchSpinner()
                Text(message).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).lineLimit(1)
            }.frame(height: StorebenchProgressStyle.lineHeight(StorebenchTheme.design.number("font-size-body")))
        }
        .padding(StorebenchTheme.space(6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StorebenchTheme.color("color-surface-sunken"))
        .accessibilityElement(children: .ignore).accessibilityLabel("Storebench, " + message)
    }
}
