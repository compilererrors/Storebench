import StorebenchCore
import SwiftUI

struct KeywordBulkView: View {
    let notebook: KeywordNotebook, initialLocale: String, onUse: (KeywordNotebook) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var terms = ""
    @State private var locale = "en-US"
    @State private var territories: Set<String> = []
    @State private var preview: KeywordBulkPreview?
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var page = 1

    var body: some View {
        StorebenchDialog(title: "Add multiple keyword ideas", wide: true, inlineActions: true, close: { dismiss() }) {
            Text("Separate terms with commas or new lines. Each term is paired with every selected research territory for one listing language.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchTextArea(title: "Keywords or phrases", text: $terms, height: StorebenchTheme.textarea(rows: 5), hint: "Separate terms with commas or new lines. Phrases stay together; blank entries are ignored.")
            StorebenchFormGrid {
                StorebenchPicker("Listing language for new ideas", selection: $locale, hint: "Research territories do not create listing languages.") { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
                StorebenchFormField(label: "Research territories", hint: "Choose any territory explicitly for unspecified context.") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            territory("", name: "Any territory / unspecified")
                            ForEach(Territories.alpha3.values.sorted(), id: \.self) { territory($0, name: "\(WorkspaceSession.countryName($0)) · \($0)") }
                        }.padding(6)
                    }.frame(height: 148)
                        .background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(StorebenchTheme.color("color-border-control")))
                }
            }
            if terms.isEmpty || territories.isEmpty { Text("Enter terms and choose at least one territory to preview combinations.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                Button("Preview") {
                    do { preview = try Keywords.previewBulk(notebook, terms: terms, locale: locale, territories: territories.sorted()); selected = []; page = 1; message = "" }
                    catch let failure as KeywordFailure { message = failure.message; preview = nil }
                    catch { message = KeywordFailure.format.message; preview = nil }
                }.help("Preview Combinations").accessibilityLabel("Preview Combinations")
            }
            if let preview {
                let newRows = preview.rows.filter { $0.duplicate == nil }
                Text("\(preview.rows.count) combinations: \(newRows.count) new, \(preview.rows.count - newRows.count) duplicates. \(selected.count) selected; room for \(preview.available) ideas.").font(.sbCallout)
                HStack {
                    if !newRows.isEmpty && newRows.count <= preview.available { Button("Select All New") { selected = Set(newRows.map(\.id)) } }
                    if !selected.isEmpty { Button("Clear") { selected = [] } }
                }
                let pages = max(1, (preview.rows.count + 9) / 10)
                let shown = Array(preview.rows.dropFirst((min(page, pages) - 1) * 10).prefix(10))
                StorebenchTableFrame {
                    GeometryReader { geometry in
                        let width = max(560, geometry.size.width), widths = [0.12, 0.40, 0.22, 0.26].map { width * $0 }
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 0) {
                                StorebenchTableHeader(columns: Array(zip(["Add", "Keyword", "Language / territory", "Result"], widths)))
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                                    StorebenchTableRow(index: index) {
                                        Group {
                                            if row.duplicate != nil { Color.clear.accessibilityHidden(true) }
                                            else { StorebenchCheckbox("Add combination " + row.candidate.term, isOn: Binding(get: { selected.contains(row.id) }, set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } })) }
                                        }.frame(height: 42).padding(.horizontal, 12).frame(width: widths[0])
                                        StorebenchTableCell(text: row.candidate.term, width: widths[1])
                                        StorebenchTableCell(text: "\(row.candidate.locale)\n\(row.candidate.territory.isEmpty ? "Any territory" : row.candidate.territory)", width: widths[2])
                                        StorebenchTableCell(text: row.duplicate == .notebook ? "Already in notebook" : row.duplicate == .input ? "Repeated in input" : "New combination", width: widths[3])
                                    }
                                }
                            }.frame(width: width)
                        }
                    }.frame(height: min(440, CGFloat(shown.count) * DataTablePresentation.rowHeight + DataTablePresentation.headerHeight))
                }
                StorebenchPagination(page: min(page, pages), count: pages) { page = $0 }
            }



        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel") { dismiss() }.help("Cancel Multiple Ideas").accessibilityLabel("Cancel Multiple Ideas")

                if let preview, !selected.isEmpty && selected.count <= preview.available {
                    Button("Add to Notebook") {
                        do { if onUse(try Keywords.applyBulk(notebook, preview: preview, selected: selected.sorted())) { dismiss() } else { message = "The notebook could not accept these ideas. Your selection is kept." } }
                        catch let failure as KeywordFailure { message = failure.message }
                        catch { message = KeywordFailure.format.message }
                    }.help("Add Selected Ideas to Notebook").accessibilityLabel("Add Selected Ideas to Notebook").buttonStyle(StorebenchButtonStyle(.primary))
                }

            }
            StorebenchFeedback(text: message.isEmpty ? "Adding ideas changes the unsaved notebook. Review the changes before saving locally." : message)
        }
        .onAppear { locale = initialLocale }
        .onChange(of: terms) { _, _ in invalidate() }
        .onChange(of: locale) { _, _ in invalidate() }
        .onChange(of: territories) { _, _ in invalidate() }
        .interactiveDismissDisabled(!terms.isEmpty || preview != nil)
        .trackUnsavedChanges(!terms.isEmpty || preview != nil)
    }

    private func territory(_ code: String, name: String) -> some View {
        Toggle(name, isOn: Binding(get: { territories.contains(code) }, set: { if $0 { territories.insert(code) } else { territories.remove(code) } })).toggleStyle(StorebenchToggleStyle())
    }
    private func invalidate() { preview = nil; selected = []; message = "" }
}
