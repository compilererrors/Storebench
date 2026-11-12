import Foundation

public enum StoreLocales {
    public static let codes = ["ar-SA", "bn-BD", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl-NL", "en-AU", "en-CA", "en-GB", "en-US", "fi", "fr-FR", "fr-CA", "de-DE", "el",
                               "gu-IN", "he", "hi", "hu", "id", "it", "ja", "kn-IN", "ko", "ms", "ml-IN", "mr-IN", "no", "or-IN", "pl", "pt-BR", "pt-PT", "pa-IN", "ro", "ru", "sk",
                               "sl-SI", "es-MX", "es-ES", "sv", "ta-IN", "te-IN", "th", "tr", "uk", "ur-PK", "vi"]
    // App Store Connect's English language labels, independent of the API locale identifiers.
    static let names = ["ar-SA": "Arabic", "bn-BD": "Bangla", "ca": "Catalan", "zh-Hans": "Chinese (Simplified)", "zh-Hant": "Chinese (Traditional)", "hr": "Croatian",
                        "cs": "Czech", "da": "Danish", "nl-NL": "Dutch", "en-AU": "English (Australia)", "en-CA": "English (Canada)", "en-GB": "English (U.K.)", "en-US": "English (U.S.)",
                        "fi": "Finnish", "fr-FR": "French", "fr-CA": "French (Canada)", "de-DE": "German", "el": "Greek", "gu-IN": "Gujarati", "he": "Hebrew", "hi": "Hindi",
                        "hu": "Hungarian", "id": "Indonesian", "it": "Italian", "ja": "Japanese", "kn-IN": "Kannada", "ko": "Korean", "ms": "Malay", "ml-IN": "Malayalam",
                        "mr-IN": "Marathi", "no": "Norwegian", "or-IN": "Odia", "pl": "Polish", "pt-BR": "Portuguese (Brazil)", "pt-PT": "Portuguese (Portugal)",
                        "pa-IN": "Punjabi", "ro": "Romanian", "ru": "Russian", "sk": "Slovak", "sl-SI": "Slovenian", "es-MX": "Spanish (Mexico)", "es-ES": "Spanish (Spain)",
                        "sv": "Swedish", "ta-IN": "Tamil", "te-IN": "Telugu", "th": "Thai", "tr": "Turkish", "uk": "Ukrainian", "ur-PK": "Urdu", "vi": "Vietnamese"]
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
    case versionNotFound, unknownLanguage, exists, sourceNotFound, sourceChanged, translationFailed, translationTooLong(field: String), notLocal

    public var message: String {
        switch self {
        case .versionNotFound: "Version not found."
        case .unknownLanguage: "Choose an App Store language."
        case .exists: "This language already exists for this version."
        case .sourceNotFound: "Source language not found."
        case .sourceChanged: "The source language changed while it was being translated. Nothing was added; try again."
        case .translationFailed: "The translation could not be finished. Nothing was added; try again or copy the language instead."
        case .translationTooLong(let field): "The translated \(TextDrafts.labels[field] ?? field) is longer than 10,000 characters, so it cannot be saved. Nothing was added; shorten the source text or copy the language instead."
        case .notLocal: "Only a language added on this Mac can be removed here. Languages already in App Store Connect are removed there."
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

    /// Adds a language to a version as a local draft, optionally copying or translating another language's text.
    public func addLanguage(accountId: String, appId: String, revisionId: String, versionId: String, locale: String, copyFrom: String?, translation: LanguageTranslation? = nil) throws -> String {
        guard StoreLocales.codes.contains(locale) else { throw LanguageFailure.unknownLanguage }
        return try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            try Self.addingLanguage(draft, source: try JSONDecoder().decode(Revision.self, from: sourceJSON.data), revisionId: revisionId, versionId: versionId, locale: locale,
                                    copyFrom: copyFrom, translation: translation)
        }
    }

    /// The version localizations added on this Mac, which can be removed again before they reach App Store Connect.
    public func addedLocalizationIds(accountId: String, appId: String, revisionId: String, versionId: String) throws -> Set<String> {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        let draft = try storeAccess { store in try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } }
        return Set(Self.items(draft?["addedLocalizations"]).filter { $0["versionId"]?.text == versionId }.compactMap { $0["id"]?.text })
    }

    /// Removes a language that was added to a version on this Mac, with its local text, layouts and selected media.
    /// Saved originals stay in the media library; languages that came from App Store Connect cannot be removed here.
    public func removeLanguage(accountId: String, appId: String, revisionId: String, versionId: String, localizationId: String) throws {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            (try Self.removingLanguage(draft, versionId: versionId, localizationId: localizationId), ())
        }
    }

    /// The draft without one locally added language, as a pure change that callers apply inside their own draft transaction.
    static func removingLanguage(_ draft: JSONText, versionId: String, localizationId: String) throws -> JSONText {
        let added = Self.items(draft["addedLocalizations"])
        guard localizationId.hasPrefix("local-locale-"),
              let entry = added.first(where: { $0["id"]?.text == localizationId && $0["versionId"]?.text == versionId }),
              let locale = entry["locale"]?.text else { throw LanguageFailure.notLocal }
        let remaining = added.filter { $0["id"]?.text != localizationId }
        let sets = Self.items(draft["addedScreenshotSets"])
        let removedSets = Set(sets.filter { $0["localizationId"]?.text == localizationId }.compactMap { $0["id"]?.text })
        // The local App Information text belongs to the locale while any version still adds it.
        var textIds: Set<String> = [localizationId]
        if !remaining.contains(where: { $0["locale"]?.text == locale }) { textIds.insert("local-app-info-\(locale)") }
        func object(_ key: String, keeping keep: (String, JSONText) -> Bool) -> JSONText? {
            guard case .object(let pairs)? = draft[key] else { return nil }
            return .object(pairs.filter { keep($0.0, $0.1) })
        }
        var result = draft.setting("addedLocalizations", .array(remaining))
            .setting("addedScreenshotSets", .array(sets.filter { $0["localizationId"]?.text != localizationId }))
        let changes: [(String, (String, JSONText) -> Bool)] = [
            ("texts", { id, _ in !textIds.contains(id) }),
            ("textSources", { id, _ in !textIds.contains(id) }),
            ("screenshotLayouts", { id, _ in !removedSets.contains(id) }),
            ("uploads", { _, upload in !removedSets.contains(upload["setId"]?.text ?? "") }),
            ("previewUploads", { _, video in video["localizationId"]?.text != localizationId }),
            ("previewLayouts", { key, _ in !key.hasPrefix(localizationId + ":") }),
        ]
        for (key, keep) in changes { if let value = object(key, keeping: keep) { result = result.setting(key, value) } }
        return result
    }

    /// The draft with one language added to a version, as a pure change that callers apply inside their own draft transaction.
    static func addingLanguage(_ draft: JSONText, source: Revision, revisionId: String, versionId: String, locale: String, copyFrom: String?,
                               translation: LanguageTranslation? = nil) throws -> (JSONText, String) {
        guard StoreLocales.codes.contains(locale) else { throw LanguageFailure.unknownLanguage }
        if let translation, translation.sourceLocale != copyFrom { throw LanguageFailure.sourceChanged }
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
            var nextTexts = texts, marks: [(target: String, field: String, sourceId: String, copied: String, reviewed: String)] = []
            func mark(_ target: String, _ sourceId: String, original: JSONText, placed: JSONText, _ fields: [String]) {
                for field in fields {
                    if let value = placed[field]?.text, !TextSemantics.trim(value).isEmpty { marks.append((target, field, sourceId, value, original[field]?.text ?? "")) }
                }
            }
            if let original {
                let copied = copy(original.id, original.fields, TextDrafts.versionFields)
                let placed = try translation?.applying(to: copied, scope: .version) ?? copied
                nextTexts = nextTexts.setting(id, placed)
                mark(id, original.id, original: copied, placed: placed, TextDrafts.versionFields)
                let appLocales = revision.appInfos.flatMap(\.localizations)
                if let info = appLocales.first(where: { $0.fields["locale"]?.text == copyFrom }), !appLocales.contains(where: { $0.fields["locale"]?.text == locale }) {
                    let target = "local-app-info-\(locale)", copiedInfo = copy(info.id, info.fields, TextDrafts.appInfoFields)
                    let placedInfo = try translation?.applying(to: copiedInfo, scope: .appInfo) ?? copiedInfo
                    nextTexts = nextTexts.setting(target, placedInfo)
                    mark(target, info.id, original: copiedInfo, placed: placedInfo, TextDrafts.appInfoFields)
                } else if let translation, !translation.appInfo.isEmpty, !appLocales.contains(where: { $0.fields["locale"]?.text == locale }) {
                    throw LanguageFailure.sourceChanged
                }
            }
            var imported: [String] = []
            for type in version.localizations.flatMap({ $0.screenshotSets.map(\.displayType) }) where !type.isEmpty && !imported.contains(type) { imported.append(type) }
            let platform = version.fields["platform"].map(Self.text) ?? ""
            let types = imported.isEmpty ? Array(StoreLocales.screenshotTypes(platform: platform).prefix(1)) : imported
            var result = draft.setting("texts", nextTexts)
                .setting("addedLocalizations", .array(Self.items(draft["addedLocalizations"]) + [.object([("id", .string(id)), ("versionId", .string(versionId)), ("locale", .string(locale))])]))
                .setting("addedScreenshotSets", .array(Self.items(draft["addedScreenshotSets"]) + types.map { .object([("id", .string("local-set-\(unique())")), ("localizationId", .string(id)), ("displayType", .string($0))]) }))
            for (target, field, sourceId, copied, reviewed) in marks {
                var marker = JSONText.object([("revisionId", .string(revisionId)), ("localizationId", .string(sourceId)), ("copiedValue", .string(copied)), ("reviewedValue", .string(reviewed))])
                if translation != nil, !TextSemantics.same(copied, reviewed) { marker = marker.setting("translated", .bool(true)) }
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
