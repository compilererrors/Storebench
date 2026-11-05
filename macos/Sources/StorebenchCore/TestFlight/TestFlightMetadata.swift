import Foundation

/// TestFlight text, links and content snapshots follow the publishing contract.
public enum TestFlightMetadata {
    public typealias Resource = AppStoreConnectClient.Resource
    public static let optionalFields = ["marketingUrl", "privacyPolicyUrl", "tvOsPrivacyPolicy"]
    static func forbidden(_ text: String, multiline: Bool) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x7f || $0.value < 0x20 && (!multiline || ![9, 10, 13].contains($0.value)) }
    }
    public static func text(_ value: String, label: String) throws -> String {
        let trimmed = TextSemantics.trim(value)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 4000, !forbidden(value, multiline: true) else { throw PublishFailure.invalid("Enter \(label) of 1–4,000 characters.") }
        return trimmed
    }
    public static func privacyPolicy(_ value: String) throws -> String {
        guard value.utf16.count <= 4000, !forbidden(value, multiline: true) else { throw PublishFailure.invalid("Enter tvOS privacy policy text of up to 4,000 characters.") }
        return TextSemantics.trim(value)
    }
    public static func url(_ value: String, label: String) throws -> String {
        guard value.utf16.count <= 255, !forbidden(value, multiline: false) else { throw PublishFailure.invalid("Enter a valid \(label) of up to 255 characters.") }
        let trimmed = TextSemantics.trim(value)
        if trimmed.isEmpty { return "" }
        // WHATWG's HTTPS parser accepts omitted and backslash separators. The original trimmed value is retained.
        guard trimmed.prefix(6).lowercased() == "https:" else { throw PublishFailure.invalid("Enter a complete HTTPS \(label).") }
        let suffix = String(trimmed.dropFirst(6)).replacingOccurrences(of: "\\", with: "/").drop { $0 == "/" }
        guard let components = URLComponents(string: "https://" + suffix), let parsed = components.url, let host = parsed.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              (components.user ?? "").isEmpty, (components.password ?? "").isEmpty, components.port.map({ (0...65535).contains($0) }) ?? true else { throw PublishFailure.invalid("Enter a public HTTPS \(label).") }
        let numericHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").last.map(String.init) ?? ""
        let numericEnd = numericHost.range(of: "^(?:[0-9]+|0[xX][0-9a-fA-F]*)$", options: .regularExpression) != nil
        guard host.contains("."), host != "localhost", !host.hasSuffix(".local"), !numericEnd, !host.contains(":"),
              !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f || " #%/<>?@[\\]^|".unicodeScalars.contains($0) }) else { throw PublishFailure.invalid("Enter a public HTTPS \(label).") }
        return trimmed
    }
    static func string(_ resource: Resource, _ field: String) throws -> String {
        switch resource.attributes?[field] { case .string(let text)?: return text; case nil, .null?: return ""; default: throw PublishFailure.invalid("Apple did not confirm the current TestFlight information.") }
    }
    static func selected(_ resources: [Resource], ownerId: String, type: String, locale: String) throws -> Resource? {
        let relation = type == "betaAppLocalizations" ? "app" : "build", ownerType = relation == "app" ? "apps" : "builds"
        guard resources.allSatisfy({ $0.type == type && !$0.id.isEmpty && Apple.owned($0, relation, ownerType, ownerId) && $0.attributes?["locale"]?.string != nil }),
              Set(resources.map { Data($0.id.utf8) }).count == resources.count, Set(resources.compactMap { $0.attributes?["locale"]?.string.map { Data($0.utf8) } }).count == resources.count else { throw PublishFailure.invalid("Apple did not confirm the current TestFlight localization.") }
        return resources.first { TextSemantics.same($0.attributes?["locale"]?.string, locale) }
    }
    static func information(_ resource: Resource?, locale: String) throws -> TestFlightLocalization {
        guard let resource else { return TestFlightLocalization(locale: locale, description: "", feedbackEmail: "") }
        return TestFlightLocalization(locale: locale, description: try string(resource, "description"), feedbackEmail: try string(resource, "feedbackEmail"),
                                      marketingUrl: try string(resource, "marketingUrl"), privacyPolicyUrl: try string(resource, "privacyPolicyUrl"), tvOsPrivacyPolicy: try string(resource, "tvOsPrivacyPolicy"))
    }
    public static func appDigest(appId: String, locale: String, resources: [Resource]) throws -> String {
        let current = try selected(resources, ownerId: appId, type: "betaAppLocalizations", locale: locale)
        return JSONText.object([("appId", .string(appId)), ("locale", .string(locale)), ("current", try current.map { .object([("id", .string($0.id)), ("fields", try information($0, locale: locale).fieldsJSON)]) } ?? .null)]).sha256
    }
    public static func notesDigest(buildId: String, locale: String, resources: [Resource]) throws -> String {
        let current = try selected(resources, ownerId: buildId, type: "betaBuildLocalizations", locale: locale)
        return JSONText.object([("buildId", .string(buildId)), ("locale", .string(locale)), ("current", try current.map { .object([("id", .string($0.id)), ("whatsNew", .string(try string($0, "whatsNew")))]) } ?? .null)]).sha256
    }
}

extension TestFlightLocalization {
    var fieldsJSON: JSONText { .object([("description", .string(description)), ("feedbackEmail", .string(feedbackEmail)), ("marketingUrl", .string(marketingUrl)), ("privacyPolicyUrl", .string(privacyPolicyUrl)), ("tvOsPrivacyPolicy", .string(tvOsPrivacyPolicy))]) }
    public static func == (a: Self, b: Self) -> Bool { JSONText.string(a.locale) == .string(b.locale) && a.fieldsJSON == b.fieldsJSON }
    public var display: String {
        ["Description: \(description.isEmpty ? "Empty" : description)", "Feedback email: \(feedbackEmail.isEmpty ? "Empty" : feedbackEmail)", "Marketing URL: \(marketingUrl.isEmpty ? "Empty" : marketingUrl)",
         "Privacy policy URL: \(privacyPolicyUrl.isEmpty ? "Empty" : privacyPolicyUrl)", "tvOS privacy policy: \(tvOsPrivacyPolicy.isEmpty ? "Empty" : tvOsPrivacyPolicy)"].joined(separator: "\n")
    }
}

extension WorkspaceSession {
    func scopedBetaLocalizations(_ resources: [AppStoreConnectClient.Resource], ownerId: String, type: String, list: (String) async throws -> [AppStoreConnectClient.Resource]) async throws -> [AppStoreConnectClient.Resource] {
        guard ["betaAppLocalizations", "betaBuildLocalizations"].contains(type), !ownerId.isEmpty, resources.allSatisfy({ $0.type == type && $0.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil }), Set(resources.map(\.id)).count == resources.count else { throw PublishFailure.invalid("Apple returned unexpected TestFlight localizations.") }
        let relation = type == "betaAppLocalizations" ? "app" : "build", ownerType = relation == "app" ? "apps" : "builds"
        var result: [AppStoreConnectClient.Resource] = []
        for resource in resources {
            var item = resource
            if Planner.resource(item)["relationships"]?[relation]?["data"] == nil {
                let owners = try await list("/v1/\(type)/\(item.id)/relationships/\(relation)")
                guard owners.count == 1, owners[0].type == ownerType, owners[0].id == ownerId else { throw PublishFailure.invalid("Apple did not confirm the TestFlight localization owner.") }
                var relationships = item.relationships ?? [:]; relationships[relation] = .object(["data": .object(["type": .string(ownerType), "id": .string(ownerId)])])
                item = AppStoreConnectClient.Resource(type: item.type, id: item.id, attributes: item.attributes, relationships: relationships)
            }
            guard Apple.owned(item, relation, ownerType, ownerId) else { throw PublishFailure.invalid("Apple returned TestFlight localizations outside the selected owner.") }
            result.append(item)
        }
        return result
    }
    func betaLocalizations(ownerId: String, type: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> [AppStoreConnectClient.Resource] {
        let path = type == "betaAppLocalizations" ? "/v1/betaAppLocalizations?filter%5Bapp%5D=\(ownerId)&limit=200" : "/v1/builds/\(ownerId)/betaBuildLocalizations?limit=200"
        let values = planner != nil ? try await planner!.list(path) : try await client.list(path)
        return try await scopedBetaLocalizations(values, ownerId: ownerId, type: type) { path in planner != nil ? try await planner!.list(path) : try await client.list(path) }
    }
    func betaLicense(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource? {
        let values = planner != nil ? try await planner!.get("/v1/apps/\(appId)/betaLicenseAgreement") : try await client.get("/v1/apps/\(appId)/betaLicenseAgreement")
        guard values.count <= 1 else { throw PublishFailure.invalid("Apple returned an ambiguous beta license agreement.") }
        guard let value = values.first else { return nil }
        guard value.type == "betaLicenseAgreements", value.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil, value.attributes?["agreementText"]?.string != nil else { throw PublishFailure.invalid("Apple did not return a beta license agreement for this app.") }
        let path = "/v1/betaLicenseAgreements/\(value.id)/relationships/app", owners = planner != nil ? try await planner!.get(path) : try await client.get(path)
        guard owners.count == 1, owners[0].type == "apps", owners[0].id == appId else { throw PublishFailure.invalid("This beta license agreement does not belong to the selected app.") }
        return value
    }
    public func testFlightAppInformation(appId: String, client: AppStoreConnectClient) async throws -> [TestFlightLocalization] {
        try requireFeedbackScope(appId: appId, client: client)
        let items = try await betaLocalizations(ownerId: appId, type: "betaAppLocalizations", client: client)
        let result = try items.map { item -> TestFlightLocalization in
            guard let locale = item.attributes?["locale"]?.string else { throw PublishFailure.invalid("Apple did not confirm the current TestFlight language.") }
            _ = try TestFlightMetadata.appDigest(appId: appId, locale: locale, resources: items)
            return try TestFlightMetadata.information(item, locale: locale)
        }
        try requireFeedbackScope(appId: appId, client: client)
        return result.sorted { $0.locale < $1.locale }
    }
    public func testFlightBetaLicense(appId: String, client: AppStoreConnectClient) async throws -> String? {
        try requireFeedbackScope(appId: appId, client: client)
        let result = try await betaLicense(appId: appId, client: client)?.attributes?["agreementText"]?.string
        try requireFeedbackScope(appId: appId, client: client)
        return result
    }
    func planTestFlightContent(_ planner: Planner) async throws -> String? {
        let request = planner.request, client = planner.client
        if request.testflightAction == "save-beta-license" {
            guard let text = request.agreementText, !TextSemantics.trim(text).isEmpty, text.utf16.count <= 20000, !TestFlightMetadata.forbidden(text, multiline: true), let current = try await betaLicense(appId: request.appId, client: client, planner: planner), let before = current.attributes?["agreementText"]?.string else { throw PublishFailure.invalid("Enter beta license text of 1–20,000 characters for this app's agreement.") }
            if !TextSemantics.same(before, text) {
                planner.add(.api, method: "PATCH", path: [.string("betaLicenseAgreements"), .string(current.id)], label: "Update TestFlight beta license", detail: "Agreement shown to this app's TestFlight testers", before: before, after: text,
                            body: .object([("data", .object([("type", .string("betaLicenseAgreements")), ("id", .string(current.id)), ("attributes", .object([("agreementText", .string(text))]))]))]),
                            guard: .object([("kind", .string("beta-license")), ("digest", .string(Apple.sha(before)))]))
            }
            planner.notes.append("Review the complete terms before approval. Apple presents this agreement to people testing this app through TestFlight.")
            return "TestFlight beta license agreement"
        }
        if request.testflightAction == "save-beta-info" {
            guard let locale = request.locale, let description = request.betaDescription, let email = request.feedbackEmail else { throw PublishFailure.invalid("Enter a supported TestFlight language, description and feedback email.") }
            let items = try await betaLocalizations(ownerId: request.appId, type: "betaAppLocalizations", client: client, planner: planner), current = try TestFlightMetadata.selected(items, ownerId: request.appId, type: "betaAppLocalizations", locale: locale)
            let old = try TestFlightMetadata.information(current, locale: locale)
            let next = TestFlightLocalization(locale: locale, description: description, feedbackEmail: email, marketingUrl: request.betaMarketingUrl ?? old.marketingUrl, privacyPolicyUrl: request.betaPrivacyPolicyUrl ?? old.privacyPolicyUrl, tvOsPrivacyPolicy: request.betaTvOsPrivacyPolicy ?? old.tvOsPrivacyPolicy)
            var optional: [(String, JSONText)] = []
            for field in TestFlightMetadata.optionalFields {
                let before = old.fieldsJSON[field]?.text ?? "", after = next.fieldsJSON[field]?.text ?? ""
                guard before.isEmpty || !after.isEmpty else { throw PublishFailure.invalid("Apple does not allow removing existing \(field) TestFlight information. Restore its value or replace it.") }
                if !after.isEmpty, !TextSemantics.same(before, after) { optional.append((field, .string(after))) }
            }
            if current == nil || !TextSemantics.same(old.description, next.description) || !TextSemantics.same(old.feedbackEmail, next.feedbackEmail) || !optional.isEmpty {
                var fields: [(String, JSONText)] = [("type", .string("betaAppLocalizations"))]
                if let current { fields.append(("id", .string(current.id))) }
                fields.append(("attributes", .object((current == nil ? [("locale", .string(locale))] : []) + [("description", .string(next.description)), ("feedbackEmail", .string(next.feedbackEmail))] + optional)))
                if current == nil { fields.append(("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))) }
                planner.add(.api, method: current == nil ? "POST" : "PATCH", path: current.map { [.string("betaAppLocalizations"), .string($0.id)] } ?? [.string("betaAppLocalizations")], label: current == nil ? "Add TestFlight test information" : "Update TestFlight test information", detail: locale,
                            before: current == nil ? "No TestFlight information for this language" : old.display, after: next.display, body: .object([("data", .object(fields))]),
                            guard: .object([("kind", .string("beta-app-info")), ("locale", .string(locale)), ("digest", .string(try TestFlightMetadata.appDigest(appId: request.appId, locale: locale, resources: items)))]))
            }
            planner.notes.append("This information is shown to TestFlight testers. Apple requires a description for every app localization before external beta review. Once information is added, Apple allows replacing values but not clearing them.")
            return "TestFlight test information · \(locale)"
        }
        guard request.testflightAction == "save-build-notes" else { return nil }
        guard let build = try await appBuilds(appId: request.appId, client: client, planner: planner).first(where: { $0.id == request.buildId }), let locale = request.locale, let text = request.whatsNew else { throw PublishFailure.invalid("Choose a build, a supported language and What to Test text.") }
        let items = try await betaLocalizations(ownerId: build.id, type: "betaBuildLocalizations", client: client, planner: planner), current = try TestFlightMetadata.selected(items, ownerId: build.id, type: "betaBuildLocalizations", locale: locale)
        let before = try current.map { try TestFlightMetadata.string($0, "whatsNew") } ?? "No What to Test text for this language"
        if current == nil || !TextSemantics.same(before, text) {
            var fields: [(String, JSONText)] = [("type", .string("betaBuildLocalizations"))]
            if let current { fields.append(("id", .string(current.id))) }
            fields.append(("attributes", .object((current == nil ? [("locale", .string(locale))] : []) + [("whatsNew", .string(text))])))
            if current == nil { fields.append(("relationships", .object([("build", Apple.relationship("builds", .string(build.id)))]))) }
            planner.add(.api, method: current == nil ? "POST" : "PATCH", path: current.map { [.string("betaBuildLocalizations"), .string($0.id)] } ?? [.string("betaBuildLocalizations")], label: current == nil ? "Add What to Test" : "Update What to Test", detail: "Build \(build.attributes?["version"]?.string ?? build.id) · \(locale)", before: before, after: text,
                        body: .object([("data", .object(fields))]), guard: .object([("kind", .string("beta-build-notes")), ("buildId", .string(build.id)), ("locale", .string(locale)), ("digest", .string(try TestFlightMetadata.notesDigest(buildId: build.id, locale: locale, resources: items)))]))
        }
        planner.notes.append("What to Test appears with this build in TestFlight and helps testers focus their feedback.")
        return "What to Test · build \(build.attributes?["version"]?.string ?? build.id) · \(locale)"
    }

    func verifyTestFlightContent(root: String, method: String, parts: [String], data: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        guard parts.first == root, ["POST", "PATCH"].contains(method), data?["type"]?.text == root,
              case .object(let envelope)? = data, Set(envelope.map(\.0)).count == envelope.count,
              case .object(let attributes)? = data?["attributes"], !attributes.isEmpty, Set(attributes.map(\.0)).count == attributes.count else { throw PublishFailure.write("Unsupported TestFlight content update.") }
        let creating = method == "POST"
        guard creating ? parts.count == 1 && data?["id"] == nil && Set(envelope.map(\.0)) == ["type", "attributes", "relationships"]
                       : parts.count == 2 && data?["id"]?.text == parts[1] && data?["relationships"] == nil && Set(envelope.map(\.0)) == ["type", "id", "attributes"] else { throw PublishFailure.write("Unsupported TestFlight content target.") }
        if root == "betaLicenseAgreements" {
            guard !creating, attributes.count == 1, let text = data?["attributes"]?["agreementText"]?.text,
                  !TextSemantics.trim(text).isEmpty, text.utf16.count <= 20000, !TestFlightMetadata.forbidden(text, multiline: true),
                  guardValue?["kind"]?.text == "beta-license", let current = try await betaLicense(appId: appId, client: client), current.id == parts[1],
                  let before = current.attributes?["agreementText"]?.string, Apple.sha(before) == guardValue?["digest"]?.text else { throw PublishFailure.write("The beta license agreement changed after review. Prepare a new review.") }
            return
        }
        let appInformation = root == "betaAppLocalizations"
        guard appInformation || root == "betaBuildLocalizations", let locale = guardValue?["locale"]?.text,
              (appInformation ? StoreLocales.codes : TestFlightActions.buildLocales).contains(locale),
              guardValue?["kind"]?.text == (appInformation ? "beta-app-info" : "beta-build-notes") else { throw PublishFailure.write("Unsupported TestFlight localization update.") }
        let ownerId: String
        if appInformation { ownerId = appId }
        else {
            guard let buildId = guardValue?["buildId"]?.text, try await appBuilds(appId: appId, client: client).contains(where: { $0.id == buildId }) else { throw PublishFailure.write("The TestFlight build no longer belongs to this app.") }
            ownerId = buildId
        }
        let items = try await betaLocalizations(ownerId: ownerId, type: root, client: client), current = try TestFlightMetadata.selected(items, ownerId: ownerId, type: root, locale: locale)
        let digest = appInformation ? try TestFlightMetadata.appDigest(appId: appId, locale: locale, resources: items) : try TestFlightMetadata.notesDigest(buildId: ownerId, locale: locale, resources: items)
        guard digest == guardValue?["digest"]?.text else { throw PublishFailure.write("TestFlight content changed after review. Prepare a new review.") }
        if creating {
            let relation = appInformation ? "app" : "build", ownerType = appInformation ? "apps" : "builds"
            guard current == nil, data?["attributes"]?["locale"]?.text == locale,
                  data?["relationships"] == .object([(relation, Apple.relationship(ownerType, .string(ownerId)))]) else { throw PublishFailure.write("The TestFlight localization target changed after review.") }
        } else {
            guard current?.id == parts[1], data?["attributes"]?["locale"] == nil else { throw PublishFailure.write("The TestFlight localization target changed after review.") }
        }
        let allowed = Set((creating ? ["locale"] : []) + (appInformation ? ["description", "feedbackEmail"] + TestFlightMetadata.optionalFields : ["whatsNew"]))
        guard attributes.allSatisfy({ allowed.contains($0.0) }) else { throw PublishFailure.write("Unsupported TestFlight localization fields.") }
        if appInformation {
            guard let description = data?["attributes"]?["description"]?.text, TextSemantics.same(try TestFlightMetadata.text(description, label: "a beta description"), description),
                  let email = data?["attributes"]?["feedbackEmail"]?.text, TestFlightAccess.validEmail(email), TextSemantics.same(email.lowercased(), email) else { throw PublishFailure.write("Invalid TestFlight test information.") }
            for field in TestFlightMetadata.optionalFields where data?["attributes"]?[field] != nil {
                guard let value = data?["attributes"]?[field]?.text, !value.isEmpty else { throw PublishFailure.write("Apple does not allow clearing optional TestFlight information.") }
                let checked = field == "tvOsPrivacyPolicy" ? try TestFlightMetadata.privacyPolicy(value) : try TestFlightMetadata.url(value, label: field)
                guard TextSemantics.same(checked, value) else { throw PublishFailure.write("Invalid optional TestFlight information.") }
            }
        } else {
            guard let text = data?["attributes"]?["whatsNew"]?.text, TextSemantics.same(try TestFlightMetadata.text(text, label: "What to Test text"), text) else { throw PublishFailure.write("Invalid What to Test text.") }
        }
    }
}
