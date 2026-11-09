import StorebenchCore
import SwiftUI

/// Selection and scrolling remain inside the outlined surface. The handle changes only its height.
struct StorebenchTextSurface<Content: View>: View {
    let label: String
    var initialHeight: Double = 140
    @ViewBuilder let content: () -> Content
    @State private var adjustedHeight: Double?
    @State private var dragging = false
    @State private var handleFocused = false
    @State private var handleHovered = false
    @Environment(\.collectionVisible) private var visible
    private var height: Double { TextSurfacePresentation.height(adjustedHeight ?? initialHeight) }
    var body: some View {
        VStack(spacing: 0) {
            content().frame(minWidth: 0, maxWidth: .infinity).frame(height: height)
            StorebenchDivider()
            GeometryReader { geometry in
                let padding = min(StorebenchTheme.space(2), geometry.size.width / 2)
                let available = max(0, geometry.size.width - padding * 2)
                let handleWidth = min(52, available)
                let gap = min(8, max(0, (available - handleWidth) / 2))
                let sideWidth = max(0, (available - handleWidth) / 2 - gap)
                HStack(spacing: gap) {
                    Text("\(Int(height)) pt").font(.sbCaption).monospacedDigit().foregroundStyle(StorebenchTheme.muted)
                        .lineLimit(1).frame(width: sideWidth, alignment: .leading)
                    resizeHandle.frame(width: handleWidth)
                    Button("Reset") { adjustedHeight = nil }.buttonStyle(StorebenchPressStyle()).font(.sbCaption)
                        .foregroundStyle(StorebenchTheme.color("color-accent-muted")).lineLimit(1)
                        .help("Reset " + label.lowercased() + " height").accessibilityLabel("Reset " + label.lowercased() + " height").frame(width: sideWidth, alignment: .trailing)
                }.padding(.horizontal, padding).frame(height: 32)
            }.frame(height: 32).background(StorebenchTheme.color("color-surface-subtle"))
                .disabled(false)
        }.background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .overlay(StorebenchControlOutline())
            .onChange(of: visible) { if !visible { finishDrag() } }
            .onDisappear { finishDrag() }
    }
    private var resizeHandle: some View {
        StorebenchIcon(name: "resize", size: 16).foregroundStyle(StorebenchTheme.muted)
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(handleHovered || dragging ? StorebenchTheme.color("color-surface-accent") : .clear, in: Capsule())
            .contentShape(Capsule())
            .overlay(StorebenchControlOutline(border: .clear, radius: 14, focusedOverride: handleFocused && !dragging))
            .overlay {
                StorebenchResizeEventBridge(label: label, height: height, changed: { value in
                    guard value != height else { return }
                    var transaction = Transaction(); transaction.animation = nil; transaction.disablesAnimations = true
                    withTransaction(transaction) { adjustedHeight = value }
                }, interaction: { active in
                    if active { dragging = true; handleFocused = false }
                    else { finishDrag() }
                }, focus: { handleFocused = $0 })
            }
            .onHover { handleHovered = $0 }
            .help("Drag vertically to resize " + label.lowercased())
    }
    private func finishDrag() {
        dragging = false; handleFocused = false; handleHovered = false
    }
}

struct StorebenchReadOnlyText: View {
    let title, text: String
    var field = ""
    var height: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.sbCaption.weight(.semibold)) }
            StorebenchTextSurface(label: title.isEmpty ? "Saved text" : title, initialHeight: height ?? TextSurfacePresentation.initialHeight(field: field)) {
                ScrollView(.vertical) {
                    Text(text.isEmpty ? "Empty" : text).font(.sbCallout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
                }.scrollIndicators(.visible).accessibilityLabel(title.isEmpty ? "Saved text" : title)
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}
