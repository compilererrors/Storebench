import StorebenchCore
import SwiftUI

/// Shared saved-coverage presentation. Destinations use the workspace's protected navigation.
struct ReportContextView: View {
    let kind: ReportContext.Kind, coverage: ReportContext.Coverage
    @Environment(\.recoveryNavigation) private var navigation
    @State private var catalog: ReportContext?
    @State private var expanded = false
    private var presentation: ReportContext.Presentation? { try? catalog?.presentation(kind, coverage: coverage) }
    var body: some View {
        Card(title: "Report context", subtitle: "Saved reporting basis and related views.") {
            DisclosureGroup(presentation?.title ?? "Reporting definitions", isExpanded: $expanded) {
                if let value = presentation {
                    VStack(alignment: .leading, spacing: 12) {
                        track(value.latest + " " + value.coverage, height: 56)
                        track(value.description, height: 72)
                        track(value.limits, height: 96)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { related(value) }
                            VStack(alignment: .leading, spacing: 16) { related(value) }
                        }.accessibilityLabel("Related reporting views")
                        if navigation.navigate != nil { Button(value.helpLabel) { if let action = value.help.resolved(scope: nil) { navigation.navigate?(action) } } }
                    }
                } else {
                    Text("Reporting definitions could not be read. Saved reports remain available.").font(.sbCallout)
                    Button("Read Again") { load() }.help("Read Reporting Definitions Again").accessibilityLabel("Read Reporting Definitions Again")
                }
            }.accessibilityLabel("Report context")
        }.task { if catalog == nil { load() } }
    }
    private func load() { catalog = try? ReportContext.bundled() }
    private func track(_ text: String, height: CGFloat) -> some View {
        StorebenchTextSlot(text: text, height: height, font: .sbCallout, color: nil)
    }
    @ViewBuilder private func related(_ value: ReportContext.Presentation) -> some View {
        ForEach(value.related) { row in
            let action = row.kind.target.resolved(scope: navigation.scope)
            VStack(alignment: .leading, spacing: 8) {
                StorebenchTextSlot(text: row.label, height: 28, font: .sbHeadline, color: nil)
                track(row.description, height: 64)
                if action != nil && navigation.navigate != nil { Button(row.action) { if let action { navigation.navigate?(action) } } }
            }.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        }
    }
}
