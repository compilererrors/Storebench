import SwiftUI

enum StorebenchStatusTone: Equatable {
    case success, caution, problem
    var color: Color { StorebenchTheme.color(self == .success ? "color-success" : self == .caution ? "color-warning" : "color-danger") }
    var icon: String { self == .success ? "check" : "warning" }
}

/// A status always has words and a registered symbol as well as its colour.
struct StorebenchCheckLabel: View {
    let text: String, tone: StorebenchStatusTone
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StorebenchIcon(name: tone.icon, size: 14).accessibilityHidden(true)
            Text(text).font(.sbCallout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(tone.color).accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
