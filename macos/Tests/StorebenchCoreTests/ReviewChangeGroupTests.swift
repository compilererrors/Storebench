import Foundation
import Testing
@testable import StorebenchCore

/// A review that adds several languages lists one entry per language, not two lines each with a locale code.
@Suite struct ReviewChangeGroupTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func eachLanguagesChangesAreOneEntryNamedByLanguage() {
        let labels = ["Add language · es-ES", "Add language · ja", "Add app information · es-ES", "Add app information · ja",
                      "Update version text · en-GB", "Set copyright", "Update app information · en-GB"]
        let groups = PublishingReviewPresentation.changeGroups(labels)
        #expect(groups.map(\.title) == ["\(StoreLocales.name("es-ES")) (es-ES) · New Language", "\(StoreLocales.name("ja")) (ja) · New Language",
                                        "\(StoreLocales.name("en-GB")) (en-GB) · 2 Changes", "Set Copyright"])
        #expect(groups[0].indices == [0, 2] && groups[2].indices == [4, 6] && groups[3].indices == [5])
        // Inside a language, each change is named without repeating the language, in Title Case.
        #expect(PublishingReviewPresentation.changeTitle("Add app information · es-ES", grouped: true) == "Add App Information")
        #expect(PublishingReviewPresentation.changeTitle("Update version text · en-GB", grouped: false) == "Update Version Text · \(StoreLocales.name("en-GB")) (en-GB)")
    }
}
