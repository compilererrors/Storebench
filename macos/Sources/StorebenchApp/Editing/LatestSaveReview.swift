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
        fields += [("method", "Pricing method", saved.method, edited.method), ("rounding", "Rounding", saved.method == "same" ? "exact" : saved.rounding, edited.method == "same" ? "exact" : edited.rounding)]
        func percentages(_ input: PricingProfileInputs) -> String { input.overrides.map { "\($0.territory): \($0.percentage)%" }.joined(separator: "\n") }
        fields.append(("countries", "Country percentages", percentages(saved), percentages(edited)))
        return fields.filter { !$0.2.utf8.elementsEqual($0.3.utf8) }.map { SavedValueChange(id: $0.0, label: $0.1, saved: $0.2, edited: $0.3) }
    }
}

/// Reuses the same editable percentage rows for shared profiles and app-specific models.
/// Countries are chosen from Apple's fixed territory list, so a code can never be mistyped.
struct PricingInputFields: View {
    @Binding var inputs: PricingProfileInputs
    let identity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
            if identity {
                StorebenchTextField("Profile name", text: $inputs.name)
                StorebenchSearchPicker("Guide country", selection: $inputs.guideTerritory, hint: "The guide country stays at 100%.") { Self.territories(including: inputs.guideTerritory) }
            }
            StorebenchPicker("Method", selection: $inputs.method) { selectionOptions(PricingProfile.methods) { SelectionOption($0.1, value: $0.0) } }
            if inputs.method != "same" { StorebenchPicker("Rounding", selection: $inputs.rounding) { selectionOptions(PricingProfile.roundings) { SelectionOption($0.1, value: $0.0) } } }
            if identity || inputs.method == "custom" {
                StorebenchDivider().padding(.vertical, StorebenchTheme.space(1))
                StorebenchHeader(stackAt: 420) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Country percentages").font(.sbHeadline)
                        Text("A percentage from 0 to 1,000 of the guide country price, with up to two decimals. Each country can appear once.")
                            .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                } actions: {
                    if inputs.overrides.count < 250 { Button { inputs.overrides.append(.init()) } label: { StorebenchLabel("Add Country", icon: "plus", size: 14) }.help("Add a country percentage") }
                }
                if inputs.overrides.isEmpty { Text("No country percentages added.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                else {
                    VStack(spacing: StorebenchTheme.space(2)) {
                        ForEach($inputs.overrides) { $row in
                            let taken = Set(inputs.overrides.filter { $0.id != row.id }.map(\.territory) + [inputs.guideTerritory])
                            HStack(alignment: .center, spacing: StorebenchTheme.space(2)) {
                                StorebenchSearchPicker("Country", selection: $row.territory) { Self.territories(including: row.territory).filter { !taken.contains($0.value) } }.labelsHidden()
                                StorebenchTextField("Percent", text: $row.percentage).labelsHidden().frame(width: 84)
                                Text("%").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                                Button { inputs.overrides.removeAll { $0.id == row.id } } label: { StorebenchIcon(name: "close", size: 14) }
                                    .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Remove Country").accessibilityLabel("Remove " + WorkspaceSession.countryName(row.territory))
                            }
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
