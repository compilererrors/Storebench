import StorebenchCore
import SwiftUI

/// Checkboxes for the measures one chart draws, up to the number of series a chart shows.
/// `change` receives the chosen measures as the text `ChartMeasures` reads.
struct ChartMeasureToggles: View {
    let options: [(key: String, title: String)], chosen: [String]
    let change: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 180) {
                ForEach(options, id: \.key) { option in
                    let full = !chosen.contains(option.key) && chosen.count >= ChartMeasures.limit
                    Toggle(option.title, isOn: Binding(get: { chosen.contains(option.key) }, set: { change(ChartMeasures.toggled(option.key, on: $0, in: chosen)) }))
                        .opacity(full ? 0 : 1).allowsHitTesting(!full).accessibilityHidden(full)
                }
            }
            Text("Choose up to four measures to show together.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }
    }
}

/// Reported values, or every series scaled to an average of 100 so measures of different size or unit can be compared.
struct ChartScalePicker: View {
    @Binding var indexed: Bool
    var body: some View {
        StorebenchPicker("Scale", selection: $indexed) { SelectionOption("Reported values", value: false); SelectionOption("Indexed · average = 100", value: true) }.storebenchFormColumn()
    }
}
