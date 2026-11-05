import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Views open in their final layout: while data is read they draw the same structure as bars, so filling it in
/// moves nothing. Loading and loaded measure the same height, and a failure keeps at least that footprint.
@MainActor @Suite struct PlaceholderRenderTests {
    init() throws { _ = try TestIsolation.require() }

    private let measurements: [CGSize] = [CGSize(width: CGFloat.infinity, height: .infinity), .zero, CGSize(width: 1, height: 1),
                                          CGSize(width: 320, height: CGFloat.infinity), CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1440, height: 900)]
    private let placements: [ProposedViewSize] = [.unspecified, .zero, ProposedViewSize(width: 1, height: nil), ProposedViewSize(width: 320, height: nil), ProposedViewSize(width: 1440, height: 900)]

    private func capture<V: View>(_ name: String, _ view: V) {
        let host = NSHostingController(rootView: view)
        for size in measurements {
            let fitted = host.sizeThatFits(in: size)
            #expect(!fitted.width.isNaN && !fitted.height.isNaN, "\(name) measured \(fitted) for \(size)")
            #expect(!size.height.isFinite || fitted.height.isFinite, "\(name) measured \(fitted) for \(size)")
        }
        for proposal in placements {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = proposal; renderer.scale = 1
            let image = renderer.cgImage
            if proposal.width == 320 { #expect(image != nil, "\(name) did not render at \(proposal)") }
        }
    }
    private func height<V: View>(_ view: V, width: CGFloat = 900) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: CGFloat.infinity)).height
    }

    private func buildStep() -> some View {
        Group {
            StorebenchPicker("Build to submit", selection: .constant("")) { SelectionOption("Choose a build", value: "") }.frame(maxWidth: 420)
            StorebenchActionGroup { Button("Refresh Builds") {} }
        }
    }

    @Test func loadingShowsOneStatusLineInsteadOfStandIns() {
        // The real card shows at once; while its data is read only a status line of fixed height stands inside it.
        for width: CGFloat in [320, 900] {
            let empty = height(Card(title: "Synthetic build", subtitle: "Synthetic") { EmptyView() }, width: width)
            let loading = height(Card(title: "Synthetic build", subtitle: "Synthetic") { StorebenchLoadState(state: .loading("Reading builds…")) { buildStep() } placeholder: { buildStep() } }, width: width)
            let longer = height(Card(title: "Synthetic build", subtitle: "Synthetic") { StorebenchLoadState(state: .loading("Reading builds from App Store Connect…")) { buildStep() } placeholder: { buildStep() } }, width: width)
            let failed = height(Card(title: "Synthetic build", subtitle: "Synthetic") { StorebenchLoadState(state: .failed("Synthetic failure", retry: {})) { buildStep() } placeholder: { buildStep() } }, width: width)
            #expect(loading > empty && loading - empty <= StorebenchLoadPhase.statusHeight + StorebenchTheme.gap + 1, "At \(width), loading measured \(loading)")
            #expect(abs(longer - loading) < 1, "At \(width), a longer status changed the height")
            #expect(failed > empty, "At \(width), failure measured \(failed)")
        }
        capture("loading placeholder", StorebenchLoadState(state: .loading("Reading builds…")) { buildStep() } placeholder: { buildStep() })
        capture("failed placeholder", StorebenchLoadState(state: .failed("Synthetic failure", retry: {})) { buildStep() } placeholder: { buildStep() })
    }

    @Test func placeholdersKeepTheirViewsSize() {
        let card = Card(title: "Synthetic", subtitle: "Synthetic description") { StorebenchMetricGrid { ForEach(0..<4, id: \.self) { Fact(title: "Synthetic \($0)", value: "12") } } }
        #expect(abs(height(card) - height(card.storebenchPlaceholder())) < 1)
        #expect(abs(height(card) - height(card.storebenchLoading("Reading saved reports…"))) < 1)
        #expect(abs(height(card) - height(card.storebenchLoading(nil))) < 1)
        capture("loading in place", card.storebenchLoading("Reading saved reports…"))
    }

    @Test func recordListsBeingReadShowOneStatusLine() {
        // However many records will follow, the list being read is one status line, not stand-in rows.
        let one = height(StorebenchCardList(padded: true) { StorebenchCollectionPlaceholder(rows: 1, icon: true) })
        let many = height(StorebenchCardList(padded: true) { StorebenchCollectionPlaceholder(rows: 10, icon: false) })
        #expect(abs(one - many) < 1)
        capture("collection placeholder", StorebenchCollectionPlaceholder(rows: 3, icon: true))
        capture("placeholder card", StorebenchPlaceholderCard(rows: 4))
    }

    @Test func reportPlaceholdersRender() {
        capture("sales placeholder", SalesAnalysisView.placeholder(filters: AnyView(Text("Synthetic filters")), actions: nil))
        capture("analytics placeholder", AnalyticsActivityView.placeholder(filters: AnyView(Text("Synthetic filters")), actions: nil))
        capture("finance placeholder", FinancialActivityView.placeholder())
    }

    @Test func releaseGuideOpensInItsFinalLayout() {
        let rail = ReleaseStepRail(guide: ReleaseGuide.guide(nil), selected: "plan") { _ in }
        #expect(abs(height(rail, width: 248) - height(rail.storebenchPlaceholder(), width: 248)) < 1)
        let account = Account(id: "synthetic-account", name: "Synthetic account", keyId: "SYNTHETIC", keyType: "team", issuerId: nil, appIds: ["1000000001"], appNames: nil)
        let guide = ReleaseWizardView(account: account, app: account.apps[0], session: nil, changed: {}, openCancellation: { _ in }, scrollTo: { _, _ in })
        #expect(height(guide, width: 1200) >= height(rail, width: 248), "The guide shows every step while it reads")
        capture("release guide before reading", guide)
    }
}
