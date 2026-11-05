import Foundation

public enum AgeRating {
    public static let frequency: [(String, String)] = [("alcoholTobaccoOrDrugUseOrReferences", "Alcohol, tobacco or drugs"), ("contests", "Contests"), ("gamblingSimulated", "Simulated gambling"),
        ("gunsOrOtherWeapons", "Guns or other weapons"), ("medicalOrTreatmentInformation", "Medical or treatment information"), ("profanityOrCrudeHumor", "Profanity or crude humor"),
        ("sexualContentGraphicAndNudity", "Graphic sexual content or nudity"), ("sexualContentOrNudity", "Sexual content or nudity"), ("horrorOrFearThemes", "Horror or fear themes"),
        ("matureOrSuggestiveThemes", "Mature or suggestive themes"), ("violenceCartoonOrFantasy", "Cartoon or fantasy violence"),
        ("violenceRealisticProlongedGraphicOrSadistic", "Prolonged graphic or sadistic violence"), ("violenceRealistic", "Realistic violence")]
    public static let boolean: [(String, String)] = [("advertising", "Advertising"), ("gambling", "Real money gambling"), ("healthOrWellnessTopics", "Health or wellness topics"),
        ("lootBox", "Loot boxes or randomized items"), ("messagingAndChat", "Messaging or chat"), ("parentalControls", "Parental controls"), ("ageAssurance", "Age assurance"),
        ("socialMedia", "Social media"), ("socialMediaAgeRestricted", "Age restricted social media"), ("unrestrictedWebAccess", "Unrestricted web access"), ("userGeneratedContent", "User generated content")]
    public static let optional: [(String, String)] = [("kidsAgeBand", "Made for Kids age band"), ("ageRatingOverrideV2", "Global age rating override"), ("koreaAgeRatingOverride", "Korea age rating override"), ("developerAgeRatingInfoUrl", "Age rating information URL")]
    public static let frequencyValues = ["NONE", "INFREQUENT", "FREQUENT"], kidsValues = ["FIVE_AND_UNDER", "SIX_TO_EIGHT", "NINE_TO_ELEVEN"]
    public static let globalValues = ["NONE", "NINE_PLUS", "THIRTEEN_PLUS", "SIXTEEN_PLUS", "EIGHTEEN_PLUS", "UNRATED"], koreaValues = ["NONE", "FIFTEEN_PLUS", "NINETEEN_PLUS"]

    public static func label(_ key: String) -> String { (frequency + boolean + optional).first { $0.0 == key }?.1 ?? key }

    /// Questions Apple needs answered before a version can be added for review. Apple creates the declaration with every
    /// answer empty, so a declaration that exists is not yet a complete one. Age restricted social media follows Social media.
    public static func unanswered(_ attributes: JSONText?) -> [String] {
        (frequency + boolean).map(\.0).filter { key in
            if key == "socialMediaAgeRestricted" { return attributes?["socialMedia"] == .bool(true) && (attributes?[key] == nil || attributes?[key] == .null) }
            return attributes?[key] == nil || attributes?[key] == .null
        }
    }

    public static func describe(_ value: JSONText?) -> String {
        switch value {
        case nil: return "Not answered at Apple"
        case .null?, .string("NONE")?: return "None"
        case .bool(let flag)?: return flag ? "Yes" : "No"
        case .string(let text)?: return text.hasPrefix("https://") ? text : text.replacingOccurrences(of: "_", with: " ").lowercased()
        default: return value!.stringify()
        }
    }

    /// Validates age rating changes against the questionnaire's allowed answers.
    static func validate(_ changes: [(String, JSONText)]) throws {
        guard !changes.isEmpty, changes.count <= 28 else { throw PublishFailure.invalid("Choose at least one age rating answer to review.") }
        for (key, answer) in changes {
            switch (key, answer) {
            case (let key, .string(let value)) where frequency.contains(where: { $0.0 == key }) && frequencyValues.contains(value): continue
            case (let key, .bool) where boolean.contains(where: { $0.0 == key }): continue
            case ("kidsAgeBand", .null): continue
            case ("kidsAgeBand", .string(let value)) where kidsValues.contains(value): continue
            case ("ageRatingOverrideV2", .string(let value)) where globalValues.contains(value): continue
            case ("koreaAgeRatingOverride", .string(let value)) where koreaValues.contains(value): continue
            case ("developerAgeRatingInfoUrl", .null): continue
            case ("developerAgeRatingInfoUrl", .string(let value)) where value.utf16.count <= 2048 && value == value.trimmingCharacters(in: .whitespaces)
                && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                && URLComponents(string: value).map({ $0.scheme?.lowercased() == "https" && $0.host?.isEmpty == false && ($0.user ?? "").isEmpty && ($0.password ?? "").isEmpty && ($0.fragment ?? "").isEmpty }) == true: continue
            default: throw PublishFailure.invalid("Invalid age rating answer for \(key).")
            }
        }
    }

    static func digest(_ attributes: JSONText) -> String {
        JSONText.array((frequency + boolean + optional).map { .array([.string($0.0), attributes[$0.0] ?? .null]) }).sha256
    }
}

extension WorkspaceSession {
    func ageRatingDeclaration(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let get = { (path: String) in planner != nil ? try await planner!.get(path) : try await client.get(path) }
        let infos = try await list("/v1/apps/\(appId)/appInfos?include=app&limit=200")
        guard infos.allSatisfy({ $0.type == "appInfos" && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned app information outside the selected app.") }
        let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }
        guard editable.count == 1 else { throw PublishFailure.invalid("Choose one editable app information record at Apple before changing the age rating.") }
        let page = try await get("/v1/appInfos/\(editable[0].id)/ageRatingDeclaration")
        guard page.count == 1, let declaration = page.first, declaration.type == "ageRatingDeclarations", !declaration.id.isEmpty, declaration.attributes != nil,
              declaration.relationships?["appInfo"] == nil || Apple.owned(declaration, "appInfo", "appInfos", editable[0].id) else { throw PublishFailure.invalid("Apple did not return an age rating declaration for this app.") }
        return declaration
    }

    public func ageRatingAnswers(appId: String, client: AppStoreConnectClient) async throws -> [String: JSONText] {
        let declaration = Planner.resource(try await ageRatingDeclaration(appId: appId, client: client))
        guard case .object(let pairs)? = declaration["attributes"] else { throw PublishFailure.invalid("Apple did not return the age rating answers. Try again.") }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func planAgeRating(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let changes = request.ageRatingChanges else { throw PublishFailure.invalid("Choose age rating answers before preparing a review.") }
        let declaration = try await ageRatingDeclaration(appId: request.appId, client: planner.client, planner: planner)
        let attributes = Planner.resource(declaration)["attributes"] ?? .object([])
        let changed = changes.filter { attributes[$0.0] != $0.1 }
        guard !changed.isEmpty else { throw PublishFailure.invalid("The selected age rating answers already match Apple. Change an answer before preparing a review.") }
        let describe = { (values: [(String, JSONText?)]) in values.map { "\(AgeRating.label($0.0)): \(AgeRating.describe($0.1))" }.joined(separator: "\n") }
        planner.add(.api, method: "PATCH", path: [.string("ageRatingDeclarations"), .string(declaration.id)], label: "Update app age rating declaration", detail: "\(changed.count) answers. Apple calculates the displayed age rating.",
                    before: describe(changed.map { ($0.0, attributes[$0.0]) }), after: describe(changed.map { ($0.0, $0.1) }),
                    body: .object([("data", .object([("type", .string("ageRatingDeclarations")), ("id", .string(declaration.id)), ("attributes", .object(changed))]))]),
                    guard: .object([("kind", .string("age-rating")), ("digest", .string(AgeRating.digest(attributes)))]))
        planner.notes.append("Only the reviewed answers are sent. Apple calculates the resulting age rating and may require additional information before App Review.")
        return "Update age rating declaration"
    }
}
