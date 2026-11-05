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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { ForEach(steps) { row($0) } }
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
            Text(step.state.label).font(.sbCaption.weight(.semibold)).foregroundStyle(step.state == .blocked ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            Text(fix != nil && !step.issues.isEmpty ? (step.issues.count == 1 ? "Fix this before adding the version for review:" : "Fix these \(step.issues.count) things before adding the version for review:") : step.detail)
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func opens(_ step: ReleaseReadiness.Step) -> Bool { ready && (fix == nil || step.issues.isEmpty) && actionable(step) }
    private func hasActions(_ step: ReleaseReadiness.Step) -> Bool { opens(step) || step.guideHref.flatMap(URL.init(string:)) != nil }
    private func actions(_ step: ReleaseReadiness.Step) -> some View {
        StorebenchActionGroup(alignment: .leading) {
            if opens(step) { Button(step.action) { open(step) }.help(step.action) }
            if let guide = step.guideHref, let url = URL(string: guide) { StorebenchActionLink("Apple Guide", destination: url) }
        }
    }
    private func problems(_ step: ReleaseReadiness.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(step.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .center, spacing: 12) {
                    StorebenchIcon(name: "warning", size: 16).foregroundStyle(StorebenchTheme.color("color-danger")).accessibilityHidden(true)
                    Text(issue.message).font(.sbCallout).foregroundStyle(StorebenchTheme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if ready, let fix {
                        Button("Edit") { fix(step, issue) }.help(issue.section == "screenshots" ? "Go to the screenshots" : "Go to " + (TextDrafts.labels[issue.field] ?? "the field"))
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
        DisclosureGroup("View selected and unselected regions") {
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
