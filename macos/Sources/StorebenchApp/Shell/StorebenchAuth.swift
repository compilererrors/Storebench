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
        StorebenchHeader(stackAt: 480, actionTopInset: 12) { heading } actions: { actions }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            StorebenchFlow(spacing: 8) {
                Text(title).font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                if recommended { Text("Recommended").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
            }
            StorebenchTextSlot(text: description, height: 96, font: .sbCallout, color: StorebenchTheme.muted)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) { content() }.environment(\.fieldHintHeight, 0)
    }
}
