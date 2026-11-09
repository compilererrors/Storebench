import StorebenchCore
import SwiftUI

/// Opens or closes the sample workspace once every open editor allows leaving.
@MainActor enum SampleData {
    static let description = "Fictional apps with listing history in several languages, 100 days of sales and App Store analytics. Nothing is sent to Apple, and it is removed when you close it."

    static func open(_ model: LibraryModel) {
        guard !model.showingSampleData, EditorWindows.allowLeaving() else { return }
        Task { await model.openSampleData() }
    }
    static func close(_ model: LibraryModel) {
        guard model.showingSampleData, EditorWindows.allowLeaving() else { return }
        Task { await model.closeSampleData() }
    }
}

/// The small command an empty workspace offers next to Connect Account.
struct LoadSampleDataButton: View {
    let model: LibraryModel
    var body: some View {
        Button("Load Sample Data") { SampleData.open(model) }
            .help("Explore Storebench with fictional apps before connecting Apple").accessibilityLabel("Load Sample Data")
    }
}

/// Shown at the top of Overview and Apps while the sample workspace is open.
struct SampleDataNotice: View {
    let model: LibraryModel
    var body: some View {
        if model.showingSampleData {
            StorebenchNotice(title: "You're viewing sample data", description: "These apps, listings and reports are fictional. Nothing here is sent to Apple, and it is removed when you close sample data.", icon: "sparkles") {
                Button("Close Sample Data") { SampleData.close(model) }.help("Close Sample Data and Return to Your Own Data").accessibilityLabel("Close Sample Data")
            }
        }
    }
}

/// Settings → General: turns the sample workspace on or off.
struct SampleDataSettings: View {
    let model: LibraryModel
    var body: some View {
        StorebenchFormSection("Sample data") {
            StorebenchToggle("Show sample data", isOn: Binding(get: { model.showingSampleData }, set: { $0 ? SampleData.open(model) : SampleData.close(model) }))
                .disabled(model.state == .unlocking || model.state == .closing)
            Text(SampleData.description + " Turning it on signs out of your own data; turning it off returns to it.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
