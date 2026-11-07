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

/// A (?) beside a setup step that happens in App Store Connect. Clicking it shows where each of Apple's labels
/// sits on a miniature page, then the same labels as a numbered list that VoiceOver reads.
struct StorebenchPathHint: View {
    let step: String, path: ConnectPath
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            StorebenchIcon(name: "help", size: 14).foregroundStyle(StorebenchTheme.color("color-accent-slate"))
                .frame(width: 22, height: 22).contentShape(Circle())
        }
        .buttonStyle(.plain).help("Show where to click in App Store Connect: " + path.summary)
        .accessibilityLabel("Where to click: " + step).accessibilityHint(path.summary)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                Text("Where to click in App Store Connect").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                ConnectPathMap(path: path)
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                    ForEach(Array(path.stops.enumerated()), id: \.offset) { index, stop in
                        HStack(alignment: .firstTextBaseline, spacing: StorebenchTheme.space(2)) {
                            ConnectPathNumber(number: index + 1)
                            (Text(stop.label).fontWeight(.semibold) + Text(" · " + stop.location).foregroundStyle(StorebenchTheme.muted))
                                .font(.sbCallout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .combine)
                    }
                }
                Text("Only the places you click are named; the grey bars stand for Apple's other items.")
                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(StorebenchTheme.space(4)).frame(width: ConnectPathMap.width + 2 * StorebenchTheme.space(4), alignment: .leading)
            .foregroundStyle(StorebenchTheme.ink).background(StorebenchTheme.surface)
        }
    }
}

private struct ConnectPathNumber: View {
    let number: Int
    var body: some View {
        Text("\(number)").font(.sbCaption.weight(.semibold)).monospacedDigit().foregroundStyle(StorebenchTheme.color("color-on-accent"))
            .frame(width: 16, height: 16).background(Circle().fill(StorebenchTheme.accent))
    }
}

/// A miniature App Store Connect page that marks where each stop of a path sits. Only the stops carry text;
/// everything else is a placeholder bar, so the picture stays true when Apple adds or renames other items.
private struct ConnectPathMap: View {
    static let width: CGFloat = 420
    let path: ConnectPath
    private func has(_ place: ConnectPath.Place) -> Bool { path.stops.contains { $0.place == place } }
    private func bar(_ width: CGFloat) -> some View { Capsule().fill(StorebenchTheme.border).frame(width: width, height: 6) }
    private var line: some View { Rectangle().fill(StorebenchTheme.border).frame(height: 1) }
    @ViewBuilder private func marks(_ place: ConnectPath.Place) -> some View {
        ForEach(Array(path.stops.enumerated()).filter { $0.element.place == place }, id: \.offset) { index, stop in
            HStack(alignment: .firstTextBaseline, spacing: StorebenchTheme.space(1)) {
                ConnectPathNumber(number: index + 1)
                Text(stop.label).font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.ink).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, StorebenchTheme.space(1)).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(StorebenchTheme.color("color-surface-accent-strong")))
        }
    }
    var body: some View {
        let gap = StorebenchTheme.space(2)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: gap) {
                bar(22); marks(.topMenu); bar(30); bar(22)
                Spacer(minLength: gap)
                if has(.accountMenu) { marks(.accountMenu) } else { bar(40) }
            }.padding(gap).frame(minHeight: 34).background(StorebenchTheme.page)
            line
            if has(.tabs) {
                HStack(spacing: gap) { bar(30); bar(36); marks(.tabs); bar(30); Spacer(minLength: 0) }.padding(gap)
                line
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: gap) { bar(54); bar(40); marks(.sidebar); bar(62) }
                    .padding(gap).frame(width: 150, alignment: .leading)
                Rectangle().fill(StorebenchTheme.border).frame(width: 1)
                HStack(alignment: .top, spacing: gap) {
                    VStack(alignment: .leading, spacing: gap) { marks(.page); bar(70); bar(48) }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: gap) {
                        marks(.pageTopRight)
                        if has(.opened) {
                            VStack(alignment: .leading, spacing: gap) { bar(46); marks(.opened) }.padding(gap)
                                .background(RoundedRectangle(cornerRadius: 6).fill(StorebenchTheme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(StorebenchTheme.border))
                        }
                    }
                }.padding(gap).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(StorebenchTheme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StorebenchTheme.border))
        .accessibilityHidden(true)
    }
}

struct StorebenchSetupStep<Action: View>: View {
    let number: Int, title: String, detail: String
    /// A finished step shows a green check instead of its number.
    var done = false
    /// Where this step happens in App Store Connect; shows a (?) beside the title.
    var path: ConnectPath? = nil
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
            ZStack {
                Circle().fill(StorebenchTheme.color(done ? "color-success" : "color-surface-accent-strong"))
                if done { StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.color("color-on-accent")) }
                else { Text("\(number)").font(.sbCallout.weight(.semibold)).monospacedDigit().foregroundStyle(StorebenchTheme.color("color-accent-muted")) }
            }.frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                HStack(spacing: StorebenchTheme.space(1)) {
                    Text(title).font(.sbCallout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let path { StorebenchPathHint(step: title, path: path) }
                }
                Text(detail).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                action()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Step \(number): \(title)" + (done ? ", done" : ""))
    }
}

extension StorebenchSetupStep where Action == EmptyView {
    init(number: Int, title: String, detail: String, done: Bool = false, path: ConnectPath? = nil) { self.init(number: number, title: title, detail: detail, done: done, path: path) { EmptyView() } }
}
