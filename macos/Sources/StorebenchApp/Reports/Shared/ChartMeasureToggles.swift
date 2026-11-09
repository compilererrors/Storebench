import StorebenchCore
import SwiftUI

/// Checkboxes for the measures one chart draws, up to the number of series a chart shows.
/// `change` receives the chosen measures as the text `ChartMeasures` reads.
struct ChartMeasureToggles: View {
    let options: [(key: String, title: String)], chosen: [String]
    let change: (String) -> Void
    init(options: [(key: String, title: String)], chosen: [String], change: @escaping (String) -> Void) {
        self.options = options; self.chosen = chosen; self.change = change
    }
    init(options: [(key: String, title: String)], selection: Binding<[String]>) {
        self.init(options: options, chosen: selection.wrappedValue) { value in
            selection.wrappedValue = ChartMeasures.chosen(value, allowed: options.map(\.key), fallback: [])
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 180) {
                ForEach(options, id: \.key) { option in
                    let full = !chosen.contains(option.key) && chosen.count >= ChartMeasures.limit
                    StorebenchToggle(option.title, isOn: Binding(get: { chosen.contains(option.key) }, set: { change(ChartMeasures.toggled(option.key, on: $0, in: chosen)) }))
                        .storebenchWorking(full)
                        .help(full ? "Deselect a measure before adding another. A chart shows up to four measures." : "Show or hide " + option.title.lowercased())
                }
            }
            Text(options.isEmpty ? "No measures with saved reports. Download or import reports to choose what to show." : "Choose up to four measures to show together.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }
    }
}

/// Reported values, or every series scaled to an average of 100 so measures of different size or unit can be compared.
struct ChartScalePicker: View {
    static let explanation = "Reported Values keeps each measure's units. Indexed scales every line to an average of 100 so measures of different sizes can be compared."
    @Binding var indexed: Bool
    var body: some View {
        StorebenchPicker("Scale", selection: $indexed, hint: Self.explanation) { SelectionOption("Reported values", value: false); SelectionOption("Indexed · average = 100", value: true) }.storebenchFormColumn()
    }
}
