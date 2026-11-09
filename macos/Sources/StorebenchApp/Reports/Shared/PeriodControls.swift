import Observation
import StorebenchCore
import SwiftUI

typealias ViewPeriods = PeriodSelection
extension PeriodSelection {
    func daysBinding(_ key: PeriodKey, session: WorkspaceSession?) -> Binding<Int> { Binding(get: { self.days(key) }, set: { self.choose(key, .days($0), session: session) }) }
    func rangeBinding(_ key: PeriodKey, session: WorkspaceSession?) -> Binding<PeriodRangeChoice> { Binding(get: { self.range(key) }, set: { self.choose(key, .range($0), session: session) }) }
}

struct PeriodDaysField: View {
    let title: String
    @Binding var value: Int
    var maximum = 365
    var presets = [1, 7, 14, 30, 60, 90, 180, 365]
    var fiscal = false
    @State private var custom = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StorebenchPicker(title, selection: Binding(get: { custom || !presets.contains(value) ? 0 : value }, set: { if $0 == 0 { custom = true } else { custom = false; value = $0 } })) {
                selectionOptions(presets.filter { $0 <= maximum }) { SelectionOption(fiscal ? "\($0) \($0 == 1 ? "period" : "periods")" : Self.label($0), value: $0) }
                SelectionOption("Custom…", value: 0)
            }
            if custom || !presets.contains(value) {
                StorebenchStepper("\(value) \(fiscal ? "fiscal periods" : "days")", value: $value, in: 1...maximum)
            }
        }
    }
    static func label(_ days: Int) -> String { days == 365 ? "1 year" : days == 180 ? "6 months" : "\(days) \(days == 1 ? "day" : "days")" }
}

struct PeriodRangeField: View {
    @Binding var choice: PeriodRangeChoice
    let latest: String
    var title = "Dates shown"
    /// Day counts for the latest windows, then This year (-2), All saved dates (-1) and Custom (0).
    private let presets = [7, 30, 90, 180, 365, -2, -1, 0]
    private var selection: Int {
        switch choice { case .all: -1; case .year: -2; case .latest(let days): presets.contains(days) ? days : 0; case .custom: 0 }
    }
    private var resolved: PeriodDateRange? { try? choice.resolve(latest: latest) }
    private var custom: Bool { selection == 0 }
    private func label(_ preset: Int) -> (title: String, help: String) {
        switch preset {
        case -2: ("This year", "From January 1 through the newest saved date")
        case -1: ("All saved dates", "Every saved report date")
        case 0: ("Custom…", "Choose the first and last date")
        default: (PeriodDaysField.label(preset), "The latest \(PeriodDaysField.label(preset)) through the newest saved date")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sbCallout.weight(.semibold)).foregroundStyle(StorebenchTheme.muted)
            if latest.isEmpty { Text("Date choices appear once reports are saved.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
            StorebenchFlow(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button { select(preset) } label: { Text(label(preset).title) }
                        .buttonStyle(StorebenchButtonStyle(selection == preset ? .secondary : .quiet)).help(label(preset).help)
                        .accessibilityAddTraits(selection == preset ? .isSelected : [])
                }
            }.environment(\.naturalActions, true)
            }
            if custom, let range = resolved, let first = PeriodDates.date(range.from), let last = PeriodDates.date(range.to) {
                StorebenchFormGrid {
                StorebenchDateField("From", selection: Binding(get: { first }, set: { update(from: PeriodDates.text($0), to: range.to) }), in: ...last, displayedComponents: .date)
                StorebenchDateField("Through", selection: Binding(get: { last }, set: { update(from: range.from, to: PeriodDates.text($0)) }), in: first..., displayedComponents: .date)
                }
            }
            Text(resolved.map { "\($0.from) through \($0.to). Latest windows and This year follow the newest saved data." } ?? "All saved dates. Missing reports stay unknown.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
        }.environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
    }
    private func select(_ selected: Int) {
        if selected == -1 { choice = .all }
        else if selected == -2 { choice = .year }
        else if selected > 0 { choice = .latest(selected) }
        else if let range = resolved ?? (try? PeriodRangeChoice.latest(30).resolve(latest: latest)) { choice = .custom(range) }
    }
    private func update(from: String, to: String) {
        guard let range = try? PeriodDateRange(from: from, to: to) else { return }
        choice = .custom(range)
    }
}

struct PeriodPreferencesNotice: View {
    let periods: ViewPeriods
    var body: some View { StorebenchTextSlot(text: periods.status, height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true) }
}
