import Foundation

public enum AccessibilityDeclarations {
    public static let families = [("IPHONE", "iPhone"), ("IPAD", "iPad"), ("APPLE_TV", "Apple TV"), ("APPLE_WATCH", "Apple Watch"), ("MAC", "Mac"), ("VISION", "Apple Vision")]
    public static let features: [(key: String, label: String, unavailable: [String])] = [("supportsVoiceover", "VoiceOver", []), ("supportsVoiceControl", "Voice Control", ["APPLE_TV", "APPLE_WATCH"]),
        ("supportsLargerText", "Larger Text", ["MAC"]), ("supportsSufficientContrast", "Sufficient Contrast", []), ("supportsDarkInterface", "Dark Interface", []),
        ("supportsDifferentiateWithoutColorAlone", "Differentiate Without Color Alone", []), ("supportsReducedMotion", "Reduced Motion", []), ("supportsCaptions", "Captions", []), ("supportsAudioDescriptions", "Audio Descriptions", [])]

    public static func applicable(_ family: String) -> [(key: String, label: String, unavailable: [String])] { features.filter { !$0.unavailable.contains(family) } }
    public static func familyName(_ family: String) -> String { families.first { $0.0 == family }?.1 ?? family }

    static func validate(_ answers: [(String, Bool)], family: String) throws {
        let allowed = applicable(family).map(\.key)
        guard answers.count == allowed.count, Set(answers.map(\.0)) == Set(allowed) else { throw PublishFailure.invalid("Choose Yes or No for every applicable accessibility feature.") }
    }

    static func summary(_ answers: (String) -> Bool?, family: String) -> String {
        applicable(family).map { "\($0.label): \(answers($0.key).map { $0 ? "Yes" : "No" } ?? "Not answered")" }.joined(separator: "\n")
    }

    static func scoped(_ resources: [AppStoreConnectClient.Resource], appId: String) throws -> [AppStoreConnectClient.Resource] {
        var ids = Set<String>(), active = Set<String>()
        for item in resources {
            let family = item.attributes?["deviceFamily"]?.string ?? "", state = item.attributes?["state"]?.string ?? ""
            guard item.type == "accessibilityDeclarations", !item.id.isEmpty, ids.insert(item.id).inserted, families.contains(where: { $0.0 == family }), ["DRAFT", "PUBLISHED", "REPLACED"].contains(state) else { throw PublishFailure.invalid("Apple returned ambiguous accessibility declarations for this app.") }
            if let relation = item.relationships?["app"] {
                guard case .object(let data) = relation, data["data"] == nil || Apple.owned(item, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned ambiguous accessibility declarations for this app.") }
            }
            for feature in features {
                if let answer = item.attributes?[feature.key], case .bool = answer { continue }
                else if item.attributes?[feature.key] != nil { throw PublishFailure.invalid("Apple returned invalid accessibility feature answers.") }
            }
            if state != "REPLACED" { guard active.insert("\(family):\(state)").inserted else { throw PublishFailure.invalid("Apple returned multiple active accessibility declarations for one device family.") } }
        }
        return resources
    }

    static func digest(_ resources: [AppStoreConnectClient.Resource], appId: String, family: String) -> String {
        let snapshot = resources.filter { $0.attributes?["deviceFamily"]?.string == family }.sorted { $0.id.compare($1.id, locale: Locale(identifier: "en")) == .orderedAscending }.map { item in
            JSONText.object([("id", .string(item.id)), ("state", item.attributes?["state"]?.string.map { .string($0) } ?? .null),
                             ("answers", .array(features.map { feature in .array([.string(feature.key), { if case .bool(let flag)? = item.attributes?[feature.key] { return .bool(flag) }; return .null }()]) }))])
        }
        return JSONText.object([("appId", .string(appId)), ("family", .string(family)), ("snapshot", .array(snapshot))]).sha256
    }
}

public struct AccessibilityDeclarationView: Identifiable, Sendable {
    public let id, family, state: String
    public let answers: [String: Bool]
    public init(id: String, family: String, state: String, answers: [String: Bool]) { self.id = id; self.family = family; self.state = state; self.answers = answers }
}

extension WorkspaceSession {
    public func accessibilityDeclarations(appId: String, client: AppStoreConnectClient) async throws -> [AccessibilityDeclarationView] {
        try AccessibilityDeclarations.scoped(try await client.list("/v1/apps/\(appId)/accessibilityDeclarations?limit=200"), appId: appId).map { item in
            var answers: [String: Bool] = [:]
            for feature in AccessibilityDeclarations.features { if case .bool(let flag)? = item.attributes?[feature.key] { answers[feature.key] = flag } }
            return AccessibilityDeclarationView(id: item.id, family: item.attributes?["deviceFamily"]?.string ?? "", state: item.attributes?["state"]?.string ?? "", answers: answers)
        }
    }

    func planAccessibility(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let family = request.accessibilityFamily, let action = request.accessibilityAction else { throw PublishFailure.invalid("Choose an accessibility declaration action and device family.") }
        let declarations = try AccessibilityDeclarations.scoped(try await planner.list("/v1/apps/\(request.appId)/accessibilityDeclarations?limit=200"), appId: request.appId)
        let current = declarations.filter { $0.attributes?["deviceFamily"]?.string == family }
        let draft = current.first { $0.attributes?["state"]?.string == "DRAFT" }, published = current.first { $0.attributes?["state"]?.string == "PUBLISHED" }
        let guardValue = JSONText.object([("kind", .string("accessibility-declaration")), ("digest", .string(AccessibilityDeclarations.digest(declarations, appId: request.appId, family: family))), ("family", .string(family))])
        let label = AccessibilityDeclarations.familyName(family)
        func answer(_ item: AppStoreConnectClient.Resource) -> (String) -> Bool? { { key in if case .bool(let flag)? = item.attributes?[key] { return flag }; return nil } }
        if action == "save-draft" {
            let answers = request.accessibilityAnswers ?? []
            try AccessibilityDeclarations.validate(answers, family: family)
            let ordered = AccessibilityDeclarations.applicable(family).compactMap { feature in answers.first { $0.0 == feature.key } }
            let changed = draft.map { item in ordered.contains { answer(item)($0.0) != $0.1 } } ?? true
            if changed {
                var data: [(String, JSONText)] = [("type", .string("accessibilityDeclarations"))]
                if let draft { data.append(("id", .string(draft.id))) }
                data.append(("attributes", .object((draft == nil ? [("deviceFamily", .string(family))] : []) + ordered.map { ($0.0, .bool($0.1)) })))
                if draft == nil { data.append(("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))) }
                planner.add(.api, method: draft == nil ? "POST" : "PATCH", path: draft.map { [.string("accessibilityDeclarations"), .string($0.id)] } ?? [.string("accessibilityDeclarations")],
                            label: draft == nil ? "Create accessibility draft" : "Update accessibility draft", detail: label,
                            before: draft.map { AccessibilityDeclarations.summary(answer($0), family: family) } ?? (published != nil ? "Published declaration remains visible until a new draft is published" : "No declaration for this device family"),
                            after: AccessibilityDeclarations.summary({ key in ordered.first { $0.0 == key }?.1 }, family: family), body: .object([("data", .object(data))]), guard: guardValue)
            }
            planner.notes.append("These are your app's self-reported accessibility features for this device family. Check every answer against the shipped app. Saving a draft does not publish it on the App Store.")
            return "\(draft == nil ? "Create" : "Update") accessibility draft · \(label)"
        }
        guard let draft else { throw PublishFailure.invalid("Apple has no accessibility draft for this device family. Save a draft first.") }
        let summary = AccessibilityDeclarations.summary(answer(draft), family: family)
        if action == "publish-draft" {
            guard AccessibilityDeclarations.applicable(family).allSatisfy({ answer(draft)($0.key) != nil }) else { throw PublishFailure.invalid("Choose Yes or No for every applicable accessibility feature.") }
            planner.add(.api, method: "PATCH", path: [.string("accessibilityDeclarations"), .string(draft.id)], label: "Publish accessibility declaration", detail: label, before: "Draft · \(summary)", after: "Published on the App Store · \(summary)",
                        body: .object([("data", .object([("type", .string("accessibilityDeclarations")), ("id", .string(draft.id)), ("attributes", .object([("publish", .bool(true))]))]))]), guard: guardValue)
            planner.notes.append("Publishing makes these self-reported accessibility features available for the app's selected device family. Check the complete draft before approval.")
            return "Publish accessibility declaration · \(label)"
        }
        planner.add(.api, method: "DELETE", path: [.string("accessibilityDeclarations"), .string(draft.id)], label: "Delete accessibility draft", detail: label, before: "Draft · \(summary)",
                    after: published != nil ? "Draft removed; existing published declaration remains" : "Draft removed; no declaration for this device family", guard: guardValue)
        planner.notes.append("Only the selected draft is deleted. An existing published declaration remains on the App Store.")
        return "Delete accessibility draft · \(label)"
    }
}
