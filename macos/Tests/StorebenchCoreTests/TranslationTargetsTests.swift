import Foundation
import Testing
@testable import StorebenchCore

/// The languages to translate into are a visible choice with a useful default, so Translate Languages can run at once.
@Suite struct TranslationTargetsTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func theVersionsOwnLanguagesAreChosenFirstThenTheLargestMarkets() {
        let all = StoreLocales.codes
        // A version with several languages fills those languages.
        #expect(TranslationTargets.initial(source: "en-US", inVersion: ["en-US", "de-DE", "fr-FR"], all: all) == ["de-DE", "fr-FR"])
        // A version with only its source language gets the largest App Store markets.
        let markets = TranslationTargets.initial(source: "en-US", inVersion: ["en-US"], all: all)
        #expect(markets == Set(TranslationTargets.topMarkets.filter(all.contains)) && !markets.contains("en-US"))
        // The source is never a target.
        #expect(!TranslationTargets.initial(source: "de-DE", inVersion: ["de-DE"], all: all).contains("de-DE"))
    }

    @Test func theFieldSaysWhatIsChosenInTitleCase() {
        #expect(TranslationTargets.summary([]) == "Choose Languages")
        #expect(TranslationTargets.summary(["de-DE"]) == StoreLocales.name("de-DE"))
        let two = TranslationTargets.summary(["de-DE", "fr-FR"]), many = TranslationTargets.summary(Set(TranslationTargets.topMarkets))
        #expect(two.contains(StoreLocales.name("de-DE")) && two.contains(StoreLocales.name("fr-FR")))
        #expect(many.hasSuffix("· \(TranslationTargets.topMarkets.count) Languages"), "\(many)")
    }
}
