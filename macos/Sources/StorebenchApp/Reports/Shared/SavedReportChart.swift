import Charts
import StorebenchCore
import SwiftUI

/// Shared read-only chart with report gaps and pointer, keyboard and accessible period inspection.
struct SavedReportChart: View {
    let series: [SavedTimeSeries.Series], markers: [SavedTimeSeries.Marker]
    private struct Input: Equatable, Sendable { let series: [SavedTimeSeries.Series], markers: [SavedTimeSeries.Marker] }
    private struct Prepared: Sendable { let input: Input, layout: SavedTimeSeries.Layout?, drawing: [[[SavedTimeSeries.Point]]] }
    @State private var prepared: Prepared?
    private var input: Input { Input(series: series, markers: markers) }
    let format: (Double) -> String, note: String?, emptyText: String
    init(series: [SavedTimeSeries.Series], markers: [SavedTimeSeries.Marker] = [], format: @escaping (Double) -> String = AsoProgress.count, note: String? = nil, emptyText: String = "Choose at least one measure with saved reports. Missing reports are not zero activity.") {
        self.series = series; self.markers = markers; self.format = format; self.note = note; self.emptyText = emptyText
    }
    @State private var active: Int?
    @FocusState private var focused: Bool
    private let colors: [Color] = (1...4).map { StorebenchTheme.color("chart-series-\($0)") }

    var body: some View {
        content.task(id: input) {
            let expected = input
            guard prepared?.input != expected else { return }
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as Prepared? }
                let layout = SavedTimeSeries.layout(expected.series, markers: expected.markers)
                guard !Task.isCancelled else { return nil as Prepared? }
                return Prepared(input: expected, layout: layout, drawing: layout?.drawingRuns() ?? [])
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, input == expected, let next else { return }
            prepared = next; active = nil
        }
    }
    @ViewBuilder private var content: some View {
        if let prepared, prepared.input == input, let layout = prepared.layout {
            let selected = active.flatMap { layout.slots.isEmpty ? nil : layout.slots[min(max(0, $0), layout.slots.count - 1)] }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading) {
                ForEach(Array(layout.series.enumerated()), id: \.element.key) { index, item in
                    HStack(spacing: 7) { Circle().fill(colors[index]).frame(width: 8, height: 8).accessibilityHidden(true); Text(item.label).foregroundStyle(StorebenchTheme.ink) }.font(.sbCaption)
                }
            }
            Text("Report dates: \(PeriodDates.text(layout.startDay)) – \(PeriodDates.text(layout.endDay))").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            GeometryReader { geometry in
                Chart {
                    ForEach(layout.gaps, id: \.start) { gap in
                        RectangleMark(xStart: .value("Missing from", PeriodDates.date(gap.start)!), xEnd: .value("Missing through", PeriodDates.date(gap.end)!.addingTimeInterval(86_400)))
                            .foregroundStyle(StorebenchTheme.color("chart-gap"))
                    }
                    ForEach(Array(layout.series.enumerated()), id: \.element.key) { index, item in
                        ForEach(Array(prepared.drawing[index].enumerated()), id: \.offset) { runIndex, run in
                            ForEach(run, id: \.start) { point in
                                LineMark(x: .value("Report period", point.date), y: .value("Value", point.value!), series: .value("Run", "\(item.key):\(runIndex)"))
                                    .foregroundStyle(colors[index])
                                PointMark(x: .value("Report period", point.date), y: .value("Value", point.value!))
                                    .foregroundStyle(colors[index]).symbolSize(18)
                            }
                        }
                    }
                    ForEach(Array(layout.markers.enumerated()), id: \.offset) { _, marker in
                        RuleMark(x: .value("Listing date", PeriodDates.date(marker.date)!))
                            .foregroundStyle(marker.active ? StorebenchTheme.ink : StorebenchTheme.muted).lineStyle(StrokeStyle(lineWidth: marker.active ? 2 : 1, dash: marker.active ? [] : [4, 4]))
                    }
                    if let selected {
                        RuleMark(x: .value("Selected period", Date(timeIntervalSince1970: selected.middle * 86_400)))
                            .foregroundStyle(StorebenchTheme.muted)
                    }
                }
                .chartXScale(domain: layout.domain)
                .chartYScale(domain: layout.scale.minimum...layout.scale.maximum)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let date = value.as(Date.self) { Text(String(PeriodDates.text(date).dropFirst(5))).foregroundStyle(StorebenchTheme.muted) } }
                } }
                .chartYAxis { AxisMarks(values: layout.scale.ticks) { value in
                    AxisGridLine(); AxisTick(); AxisValueLabel { if let number = value.as(Double.self) { Text(format(number)).foregroundStyle(StorebenchTheme.muted) } }
                } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): inspect(location.x, proxy: proxy, geometry: geometry, layout: layout)
                                case .ended: if !focused { active = nil }
                                }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                                focused = true; inspect(gesture.location.x, proxy: proxy, geometry: geometry, layout: layout)
                            })
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .focusable().focused($focused)
                .accessibilityLabel("Saved report periods. Use arrow keys, Home, End and Escape to inspect reports.")
                .onKeyPress { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    let key: String
                    switch press.key { case .leftArrow: key = "ArrowLeft"; case .rightArrow: key = "ArrowRight"; case .home: key = "Home"; case .end: key = "End"; case .escape: key = "Escape"; default: return .ignored }
                    active = layout.selection(active, key: key); return .handled
                }
            }
            .frame(height: 320).frame(maxWidth: .infinity).onChange(of: focused) { if !focused { active = nil } }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    if let selected {
                        Text(selected.label).font(.sbCallout.weight(.semibold))
                        ForEach(Array(layout.markers.filter { $0.date >= selected.start && $0.date <= selected.end }.enumerated()), id: \.offset) { _, marker in Text(marker.label).font(.sbCaption) }
                        ForEach(Array(layout.series.enumerated()), id: \.element.key) { index, item in
                            Text("\(item.label): \(item.points.first { $0.start == selected.start && $0.end == selected.end }?.exactLabel ?? selected.values[index].map(format) ?? "Not reported")").font(.sbCallout)
                        }
                    } else { Text("Point to the chart or focus it and use arrow keys to read each report period.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: min(132, max(56, Double(32 + layout.series.count * 21)))).accessibilityElement(children: .combine)
            Text(note ?? (layout.gaps.isEmpty ? "Missing reports are not zero activity." : "Shaded days have no saved report. Missing reports are not zero.")).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            if prepared.drawing.flatMap({ $0 }).reduce(0, { $0 + $1.count }) < layout.runs.flatMap({ $0 }).reduce(0, { $0 + $1.count }) {
                Text("Long series use a min/max drawing envelope. Inspection and saved values retain every exact report.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            }
            DisclosureGroup("Read saved report values and listing dates") {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(layout.slots.enumerated()), id: \.offset) { _, slot in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(slot.label).bold()
                                ForEach(Array(layout.series.enumerated()), id: \.element.key) { index, item in Text("\(item.label): \(item.points.first { $0.start == slot.start && $0.end == slot.end }?.exactLabel ?? slot.values[index].map(format) ?? "Not reported")") }
                                ForEach(Array(layout.markers.filter { $0.date >= slot.start && $0.date <= slot.end }.enumerated()), id: \.offset) { _, marker in Text(marker.label).foregroundStyle(StorebenchTheme.muted) }
                            }.font(.sbCallout).textSelection(.enabled)
                        }
                        ForEach(Array(layout.markers.enumerated()), id: \.offset) { _, marker in Text("\(marker.date): \(marker.label)").font(.sbCallout).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 300)
            }
        } else if prepared?.input != input {
            ProgressView("Preparing saved chart…").frame(maxWidth: .infinity, minHeight: 320)
        } else { Text(emptyText).foregroundStyle(StorebenchTheme.muted) }
    }
    private func inspect(_ x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy, layout: SavedTimeSeries.Layout) {
        guard let frame = proxy.plotFrame, let date: Date = proxy.value(atX: x - geometry[frame].minX) else { return }
        let next = layout.nearest(date.timeIntervalSince1970 / 86_400)
        if active != next { active = next }
    }
}
