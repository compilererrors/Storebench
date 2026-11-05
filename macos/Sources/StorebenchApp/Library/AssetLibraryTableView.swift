import StorebenchCore
import SwiftUI

struct AssetLibraryAssetsCard: View {
    let account: Account, appId: String, session: WorkspaceSession?
    let rows: [AssetLibraryTable.Row]
    let fresh, working, read: Bool
    @Binding var selectedIDs: Set<String>
    let open: (AssetLibrary.Asset) -> Void
    let selectionChanged: () -> Void
    @State private var filters = AssetLibraryTable.Filters()
    @State private var shownFilters: [String] = []
    @State private var sortColumn: AssetLibraryTable.Column = .modified
    @State private var descending = true
    @State private var layout = "list"
    @State private var editing = false
    private struct Choices: Equatable { var filters: AssetLibraryTable.Filters; var shownFilters: [String]; var sortColumn: AssetLibraryTable.Column; var descending: Bool; var layout: String }
    private static let rowHeight = 84.0, thumbnailHeight = 60.0, visibleRows = 8
    private var shown: [AssetLibraryTable.Row] { AssetLibraryTable.sorted(AssetLibraryTable.filtered(rows, filters), by: sortColumn, descending: descending) }
    private var columns: [AssetLibraryTable.Column] { AssetLibraryTable.Column.allCases }
    static func reviewable(_ asset: AssetLibrary.Asset) -> Bool { ["PREPARE_FOR_SUBMISSION", "REJECTED"].contains(asset.state) }

    var body: some View {
        let shown = shown
        Card(title: "Assets (\(shown.count))", subtitle: "Processing and review states come from Apple. Live Version is the version Ready for Distribution when the asset was last modified, from saved imports and Apple's current versions; anything the history cannot settle stays unknown.", actions: AnyView(
            HStack(spacing: StorebenchTheme.space(2)) {
                StorebenchChoicePicker("View", selection: $layout, options: [("list", "List"), ("grid", "Grid")]).labelsHidden().environment(\.fieldHintHeight, 0)
                Button(editing ? "Done" : "Edit") { editing.toggle(); if !editing { selectionChanged() } }
                    .help(editing ? "Finish selecting assets" : "Select assets for App Review").accessibilityLabel(editing ? "Done Selecting" : "Edit Selection")
            }.storebenchWorking(working)
        )) {
            filterBar
            if editing { Text("\(selectedIDs.count) assets selected. Only processed assets that are Prepare for Submission or Rejected can be selected.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            if !read { Text("Choose Refresh to list Apple's assets.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else if shown.isEmpty { Text(rows.isEmpty ? "No assets in Asset Library." : "No assets match these filters.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else if layout == "grid" { grid(shown) }
            else { table(shown) }
        }
        .historyValue("asset-table", Binding(get: { Choices(filters: filters, shownFilters: shownFilters, sortColumn: sortColumn, descending: descending, layout: layout) }, set: { value in
            filters = value.filters; shownFilters = value.shownFilters; sortColumn = value.sortColumn; descending = value.descending; layout = value.layout
        }))
    }

    private var filterBar: some View {
        let choices = AssetLibraryTable.choices(rows)
        return StorebenchFlow(spacing: StorebenchTheme.space(2)) {
            StorebenchMenu("Type: " + (AssetLibrary.Category(rawValue: filters.type)?.label ?? "All"), icon: "apps") {
                option("All", chosen: filters.type.isEmpty) { filters.type = "" }
                ForEach(AssetLibrary.Category.allCases, id: \.self) { category in option(category.label, chosen: filters.type == category.rawValue) { filters.type = category.rawValue } }
            }
            StorebenchMenu("Status: " + (filters.status.isEmpty ? "All" : AppStoreNames.state(filters.status)), icon: "progress") {
                option("All", chosen: filters.status.isEmpty) { filters.status = "" }
                ForEach(AssetLibraryTable.statuses, id: \.self) { code in option(AppStoreNames.state(code), chosen: filters.status == code) { filters.status = code } }
            }
            if shownFilters.contains("worksWith") {
                StorebenchMenu("Works With: " + (filters.worksWith.isEmpty ? "All" : AppStoreNames.placementType(filters.worksWith)), icon: "screenshots") {
                    option("All", chosen: filters.worksWith.isEmpty) { filters.worksWith = "" }
                    ForEach(choices.worksWith, id: \.self) { code in option(AppStoreNames.placementType(code), chosen: filters.worksWith == code) { filters.worksWith = code } }
                    Button("Remove Filter") { filters.worksWith = ""; shownFilters.removeAll { $0 == "worksWith" } }
                }
            }
            if shownFilters.contains("size") {
                StorebenchMenu("Size: " + (filters.size.isEmpty ? "All" : filters.size), icon: "resize") {
                    option("All", chosen: filters.size.isEmpty) { filters.size = "" }
                    ForEach(choices.sizes, id: \.self) { size in option(size, chosen: filters.size == size) { filters.size = size } }
                    Button("Remove Filter") { filters.size = ""; shownFilters.removeAll { $0 == "size" } }
                }
            }
            if shownFilters.contains("media") {
                StorebenchMenu("Media: " + (filters.media.isEmpty ? "All" : filters.media == "image" ? "Images" : "Videos"), icon: "display") {
                    option("All", chosen: filters.media.isEmpty) { filters.media = "" }
                    option("Images", chosen: filters.media == "image") { filters.media = "image" }
                    option("Videos", chosen: filters.media == "video") { filters.media = "video" }
                    Button("Remove Filter") { filters.media = ""; shownFilters.removeAll { $0 == "media" } }
                }
            }
            if shownFilters.count < 3 {
                StorebenchMenu("Add Filters", icon: "plus") {
                    if !shownFilters.contains("worksWith") { Button("Works With") { shownFilters.append("worksWith") } }
                    if !shownFilters.contains("size") { Button("Size") { shownFilters.append("size") } }
                    if !shownFilters.contains("media") { Button("Media") { shownFilters.append("media") } }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func option(_ title: String, chosen: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { if chosen { StorebenchLabel(title, icon: "check", size: 14) } else { Text(title) } }
    }

    private func table(_ shown: [AssetLibraryTable.Row]) -> some View {
        let selection = editing ? 1 : 0
        let minimum = (editing ? [52.0] : []) + [300, 90, 170, 130, 190, 260]
        return StorebenchTableFrame {
            StorebenchResizableTableViewport(key: editing ? "asset-library-edit" : "asset-library", minimum: minimum, weights: (editing ? [0] : []) + [3, 0, 1, 1, 1, 2],
                height: DataTablePresentation.headerHeight + Double(min(shown.count, Self.visibleRows)) * Self.rowHeight, fixed: editing ? [0] : []) { widths, resize in
                LazyVStack(alignment: .leading, spacing: 0) {
                    StorebenchTableHeader(columns: (editing ? [("Select", CGFloat(widths[0]))] : []) + columns.indices.map { (columns[$0].title, CGFloat(widths[$0 + selection])) },
                        resize: resize, fixed: editing ? [0] : [], capitals: true, sortable: Set(columns.indices.map { $0 + selection }),
                        sorted: columns.firstIndex(of: sortColumn).map { ($0 + selection, descending) },
                        sort: { index in choose(columns[index - selection]) })
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        StorebenchTableRow(index: index, height: Self.rowHeight) {
                            if editing { selectCell(row.asset).frame(width: widths[0]) }
                            nameCell(row).frame(width: widths[selection], height: Self.rowHeight - 1)
                            textCell(row.sizeText, title: "Size", width: widths[1 + selection])
                            textCell(row.worksWithText, title: "Works With", width: widths[2 + selection])
                            textCell(row.modifiedText, title: "Modified", width: widths[3 + selection])
                            StorebenchStateLabel(code: row.asset.state).padding(.horizontal, 12).frame(width: widths[4 + selection], alignment: .leading)
                            StorebenchTableValue(text: row.version.detail, title: "Live Version", summary: row.version.summary, lines: 3)
                                .foregroundStyle(row.version.known ? StorebenchTheme.ink : StorebenchTheme.muted).frame(width: widths[5 + selection], height: Self.rowHeight - 1)
                        }
                    }
                }.frame(width: widths.reduce(0, +), alignment: .leading)
            }.accessibilityLabel("Assets")
        }
    }
    private func choose(_ column: AssetLibraryTable.Column) {
        if sortColumn == column { descending.toggle() } else { sortColumn = column; descending = column == .modified }
    }
    private func textCell(_ text: String, title: String, width: Double) -> some View {
        Text(text).font(.sbCallout).monospacedDigit().foregroundStyle(StorebenchTheme.ink).lineLimit(3).help(text)
            .padding(.horizontal, 12).frame(width: width, alignment: .leading).accessibilityLabel(title + ": " + text)
    }
    private func nameCell(_ row: AssetLibraryTable.Row) -> some View {
        HStack(spacing: 12) {
            Button { open(row.asset) } label: {
                AppleLibraryThumbnail(account: account, appId: appId, asset: row.asset, session: session, fresh: fresh, height: Self.thumbnailHeight)
                    .frame(width: 96).background(StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(StorebenchControlOutline(border: .clear))
            }.buttonStyle(StorebenchPressStyle()).help("Open " + row.asset.name).accessibilityLabel("Open " + row.asset.name)
            Button { open(row.asset) } label: {
                Text(row.asset.name).font(.sbCallout).foregroundStyle(StorebenchTheme.accent).multilineTextAlignment(.leading).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(StorebenchPressStyle()).help(row.asset.name == row.asset.fileName ? row.asset.fileName : row.asset.name + "\n" + row.asset.fileName).accessibilityLabel(row.asset.name)
        }.padding(.horizontal, 12)
    }
    @ViewBuilder private func selectCell(_ asset: AssetLibrary.Asset) -> some View {
        let allowed = fresh && Self.reviewable(asset)
        StorebenchCheckbox("Select " + asset.name + " for review", isOn: Binding(get: { selectedIDs.contains(asset.id) }, set: { value in
            if value { if allowed { selectedIDs.insert(asset.id) } } else { selectedIDs.remove(asset.id) }; selectionChanged()
        })).opacity(allowed ? 1 : 0).allowsHitTesting(allowed).accessibilityHidden(!allowed)
    }

    private func grid(_ shown: [AssetLibraryTable.Row]) -> some View {
        StorebenchCollection(items: shown, title: { $0.asset.name }, subtitle: { $0.status }, maximumColumns: 4, cardSurface: false, initialOpeningLimit: -1, empty: "No assets match these filters.") { row in
            StorebenchAssetCard(title: row.asset.name == row.asset.fileName ? row.asset.name : row.asset.name + "\n" + row.asset.fileName,
                metadata: [row.sizeText, row.worksWithText, row.modifiedText, "Live Version: " + row.version.summary].joined(separator: " · "), status: row.status) {
                Button { open(row.asset) } label: {
                    AppleLibraryThumbnail(account: account, appId: appId, asset: row.asset, session: session, fresh: fresh).overlay(StorebenchControlOutline(border: .clear))
                }.buttonStyle(StorebenchPressStyle()).help("Open " + row.asset.name).accessibilityLabel("Open " + row.asset.name)
            } actions: {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                    Button("Open Asset") { open(row.asset) }.buttonStyle(StorebenchButtonStyle(.quiet, stretch: true))
                    if editing { selectCell(row.asset) }
                }
            }
        }
    }
}
