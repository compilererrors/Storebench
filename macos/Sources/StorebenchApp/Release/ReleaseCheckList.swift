import StorebenchCore
import SwiftUI

struct ReleaseCheckList: View {
    let steps: [ReleaseReadiness.Step]
    let ready: Bool
    let open: (ReleaseReadiness.Step) -> Void
    /// Goes straight to the field or media a language problem names; without it the row's own action opens the language.
    var fix: ((ReleaseReadiness.Step, ReleaseMaterial.Issue) -> Void)? = nil
    /// False for a check whose fix is already the content right below the list, so the row offers no second, equal command.
    var actionable: (ReleaseReadiness.Step) -> Bool = { _ in true }
    /// Settles a field App Store Connect changed since the draft: true keeps this Mac's text, false uses App Store Connect's.
    var resolve: ((ReleaseReadiness.Step, ReleaseMaterial.Issue, _ keepMine: Bool) -> Void)? = nil
    /// The field whose texts are being compared before the person chooses.
    private struct Comparing: Identifiable { let id = UUID(); let step: ReleaseReadiness.Step; let issue: ReleaseMaterial.Issue }
    @State private var comparing: Comparing?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { ForEach(steps) { row($0) } }
            .sheet(item: $comparing) { item in
                ReleaseTextComparisonView(language: item.step.label, issue: item.issue, unavailable: waiting,
                                          choose: resolve.map { resolve in { keep in comparing = nil; resolve(item.step, item.issue, keep) } },
                                          close: { comparing = nil })
            }
    }
    private func row(_ step: ReleaseReadiness.Step) -> AnyView {
        // Every row has the same shape: what is needed, then its command under it, whatever the width.
        AnyView(VStack(alignment: .leading, spacing: 12) {
            copy(step)
            if hasActions(step) { actions(step) }
            if fix != nil, !step.issues.isEmpty { problems(step) }
            if let territories = step.territories { regions(territories) }
            StorebenchDivider()
        })
    }
    private func copy(_ step: ReleaseReadiness.Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.label).font(.sbCallout.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityLabel(step.label)
            // A language that only waits for its upload is ready, not a problem.
            let ready = ReleaseWizard.readyToSend(step)
            Text(ready ? "Ready to Send" : step.state.label).font(.sbCaption.weight(.semibold))
                .foregroundStyle(ready ? StorebenchTheme.color("color-accent-muted") : step.state == .blocked ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            Text(fix != nil && !step.issues.isEmpty ? (step.issues.count == 1 ? "Fix this before adding the version for review:" : "Fix these \(step.issues.count) things before adding the version for review:") : step.detail)
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func opens(_ step: ReleaseReadiness.Step) -> Bool { ready && !step.action.isEmpty && (fix == nil || step.issues.isEmpty) && actionable(step) }
    private func hasActions(_ step: ReleaseReadiness.Step) -> Bool { opens(step) || step.guideHref.flatMap(URL.init(string:)) != nil }
    private func actions(_ step: ReleaseReadiness.Step) -> some View {
        StorebenchActionGroup(alignment: .leading) {
            if opens(step) { let title = PublishingReviewPresentation.titleCase(step.action); Button(title) { open(step) }.help(title) }
            if let guide = step.guideHref, let url = URL(string: guide) { StorebenchActionLink("Apple Guide", destination: url) }
        }
    }
    /// Why a row's commands wait: the step is being checked again. The commands stay in place, so the rows never change height.
    private var waiting: String? { ready ? nil : "Wait for the check to finish." }
    private func problems(_ step: ReleaseReadiness.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(step.issues.enumerated()), id: \.offset) { _, issue in
                let label = TextDrafts.labels[issue.field] ?? issue.field
                StorebenchActionRow {
                    HStack(alignment: .top, spacing: 12) {
                        StorebenchIcon(name: "warning", size: 16).foregroundStyle(StorebenchTheme.color("color-danger")).accessibilityHidden(true)
                            .frame(height: 20)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(issue.message).font(.sbCallout).foregroundStyle(StorebenchTheme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if resolve != nil, !issue.comparisons.isEmpty {
                                StorebenchActionGroup(alignment: .leading) {
                                    Button("View Changes") { comparing = Comparing(step: step, issue: issue) }
                                        .help("Compare your draft with App Store Connect's \(label), side by side, before you choose")
                                        .accessibilityLabel("View Changes: " + label)
                                        .storebenchControlID("release.issue.view-changes." + issue.field)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } actions: {
                    if let resolve, issue.changedAtApple || issue.changedOnBothSides {
                        StorebenchCommand(title: "Use App Store Connect", busy: false, unavailable: waiting) { resolve(step, issue, false) }
                            .help(waiting ?? "Put App Store Connect's current \(label) into your draft on this Mac. Nothing is sent.")
                            .storebenchControlID("release.issue.use-apple." + issue.field)
                        StorebenchCommand(title: "Keep Mine", busy: false, unavailable: waiting, primary: false) { resolve(step, issue, true) }
                            .help(waiting ?? "Keep your text; the review on this step then sends it to App Store Connect")
                            .storebenchControlID("release.issue.keep-mine." + issue.field)
                    } else if let fix {
                        StorebenchCommand(title: "Edit", busy: false, unavailable: waiting, primary: false) { fix(step, issue) }
                            .help(waiting ?? (issue.section == "screenshots" ? "Go to the screenshots" : "Go to " + label))
                            .accessibilityLabel("Edit: " + issue.message)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(StorebenchTheme.color("color-danger-surface"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
                .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.color("color-danger-border")))
            }
        }
    }
    private func regions(_ value: JSONText) -> some View {
        DisclosureGroup("View Selected and Unselected Regions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach([("Selected", "selected"), ("Not selected", "unselected")], id: \.1) { label, key in
                        let codes: [String] = { if case .array(let values)? = value[key] { return values.compactMap(\.text) }; return [] }()
                        Text("\(label) · \(codes.count)").font(.sbHeadline)
                        if codes.isEmpty { Text("None").foregroundStyle(StorebenchTheme.muted) }
                        ForEach(codes, id: \.self) { code in Text("\(WorkspaceSession.countryName(code)) (\(code))").font(.sbCallout).fixedSize(horizontal: false, vertical: true) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 200)
        }
    }
}
