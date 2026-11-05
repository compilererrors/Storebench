import SwiftUI

/// Equal label, status and comparison tracks keep report feedback inside its assigned card.
struct SavedDeltaCard: View {
    let title, value, detail, beforeLabel, afterLabel, explanation: String
    let before, after: Double?
    var tone: Color = StorebenchTheme.ink
    private var maximum: Double { max(1, max(before ?? 0, after ?? 0)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.sbCaption.bold()).lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Text(value).font(.sbHeadline).foregroundStyle(tone).lineLimit(2).frame(minHeight: 42, alignment: .topLeading)
            Text(detail).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
            side(before, label: beforeLabel, color: StorebenchTheme.muted)
            side(after, label: afterLabel, color: tone)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .help(explanation).accessibilityElement(children: .combine).textSelection(.enabled)
    }
    private func side(_ number: Double?, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.sbCaption).lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(StorebenchTheme.color("color-surface-sunken"))
                    if let number { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: max(0, min(geometry.size.width, geometry.size.width * number / maximum))) }
                }
            }.frame(height: 6).accessibilityHidden(true)
        }
    }
}
