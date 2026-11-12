import StorebenchCore
import SwiftUI

/// The same concise release summary in the portfolio and alongside an app's other workflow cards.
struct ReleaseOverviewCard: View {
    let title: String, overview: ReleaseOverview?
    var icon: AnyView? = nil
    var unavailable = false
    var compact = false
    var identifier = "release.overview"
    let open: () -> Void
    var body: some View {
        StorebenchWorkflowCard(description: description, feedback: feedback, details: AnyView(rows), heading: {
            StorebenchWorkflowHeading(title: title, symbol: icon == nil ? "release" : nil) { if let icon { icon } }
        }, action: {
            Button(action: open) { StorebenchLabel(overview?.action ?? "Open Release", icon: "right", size: 14) }
                .buttonStyle(StorebenchButtonStyle(.quiet, stretch: true)).storebenchWorking(unavailable)
                .storebenchControlID(identifier + ".open")
        }).storebenchControlID(identifier).help(context)
    }
    private var description: String {
        guard let overview else { return "Release status is unavailable. Open Release to check this app." }
        let version = overview.version.isEmpty ? "" : Releases.platformName(overview.platform) + " " + overview.version + " · "
        return version + overview.detail
    }
    private var feedback: String {
        guard let overview else { return "" }
        if compact, !overview.failed, let first = overview.preview.first {
            return "Next: " + first.title + (overview.checking ? "\nChecking App Store Connect…" : overview.items.count > 1 ? "\nAnd \(overview.items.count - 1) More in Release" : "")
        }
        let more = !compact && overview.moreCount > 0 ? "And \(overview.moreCount) More in Release\n" : ""
        if overview.checking { return more + "Checking App Store Connect…" }
        if overview.failed {
            return more + "Latest Check Failed" + (overview.checkedAt.map { "\nLast Confirmed " + timestamp($0) } ?? " · Open Release to Retry")
        }
        if let date = overview.checkedAt { return more + "Status Checked " + timestamp(date) }
        return more + "App Store Connect has not been checked yet"
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let code = overview?.appleState, !code.isEmpty { StorebenchStateLabel(code: code) }
                else { StorebenchAdaptiveText(text: overview?.status ?? "Status Unavailable", font: .sbCallout.weight(.medium)) }
            }.frame(height: 32, alignment: .topLeading).storebenchControlID(identifier + ".state")
            if !compact { ForEach(0..<3, id: \.self) { index in
                let item = overview?.preview.indices.contains(index) == true ? overview!.preview[index] : nil
                StorebenchTextSlot(text: item.map { "• " + $0.title } ?? "", height: 30, font: .sbCaption,
                                   color: item?.kind == "blocked" ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                    .help(item?.detail ?? "").storebenchControlID(identifier + ".item.\(index)")
            } }
        }
    }
    private var context: String {
        [overview?.checkedAt.map { "Last Confirmed " + timestamp($0) }, overview?.preview.first?.detail].compactMap { $0 }.joined(separator: "\n")
    }
    private func timestamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
