import StorebenchCore
import SwiftUI

enum StorebenchHelpTopics {
    static let byId: [String: HelpCatalog.Topic] = Dictionary(((try? HelpCatalog.bundled())?.topics ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
}

/// A (?) beside a heading. Hovering shows the topic's summary as a help tag; clicking opens it,
/// with a link to the complete topic in Help. VoiceOver reads the summary as the button's hint.
struct StorebenchHelpButton: View {
    let topic: String
    @State private var showing = false
    @Environment(\.recoveryNavigation) private var recovery
    var body: some View {
        if let info = StorebenchHelpTopics.byId[topic] {
            Button { showing.toggle() } label: {
                StorebenchIcon(name: "help", size: 16).foregroundStyle(StorebenchTheme.color("color-accent-slate"))
                    .frame(width: 24, height: 24).contentShape(Circle())
            }
            .buttonStyle(.plain).help(info.summary)
            .accessibilityLabel("Help: " + info.title).accessibilityHint(info.summary)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                    Text(info.title).font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                    Text(info.summary).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let navigate = recovery.navigate, let action = try? RecoveryGuidance.Target.help(topic).resolved(scope: nil) {
                        Button("Open in Help") { showing = false; navigate(action) }.environment(\.naturalActions, true)
                    }
                }
                .padding(StorebenchTheme.space(4)).frame(width: 320, alignment: .leading)
                .foregroundStyle(StorebenchTheme.ink).background(StorebenchTheme.surface)
            }
        }
    }
}

/// An (i) beside a field or value whose label does not explain itself. Hovering shows the explanation
/// as a help tag; clicking or pressing Space shows it in a popover, so keyboard users can read it too.
struct StorebenchInfoTip: View {
    let title: String, text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            StorebenchIcon(name: "info", size: 14).foregroundStyle(StorebenchTheme.muted)
                .frame(width: 22, height: 22).contentShape(Circle())
        }
        .buttonStyle(.plain).help(text)
        .accessibilityLabel("About " + title).accessibilityHint(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                Text(title).font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                Text(text).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(StorebenchTheme.space(4)).frame(width: 300, alignment: .leading)
            .foregroundStyle(StorebenchTheme.ink).background(StorebenchTheme.surface)
        }
    }
}

struct StorebenchSetupStep<Action: View>: View {
    let number: Int, title: String, detail: String
    /// A finished step shows a green check instead of its number.
    var done = false
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
            ZStack {
                Circle().fill(StorebenchTheme.color(done ? "color-success" : "color-surface-accent-strong"))
                if done { StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.color("color-on-accent")) }
                else { Text("\(number)").font(.sbCallout.weight(.semibold)).monospacedDigit().foregroundStyle(StorebenchTheme.color("color-accent-muted")) }
            }.frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                Text(title).font(.sbCallout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                action()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Step \(number): \(title)" + (done ? ", done" : ""))
    }
}

extension StorebenchSetupStep where Action == EmptyView {
    init(number: Int, title: String, detail: String, done: Bool = false) { self.init(number: number, title: title, detail: detail, done: done) { EmptyView() } }
}
