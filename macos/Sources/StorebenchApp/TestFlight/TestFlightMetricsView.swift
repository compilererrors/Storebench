import StorebenchCore
import SwiftUI

struct TestFlightMetricsView: View {
    let account: Account, app: Account.App, build: TestFlightBuild, session: WorkspaceSession?
    @State private var metrics: TestFlightMetrics?
    @State private var message = ""
    @State private var loading = true

    var body: some View {
        Card(title: "Build \(build.version) metrics", subtitle: "Apple's reported TestFlight usage. Missing counts are unavailable.") {
            if loading { ProgressView("Reading usage…") }
            else if !message.isEmpty { Text(message).foregroundStyle(StorebenchTheme.muted) }
            else if let metrics, !metrics.points.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(metrics.points.enumerated()), id: \.offset) { _, point in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(point.start) to \(point.end) · Series \(point.series)").font(.sbSubheadline.weight(.semibold)).textSelection(.enabled)
                                ForEach(Array(TestFlightMetrics.names.enumerated()), id: \.offset) { index, name in
                                    HStack { Text(TestFlightMetrics.labels[index]); Spacer(); Text(point.values[name].map { String(format: "%.0f", $0) } ?? "Unavailable").monospacedDigit() }
                                }
                            }
                            StorebenchDivider()
                        }
                    }
                }.frame(maxHeight: 300)
            } else { Text("Apple has not returned a reporting interval for this build.").foregroundStyle(StorebenchTheme.muted) }
        }.task(id: build.id) {
            guard let session else { loading = false; return }
            loading = true; metrics = nil; message = ""
            do { metrics = try await session.testFlightMetrics(account: account, appId: app.id, buildId: build.id) }
            catch is CancellationError { return }
            catch { message = "Build metrics could not be read. Build access and feedback remain available." }
            loading = false
        }
    }
}
