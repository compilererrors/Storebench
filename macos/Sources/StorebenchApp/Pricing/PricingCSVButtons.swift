import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Import CSV… and Copy CSV Format for one kind of country values, with a fixed feedback line. Reading a file only fills the
/// editor; nothing is saved or sent.
struct PricingCSVButtons: View {
    let kind: PricingCSV.Kind
    let territories: [Territory]
    let onImport: ([String: String]) -> Void
    @State private var status = ""
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            StorebenchActionGroup {
                Button(reading ? "Reading…" : "Import CSV…") { Task { await choose() } }.help("Fill in \(kind.title.lowercased()) from a CSV file").storebenchWorking(reading)
                Button("Copy CSV Format") {
                    NSPasteboard.general.clearContents()
                    status = NSPasteboard.general.setString(kind.format, forType: .string) ? "CSV format copied. " + kind.meaning : "The CSV format could not be copied."
                }.help("Copy the CSV columns with example rows")
            }
            StorebenchFeedback(text: status, height: 34)
        }
    }

    private func choose() async {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reading = true; defer { reading = false }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let file = try await SelectedFiles.readAsync([url], purpose: .transfer).first else { throw SelectedFiles.Failure.read }
            let values = try PricingCSV.read(file.data, kind: kind, territories: territories)
            onImport(values)
            status = "\(values.count) \(values.count == 1 ? "country or region" : "countries or regions") filled in from the file. Nothing is saved yet."
        } catch let failure as PricingFailure { status = failure.message }
        catch { status = "The file could not be read. Choose a CSV file saved as UTF-8 text." }
    }
}
