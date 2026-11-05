import StorebenchCore
import SwiftUI

struct SalesAvailabilityView: View {
    let days: [String], readAt: Date, covered: Int, requested: Int
    let openReports: (() -> Void)?
    private var scope: String { "These totals cover the \(covered) of \(requested) days that have a report." }
    var body: some View {
        if let guidance = try? SalesCalendar.guidance(days, now: readAt) {
            if let last = guidance.waiting.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting for Apple's report for \(SalesCalendar.label(guidance.waiting))").font(.sbHeadline)
                    Text(guidance.waiting.contains { $0.availability == .publishing } ? "Apple usually publishes it about now. Sync or download after the publication window." : "The usual publication window has not started. Sync or download after it.").fixedSize(horizontal: false, vertical: true)
                    window(last.window); Text(scope).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }.padding(.vertical, 6)
            }
            if let last = guidance.late.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple's report for \(SalesCalendar.label(guidance.late)) is later than usual").font(.sbHeadline)
                    Text("Sync again later. Delivery times can vary.").foregroundStyle(StorebenchTheme.muted)
                    window(last.window); Text(scope).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }.padding(.vertical, 6)
            }
            if !guidance.missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(guidance.missing.count) \(guidance.missing.count == 1 ? "day has" : "days have") no downloaded report").font(.sbHeadline)
                    Text("\(SalesCalendar.label(guidance.missing)): download these days or run Sync. \(scope)").fixedSize(horizontal: false, vertical: true)
                    if let openReports { Button("Download Reports") { openReports() } }
                }.padding(.vertical, 6)
            }
        } else { Text("Reporting-clock guidance is unavailable. Missing reports remain unknown.").foregroundStyle(StorebenchTheme.muted) }
    }
    private func window(_ value: SalesCalendar.Window) -> some View {
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute().timeZone(.specificName(.short))
        return Text("Usual window: \(value.from.formatted(style)) – \(value.to.formatted(style)). 05:30–07:30 Pacific Time, the next morning; this is not a delivery promise.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
}
