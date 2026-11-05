import Foundation

public enum TransferKind: String, CaseIterable, Sendable { case languages, screenshots, prices, release }
public enum TransferFormat: String, CaseIterable, Sendable { case csv, json }

public struct TransferChange: Identifiable, Sendable, Equatable { public let id, label, before, after: String }

/// What an import would change, and the fingerprint the import must be confirmed with.
public struct TransferPreview: Sendable, Equatable {
    public let changes: [TransferChange], fingerprint: String, count, added, totalRows: Int, saved: Bool
}

public enum TransferFailure: Error, Equatable {
    case invalid(String), changed
    public var message: String {
        switch self {
        case .invalid(let text): text
        case .changed: "The file or saved data changed after your preview. Preview this file again before importing."
        }
    }
}

public enum Transfer {
    public static let columns: [TransferKind: [String]] = [
        .languages: ["app_id", "version_id", "locale", "scope", "field", "value"],
        .screenshots: ["app_id", "version_id", "locale", "display_type", "screenshot_id", "file_name", "position", "included"],
        .prices: ["app_id", "territory", "currency", "amount", "start_date", "end_date"],
        .release: ["app_id", "source_revision_id", "base_version_id", "target_version"]]
    static let releaseOptions = ["release_type", "earliest_release_date"]

    /// Pretty-printed JSON with two-space indentation.
    static func pretty(_ value: JSONText, _ indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .array(let items): return items.isEmpty ? "[]" : "[\n" + items.map { inner + pretty($0, inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let pairs): return pairs.isEmpty ? "{}" : "{\n" + pairs.map { inner + JSONText.string($0.0).stringify() + ": " + pretty($0.1, inner) }.joined(separator: ",\n") + "\n\(indent)}"
        default: return value.stringify()
        }
    }

    public static func text(_ kind: TransferKind, _ table: Delimited.Table, format: TransferFormat) -> String {
        if format == .json {
            return pretty(.object([("format", .string("storebench-data")), ("version", .number(1)), ("kind", .string(kind.rawValue)), ("columns", .array(table.columns.map { .string($0) })),
                                   ("rows", .array(table.rows.map { .array($0.map { .string($0) }) }))])) + "\n"
        }
        return Delimited.write(Delimited.Table(columns: table.columns, rows: table.rows.map { $0.map(Delimited.spreadsheetCell) }))
    }

    public static func parse(_ kind: TransferKind, _ text: String, format: TransferFormat) throws -> Delimited.Table {
        var table: Delimited.Table
        if format == .csv {
            let parsed = try Delimited.parse(text)
            table = Delimited.Table(columns: parsed.columns, rows: parsed.rows.map { $0.map(Delimited.unspreadsheetCell) })
        } else {
            guard let value = try? JSONText.parse(Data(text.utf8)), value["format"]?.text == "storebench-data", value["version"] == .number(1), value["kind"]?.text == kind.rawValue,
                  case .array(let header)? = value["columns"], case .array(let rows)? = value["rows"], rows.count <= 100_000 else { throw TransferFailure.invalid("This JSON file does not match the selected workspace data.") }
            let names = header.compactMap { if case .string(let text) = $0 { text } else { nil } }
            guard names.count == header.count, Set(names).count == names.count else { throw TransferFailure.invalid("This JSON file does not match the selected workspace data.") }
            let cells = rows.map { row -> [String]? in
                guard case .array(let items) = row, items.count == names.count else { return nil }
                let strings = items.compactMap { if case .string(let text) = $0 { text } else { nil } }
                return strings.count == items.count ? strings : nil
            }
            guard cells.allSatisfy({ $0 != nil }) else { throw TransferFailure.invalid("This JSON file does not match the selected workspace data.") }
            table = Delimited.Table(columns: names, rows: cells.map { $0! })
        }
        _ = try Delimited.records(table, expected: columns[kind]!, optional: kind == .release ? releaseOptions : [])
        return table
    }

    static func records(_ table: Delimited.Table) -> [[String: String]] { table.rows.map { row in Dictionary(uniqueKeysWithValues: table.columns.enumerated().map { ($0.element, $0.offset < row.count ? row[$0.offset] : "") }) } }

    static let fieldLabels = ["name": "App name", "subtitle": "Subtitle", "privacyPolicyUrl": "Privacy policy URL", "privacyChoicesUrl": "Privacy choices URL", "privacyPolicyText": "Privacy policy text",
                              "description": "Description", "keywords": "Keywords", "promotionalText": "Promotional text", "whatsNew": "What's new", "supportUrl": "Support URL", "marketingUrl": "Marketing URL"]

    public static func changes(_ kind: TransferKind, before: Delimited.Table, after: Delimited.Table, versionNames: [String: String] = [:]) -> [TransferChange] {
        func identity(_ row: [String: String]) -> String {
            let keys: [String] = switch kind {
            case .languages: ["app_id", "version_id", "locale", "scope", "field"]
            case .screenshots: ["app_id", "version_id", "locale", "display_type", "screenshot_id"]
            case .prices: ["app_id", "territory", "start_date", "end_date"]
            case .release: ["app_id"]
            }
            return JSONText.array(keys.map { .string(row[$0] ?? "") }).stringify()
        }
        let previous = Dictionary(records(before).map { (identity($0), $0) }, uniquingKeysWith: { _, last in last })
        return records(after).flatMap { row -> [TransferChange] in
            let id = identity(row), old = previous[id], version = versionNames[row["version_id"] ?? ""].map { " · \($0)" } ?? ""
            switch kind {
            case .languages:
                if TextSemantics.same(old?["value"], row["value"]) { return [] }
                return [TransferChange(id: id, label: "\(StoreLocales.name(row["locale"] ?? ""))\(version) · \(fieldLabels[row["field"] ?? ""] ?? row["field"] ?? "")", before: old?["value"] ?? "Language not added yet", after: row["value"] ?? "")]
            case .screenshots:
                return ["position", "included"].compactMap { field in
                    if old?[field] == row[field] { return nil }
                    func value(_ item: [String: String]?) -> String { guard let item else { return "Not in this layout" }; return field == "position" ? item["position"] ?? "" : item["included"] == "true" ? "Included" : "Excluded" }
                    return TransferChange(id: "\(id):\(field)", label: "\(StoreLocales.name(row["locale"] ?? ""))\(version) · \(StoreLocales.displayTypeName(row["display_type"] ?? "")) · \(row["file_name"] ?? "") · \(field == "position" ? "Position" : "Selection")",
                                          before: value(old), after: value(row))
                }
            case .prices:
                if let old, old["currency"] == row["currency"], Decimal(string: old["amount"] ?? "") == Decimal(string: row["amount"] ?? "") { return [] }
                let period = (row["start_date"] ?? "").isEmpty ? "Country override" : "\(row["start_date"]!) to \(row["end_date"] ?? "")"
                return [TransferChange(id: id, label: "\(row["territory"] ?? "") · \(period)", before: old.map { "\($0["amount"] ?? "") \($0["currency"] ?? "")" } ?? "No saved country draft", after: "\(row["amount"] ?? "") \(row["currency"] ?? "")")]
            case .release:
                let labels = [("source_revision_id", "Imported source"), ("base_version_id", "Starting version"), ("target_version", "New version number"), ("release_type", "Version Release"), ("earliest_release_date", "Earliest release date")]
                let methods = ["MANUAL": "Manual release", "AFTER_APPROVAL": "Automatically release this version", "SCHEDULED": "Scheduled release"]
                return labels.compactMap { key, label in
                    if old?[key] == row[key] { return nil }
                    func value(_ item: [String: String]?) -> String { guard let item else { return "No release plan" }; let text = key == "release_type" ? methods[item[key] ?? ""] ?? item[key] ?? "" : item[key] ?? ""; return text.isEmpty ? "Not set" : text }
                    return TransferChange(id: "\(id):\(key)", label: label, before: value(old), after: value(row))
                }
            }
        }
    }

    static func materialTable(_ kind: TransferKind, source: Revision, draft: JSONText, versionId: String?) -> Delimited.Table {
        let revision = WorkspaceSession.overlay(source, draft: draft)
        var rows: [[String]] = []
        let infoLocales = revision.appInfos.flatMap(\.localizations)
        for version in revision.versions where versionId == nil || version.id == versionId {
            var codes: [String] = []
            for code in version.localizations.map({ $0.fields["locale"]?.text ?? "" }) + infoLocales.map({ $0.fields["locale"]?.text ?? "" }) where !codes.contains(code) { codes.append(code) }
            for code in codes {
                if kind == .languages {
                    if let item = version.localizations.first(where: { $0.fields["locale"]?.text == code }) {
                        for field in TextDrafts.versionFields { rows.append([source.app.id, version.id, code, "version", field, draft["texts"]?[item.id]?[field]?.text ?? item.fields[field]?.text ?? ""]) }
                    }
                    if let item = infoLocales.first(where: { $0.fields["locale"]?.text == code }) {
                        for field in TextDrafts.appInfoFields { rows.append([source.app.id, version.id, code, "appInfo", field, draft["texts"]?[item.id]?[field]?.text ?? item.fields[field]?.text ?? ""]) }
                    }
                } else {
                    for locale in version.localizations where locale.fields["locale"]?.text == code {
                        for set in locale.screenshotSets {
                            let uploads = WorkspaceSession.uploads(draft).filter { $0.1["setId"]?.text == set.id }.map { (id: $0.0, fileName: $0.1["fileName"]?.text ?? "") }
                            let shots = set.screenshots.map { (id: $0.id, fileName: $0.fileName) } + uploads
                            let layout = draft["screenshotLayouts"]?[set.id], order = WorkspaceSession.strings(layout?["order"]), hidden = Set(WorkspaceSession.strings(layout?["hidden"]))
                            let ordered = layout == nil ? shots : shots.enumerated().sorted { (order.firstIndex(of: $0.element.id) ?? Int.max, $0.offset) < (order.firstIndex(of: $1.element.id) ?? Int.max, $1.offset) }.map(\.element)
                            for (index, shot) in ordered.enumerated() { rows.append([source.app.id, version.id, code, set.displayType, shot.id, shot.fileName, String(index + 1), hidden.contains(shot.id) ? "false" : "true"]) }
                        }
                    }
                }
            }
        }
        return Delimited.Table(columns: columns[kind]!, rows: rows)
    }

    /// Applies language text or screenshot layouts from a table to a draft.
    static func importMaterials(_ kind: TransferKind, _ table: Delimited.Table, source: Revision, draft start: JSONText, versionId: String?) throws -> (draft: JSONText, count: Int, added: Int) {
        let rows = try Delimited.records(table, expected: columns[kind]!)
        guard rows.count <= 20_000 else { throw TransferFailure.invalid("Import up to 20,000 material rows at a time.") }
        var draft = start, added = 0, seen = Set<String>()
        var texts: [(String, [String: String], [String])] = [], layouts: [(String, [(id: String, position: Int, included: Bool)])] = []
        for row in rows {
            guard row["app_id"] == source.app.id else { throw TransferFailure.invalid("A row belongs to another app. Select that app before importing.") }
            if let versionId, row["version_id"] != versionId { throw TransferFailure.invalid("A row belongs to a version outside this release plan.") }
            var revision = WorkspaceSession.overlay(source, draft: draft)
            guard var version = revision.versions.first(where: { $0.id == row["version_id"] }) else { throw TransferFailure.invalid("A version was not found in this import. Use a template from this workspace.") }
            let locale = row["locale"] ?? ""
            if kind == .languages {
                guard row["scope"] == "version" || row["scope"] == "appInfo" else { throw TransferFailure.invalid("Scope must be version or appInfo.") }
                if !version.localizations.contains(where: { $0.fields["locale"]?.text == locale }) {
                    do { draft = try WorkspaceSession.addingLanguage(draft, source: source, revisionId: source.id, versionId: version.id, locale: locale, copyFrom: nil).0 }
                    catch { throw TransferFailure.invalid("A language code is not supported by the App Store.") }
                    added += 1; revision = WorkspaceSession.overlay(source, draft: draft); version = revision.versions.first { $0.id == row["version_id"] }!
                }
                let scope = row["scope"]!, items = scope == "version" ? version.localizations.map { ($0.id, $0.fields) } : revision.appInfos.flatMap(\.localizations).map { ($0.id, $0.fields) }
                guard let item = items.first(where: { $0.1["locale"]?.text == locale }) else { throw TransferFailure.invalid("App Information for this language was not found.") }
                let fields = scope == "version" ? TextDrafts.versionFields : TextDrafts.appInfoFields, field = row["field"] ?? "", value = row["value"] ?? ""
                guard fields.contains(field), value.utf16.count <= 10_000 else { throw TransferFailure.invalid("A text field is unknown or longer than 10,000 characters.") }
                let key = "\(item.0):\(field)", index = texts.firstIndex { $0.0 == item.0 }
                if seen.contains(key), let index, texts[index].1[field] != value { throw TransferFailure.invalid("Duplicate rows contain different values for the same text field.") }
                seen.insert(key)
                if let index { texts[index].1[field] = value }
                else {
                    var current = Dictionary(uniqueKeysWithValues: fields.map { ($0, draft["texts"]?[item.0]?[$0]?.text ?? item.1[$0]?.text ?? "") })
                    current[field] = value; texts.append((item.0, current, fields))
                }
            } else {
                guard let set = version.localizations.first(where: { $0.fields["locale"]?.text == locale })?.screenshotSets.first(where: { $0.displayType == row["display_type"] }) else {
                    throw TransferFailure.invalid("Screenshot set not found. Add this language and display size first.")
                }
                let uploads = WorkspaceSession.uploads(draft).filter { $0.1["setId"]?.text == set.id }.map { (id: $0.0, fileName: $0.1["fileName"]?.text ?? "") }
                let shots = set.screenshots.map { (id: $0.id, fileName: $0.fileName) } + uploads
                guard let shot = shots.first(where: { $0.id == row["screenshot_id"] }), shot.fileName == row["file_name"] else { throw TransferFailure.invalid("A screenshot does not match this workspace. Upload its image before importing a layout.") }
                guard let position = row["position"], position.range(of: #"^[1-9]\d*$"#, options: .regularExpression) != nil, let number = Int(position), ["true", "false"].contains(row["included"] ?? "") else {
                    throw TransferFailure.invalid("Screenshot position must start at 1; included must be true or false.")
                }
                let index = layouts.firstIndex { $0.0 == set.id }
                if let index, layouts[index].1.contains(where: { $0.id == shot.id || $0.position == number }) { throw TransferFailure.invalid("Duplicate screenshot or position.") }
                let entry = (id: shot.id, position: number, included: row["included"] == "true")
                if let index { layouts[index].1.append(entry) } else { layouts.append((set.id, [entry])) }
            }
        }
        for (id, fields, allowed) in texts {
            draft = draft.setting("texts", (draft["texts"] ?? .object([])).setting(id, .object(allowed.map { ($0, .string(fields[$0] ?? "")) })))
        }
        let revision = WorkspaceSession.overlay(source, draft: draft)
        for (setId, entries) in layouts {
            let set = revision.versions.flatMap { $0.localizations.flatMap(\.screenshotSets) }.first { $0.id == setId }!
            let available = set.screenshots.map(\.id) + WorkspaceSession.uploads(draft).filter { $0.1["setId"]?.text == setId }.map(\.0)
            let sorted = entries.sorted { $0.position < $1.position }
            guard sorted.enumerated().allSatisfy({ $0.element.position == $0.offset + 1 }) else { throw TransferFailure.invalid("Screenshot positions must be consecutive, starting at 1.") }
            let order = sorted.map(\.id), hidden = sorted.filter { !$0.included }.map(\.id)
            guard Set(order) == Set(available), order.count == available.count else { throw TransferFailure.invalid("Include every screenshot of a display size once when importing its layout.") }
            guard available.count - hidden.count <= ScreenshotSpecs.maximum else { throw TransferFailure.invalid("Select no more than 10 screenshots per language and display size.") }
            draft = draft.setting("screenshotLayouts", (draft["screenshotLayouts"] ?? .object([])).setting(setId, .object([("order", .array(order.map { .string($0) })), ("hidden", .array(hidden.map { .string($0) }))])))
        }
        return (draft, kind == .languages ? texts.count : layouts.count, added)
    }

    static func priceTable(_ drafts: [PricingDraft]) -> Delimited.Table {
        Delimited.Table(columns: columns[.prices]!, rows: drafts.map { [$0.appId, $0.territory, $0.currency, $0.amount, $0.startDate ?? "", $0.endDate ?? ""] })
    }

    static func releaseTable(_ plan: ReleasePlan?) -> Delimited.Table {
        Delimited.Table(columns: columns[.release]! + releaseOptions, rows: plan.map { [[$0.appId, $0.sourceRevisionId, $0.baseVersionId, $0.targetVersion, $0.releaseType ?? "MANUAL", $0.earliestReleaseDate ?? ""]] } ?? [])
    }
}

extension WorkspaceSession {
    /// The source and version a material transfer applies to: the release plan's when there is one, otherwise the chosen or newest revision.
    func materialContext(accountId: String, appId: String, revisionId: String?) throws -> (source: Revision, draft: JSONText, versionId: String?, plan: ReleasePlan?) {
        let plan = try releasePlan(accountId: accountId, appId: appId), history = try revisions(accountId: accountId, appId: appId)
        guard let source = history.first(where: { $0.id == (revisionId ?? plan?.sourceRevisionId ?? history.first?.id) }), plan == nil || source.id == plan!.sourceRevisionId else {
            throw TransferFailure.invalid("The workspace source changed. Reload and choose the file again.")
        }
        let draft = try storeAccess { try $0.document(namespace: "drafts", key: "\(accountId):\(appId):\(source.id)").map { try JSONText.parse($0.payload) } } ?? TextDrafts.empty(source.id)
        return (source, draft, plan?.baseVersionId, plan)
    }

    /// The current data for an export; a template has only the columns.
    public func exportTransfer(accountId: String, appId: String, kind: TransferKind, revisionId: String? = nil, template: Bool = false, applePrices: [PriceRow]? = nil) throws -> Delimited.Table {
        if template { return kind == .release ? Transfer.releaseTable(nil) : Delimited.Table(columns: Transfer.columns[kind]!, rows: []) }
        switch kind {
        case .languages, .screenshots:
            let context = try materialContext(accountId: accountId, appId: appId, revisionId: revisionId)
            return Transfer.materialTable(kind, source: context.source, draft: context.draft, versionId: context.versionId)
        case .release: return Transfer.releaseTable(try releasePlan(accountId: accountId, appId: appId))
        case .prices:
            if let applePrices {
                let current = PricingMath.current(applePrices, today: ProductPricing.today()).values.sorted { $0.territory < $1.territory }
                return Delimited.Table(columns: Transfer.columns[.prices]!, rows: current.filter { !$0.currency.isEmpty && !$0.customerPrice.isEmpty }.map { [appId, $0.territory, $0.currency, $0.customerPrice, "", ""] })
            }
            return Transfer.priceTable(try pricingDrafts(accountId: accountId, appId: appId))
        }
    }

    /// Previews an import, or applies it when `fingerprint` is the preview's. Nothing is sent to App Store Connect.
    public func importTransfer(account: Account, appId: String, kind: TransferKind, table: Delimited.Table, revisionId: String? = nil, currencies: [String: String] = [:], fingerprint: String? = nil, now: Date = Date()) throws -> TransferPreview {
        guard account.appIds.contains(appId) else { throw TransferFailure.invalid("App not found.") }
        let apply = fingerprint != nil
        func signature(_ state: JSONText) -> String { Apple.sha(JSONText.array([.string(kind.rawValue), .array(table.columns.map { .string($0) }), .array(table.rows.map { .array($0.map { .string($0) }) }), state]).stringify()) }
        func check(_ state: JSONText) throws -> String {
            let value = signature(state)
            if apply && value != fingerprint { throw TransferFailure.changed }
            return value
        }
        switch kind {
        case .languages, .screenshots:
            let context = try materialContext(accountId: account.id, appId: appId, revisionId: revisionId)
            let names = Dictionary(context.source.versions.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
            func run(_ draft: JSONText) throws -> (JSONText, TransferPreview) {
                let print = try check(.array([.string(context.source.id), draft, context.versionId.map { .string($0) } ?? .null]))
                let result = try Transfer.importMaterials(kind, table, source: context.source, draft: draft, versionId: context.versionId)
                let preview = TransferPreview(changes: Transfer.changes(kind, before: Transfer.materialTable(kind, source: context.source, draft: draft, versionId: context.versionId),
                                                                        after: Transfer.materialTable(kind, source: context.source, draft: result.draft, versionId: context.versionId), versionNames: names),
                                              fingerprint: print, count: result.count, added: result.added, totalRows: table.rows.count, saved: apply)
                return (result.draft, preview)
            }
            guard apply else { return try run(context.draft).1 }
            // The release plan's lock is held through the draft write, in the documented lock order.
            let directory = try storeAccess { $0.directory }
            return try FileMutex.withLock(directory.appendingPathComponent("release_plans.mutex")) {
                let plan = try releasePlan(accountId: account.id, appId: appId)
                guard plan?.sourceRevisionId == context.plan?.sourceRevisionId, plan?.baseVersionId == context.versionId else { throw TransferFailure.changed }
                return try mutateDraft(accountId: account.id, appId: appId, revisionId: context.source.id) { draft, _ in try run(draft) }
            }
        case .prices:
            let rows = try Delimited.records(table, expected: Transfer.columns[.prices]!)
            func run(_ existing: [PricingDraft], protected: [String]) throws -> ([JSONText], TransferPreview) {
                let print = try check(.array([.array(existing.map(\.json)), .array(protected.sorted().map { .string($0) }), .object(currencies.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })]))
                let created = CustomerReview.isoString(now)
                let incoming = try rows.map { row -> PricingDraft in
                    guard row["app_id"] == appId else { throw TransferFailure.invalid("A price row belongs to another app.") }
                    let territory = row["territory"] ?? "", currency = row["currency"] ?? ""
                    guard let known = currencies[territory], known == currency else { throw TransferFailure.invalid("Country or currency does not match Apple's catalog: \(territory).") }
                    guard !protected.contains(territory) else { throw TransferFailure.invalid("Price protection is enabled for \(territory). Unlock that country or remove its row before importing.") }
                    let amount = row["amount"] ?? "", start = (row["start_date"] ?? "").isEmpty ? nil : row["start_date"], end = (row["end_date"] ?? "").isEmpty ? nil : row["end_date"]
                    if amount.range(of: #"^0(?:\.0{1,4})?$"#, options: .regularExpression) == nil { do { _ = try PricingMath.desired(amount) } catch { throw TransferFailure.invalid("Enter a positive price with up to four decimals for \(territory).") } }
                    guard (start == nil) == (end == nil), start.map(ReportTables.validDate) ?? true, end.map(ReportTables.validDate) ?? true, (start ?? "") <= (end ?? "") else { throw TransferFailure.invalid("Temporary prices need valid start and end dates.") }
                    return PricingDraft(id: UUID().uuidString.lowercased(), accountId: account.id, appId: appId, territory: territory, currency: currency, amount: amount, startDate: start, endDate: end, createdAt: created)
                }
                let keys = incoming.map { "\($0.territory):\($0.startDate ?? "null"):\($0.endDate ?? "null")" }
                guard Set(keys).count == keys.count else { throw TransferFailure.invalid("A price period occurs more than once for a country.") }
                let kept = existing.filter { !keys.contains("\($0.territory):\($0.startDate ?? "null"):\($0.endDate ?? "null")") }
                let permanent = Set(incoming.filter { $0.startDate == nil }.map(\.territory))
                let all = kept.filter { $0.startDate != nil || !permanent.contains($0.territory) } + incoming
                var periods: [String: [(String, String)]] = [:]
                for draft in all { if let start = draft.startDate, let end = draft.endDate {
                    if periods[draft.territory, default: []].contains(where: { $0.0 <= end && start <= $0.1 }) { throw TransferFailure.invalid("Temporary price dates overlap for a country.") }
                    periods[draft.territory, default: []].append((start, end))
                } }
                return (all.map(\.json), TransferPreview(changes: Transfer.changes(.prices, before: Transfer.priceTable(existing), after: Transfer.priceTable(all)), fingerprint: print, count: rows.count, added: 0, totalRows: rows.count, saved: apply))
            }
            func locks(_ value: JSONText?) -> [String] { Self.items(value?["locks"]).filter { $0["accountId"]?.text == account.id && $0["appId"]?.text == appId && $0["priceProduct"]?.text == "paid-app" }.compactMap { $0["territory"]?.text } }
            guard apply else { return try run(try pricingDrafts(accountId: account.id, appId: appId), protected: try priceProtection(accountId: account.id, appId: appId).map(\.territory)).1 }
            return try storeAccess { store in
                try PricingLock.holding([.protection, .drafts], in: store) {
                    let protected = locks(try stateDocument(store, "price_protection").1)
                    let (document, value) = try stateDocument(store, "pricing_drafts")
                    let everything = Self.items(value?["drafts"]), others = everything.filter { !($0["accountId"]?.text == account.id && $0["appId"]?.text == appId) }
                    let mine = everything.compactMap(PricingDraft.init).filter { $0.accountId == account.id && $0.appId == appId }
                    let (drafts, preview) = try run(mine, protected: protected)
                    guard others.count + drafts.count <= 2000 else { throw TransferFailure.invalid("Too many price drafts.") }
                    try writeState(store, "pricing_drafts", previous: document, value: .object([("schemaVersion", .number(1)), ("drafts", .array(others + drafts))]))
                    return preview
                }
            }
        case .release:
            let rows = try Delimited.records(table, expected: Transfer.columns[.release]!, optional: Transfer.releaseOptions)
            guard rows.count == 1, rows[0]["app_id"] == appId else { throw TransferFailure.invalid("Choose one release plan for this app.") }
            let row = rows[0], target = row["target_version"] ?? ""
            guard target.range(of: #"^\d+(?:\.\d+){0,2}$"#, options: .regularExpression) != nil else { throw TransferFailure.invalid("Use a version number such as 2.0 or 2.0.1.") }
            let history = try revisions(accountId: account.id, appId: appId)
            guard let source = history.first(where: { $0.id == row["source_revision_id"] }), let version = source.versions.first(where: { $0.id == row["base_version_id"] }) else {
                throw TransferFailure.invalid("The release source was not found. Import its Apple metadata first.")
            }
            let current = try releasePlan(accountId: account.id, appId: appId)
            let print = try check(current.map { .string($0.token) } ?? .null)
            if let current, current.sourceRevisionId != source.id || current.baseVersionId != version.id { throw TransferFailure.invalid("This app already has a plan with another source. Remove that plan before changing its source.") }
            let type = row["release_type"] ?? current?.releaseType ?? "MANUAL", earliest = row["release_type"] != nil ? (row["earliest_release_date"] ?? "") : (current?.earliestReleaseDate ?? "")
            let after = Delimited.Table(columns: Transfer.columns[.release]! + Transfer.releaseOptions, rows: [[appId, source.id, version.id, target, type, earliest]])
            let preview = TransferPreview(changes: Transfer.changes(.release, before: Transfer.releaseTable(current), after: after), fingerprint: print, count: 1, added: 0, totalRows: 1, saved: apply)
            if apply {
                let date = earliest.isEmpty ? nil : ASO.iso(earliest)
                do {
                    _ = try saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: source.id, baseVersionId: version.id, targetVersion: target, releaseType: type, earliestReleaseDate: date, expected: current?.token, now: now)
                } catch let failure as ReleaseFailure { throw TransferFailure.invalid(failure.message) }
            }
            return preview
        }
    }
}
