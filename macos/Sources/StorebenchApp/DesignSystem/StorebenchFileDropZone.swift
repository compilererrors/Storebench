import SwiftUI

struct StorebenchFileDropZone: View {
    let title, detail: String
    var disabled = false
    let choose: () -> Void, drop: ([URL]) -> Bool
    @State private var targeted = false
    var body: some View {
        StorebenchHeader {
            HStack(spacing: StorebenchTheme.space(3)) {
                StorebenchIcon(name: "upload", size: 24).foregroundStyle(StorebenchTheme.accent)
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchTextSlot(text: title, height: 22, font: .sbHeadline)
                    StorebenchTextSlot(text: detail, height: 40, font: .sbCaption, color: StorebenchTheme.muted)
                }
            }
        } actions: { Button("Choose Files…") { if !disabled { choose() } }.storebenchWorking(disabled) }
        .padding(StorebenchTheme.padding).frame(maxWidth: .infinity)
        .background(StorebenchTheme.color(targeted && !disabled ? "color-surface-accent" : "color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(targeted && !disabled ? StorebenchTheme.accent : StorebenchTheme.border, style: StrokeStyle(lineWidth: targeted && !disabled ? 2 : 1, dash: [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled, !urls.isEmpty, urls.count <= 50, urls.allSatisfy(\.isFileURL), Set(urls).count == urls.count else { return false }
            return drop(urls)
        } isTargeted: { targeted = $0 }
    }
}
