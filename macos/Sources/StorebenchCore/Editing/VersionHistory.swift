import Foundation

/// The App Store listing every version had, read from the imports saved on this Mac: newest version first, one entry per platform and number.
/// Each version shows what the newest import that holds it saw, and each field notes whether it changed from the version before it.
public struct VersionHistory: Sendable {
    public struct Field: Identifiable, Sendable {
        public let key, label, value: String
        /// The value differs from the previous version of the same platform in the same language.
        public let changed: Bool
        public var id: String { key }
    }
    public struct Language: Identifiable, Sendable {
        public let locale: String, fields: [Field], screenshots: [LibraryChooser.Shot]
        public var id: String { locale }
        public var changedCount: Int { fields.filter(\.changed).count }
    }
    public struct Entry: Identifiable, Sendable {
        public let platform, number, stateCode, savedAt: String
        /// The previous version of the same platform, when the imports hold one.
        public let previous: String?
        public let languages: [Language]
        public var id: String { platform + "/" + number }
        public var title: String { "\(AppStoreNames.platform(platform)) \(number)" }
        public var state: String { AppStoreNames.state(stateCode) }
        public var changedCount: Int { languages.reduce(0) { $0 + $1.changedCount } }
    }
    /// One change of the app name or subtitle in the primary language, as an import saw it.
    public struct NameChange: Identifiable, Sendable {
        public let savedAt, name, subtitle: String
        public var id: String { savedAt }
    }
    public let entries: [Entry]
    /// Name and subtitle changes, newest first.
    public let names: [NameChange]

    static let fields = ["whatsNew", "promotionalText", "description", "keywords", "supportUrl", "marketingUrl"]

    /// `revisions` are newest first, as `archivedHistory` returns them. Local drafts are left out: this is what Apple had.
    public init(_ revisions: [ArchivedRevision]) {
        struct Seen { let revision: ArchivedRevision, version: JSONText, shots: [LibraryChooser.Shot], offset: Int }
        func items(_ value: JSONText?) -> [JSONText] { if case .array(let values)? = value { values } else { [] } }
        func text(_ value: JSONText?) -> String { value?.text ?? "" }
        let imports = revisions.filter { !$0.local }
        var seen: [String: Seen] = [:], order: [String] = []
        for revision in imports {
            let shots = (try? LibraryChooser.images(revision)) ?? []
            var offset = 0
            for version in items(revision.value["versions"]) {
                let key = text(version["fields"]?["platform"]) + "/" + text(version["fields"]?["versionString"])
                if seen[key] == nil, !text(version["fields"]?["versionString"]).isEmpty { seen[key] = Seen(revision: revision, version: version, shots: shots, offset: offset); order.append(key) }
                offset += items(version["localizations"]).reduce(0) { total, locale in total + items(locale["screenshotSets"]).reduce(0) { $0 + items($1["screenshots"]).count } }
            }
        }
        let keys = order.sorted { a, b in
            let left = a.split(separator: "/", maxSplits: 1).map(String.init), right = b.split(separator: "/", maxSplits: 1).map(String.init)
            return left[0] != right[0] ? left[0] < right[0] : Releases.earlier(right.last ?? "", left.last ?? "")
        }
        func languages(_ seen: Seen) -> [(locale: String, values: [String: String], shots: [LibraryChooser.Shot])] {
            var offset = seen.offset
            return items(seen.version["localizations"]).map { locale in
                let count = items(locale["screenshotSets"]).reduce(0) { $0 + items($1["screenshots"]).count }
                let shots = offset + count <= seen.shots.count ? Array(seen.shots[offset..<(offset + count)]) : []
                offset += count
                let values = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0, text(locale["fields"]?[$0])) })
                return (text(locale["fields"]?["locale"]), values, shots)
            }
        }
        let primary = imports.first.map { text($0.value["app"]?["primaryLocale"]) } ?? ""
        entries = keys.enumerated().compactMap { index, key in
            guard let current = seen[key] else { return nil }
            let fields = current.version["fields"], platform = text(fields?["platform"])
            let previousKey = keys.dropFirst(index + 1).first { $0.hasPrefix(platform + "/") }
            let earlier = previousKey.flatMap { seen[$0] }.map(languages) ?? []
            let shown = languages(current).sorted { ($0.locale == primary ? 0 : 1, $0.locale) < ($1.locale == primary ? 0 : 1, $1.locale) }.map { language in
                let before = earlier.first { $0.locale == language.locale }?.values
                return Language(locale: language.locale, fields: Self.fields.map { key in
                    Field(key: key, label: TextDrafts.labels[key] ?? key, value: language.values[key] ?? "",
                          changed: previousKey != nil && !TextSemantics.same(before?[key] ?? "", language.values[key] ?? ""))
                }, screenshots: language.shots)
            }
            return Entry(platform: platform, number: text(fields?["versionString"]), stateCode: text(fields?["appVersionState"]).isEmpty ? text(fields?["appStoreState"]) : text(fields?["appVersionState"]),
                         savedAt: current.revision.importedAt, previous: previousKey.map { String($0.split(separator: "/", maxSplits: 1).last ?? "") }, languages: shown)
        }
        // Oldest first, keeping each import whose live name or subtitle differs from the one before.
        var changes: [NameChange] = []
        for revision in imports.reversed() {
            let infos = items(revision.value["appInfos"])
            let live = infos.first { ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(text($0["fields"]?["appStoreState"]).isEmpty ? text($0["fields"]?["state"]) : text($0["fields"]?["appStoreState"])) } ?? infos.first
            let locales = items(live?["localizations"])
            guard let locale = locales.first(where: { text($0["fields"]?["locale"]) == text(revision.value["app"]?["primaryLocale"]) }) ?? locales.first else { continue }
            let name = text(locale["fields"]?["name"]), subtitle = text(locale["fields"]?["subtitle"])
            if let last = changes.last, TextSemantics.same(last.name, name), TextSemantics.same(last.subtitle, subtitle) { continue }
            changes.append(NameChange(savedAt: revision.importedAt, name: name, subtitle: subtitle))
        }
        names = changes.reversed()
    }
}
