import StorebenchCore
import SwiftUI

struct SavedValueChange: Identifiable {
    let id, label, saved, edited: String
}

/// Shared presentation for reading and explicitly choosing an editor's next baseline.
struct LatestSaveReview: View {
    let busy: Bool
    var reading = false
    var hasEdits = true
    var available = true
    let changes: [SavedValueChange]?
    let note: String?
    let onRead: () -> Void
    let onKeep: (() -> Void)?
    let onUse: (() -> Void)?

    var body: some View {
        DisclosureGroup("Compare with latest saved values") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Read the latest save without changing your inputs. Compare it with your edits, then choose which values to keep. Nothing is saved by this comparison.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if available && (hasEdits || changes != nil) {
                    StorebenchActionGroup { StorebenchBusyButton(title: "Read Latest Save", loadingTitle: "Reading…", busy: busy || reading, action: onRead) }
                } else {
                    Text(available ? "No local edits to compare. The latest save is read only when you choose Read Latest Save." : "Load the saved editor first to compare changes.")
                        .font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }
                if let changes {
                    if changes.isEmpty { Text("Your inputs match the latest saved values.").foregroundStyle(StorebenchTheme.muted) }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(changes) { change in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(change.label).font(.sbHeadline)
                                        StorebenchReadOnlyText(title: "Saved", text: change.saved, field: change.id)
                                        StorebenchReadOnlyText(title: "Your edits", text: change.edited, field: change.id)
                                    }.font(.sbCallout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 220)
                    }
                    if let note { Text(note).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                    if onKeep != nil || onUse != nil {
                        StorebenchFormFooter {
                            if let onKeep { Button("Keep My Edits") { onKeep() } }
                            if let onUse { Button("Use Saved Values") { onUse() } }
                        }.storebenchWorking(busy)
                    }
                }
            }
        }
    }
}

enum PricingInputChanges {
    static func compare(_ saved: PricingProfileInputs, _ edited: PricingProfileInputs, identity: Bool) -> [SavedValueChange] {
        var fields: [(String, String, String, String)] = []
        if identity { fields += [("name", "Profile name", saved.name, edited.name), ("guide", "Guide country", saved.guideTerritory, edited.guideTerritory)] }
        fields += [("method", "Pricing method", PricingMethod.name(saved.method), PricingMethod.name(edited.method)), ("rounding", "Rounding", saved.effectiveRounding, edited.effectiveRounding)]
        func mix(_ input: PricingProfileInputs) -> String { input.effectiveMixMethod.isEmpty ? "No mix" : "\(input.mixShare)% \(PricingMethod.name(input.effectiveMixMethod))" }
        func rows(_ rows: [PricingProfileInputs.Override], _ unit: String) -> String { rows.map { "\($0.territory): \($0.percentage)\(unit)" }.joined(separator: "\n") }
        fields += [("mix", "Mix With", mix(saved), mix(edited)), ("floor", "Lowest price", saved.floor, edited.floor), ("ceiling", "Highest price", saved.ceiling, edited.ceiling)]
        fields.append(("countries", "Country percentages", rows(saved.overrides, "%"), rows(edited.overrides, "%")))
        fields.append(("index", "Your own index", rows(saved.indexRows, ""), rows(edited.indexRows, "")))
        return fields.filter { !$0.2.utf8.elementsEqual($0.3.utf8) }.map { SavedValueChange(id: $0.0, label: $0.1, saved: $0.2, edited: $0.3) }
    }
}

/// Reuses the same editable percentage rows for shared profiles and app-specific models.
/// Countries are chosen from Apple's fixed territory list, so a code can never be mistyped.
struct PricingInputFields: View {
    @Binding var inputs: PricingProfileInputs
    let identity: Bool
    private var method: PricingMethod? { inputs.pricingMethod }

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
            if identity {
                StorebenchTextField("Profile name", text: $inputs.name)
                StorebenchSearchPicker("Guide country", selection: $inputs.guideTerritory, hint: "The guide country stays at 100%.") { Self.territories(including: inputs.guideTerritory) }
            }
            StorebenchPicker("Method", selection: Binding(get: { inputs.method }, set: { inputs.choose(method: $0) }), hint: method?.explanation ?? "") { selectionOptions(PricingMethod.allCases) { SelectionOption($0.name, value: $0.rawValue) } }
            if method?.exactOnly != true { StorebenchPicker("Rounding", selection: $inputs.rounding) { selectionOptions(PricingRounding.allCases) { SelectionOption($0.name, value: $0.rawValue) } } }
            if method?.mixes == true {
                StorebenchFormGrid {
                    StorebenchPicker("Mix With", selection: $inputs.mixMethod, hint: "Blend in a second method, such as Currency conversion to soften an index.") {
                        SelectionOption("No mix", value: "")
                        selectionOptions(PricingMethod.allCases.filter { $0.mixes && $0 != method }) { SelectionOption($0.name, value: $0.rawValue) }
                    }
                    if !inputs.mixMethod.isEmpty { StorebenchTextField("Mixed-In Share (%)", text: $inputs.mixShare, hint: "Above 0 and below 100. 30 means 70% of the method and 30% of the mix.") }
                }
            }
            if method?.exactOnly != true {
                StorebenchFormGrid {
                    StorebenchTextField("Lowest Price (%)", text: $inputs.floor, hint: "Optional. Never below this share of the guide price converted at exchange rates.")
                    StorebenchTextField("Highest Price (%)", text: $inputs.ceiling, hint: "Optional. Never above this share of the guide price converted at exchange rates.")
                }
                rows(title: "Country percentages", description: method?.usesCountryPercentages == true
                     ? "The countries this method prices, each a percentage from 0 to 1,000 of the guide price, with up to two decimals."
                     : "Optional. Scales a country's price by a percentage from 0 to 1,000, with up to two decimals.",
                     empty: "No country percentages added.", unit: "%", kind: .percentages, values: $inputs.overrides, exclude: inputs.guideTerritory)
            }
            if inputs.usesOwnIndex {
                rows(title: "Your own index", description: "A value per country in its own currency. Prices scale by each country's value divided by the guide country's, so include the guide country.",
                     empty: "No index values added. Import a CSV file or add countries.", unit: "", kind: .index, values: $inputs.indexRows, exclude: nil)
            }
        }
    }

    /// Editable country rows with Add Country, Import CSV… and Copy CSV Format.
    private func rows(title: String, description: String, empty: String, unit: String, kind: PricingCSV.Kind, values: Binding<[PricingProfileInputs.Override]>, exclude: String?) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchDivider().padding(.vertical, StorebenchTheme.space(1))
            StorebenchHeader(stackAt: 420) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.sbHeadline)
                    Text(description).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            } actions: {
                if values.wrappedValue.count < 250 { Button { values.wrappedValue.append(.init(percentage: kind == .index ? "" : "100")) } label: { StorebenchLabel("Add Country", icon: "plus", size: 14) }.help("Add a country to \(title.lowercased())") }
            }
            PricingCSVButtons(kind: kind, territories: []) { values.wrappedValue = PricingProfileInputs.merge(values.wrappedValue, $0) }
            if values.wrappedValue.isEmpty { Text(empty).font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                VStack(spacing: StorebenchTheme.space(2)) {
                    ForEach(values) { $row in
                        let taken = Set(values.wrappedValue.filter { $0.id != row.id }.map(\.territory) + (exclude.map { [$0] } ?? []))
                        HStack(alignment: .center, spacing: StorebenchTheme.space(2)) {
                            StorebenchSearchPicker("Country", selection: $row.territory) { Self.territories(including: row.territory).filter { !taken.contains($0.value) } }.labelsHidden()
                            StorebenchTextField(kind == .index ? "Value" : "Percent", text: $row.percentage).labelsHidden().frame(width: 96)
                            if !unit.isEmpty { Text(unit).font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                            Button { values.wrappedValue.removeAll { $0.id == row.id } } label: { StorebenchIcon(name: "close", size: 14) }
                                .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Remove Country").accessibilityLabel("Remove " + WorkspaceSession.countryName(row.territory))
                        }
                    }
                }
            }
        }
    }

    /// Apple territories by English name. A saved three-letter code outside the list stays visible so it is never silently replaced.
    static func territories(including current: String) -> [SelectionOption<String>] {
        let codes = Set(Territories.alpha3.values).union(current.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil ? [] : [current])
        return codes.map { (code: $0, name: WorkspaceSession.countryName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { SelectionOption("\($0.name) · \($0.code)", value: $0.code) }
    }
}
