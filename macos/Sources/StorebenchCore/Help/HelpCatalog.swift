import Foundation

public struct HelpCatalog: Sendable, Equatable {
    public enum Failure: Error, Equatable { case invalid, unavailable }
    public struct Question: Decodable, Sendable, Equatable {
        public let question, answer: String
        public init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            question = try values.decode(String.self); answer = try values.decode(String.self)
            guard values.isAtEnd else { throw Failure.invalid }
        }
    }
    public struct Link: Decodable, Sendable, Equatable {
        public let label, href: String
        public var url: URL { URL(string: href)! }
    }
    public struct Topic: Decodable, Identifiable, Sendable, Equatable {
        public let id, title, summary: String
        public let questions: [Question], links: [Link]
        public var json: JSONText { .object([("id", .string(id)), ("title", .string(title)), ("summary", .string(summary)),
            ("links", .array(links.map { .object([("label", .string($0.label)), ("href", .string($0.href))]) })),
            ("questions", .array(questions.map { .array([.string($0.question), .string($0.answer)]) }))]) }
        fileprivate var searchable: String { ([title, summary] + questions.flatMap { [$0.question, $0.answer] }).joined(separator: " ").lowercased() }
    }
    public let topics: [Topic]
    private let searchText: [Data]
    public var json: JSONText { .object([("schemaVersion", .number(1)), ("topics", .array(topics.map(\.json)))]) }
    public init(data: Data) throws {
        struct Document: Decodable { let schemaVersion: Int, topics: [Topic] }
        guard data.count <= 1_000_000 else { throw Failure.invalid }
        let value: Document
        do { value = try JSONDecoder().decode(Document.self, from: data) } catch { throw Failure.invalid }
        func text(_ value: String) -> Bool { !value.isEmpty && value.utf16.count <= 10_000 && !value.contains("\0") }
        guard value.schemaVersion == 1, (1...200).contains(value.topics.count), Set(value.topics.map(\.id)).count == value.topics.count,
              value.topics.allSatisfy({ topic in
                topic.id.range(of: #"\A[A-Za-z0-9_-]{1,100}\z"#, options: .regularExpression) != nil && text(topic.title) && text(topic.summary)
                    && (1...100).contains(topic.questions.count) && topic.questions.allSatisfy { text($0.question) && text($0.answer) }
                    && topic.links.count <= 20 && topic.links.allSatisfy { link in
                        guard text(link.label), let url = URL(string: link.href) else { return false }
                        return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
                    }
              }) else { throw Failure.invalid }
        topics = value.topics; searchText = topics.map { Data($0.searchable.utf8) }
    }
    public func matching(_ query: String) -> [Topic] {
        let query = TextSemantics.trim(query).lowercased()
        if query.isEmpty { return topics }
        // Match literal UTF-8 sequences without Unicode normalization.
        let bytes = Data(query.utf8)
        // Skip unmatched bytes for short patterns; keep Foundation's search for longer input.
        let needle = Array(bytes)
        var shifts = [Int](repeating: needle.count, count: 256)
        if needle.count <= 64 {
            for index in 0..<(needle.count - 1) { shifts[Int(needle[index])] = needle.count - index - 1 }
        }
        var matches: [Topic] = []
        for index in topics.indices {
            let found = needle.count <= 64 ? Self.contains(searchText[index], needle: needle, shifts: shifts) : searchText[index].range(of: bytes) != nil
            if found { matches.append(topics[index]) }
        }
        return matches
    }

    private static func contains(_ text: Data, needle: [UInt8], shifts: [Int]) -> Bool {
        guard text.count >= needle.count else { return false }
        return text.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            var end = needle.count - 1
            while end < source.count {
                var remaining = needle.count
                while remaining > 0 && source[end - needle.count + remaining] == needle[remaining - 1] { remaining -= 1 }
                if remaining == 0 { return true }
                end += shifts[Int(source[end])]
            }
            return false
        }
    }
    /// SwiftPM puts the resource beside command-line products; app packages put it in Resources.
    /// Explicit bundle discovery avoids embedding a development build path in the application.
    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        try Self(data: CoreResources.json("help-topics", in: bundle))
    }
}

/// Public support configuration comes from the packaged app, independently of accounts or credentials.
/// The public website and support page from the packaged app's Info.plist, written there from the packaging configuration.
/// Support opens that page in the browser; nothing about the app, its accounts or an error is sent with it.
public struct SupportContact: Sendable, Equatable {
    public let website, version: String
    public let support: URL
    public init(website: String, support: String, version: String) throws {
        guard let url = URL(string: website), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              support.utf8.count <= 500, let page = URL(string: support), page.scheme == "https", page.host?.isEmpty == false, page.user == nil, page.password == nil, page.query == nil,
              version.utf8.count <= 100, version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil else { throw HelpCatalog.Failure.invalid }
        self.website = website; self.support = page; self.version = version
    }
    public init(info: [String: String]) throws {
        guard let website = info["StorebenchSupportWebsite"], let support = info["StorebenchSupportURL"], let version = info["CFBundleShortVersionString"] else { throw HelpCatalog.Failure.unavailable }
        try self.init(website: website, support: support, version: version)
    }
    public var about: URL { URL(string: website + "/#about")! }
}
