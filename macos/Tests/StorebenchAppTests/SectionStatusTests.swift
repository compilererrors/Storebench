@testable import StorebenchCore
import CoreText
import Foundation
import Testing
@testable import StorebenchApp

@MainActor @Suite struct ExplicitRefreshTests {
    init() throws { _ = try TestIsolation.require() }
    private actor Source {
        var reads = 0
        func read() -> Data { reads += 1; return Data(String(reads).utf8) }
    }
    @Test func aReadButtonReplacesCachedAnswersButAPassiveReadSharesThem() async throws {
        let cache = AppStoreReadCache(), source = Source()
        let first = try await cache.read("synthetic-refresh") { await source.read() }
        let passive = try await cache.read("synthetic-refresh") { await source.read() }
        let passiveReads = await source.reads
        #expect(first == Data("1".utf8) && passive == first && passiveReads == 1)
        var refreshed: Data?
        await StorebenchReadButton.perform {
            do { refreshed = try await cache.read("synthetic-refresh") { await source.read() } }
            catch { Issue.record("An explicit synthetic refresh unexpectedly failed") }
        }
        let refreshedReads = await source.reads
        #expect(refreshed == Data("2".utf8) && refreshedReads == 2)
        #expect(AppStoreReadCache.refreshedSince == nil)
    }
}

@MainActor @Suite struct PricingInputChangesTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func comparisonDescribesTheMixThatSavingUses() throws {
        let base = PricingProfileInputs(PricingProfile(id: "synthetic", name: "Synthetic", guideTerritory: "USA", rounding: "nearest", method: "same", percentages: [:]))
        var edited = base
        edited.mixMethod = "fx"; edited.mixShare = "25"
        #expect(try edited.validated().mix == nil)
        #expect(PricingInputChanges.compare(base, edited, identity: true).isEmpty)
        edited.method = "ppp"
        let changes = PricingInputChanges.compare(base, edited, identity: true)
        let mix = try #require(changes.first { $0.id == "mix" })
        #expect(mix.saved == "No mix" && mix.edited == "25% Currency conversion")
        #expect(try edited.validated().mix == PricingMix(method: "fx", share: 25))
        edited.choose(method: "fx")
        #expect(!PricingInputChanges.compare(base, edited, identity: true).contains { $0.id == "mix" })
        #expect(try edited.validated().mix == nil)
    }

    @Test func comparisonLeavesUnusedCountryAdjustmentsAndIndexesOut() throws {
        let saved = PricingProfileInputs(PricingProfile(id: "synthetic", name: "Synthetic", guideTerritory: "USA", rounding: "nearest", method: "same", percentages: [:]))
        var edited = saved
        edited.overrides = [.init(territory: "", percentage: "unfinished")]
        edited.floor = "unfinished"; edited.ceiling = "unfinished"
        edited.indexRows = [.init(territory: "", percentage: "unfinished")]
        #expect(PricingInputChanges.compare(saved, edited, identity: true).isEmpty)
        #expect(try edited.validated().percentages.isEmpty)
        edited.choose(method: "ppp")
        #expect(Set(PricingInputChanges.compare(saved, edited, identity: true).map(\.id)) == Set(["method", "rounding", "floor", "ceiling", "countries"]))
    }
}

@MainActor @Suite struct MediaCardPreviewRequestTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aTextOnlyCardRendersWhenItsFontArrivesWithoutAScreenshot() async throws {
        let url = try #require(CTFontCopyAttribute(CTFontCreateWithName("Helvetica" as CFString, 12, nil), kCTFontURLAttribute) as? URL)
        let font = try Data(contentsOf: url)
        var card = MediaCard(); card.layout = .textOnly; card.title = "Synthetic title"
        card.style.typeface = .file; card.style.fontFile = .init(hash: String(repeating: "a", count: 64), name: "Synthetic.ttc", family: "Helvetica")
        let before = MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: false, fontLoaded: false)
        let after = MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: false, fontLoaded: true)
        #expect(before != after && !before.ready && after.ready)
        await #expect(throws: MediaCardFailure.font) { _ = try await MediaCardRenderer.previewAsync(card, width: 1320, height: 2868, screenshot: nil) }
        let rendered = try await MediaCardRenderer.previewAsync(card, width: 1320, height: 2868, screenshot: nil, font: font)
        #expect(rendered.image.width > 0 && rendered.image.height > 0)
    }

    @Test func imageAndFontCanArriveInEitherOrderAndTextOnlyDoesNotWaitForUnusedMedia() {
        var card = MediaCard()
        card.screenshot = .init(hash: String(repeating: "a", count: 64), name: "Synthetic.png", width: 1290, height: 2796)
        card.style.typeface = .file; card.style.fontFile = .init(hash: String(repeating: "b", count: 64), name: "Synthetic.ttc", family: "Synthetic")
        let imageOnly = MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: true, fontLoaded: false)
        let fontOnly = MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: false, fontLoaded: true)
        let ready = MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: true, fontLoaded: true)
        #expect(!imageOnly.ready && !fontOnly.ready && ready.ready && imageOnly != ready && fontOnly != ready)
        card.layout = .textOnly
        #expect(MediaCardPreviewRequest(card: card, width: 1320, height: 2868, screenshotLoaded: false, fontLoaded: true).ready)
    }
}

/// A section App Store Connect could not show now keeps its last answer as older information; a price read that failed is not done.
@MainActor @Suite struct SectionStatusTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aSectionThatCannotBeReadNowShowsItsLastAnswerAsOlder() {
        let saved = SectionCheck(area: .pricing, answered: true, detail: "4.99 USD", checkedAt: "2026-01-02T03:04:05Z")
        let price = AppleProblemsView.Now.lastKnown(saved, reason: "The price could not be read from App Store Connect.", counts: false)
        #expect(!price.done && price.text.contains("last read") && price.text.hasSuffix("The price could not be read from App Store Connect."))
        let privacy = AppleProblemsView.Now.lastKnown(SectionCheck(area: .privacy, answered: true, detail: "Published", checkedAt: "2026-01-02T03:04:05Z"),
                                                      reason: "The Apple ID is signed out.", counts: true)
        #expect(privacy.done && privacy.text.contains("last read"))
        let never = AppleProblemsView.Now.lastKnown(nil, reason: "The price could not be read from App Store Connect.", counts: true)
        #expect(!never.done && never.text == "Not checked: The price could not be read from App Store Connect.")
    }
}

@MainActor @Suite struct TestFlightRefreshStatusTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aFailedRefreshIsShownAboveTheLastCheckUntilAReadSucceeds() {
        #expect(TestFlightGuideView.refreshStatus(problem: "", reading: true) == "Checking App Store Connect for changes…")
        let failed = TestFlightGuideView.refreshStatus(problem: "TestFlight could not be read from App Store Connect.", reading: false)
        #expect(failed.hasPrefix("The latest refresh failed") && failed.hasSuffix("TestFlight could not be read from App Store Connect."))
        #expect(TestFlightGuideView.refreshStatus(problem: "", reading: false).isEmpty)
    }
}

@MainActor @Suite struct PricePreviewTicketTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aPreviewThatArrivesAfterTheInputsChangedIsNotShown() {
        let model = PriceStrategyModel()
        model.strategy = .manual; model.typed = ["USA": "4.99"]
        let started = model.ticket(.subscription("sub-1"), base: "USA")
        // The price changes while the calculation waits for Apple: its late answer must not come back as the preview.
        model.typed = ["USA": "5.99"]
        model.accept((rows: [], warnings: [], points: ["USA": "point-499"]), for: started)
        #expect(model.preview == nil && model.previewed == nil)
        #expect(model.blocked(base: "USA") == "Enter the prices, then Preview Prices.")

        let current = model.ticket(.subscription("sub-1"), base: "USA")
        model.accept((rows: [], warnings: [], points: ["USA": "point-599"]), for: current)
        #expect(model.preview?.points == ["USA": "point-599"] && model.blocked(base: "USA") == nil)
        // A preview made for another base country is not used for this one.
        #expect(model.blocked(base: "FRA") == "Enter the prices, then Preview Prices.")
        model.invalidate()
        #expect(model.preview == nil && !model.current(current))
    }
}

@Suite struct AppleIDStorageTextTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func theCardNamesTheStorageChosenForTheWorkspace() {
        let keychain = AppleIDStorageText(passwordFile: false), file = AppleIDStorageText(passwordFile: true)
        #expect(keychain.subtitle.contains("your Mac Keychain") && keychain.signedIn == "Signed in. The session is kept in your Mac Keychain.")
        for text in [file.subtitle, file.saveHelp, file.signedIn, file.passwordNotRemoved, file.sessionNotRemoved, file.passwordHint(saving: true)] {
            #expect(text.contains("Storebench's password-protected storage") && !text.contains("Keychain"))
        }
        #expect(file.passwordHint(saving: false) == "Used to sign in; not stored.")
    }
}

@MainActor @Suite struct ReadyReviewsTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func theBarNamesTheFirstReadyReviewAndLeavesWhenItIsSentOrDiscarded() {
        let reviews = ReadyReviews()
        reviews.update(id: "synthetic-1", title: "Create macOS version 1.10", state: "prepared")
        reviews.update(id: "synthetic-2", title: "Text for 1.10", state: "prepared")
        #expect(ReadyReviews.text(reviews.entries) == "Ready to send · Create macOS version 1.10 · 1 more")
        reviews.update(id: "synthetic-1", title: "Create macOS version 1.10", state: "running")
        #expect(ReadyReviews.text(reviews.entries) == "Sending · Create macOS version 1.10 · 1 more")
        reviews.update(id: "synthetic-1", title: "Create macOS version 1.10", state: "complete")
        #expect(ReadyReviews.text(reviews.entries) == "Ready to send · Text for 1.10")
        reviews.show("synthetic-2"); let first = reviews.shown?.request
        reviews.show("synthetic-2")
        #expect(reviews.shown?.id == "synthetic-2" && reviews.shown?.request != first)
        reviews.remove("synthetic-2")
        #expect(reviews.entries.isEmpty && ReadyReviews.text(reviews.entries).isEmpty)
    }
}
