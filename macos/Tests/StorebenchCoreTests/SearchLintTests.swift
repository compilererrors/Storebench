import Foundation
import Testing
@testable import StorebenchCore

@Suite struct SearchLintTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func completeCleanupFindingsMatchTheActualPrimaryHelper() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/search-lint.json")))
        guard case .array(let cases)? = fixture["cases"] else { throw DraftFailure.invalid }
        #expect(cases.count == 88)
        for row in cases {
            let input = try #require(row["keywords"]?.text)
            let result = SearchLint(input, name: row["title"]?["name"]?.text ?? "", subtitle: row["title"]?["subtitle"]?.text ?? "")
            #expect(result.json == row["expected"], "Synthetic keyword input: \(input)")
            #expect(result.freedBytes >= 0)
        }
    }
    @Test func perLanguageChecksMarkWordFormsAsPossibleAndNeverRemoveThem() throws {
        // "news" is not the plural of "new"; "photos" may be another form of "photo" and stays in the cleaned list.
        let english = SearchLint("new,news,photo,photos,photo,studio", name: "Synthetic Studio", subtitle: "Studio for edits", locale: "en-US")
        #expect(english.findings.map(\.kind) == ["duplicate", "in-title", "plural"])
        #expect(english.findings.first { $0.kind == "plural" }?.certain == false && english.findings.first { $0.kind == "duplicate" }?.certain == true)
        #expect(english.cleaned == "new,news,photo,photos" && english.freedBytes == "photo,studio,".utf8.count)
        let lines = SearchLintPresentation.lines(english)
        #expect(lines.contains { $0.hasPrefix("Possible overlap: ") && !$0.contains("bytes") })
        #expect(english.nameAndSubtitle == ["studio"] && lines.contains { $0.contains("app name and subtitle both use studio") })
        // Other languages match exact repeats only; their word endings are not folded.
        let swedish = SearchLint("bild,bilder,bild", name: "Synthetic", subtitle: "", locale: "sv")
        #expect(swedish.findings.map(\.kind) == ["duplicate"] && swedish.cleaned == "bild,bilder")
        #expect(SearchLint("bild,bilder", locale: "sv").findings.isEmpty)
        // Without a language the earlier rules stay, as the saved fixtures expect.
        #expect(SearchLint("new,news").findings.map(\.kind) == ["plural"] && SearchLint("new,news").nameAndSubtitle.isEmpty)
    }
    @Test func anotherFormOfATitleWordIsOnlyAPossibleOverlapWhileExactTitleWordsAreRemoved() {
        for (name, subtitle) in [("Synthetic Photo", ""), ("Synthetic", "Quick photo edits")] {
            let lint = SearchLint("photos,sketch", name: name, subtitle: subtitle, locale: "en-US")
            #expect(lint.cleaned == "photos,sketch" && lint.freedBytes == 0)
            #expect(lint.findings.map(\.kind) == ["title-form"] && lint.findings[0].certain == false)
        }
        let exact = SearchLint("photo,sketch", name: "Synthetic Photo", locale: "en-US")
        #expect(exact.cleaned == "sketch" && exact.findings.map(\.kind) == ["in-title"] && exact.findings[0].certain)
        // Without a language the earlier rule still removes the other form, as the saved fixtures expect.
        #expect(SearchLint("photos,sketch", name: "Synthetic Photo").cleaned == "sketch")
    }
}
