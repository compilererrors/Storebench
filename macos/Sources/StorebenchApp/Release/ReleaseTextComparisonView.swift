import StorebenchCore
import SwiftUI

/// A field App Store Connect changed since the draft took its text: your draft and App Store Connect's text side by side, as a
/// text comparison shows two files, each marking the words only it has, with the choice under them.
struct ReleaseTextComparisonView: View {
    let language: String
    let issue: ReleaseMaterial.Issue
    /// Why the choice cannot be made now, such as while the step is checked again; nil when it can.
    var unavailable: String? = nil
    /// Settles the field from here: true keeps this Mac's text, false uses App Store Connect's. Nil shows the comparison only.
    let choose: ((_ keepMine: Bool) -> Void)?
    let close: () -> Void
    static let panelHeight: Double = 360
    private var label: String { TextDrafts.labels[issue.field] ?? issue.field }
    private var mine: String { issue.mine ?? "" }
    private var apple: String { issue.apple ?? "" }
    private var summary: String {
        issue.changedOnBothSides
            ? "Both App Store Connect and this Mac changed this text after your draft took it. Choose the text to keep."
            : "App Store Connect has newer text than your draft. Choose the text to keep."
    }
    var body: some View {
        let sides = AsoProgress.sides(mine, apple)
        StorebenchDialog(title: label + " · Changes", kind: .content, subtitle: language, close: close) {
            Text(summary).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: StorebenchTheme.gap) {
                panel(title: "Your Draft", detail: "Marked: only in your draft", text: mine, segments: sides.before, tone: "color-danger", id: "mine")
                panel(title: "App Store Connect", detail: "Marked: only in App Store Connect", text: apple, segments: sides.after, tone: "color-success", id: "apple")
            }
            if issue.changedOnBothSides, let base = issue.base {
                DisclosureGroup("Text Your Draft Took From the Last Import") {
                    StorebenchReadOnlyText(title: "", text: base, height: 140)
                }
            }
        } actions: {
            if let choose {
                StorebenchActionGroup(alignment: .trailing) {
                    StorebenchCommand(title: "Keep Mine", busy: false, unavailable: unavailable, primary: false) { choose(true) }
                        .help(unavailable ?? "Keep your text; the review on this step then sends it to App Store Connect")
                        .storebenchControlID("release.compare.keep")
                    StorebenchCommand(title: "Use App Store Connect", busy: false, unavailable: unavailable) { choose(false) }
                        .help(unavailable ?? "Put App Store Connect's current \(label) into your draft on this Mac. Nothing is sent.")
                        .storebenchControlID("release.compare.use")
                }
            } else {
                Button("Close", action: close).buttonStyle(StorebenchButtonStyle(.primary)).storebenchControlID("release.compare.close")
            }
        }
    }

    /// One side: its name and length on top, then the whole text with the words only it has marked, scrolling inside a fixed height.
    private func panel(title: String, detail: String, text: String, segments: [AsoTextSegment], tone: String, id: String) -> some View {
        let used = TextDrafts.used(issue.field, text), limit = TextDrafts.limits[issue.field] ?? 0
        let length = limit > 0 ? "\(used) of \(limit) \(issue.field == "keywords" ? "bytes" : "characters")" : ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.sbHeadline)
                Spacer(minLength: 0)
                Text(length).font(.sbCaption.monospacedDigit()).foregroundStyle(used > limit && limit > 0 ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            }
            Text(detail).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            StorebenchTextSurface(label: title, initialHeight: Self.panelHeight) {
                ScrollView(.vertical) {
                    Self.marked(segments, tone: tone).font(.sbCallout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
                }.scrollIndicators(.visible).accessibilityLabel(title)
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).storebenchControlID("release.compare." + id)
    }

    /// The text with the words only this side has on a tinted background, as text comparisons mark them.
    static func marked(_ segments: [AsoTextSegment], tone: String) -> Text {
        if segments.isEmpty { return Text("Empty").foregroundColor(StorebenchTheme.muted) }
        var text = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if segment.kind != .same {
                part.backgroundColor = StorebenchTheme.color(tone + "-surface")
                part.foregroundColor = StorebenchTheme.color(tone)
                part.font = .sbCallout.weight(.semibold)
            }
            text += part
        }
        return Text(text)
    }
}
