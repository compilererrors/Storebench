import Foundation

/// One thing Apple refused a change for: its error code, the kind of resource it concerns, the field it points at and Apple's
/// own sentence about it, kept as plain single-line text so the stop says exactly what Apple wants.
public struct AppleProblem: Sendable, Equatable {
    public let code: String, resource: String?, field: String?
    public var detail: String? = nil

    /// App Store Connect's sections, each with the Release check that opens where it is answered.
    public enum Area: String, CaseIterable, Sendable {
        case ageRating = "age-rating", reviewInformation = "review-info", appConfiguration = "app-configuration", copyright, listing
        case build, exportCompliance = "export-compliance", pricing, availability = "territories", accessibility, privacy, tax, version, other

        public var title: String {
            switch self {
            case .ageRating: "Age Ratings"
            case .reviewInformation: "App Review Information"
            case .appConfiguration: "App Information"
            case .copyright: "Copyright"
            case .listing: "Product Page"
            case .build: "Build"
            case .exportCompliance: "Export Compliance"
            case .pricing: "Pricing"
            case .availability: "Availability"
            case .accessibility: "Accessibility"
            case .privacy: "App Privacy"
            case .tax: "Tax Category"
            case .version: "Version"
            case .other: "Other"
            }
        }
        /// The command that opens where it is answered. App Privacy and Tax Category are answered with an Apple ID in App Store changes.
        public var action: String {
            switch self {
            case .ageRating: "Answer Age Ratings"
            case .reviewInformation: "Open App Review Information"
            case .appConfiguration: "Open App Information"
            case .copyright: "Open Copyright"
            case .listing: "Open Text and Screenshots"
            case .build: "Open Build"
            case .exportCompliance: "Answer Export Compliance"
            case .pricing: "Open Pricing"
            case .availability: "Open Availability"
            case .accessibility: "Open Accessibility"
            case .privacy: "Answer App Privacy"
            case .tax: "Choose Tax Category"
            case .version: "Open Version"
            case .other: "Open"
            }
        }
        /// The Release check that opens the fix; nil for codes Storebench does not know.
        public var check: String? { self == .other ? nil : rawValue }
    }

    public var area: Area {
        if field == nil, let area = Self.codeArea(code) { return area }
        if resource == "ageRatingDeclarations" || field.map(Self.ages.contains) == true { return .ageRating }
        switch resource {
        case "appStoreReviewDetails", "appStoreReviewAttachments": return .reviewInformation
        case "appInfos": return .appConfiguration
        case "appStoreVersionLocalizations", "appInfoLocalizations", "appScreenshotSets", "appScreenshots", "appPreviewSets", "appPreviews", "appAssetLibraryPlacements": return .listing
        case "builds": return field == "usesNonExemptEncryption" ? .exportCompliance : .build
        case "appEncryptionDeclarations": return .exportCompliance
        case "appPriceSchedules", "appAvailabilities", "territoryAvailabilities": return .availability
        case "accessibilityDeclarations": return .accessibility
        case "appDataUsages", "appDataUsagesPublishState": return .privacy
        case "appStoreVersions" where field == "build": return .build
        case "appStoreVersions" where field != "copyright": return .version
        default: break
        }
        switch field {
        case "copyright": return .copyright
        case "primaryCategory", "secondaryCategory", "contentRightsDeclaration": return .appConfiguration
        case "usesNonExemptEncryption", "appDescription", "containsProprietaryCryptography", "containsThirdPartyCryptography", "availableOnFrenchStore": return .exportCompliance
        case "contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName", "demoAccountPassword", "demoAccountRequired", "notes": return .reviewInformation
        case "description", "keywords", "supportUrl", "marketingUrl", "promotionalText", "whatsNew", "name", "subtitle", "privacyPolicyUrl": return .listing
        case "build": return .build
        default: return .other
        }
    }

    /// The field in App Store Connect's words, or Apple's code when it names no field.
    public var label: String {
        guard let field else { return Self.codeLabel(code) }
        if Self.ages.contains(field) { return AgeRating.label(field) }
        if let known = Self.labels[field] { return known }
        let words = field.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Apple's state codes that name a whole section rather than a field, such as STATE_ERROR.APP_DATA_USAGES_REQUIRED.
    static let codeAreas: [(String, Area, String)] = [
        ("APP_DATA_USAGES", .privacy, "App Privacy answers are not published"), ("PRIVACY", .privacy, "App Privacy answers are missing"),
        ("UNSUPPORTED_TERRITORY", .pricing, "The product is not available in this country or region"), ("PRICING", .pricing, "No price is set"), ("PRICE", .pricing, "No price is set"),
        ("AVAILABILITY", .availability, "No country or region is chosen"), ("TERRITOR", .availability, "No country or region is chosen"),
        ("CONTENT_RIGHTS", .appConfiguration, "Content Rights are not answered"), ("CATEGORY", .appConfiguration, "No primary category is chosen"),
        ("AGE_RATING", .ageRating, "Age Ratings are not answered"), ("SCREENSHOT", .listing, "Screenshots are missing"), ("PREVIEW", .listing, "App previews need attention"),
        ("ENCRYPTION", .exportCompliance, "Export Compliance is not answered"), ("EXPORT_COMPLIANCE", .exportCompliance, "Export Compliance is not answered"),
        ("BUILD", .build, "No build is chosen"), ("REVIEW_DETAIL", .reviewInformation, "App Review Information is incomplete"), ("CONTACT", .reviewInformation, "App Review contact is incomplete"),
        ("TAX", .tax, "No tax category is chosen"), ("ACCESSIBILITY", .accessibility, "Accessibility answers are missing"),
    ]
    static func codeArea(_ code: String) -> Area? { codeAreas.first { code.contains($0.0) }?.1 }
    static func codeLabel(_ code: String) -> String {
        if let known = codeAreas.first(where: { code.contains($0.0) }) { return known.2 }
        let words = (code.split(separator: ".").last.map(String.init) ?? code).replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static let ages = Set((AgeRating.frequency + AgeRating.boolean).map(\.0))
    static let labels: [String: String] = [
        "copyright": "Copyright", "description": "Description", "keywords": "Keywords", "supportUrl": "Support URL", "marketingUrl": "Marketing URL",
        "promotionalText": "Promotional Text", "whatsNew": "What's New in This Version", "name": "Name", "subtitle": "Subtitle", "privacyPolicyUrl": "Privacy Policy URL",
        "contactFirstName": "First name", "contactLastName": "Last name", "contactPhone": "Phone number", "contactEmail": "Email", "demoAccountName": "User name",
        "demoAccountPassword": "Password", "demoAccountRequired": "Sign-in required", "notes": "Notes", "primaryCategory": "Primary Category",
        "secondaryCategory": "Secondary Category", "contentRightsDeclaration": "Content Rights", "usesNonExemptEncryption": "Encryption", "build": "Build",
        "containsProprietaryCryptography": "Proprietary encryption algorithms", "containsThirdPartyCryptography": "Standard encryption algorithms",
        "availableOnFrenchStore": "Available on the App Store in France", "appDescription": "Encryption description",
    ]

    var json: JSONText { .object([("code", .string(code))] + [("resource", resource), ("field", field), ("detail", detail)].compactMap { key, value in value.map { (key, JSONText.string($0)) } }) }
    init?(json: JSONText) {
        guard let code = json["code"]?.text, Self.valid(code, Self.codePattern) else { return nil }
        self.code = code
        resource = json["resource"]?.text.flatMap { Self.valid($0, Self.namePattern) ? $0 : nil }
        field = json["field"]?.text.flatMap { Self.valid($0, Self.namePattern) ? $0 : nil }
        detail = json["detail"]?.text.flatMap(Self.sentence)
    }
    public init(code: String, resource: String?, field: String?, detail: String? = nil) { self.code = code; self.resource = resource; self.field = field; self.detail = detail.flatMap(Self.sentence) }

    /// Apple's explanation as one plain line: control characters become spaces and it stops at 400 characters.
    static func sentence(_ text: String) -> String? {
        let plain = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : $0 }))
        let line = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 400 ? String(line.prefix(399)) + "…" : line
    }

    enum Pattern { case code, name }
    static let codePattern = Pattern.code, namePattern = Pattern.name
    /// An Apple error code such as ENTITY_ERROR.ATTRIBUTE.REQUIRED, or a resource or field name such as ageRatingDeclarations.
    /// Checked byte by byte: a refusal can list dozens of codes, and this runs for each one.
    static func valid(_ text: String, _ pattern: Pattern) -> Bool {
        let bytes = Array(text.utf8), first = bytes.first ?? 0
        switch pattern {
        case .code:
            guard (1...101).contains(bytes.count), (65...90).contains(first) else { return false }
            return bytes.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46 }
        case .name:
            guard (1...61).contains(bytes.count), (65...90).contains(first) || (97...122).contains(first) else { return false }
            return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
        }
    }

    /// Apple's error body as problems: every error and the associated errors Apple lists when a version is not ready for
    /// review. The umbrella "entity state invalid" code is left out when Apple names the actual problems.
    /// `resource` is the kind of record the refused write sent, used when Apple names none.
    public static func parse(data: Data, contentType: String?, resource sent: String? = nil) -> [AppleProblem] {
        guard data.count <= 64_000, contentType?.lowercased().contains("json") == true, let value = try? JSONText.parse(data), case .array(let errors)? = value["errors"] else { return [] }
        var problems: [AppleProblem] = []
        func collect(_ error: JSONText, resource: String?) {
            guard let code = error["code"]?.text, valid(code, codePattern) else { return }
            let pointer = error["source"]?["pointer"]?.text ?? ""
            let field = pointer.hasPrefix("/data/attributes/") || pointer.hasPrefix("/data/relationships/") ? pointer.components(separatedBy: "/").last.flatMap { valid($0, namePattern) ? $0 : nil } : nil
            let problem = AppleProblem(code: code, resource: resource ?? sent.flatMap { valid($0, namePattern) ? $0 : nil }, field: field, detail: error["detail"]?.text)
            if !problems.contains(problem), problems.count < 60 { problems.append(problem) }
            if case .object(let associated)? = error["meta"]?["associatedErrors"] {
                for (path, nested) in associated {
                    // The key is the resource path, such as /v1/ageRatingDeclarations/ID; only its type is kept.
                    let parts = path.split(separator: "/").map(String.init), type = parts.count >= 2 && valid(parts[1], namePattern) ? parts[1] : nil
                    if case .array(let items) = nested { items.prefix(60).forEach { collect($0, resource: type) } }
                }
            }
        }
        errors.prefix(20).forEach { collect($0, resource: nil) }
        let specific = problems.filter { $0.field != nil || $0.resource != nil }
        return specific.isEmpty ? problems : problems.filter { $0.code != "STATE_ERROR.ENTITY_STATE_INVALID" || $0.field != nil }
    }

    /// A short sentence for the stop: Apple's own reason for a single problem, otherwise how many things Apple wants and where.
    public static func summary(_ problems: [AppleProblem], status: Int) -> String {
        let areas = Area.allCases.filter { area in problems.contains { $0.area == area } }
        guard !areas.isEmpty else { return "Apple refused this change (\(status)). Completed steps remain applied." }
        if problems.count == 1, let only = problems.first {
            return "Apple refused this change in \(only.area.title): " + (only.detail ?? only.label) + (only.detail?.hasSuffix(".") == false ? "." : "")
        }
        return "Apple needs \(problems.count) \(problems.count == 1 ? "answer" : "answers") before it accepts this change, in " + areas.map(\.title).joined(separator: ", ") + ". Fix them, then Resume."
    }
}
