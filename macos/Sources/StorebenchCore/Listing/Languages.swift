import Foundation

public enum StoreLocales {
    public static let codes = ["ar-SA", "bn-BD", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl-NL", "en-AU", "en-CA", "en-GB", "en-US", "fi", "fr-FR", "fr-CA", "de-DE", "el",
                               "gu-IN", "he", "hi", "hu", "id", "it", "ja", "kn-IN", "ko", "ms", "ml-IN", "mr-IN", "no", "or-IN", "pl", "pt-BR", "pt-PT", "pa-IN", "ro", "ru", "sk",
                               "sl-SI", "es-MX", "es-ES", "sv", "ta-IN", "te-IN", "th", "tr", "uk", "ur-PK", "vi"]
    static let names = ["ar-SA": "Arabic (Saudi Arabia)", "bn-BD": "Bangla (Bangladesh)", "ca": "Catalan", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese", "hr": "Croatian",
                        "cs": "Czech", "da": "Danish", "nl-NL": "Dutch (Netherlands)", "en-AU": "Australian English", "en-CA": "Canadian English", "en-GB": "British English", "en-US": "American English",
                        "fi": "Finnish", "fr-FR": "French (France)", "fr-CA": "Canadian French", "de-DE": "German (Germany)", "el": "Greek", "gu-IN": "Gujarati (India)", "he": "Hebrew", "hi": "Hindi",
                        "hu": "Hungarian", "id": "Indonesian", "it": "Italian", "ja": "Japanese", "kn-IN": "Kannada (India)", "ko": "Korean", "ms": "Malay", "ml-IN": "Malayalam (India)",
                        "mr-IN": "Marathi (India)", "no": "Norwegian", "or-IN": "Odia (India)", "pl": "Polish", "pt-BR": "Brazilian Portuguese", "pt-PT": "European Portuguese",
                        "pa-IN": "Punjabi (India)", "ro": "Romanian", "ru": "Russian", "sk": "Slovak", "sl-SI": "Slovenian (Slovenia)", "es-MX": "Mexican Spanish", "es-ES": "European Spanish",
                        "sv": "Swedish", "ta-IN": "Tamil (India)", "te-IN": "Telugu (India)", "th": "Thai", "tr": "Turkish", "uk": "Ukrainian", "ur-PK": "Urdu (Pakistan)", "vi": "Vietnamese"]
    public static func name(_ code: String) -> String { names[code] ?? code }

    static let displayTypes = ["IOS": ["APP_IPHONE_67", "APP_IPHONE_61", "APP_IPHONE_65", "APP_IPHONE_58", "APP_IPHONE_55", "APP_IPHONE_47", "APP_IPHONE_40", "APP_IPHONE_35", "APP_IPAD_PRO_3GEN_129",
                                       "APP_IPAD_PRO_3GEN_11", "APP_IPAD_PRO_129", "APP_IPAD_105", "APP_IPAD_97", "APP_WATCH_ULTRA", "APP_WATCH_SERIES_10", "APP_WATCH_SERIES_7", "APP_WATCH_SERIES_4", "APP_WATCH_SERIES_3"],
                               "MAC_OS": ["APP_DESKTOP"], "TV_OS": ["APP_APPLE_TV"], "VISION_OS": ["APP_APPLE_VISION_PRO"]]

    public static func screenshotTypes(platform: String, imported: [String] = []) -> [String] {
        var result: [String] = []
        for type in (displayTypes[platform] ?? []) + imported where !result.contains(type) { result.append(type) }
        return result
    }

    public static func displayTypeName(_ type: String) -> String {
        switch type {
        case "APP_DESKTOP": return "Mac"
        case "APP_APPLE_TV": return "Apple TV"
        case "APP_APPLE_VISION_PRO": return "Apple Vision Pro"
        case "APP_IPHONE_67": return "iPhone large display"
        case "APP_IPAD_PRO_3GEN_129": return "iPad 13″"
        case "APP_IPAD_PRO_3GEN_11": return "iPad 11″"
        case "APP_IPAD_PRO_129": return "iPad 12.9″"
        case "APP_IPAD_105": return "iPad 10.5″"
        case "APP_IPAD_97": return "iPad 9.7″"
        default:
            if type.range(of: #"^APP_IPHONE_\d\d$"#, options: .regularExpression) != nil { let digits = Array(type.suffix(2)); return "iPhone \(digits[0]).\(digits[1])″" }
            return type.replacingOccurrences(of: "APP_", with: "", options: .anchored).replacingOccurrences(of: "_", with: " ")
        }
    }
}

public enum LanguageFailure: Error, Equatable {
    case versionNotFound, unknownLanguage, exists, sourceNotFound

    public var message: String {
        switch self {
        case .versionNotFound: "Version not found."
        case .unknownLanguage: "Choose an App Store language."
        case .exists: "This language already exists for this version."
        case .sourceNotFound: "Source language not found."
        }
    }
}

extension WorkspaceSession {
    /// The revision with languages and screenshot sizes added in its local draft.
    public func workspaceRevision(_ source: Revision, accountId: String, appId: String) throws -> Revision {
        let draft = try storeAccess { store in try store.document(namespace: "drafts", key: "\(accountId):\(appId):\(source.id)").map { try JSONText.parse($0.payload) } }
        return Self.overlay(source, draft: draft)
    }

    static func overlay(_ source: Revision, draft: JSONText?) -> Revision {
        guard let draft else { return source }
        let added = Self.items(draft["addedLocalizations"]), sets = Self.items(draft["addedScreenshotSets"])
        var codes: [String] = []
        for item in added { if let code = item["locale"]?.text, !codes.contains(code), !source.appInfos.contains(where: { $0.localizations.contains { $0.fields["locale"]?.text == code } }) { codes.append(code) } }
        var appInfos = source.appInfos
        if !codes.isEmpty {
            appInfos.append(Revision.AppInfo(id: "local-app-info", fields: [:], localizations: codes.map { Revision.AppInfoLocalization(id: "local-app-info-\($0)", fields: ["locale": .text($0)]) }))
        }
        let versions = source.versions.map { version in
            let locales = version.localizations + added.filter { $0["versionId"]?.text == version.id }.compactMap { item -> Revision.Localization? in
                guard let id = item["id"]?.text, let locale = item["locale"]?.text else { return nil }
                return Revision.Localization(id: id, fields: ["locale": .text(locale)], screenshotSets: [])
            }
            return Revision.Version(id: version.id, fields: version.fields, localizations: locales.map { locale in
                Revision.Localization(id: locale.id, fields: locale.fields, screenshotSets: locale.screenshotSets + sets.filter { $0["localizationId"]?.text == locale.id }.compactMap { set in
                    guard let id = set["id"]?.text, let type = set["displayType"]?.text else { return nil }
                    return Revision.ScreenshotSet(id: id, displayType: type, screenshots: [])
                })
            })
        }
        return Revision(schemaVersion: source.schemaVersion, origin: source.origin, id: source.id, importedAt: source.importedAt, app: source.app, appInfos: appInfos, versions: versions)
    }

    static func items(_ value: JSONText?) -> [JSONText] { if case .array(let items)? = value { items } else { [] } }

    /// Adds a language to a version as a local draft, optionally copying another language's text.
    public func addLanguage(accountId: String, appId: String, revisionId: String, versionId: String, locale: String, copyFrom: String?) throws -> String {
        guard StoreLocales.codes.contains(locale) else { throw LanguageFailure.unknownLanguage }
        return try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            try Self.addingLanguage(draft, source: try JSONDecoder().decode(Revision.self, from: sourceJSON.data), revisionId: revisionId, versionId: versionId, locale: locale, copyFrom: copyFrom)
        }
    }

    /// The draft with one language added to a version, as a pure change that callers apply inside their own draft transaction.
    static func addingLanguage(_ draft: JSONText, source: Revision, revisionId: String, versionId: String, locale: String, copyFrom: String?) throws -> (JSONText, String) {
        guard StoreLocales.codes.contains(locale) else { throw LanguageFailure.unknownLanguage }
        let unique = { UUID().uuidString.lowercased() }
        do {
            let revision = Self.overlay(source, draft: draft)
            guard let version = revision.versions.first(where: { $0.id == versionId }) else { throw LanguageFailure.versionNotFound }
            guard !version.localizations.contains(where: { $0.locale == locale }) else { throw LanguageFailure.exists }
            let original = copyFrom.flatMap { code in version.localizations.first { $0.locale == code } }
            if copyFrom != nil && original == nil { throw LanguageFailure.sourceNotFound }
            let id = "local-locale-\(unique())"
            let texts = draft["texts"] ?? .object([])
            func copy(_ itemId: String, _ fields: Fields, _ names: [String]) -> JSONText {
                .object(names.map { name in (name, .string(texts[itemId]?[name]?.text ?? fields[name].map(Self.text) ?? "")) })
            }
            var nextTexts = texts, marks: [(String, String, String, String)] = []
            if let original {
                let copied = copy(original.id, original.fields, TextDrafts.versionFields)
                nextTexts = nextTexts.setting(id, copied)
                for field in TextDrafts.versionFields { if let value = copied[field]?.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { marks.append((id, field, original.id, value)) } }
                let appLocales = revision.appInfos.flatMap(\.localizations)
                if let info = appLocales.first(where: { $0.fields["locale"]?.text == copyFrom }), !appLocales.contains(where: { $0.fields["locale"]?.text == locale }) {
                    let target = "local-app-info-\(locale)", copiedInfo = copy(info.id, info.fields, TextDrafts.appInfoFields)
                    nextTexts = nextTexts.setting(target, copiedInfo)
                    for field in TextDrafts.appInfoFields { if let value = copiedInfo[field]?.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { marks.append((target, field, info.id, value)) } }
                }
            }
            var imported: [String] = []
            for type in version.localizations.flatMap({ $0.screenshotSets.map(\.displayType) }) where !type.isEmpty && !imported.contains(type) { imported.append(type) }
            let platform = version.fields["platform"].map(Self.text) ?? ""
            let types = imported.isEmpty ? Array(StoreLocales.screenshotTypes(platform: platform).prefix(1)) : imported
            var result = draft.setting("texts", nextTexts)
                .setting("addedLocalizations", .array(Self.items(draft["addedLocalizations"]) + [.object([("id", .string(id)), ("versionId", .string(versionId)), ("locale", .string(locale))])]))
                .setting("addedScreenshotSets", .array(Self.items(draft["addedScreenshotSets"]) + types.map { .object([("id", .string("local-set-\(unique())")), ("localizationId", .string(id)), ("displayType", .string($0))]) }))
            for (target, field, sourceId, value) in marks {
                let marker = JSONText.object([("revisionId", .string(revisionId)), ("localizationId", .string(sourceId)), ("copiedValue", .string(value)), ("reviewedValue", .string(value))])
                let sources = result["textSources"] ?? .object([])
                result = result.setting("textSources", sources.setting(target, (sources[target] ?? .object([])).setting(field, marker)))
            }
            return (result, id)
        }
    }

    static func text(_ value: FieldValue) -> String {
        value.text ?? ""
    }
}
