import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct HelpCatalogTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/help-catalog.json"))) }
    @Test func everyTopicQuestionLinkAndSearchMatchesWeb() throws {
        let fixture = try fixture(), catalog = try HelpCatalog(data: #require(fixture["catalog"]).data)
        #expect(catalog.json == fixture["catalog"])
        #expect(catalog.topics.count == 36 && catalog.topics.reduce(0) { $0 + $1.questions.count } == 183)
        guard case .array(let search)? = fixture["search"] else { throw HelpCatalog.Failure.invalid }
        for row in search { #expect(JSONText.array(catalog.matching(try #require(row["query"]?.text)).map { .string($0.id) }) == row["ids"], "Synthetic help query \(row["query"]?.text ?? "unknown")") }
        #expect(throws: HelpCatalog.Failure.invalid) { try HelpCatalog(data: Data(#"{"schemaVersion":1,"topics":[]}"#.utf8)) }
        var data = try #require(fixture["catalog"])
        guard case .array(let original)? = data["topics"], let first = original.first else { throw HelpCatalog.Failure.invalid }
        data = .object([("schemaVersion", .number(1)), ("topics", .array([first, first]))])
        #expect(throws: HelpCatalog.Failure.invalid) { try HelpCatalog(data: data.data) }
        let unsafe = first.stringify().replacingOccurrences(of: "https://", with: "file://")
        #expect(throws: HelpCatalog.Failure.invalid) { try HelpCatalog(data: JSONText.object([("schemaVersion", .number(1)), ("topics", .array([try JSONText.parse(Data(unsafe.utf8))]))]).data) }
        let literal = JSONText.object([("schemaVersion", .number(1)), ("topics", .array([.object([
            ("id", .string("synthetic-literal")), ("title", .string("Synthetic Café")), ("summary", .string("Synthetic literal text")),
            ("links", .array([])), ("questions", .array([.array([.string("Synthetic question"), .string("Synthetic answer")])]))])]))])
        let text = try HelpCatalog(data: literal.data)
        #expect(text.matching("CAFÉ").count == 1 && text.matching("cafe\u{301}").isEmpty)
    }
    @Test func literalSearchPreservesUtf8BoundariesOverlapsAndLongPatterns() throws {
        let samples = ["a", "aaaaabaaaaac", "abababababaca", "Synthetic Café cafe\u{301} 🧪", "a[b].*?", String(repeating: "b", count: 160) + "end"]
        let rows = samples.enumerated().map { index, sample in
            JSONText.object([("id", .string("synthetic-\(index)")), ("title", .string("Synthetic topic")), ("summary", .string(sample)),
                             ("links", .array([])), ("questions", .array([.array([.string("Synthetic question"), .string("Synthetic answer")])]))])
        }
        let catalog = try HelpCatalog(data: JSONText.object([("schemaVersion", .number(1)), ("topics", .array(rows))]).data)
        var queries = ["", "a", "aaaaac", "abaca", "CAFÉ", "cafe\u{301}", "🧪", "[b].*?", "absent", "\0", String(repeating: "b", count: 64), String(repeating: "b", count: 65), String(repeating: "b", count: 160) + "end"]
        for sample in samples {
            let characters = Array(sample)
            for start in characters.indices {
                for length in 1...min(6, characters.count - start) { queries.append(String(characters[start..<(start + length)])) }
            }
        }
        for query in queries {
            let normalized = TextSemantics.trim(query).lowercased(), bytes = Data(normalized.utf8)
            let expected = catalog.topics.filter { topic in
                let text = ([topic.title, topic.summary] + topic.questions.flatMap { [$0.question, $0.answer] }).joined(separator: " ").lowercased()
                return normalized.isEmpty || Data(text.utf8).range(of: bytes) != nil
            }.map(\.id)
            #expect(catalog.matching(query).map(\.id) == expected)
        }
    }
    @Test func supportOpensThePackagedSupportPageOnly() throws {
        let contact = try SupportContact(website: "https://synthetic.example.test", support: "https://synthetic.example.test/support#support", version: "1.2.3")
        #expect(contact.about.absoluteString == "https://synthetic.example.test/#about" && contact.support.absoluteString == "https://synthetic.example.test/support#support")
        #expect(try SupportContact(info: ["StorebenchSupportWebsite": contact.website, "StorebenchSupportURL": contact.support.absoluteString, "CFBundleShortVersionString": contact.version]) == contact)
        // A packaged app from before the support page names only an email, so it shows no support link rather than a guessed one.
        #expect(throws: HelpCatalog.Failure.unavailable) { try SupportContact(info: ["StorebenchSupportEmail": "synthetic@example.invalid", "StorebenchSupportWebsite": contact.website, "CFBundleShortVersionString": "1.2.3"]) }
        #expect(throws: HelpCatalog.Failure.invalid) { try SupportContact(website: contact.website, support: "http://synthetic.example.test/support", version: contact.version) }
        #expect(throws: HelpCatalog.Failure.invalid) { try SupportContact(website: contact.website, support: "https://synthetic.example.test/support?code=SB-SYNTHETIC", version: contact.version) }
        #expect(throws: HelpCatalog.Failure.invalid) { try SupportContact(website: "file:///synthetic", support: contact.support.absoluteString, version: contact.version) }
    }
    @Test func aPackagedResourceIsFoundWithoutADevelopmentBuildPath() throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-help-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Synthetic.app"), resources = app.appendingPathComponent("Contents/Resources"), bundle = resources.appendingPathComponent("Storebench_StorebenchCore.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info: [String: String] = ["CFBundleIdentifier": "test.synthetic.help", "CFBundlePackageType": "APPL", "CFBundleName": "Synthetic Help"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let data = try #require(fixture()["catalog"]).data
        try data.write(to: bundle.appendingPathComponent("help-topics.json"))
        let application = try #require(Bundle(url: app))
        #expect(try HelpCatalog.bundled(in: application).json == HelpCatalog(data: data).json)
        try FileManager.default.removeItem(at: bundle)
        #expect(throws: HelpCatalog.Failure.unavailable) { try HelpCatalog.bundled(in: application) }
    }
}
