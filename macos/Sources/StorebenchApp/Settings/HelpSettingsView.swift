import StorebenchCore
import SwiftUI

struct HelpSettingsView: View {
    var requestedTopic: String? = nil
    var requestId: UUID? = nil
    @State private var catalog: HelpCatalog?
    @State private var query = ""
    @State private var failed = false
    @State private var jump = ""
    private var topics: [HelpCatalog.Topic] { catalog?.matching(query) ?? [] }
    private var contact: SupportContact? { try? SupportContact(info: Bundle.main.infoDictionary?.compactMapValues { $0 as? String } ?? [:]) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                    Card(title: "Help & data sources", subtitle: "Find answers about setup, pricing, protection, reports, media and publishing.") {
                        if catalog != nil { StorebenchSearchField("Find an answer", text: $query) }
                        Text("Search all questions and answers. For example: unprotected.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                        StorebenchActionGroup {
                            Button { StorebenchAbout.show() } label: { StorebenchLabel("About Storebench", icon: "info", size: 16) }
                            if let contact {
                                StorebenchActionLink("Contact Support", destination: contact.support, help: "Open the Storebench support page in your browser")
                            }
                        }
                        if contact != nil {
                            Text("Contact Support opens the support page in your browser. Nothing is sent from the app; remove private information from what you write.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                        } else { Text("Support links are available in the packaged application.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                        if failed { Text("Help could not be read. Retry to load the complete help catalog.").foregroundStyle(StorebenchTheme.muted); Button("Read Help Again") { load() } }
                        else if catalog == nil { ProgressView("Reading help…") }
                        else {
                            StorebenchPicker("Go to topic", selection: Binding(get: { jump }, set: { id in
                                jump = id; withAnimation { scroll.scrollTo(id, anchor: .top) }
                            })) { selectionOptions(topics) { SelectionOption($0.title, value: $0.id) } }
                        }
                    }
                    ForEach(topics) { topic in
                        Card(title: topic.title, subtitle: "") {
                            Text(topic.summary).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            ForEach(Array(topic.links.enumerated()), id: \.offset) { _, link in StorebenchTextLink(link.label, destination: link.url) }
                            ForEach(Array(topic.questions.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.question).font(.sbHeadline)
                                    Text(item.answer).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                        }.id(topic.id)
                    }
                    if catalog != nil && topics.isEmpty { Text("No topics match. Try a shorter search.").foregroundStyle(StorebenchTheme.muted).accessibilityAddTraits(.updatesFrequently) }
                }.frame(maxWidth: .infinity, alignment: .leading).settingsPageInsets(true)
            }.task(id: requestId) {
                if catalog == nil { load() }
                guard let requestedTopic, catalog?.topics.contains(where: { $0.id == requestedTopic }) == true else { return }
                query = ""; await Task.yield()
                guard !Task.isCancelled else { return }
                scroll.scrollTo(requestedTopic, anchor: .top)
            }
        }
    }
    private func load() { do { catalog = try HelpCatalog.bundled(); failed = false } catch { catalog = nil; failed = true } }
}
