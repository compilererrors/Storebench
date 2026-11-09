import StorebenchCore
import SwiftUI

/// A pricing command that stays in place: dimmed with the reason while it cannot run, and showing its spinner while it runs.
/// One pricing change: its form, one command named as in App Store Connect, the next thing to fill in while it is dimmed, an Attention
/// panel for what stopped it, and its review right below the card. The command prepares the review; nothing is sent until it is approved.
struct PricingReviewCard<Form: View>: View {
    let title, subtitle: String
    var help = ""
    var command = "Sync to Apple"
    let account: Account, app: Account.App, session: WorkspaceSession?
    /// Why the review cannot be prepared now; nil when it can.
    let blocked: String?
    let request: () async throws -> PublishRequest
    var done: () -> Void = {}
    /// The review that follows once this one is sent, such as prices for products the first review created; nil when nothing follows.
    var followUp: (() async throws -> PublishRequest?)? = nil
    /// A second command before the main one that prepares its own review, such as Save beside Publish.
    var reviewIdentity = ""
    var secondary: (title: String, request: () async throws -> PublishRequest)? = nil
    @ViewBuilder let form: () -> Form
    @State private var review: PublishReview?
    @State private var preparing = false
    @State private var publishing = false
    @State private var problem = ""
    @State private var next = ""
    @State private var choice = ""

    private var unavailable: String? {
        if session == nil { return "Connect the workspace to read App Store Connect." }
        if publishing || review?.state == "running" { return "Wait for the review below to finish." }
        return blocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: title, subtitle: subtitle, help: help) {
                form().storebenchWorking(preparing || publishing)
                StorebenchFormFooter {
                    if let secondary {
                        StorebenchCommand(title: secondary.title, busy: preparing && choice == secondary.title, unavailable: preparing ? "Wait for the review to be prepared." : unavailable, primary: false) { Task { await prepare(using: secondary) } }
                    }
                    StorebenchCommand(title: command, busy: preparing && choice != secondary?.title, unavailable: preparing ? "Wait for the review to be prepared." : unavailable) { Task { await prepare() } }
                }
                // What to fill in next, in words beside the dimmed command rather than only on hover.
                StorebenchTextSlot(text: preparing || publishing ? "" : unavailable.map { "To continue: " + $0 } ?? "\(command) opens a review below. Nothing is sent to App Store Connect until you approve it.",
                                   height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                if followUp != nil { StorebenchTextSlot(text: next, height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
                if !problem.isEmpty {
                    StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                }
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { Task { await finished() } } }, busyChanged: { publishing = $0 }, syncConfirmation: choice == "Sync to Apple")
        }
        .onChange(of: reviewIdentity) { if review?.state == "prepared" { review = nil } }
    }

    /// After a sent review: refreshes the section, then prepares the review that follows, if any.
    private func finished() async {
        done()
        guard let followUp else { return }
        preparing = true
        do {
            let value = try await followUp()
            preparing = false
            if let value { next = "The next review is ready below. Approve it to finish."; await prepare(value) } else { next = "" }
        } catch {
            preparing = false
            problem = (error as? PublishFailure)?.message ?? "The next review could not be prepared. \(command) tries again."
        }
    }

    private func prepare(_ prepared: PublishRequest? = nil, using alternative: (title: String, request: () async throws -> PublishRequest)? = nil) async {
        guard let session, !preparing, prepared != nil || unavailable == nil else { return }
        preparing = true; choice = alternative?.title ?? command; defer { preparing = false }
        do {
            let value: PublishRequest
            if let prepared { value = prepared } else { value = try await (alternative?.request ?? request)(); next = "" }
            review = try await session.preparePublishing(account: account, request: value)
            problem = ""
        } catch let failure as PublishFailure { problem = failure.message }
        catch let failure as PricingFailure { problem = failure.message }
        catch is URLError { problem = "App Store Connect could not be reached. Nothing was sent; try again." }
        catch { problem = "The review could not be prepared. Nothing was sent to Apple." }
    }
}

struct PricingCountryPicker: View {
    var title = "Country or Region"
    let territories: [Territory]
    @Binding var selection: String
    var body: some View {
        StorebenchSearchPicker(title, selection: $selection) {
            SelectionOption("Choose a country or region", value: "")
            selectionOptions(territories) { SelectionOption("\($0.name) · \($0.currency)", value: $0.code) }
        }
    }
}

struct PricingLevelPicker: View {
    var title = "Price"
    let levels: [ProductPricePoint]?
    @Binding var selection: String
    var includeFree = true
    /// Why Apple's prices are not shown yet, such as a product still to choose; nil uses the general reason.
    var reason: String? = nil
    var body: some View {
        StorebenchSearchPicker(title, selection: $selection, hint: reason ?? (levels == nil ? "Reading Apple's prices…" : "\(levels!.count) Apple prices")) {
            SelectionOption("Choose a price", value: "")
            selectionOptions((levels ?? []).filter { includeFree || PricingMath.decimal($0.customerPrice ?? "").map { $0 > 0 } == true }) { level in
                SelectionOption(PricingMath.decimal(level.customerPrice ?? "") == 0 ? "Free" : "\(level.customerPrice ?? "Amount unknown") \(level.currency ?? "")", value: level.id)
            }
        }
    }
}

/// An Apple price amount in the base country or region, for products whose own price levels exist only after Apple creates them.
struct PricingAmountPicker: View {
    var title = "Price"
    let levels: [ProductPricePoint]?
    @Binding var selection: String
    var none: String? = nil
    var body: some View {
        StorebenchSearchPicker(title, selection: $selection, hint: levels == nil ? "Choose a country or region to read Apple's prices." : "Apple's prices in this country or region") {
            SelectionOption(none ?? "Choose a price", value: "")
            selectionOptions((levels ?? []).filter { PricingMath.decimal($0.customerPrice ?? "").map { $0 > 0 } == true }) { level in
                SelectionOption("\(level.customerPrice ?? "") \(level.currency ?? "")", value: level.customerPrice ?? "")
            }
        }
    }
}

/// The territories and one territory's price levels a pricing form chooses from, read from Apple when the form opens and when the country changes.
@MainActor @Observable final class PricingChoices {
    var territories: [Territory] = []
    var levels: [ProductPricePoint]?
    var reading = false
    var problem = ""
    private var readingTerritory = ""
    private var ticket = UUID()

    func loadTerritories(account: Account, session: WorkspaceSession?) async {
        guard territories.isEmpty, let session else { return }
        do { territories = try await session.territories(account: account) }
        catch { problem = ProductPricing.readProblem(error, reading: "Apple's countries and regions") }
    }

    func loadLevels(territory: String = "", _ read: @escaping @MainActor () async throws -> [ProductPricePoint]) async {
        let current = UUID(); ticket = current; levels = nil; reading = true; problem = ""; readingTerritory = territory
        defer { if ticket == current { reading = false } }
        // The shared read is read again in Core if a refresh elsewhere cancelled it, rather than leaving the menu empty.
        do { let value = try await read(); if ticket == current { levels = value } }
        catch { if ticket == current, !(error is CancellationError) { problem = ProductPricing.readProblem(error, reading: "Apple's prices for \(WorkspaceSession.countryName(territory))") } }
    }

    /// Why a price cannot be chosen yet; nil once the levels are read.
    func levelsBlocked(_ territory: String) -> String? {
        if territory.isEmpty { return "Choose a country or region to read Apple's prices." }
        if reading { return "Reading Apple's prices for \(WorkspaceSession.countryName(readingTerritory.isEmpty ? territory : readingTerritory))…" }
        if levels == nil { return problem.isEmpty ? "Apple's prices are not read yet." : problem }
        return nil
    }
}

/// A product list: Reference Name, Product ID, type and App Store Connect status.
struct PricingProductTable: View {
    let key: String
    let products: [PriceProduct]
    var groups = false
    var body: some View {
        let titles = (groups ? ["Subscription Group"] : []) + ["Reference Name", "Product ID", groups ? "Duration" : "Type", "Status"]
        StorebenchTableFrame {
            StorebenchResizableTableViewport(key: key, minimum: (groups ? [180] : []) + [200, 220, 170, 170], weights: (groups ? [1] : []) + [2, 2, 1, 1],
                                             height: DataTablePresentation.headerHeight + Double(max(1, products.count)) * ComponentLayout.tableRowHeight(lines: 2)) { columns, resize in
                VStack(alignment: .leading, spacing: 0) {
                    StorebenchTableHeader(columns: zip(titles, columns).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                    ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                        let offset = groups ? 1 : 0
                        StorebenchTableRow(index: index) {
                            if groups { StorebenchTableCell(text: product.group ?? "Unknown", width: columns[0], title: titles[0]) }
                            StorebenchTableCell(text: product.name, width: columns[offset], title: titles[offset])
                            StorebenchTableCell(text: product.productId, width: columns[offset + 1], title: titles[offset + 1])
                            StorebenchTableCell(text: groups ? PricingSetupChange.label(product.type, in: PricingSetupChange.subscriptionDurations) : PricingSetupChange.label(product.type, in: PricingSetupChange.purchaseTypes), width: columns[offset + 2], title: titles[offset + 2])
                            StorebenchTableCell(text: AppStoreNames.state(product.state), width: columns[offset + 3], title: titles[offset + 3])
                        }
                    }
                    if products.isEmpty {
                        Text(groups ? "No subscriptions yet." : "No in-app purchases yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                            .padding(.horizontal, 12).frame(width: columns.reduce(0, +), height: ComponentLayout.tableRowHeight(lines: 2), alignment: .leading)
                    }
                }.frame(width: columns.reduce(0, +), alignment: .leading)
            }
        }
    }
}

extension Date {
    /// The same calendar day in UTC, as Apple's price dates use.
    var pricingDay: String { ReportDay.format(self) }
}
