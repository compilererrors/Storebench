@testable import StorebenchCore
import Testing
@testable import StorebenchApp

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
