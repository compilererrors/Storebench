import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchAuthScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.workspaceHeight) private var height
    var body: some View {
        ScrollView {
            VStack(spacing: 20) { content() }.padding(24)
                .frame(maxWidth: .infinity, minHeight: height)
        }.background(StorebenchTheme.color("color-surface-sunken"))
    }
}

struct StorebenchAuthCard<Content: View>: View {
    let title: String, message: String
    var wide = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StorebenchBrand().padding(.bottom, 27)
            Text(title).font(.system(size: 28).bold()).tracking(-0.8).padding(.bottom, 10)
            Text(message).font(.sbSubheadline).foregroundStyle(StorebenchTheme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 17) { content() }
        }.padding(wide ? 32 : 34).frame(maxWidth: wide ? 760 : 420, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 16).fill(StorebenchTheme.surface).shadow(color: StorebenchTheme.ink.opacity(0.1), radius: 27, y: 18) }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StorebenchTheme.border))
    }
}

struct StorebenchSetupOption<Content: View>: View {
    let title: String, description: String
    var recommended = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchFlow(spacing: 8) {
                Text(title).font(.system(size: 15).bold()).frame(height: 22)
                if recommended { Text("RECOMMENDED").font(.sbCaption.bold()).tracking(0.44).foregroundStyle(StorebenchTheme.color("color-accent-muted")).frame(height: 22) }
            }
            StorebenchTextSlot(text: description, height: 72, font: .sbCallout, color: StorebenchTheme.color("color-text-secondary"))
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 12) { content() }.environment(\.fieldHintHeight, 0)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StorebenchTheme.color(recommended ? "color-surface-accent" : "color-surface"), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StorebenchTheme.color(recommended ? "color-border-accent" : "color-border-control"), lineWidth: 1.5))
    }
}
