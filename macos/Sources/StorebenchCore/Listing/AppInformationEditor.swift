import Foundation

/// Editable app settings keep each section's last confirmed baseline and explicit changes.
/// A failed read disables that section without discarding the user's answers.
public struct AppInformationEditor: Sendable {
    public private(set) var information: AppInformationState?
    public private(set) var informationReady = false
    public private(set) var rights = ""
    public private(set) var categories: [String: String?] = [:]
    private var savedCategories: [String: String?]?
    public private(set) var ageAnswers: [String: JSONText]?
    public private(set) var ageReady = false
    public private(set) var ageChanges: [String: JSONText] = [:]
    public private(set) var declarations: [AccessibilityDeclarationView]?
    public private(set) var accessibilityReady = false
    private var familyInputs: [String: [String: Bool]] = [:]

    public init() {}

    public var categoryChanged: Bool {
        guard let current = savedCategories else { return false }
        return AppInformation.categoryFields.contains { (current[$0] ?? nil) != (categories[$0] ?? nil) }
    }
    public var informationChanged: Bool { informationReady && ((!rights.isEmpty && rights != information?.contentRights) || (information?.categories != nil && categoryChanged)) }
    public var dirty: Bool {
        (information != nil && rights != (information?.contentRights ?? "")) || categoryChanged || !ageChanges.isEmpty ||
        AccessibilityDeclarations.families.contains { answers(for: $0.0) != draftAnswers($0.0) }
    }
    public var categoryChoices: [AppCategory] { AppInformation.choices(information?.catalog ?? [], platforms: information?.platforms ?? []) }
    public var ordinaryTerritories: [TerritoryAvailability] { information?.territories.filter(\.supportsOrdinaryChange) ?? [] }
    public func informationRequest(accountId: String, appId: String) -> PublishRequest? {
        guard informationChanged else { return nil }
        var request = PublishRequest(accountId: accountId, appId: appId, scope: .appInformation)
        if !rights.isEmpty && rights != information?.contentRights { request.contentRightsDeclaration = rights }
        if information?.categories != nil && categoryChanged { request.categorySelection = categories }
        return request
    }

    public mutating func receive(_ information: AppInformationState) {
        let retainRights = self.information != nil && rights != (self.information?.contentRights ?? "")
        let retainCategories = categoryChanged
        if !retainRights { rights = information.contentRights ?? "" }
        if let saved = information.categories {
            if !retainCategories { categories = saved }
            savedCategories = saved
        } else if savedCategories == nil { categories = Dictionary(uniqueKeysWithValues: AppInformation.categoryFields.map { ($0, String?.none) }) }
        self.information = information; informationReady = true
    }
    public mutating func informationFailed() { informationReady = false }
    public mutating func chooseRights(_ value: String) { if informationReady { rights = value } }
    public mutating func chooseCategory(_ field: String, _ value: String?) {
        guard informationReady, information?.categories != nil, AppInformation.categoryFields.contains(field) else { return }
        categories.updateValue(value, forKey: field)
        if field == "primaryCategory" || field == "secondaryCategory" {
            let prefix = field == "primaryCategory" ? "primary" : "secondary"
            categories.updateValue(nil, forKey: prefix + "SubcategoryOne"); categories.updateValue(nil, forKey: prefix + "SubcategoryTwo")
        }
        if value == nil && field.hasSuffix("SubcategoryOne") {
            categories.updateValue(nil, forKey: field.hasPrefix("primary") ? "primarySubcategoryTwo" : "secondarySubcategoryTwo")
        }
    }

    public mutating func receiveAgeAnswers(_ answers: [String: JSONText]) {
        ageChanges = ageChanges.filter { answers[$0.key] != $0.value }
        ageAnswers = answers; ageReady = true
    }
    public mutating func ageFailed() { ageReady = false }
    public func ageValue(_ key: String) -> JSONText? { ageChanges[key] ?? ageAnswers?[key] }
    public mutating func chooseAge(_ key: String, _ value: JSONText?) {
        guard ageReady, (AgeRating.frequency + AgeRating.boolean + AgeRating.optional).contains(where: { $0.0 == key }) else { return }
        if value == nil || value == ageAnswers?[key] { ageChanges.removeValue(forKey: key) } else { ageChanges[key] = value }
    }
    /// Gives every question of one kind the same answer: content questions take None, Infrequent or Frequent, yes/no questions take a flag.
    public mutating func chooseAllAges(frequency value: String) {
        guard AgeRating.frequencyValues.contains(value) else { return }
        for (key, _) in AgeRating.frequency { chooseAge(key, .string(value)) }
    }
    public mutating func chooseAllAges(flag value: Bool) {
        for (key, _) in AgeRating.boolean { chooseAge(key, .bool(value)) }
    }
    public var orderedAgeChanges: [(String, JSONText)] { (AgeRating.frequency + AgeRating.boolean + AgeRating.optional).compactMap { field in ageChanges[field.0].map { (field.0, $0) } } }

    private func draftAnswers(_ family: String) -> [String: Bool] {
        let applicable = Set(AccessibilityDeclarations.applicable(family).map(\.key))
        return declarations?.first { $0.family == family && $0.state == "DRAFT" }?.answers.filter { applicable.contains($0.key) } ?? [:]
    }
    public func answers(for family: String) -> [String: Bool] { familyInputs[family] ?? draftAnswers(family) }
    public func draft(for family: String) -> AccessibilityDeclarationView? { declarations?.first { $0.family == family && $0.state == "DRAFT" } }
    public func canSaveAccessibility(_ family: String) -> Bool { accessibilityReady && AccessibilityDeclarations.applicable(family).allSatisfy { answers(for: family)[$0.key] != nil } }
    public func canPublishAccessibility(_ family: String) -> Bool {
        accessibilityReady && draft(for: family).map { draft in AccessibilityDeclarations.applicable(family).allSatisfy { draft.answers[$0.key] != nil } } == true
    }
    public mutating func receiveDeclarations(_ declarations: [AccessibilityDeclarationView]) {
        let retained = familyInputs.filter { $0.value != draftAnswers($0.key) }
        self.declarations = declarations
        familyInputs = retained.filter { $0.value != draftAnswers($0.key) }; accessibilityReady = true
    }
    public mutating func accessibilityFailed() { accessibilityReady = false }
    public mutating func chooseAccessibility(_ family: String, _ key: String, _ value: Bool?) {
        guard accessibilityReady, AccessibilityDeclarations.families.contains(where: { $0.0 == family }), AccessibilityDeclarations.applicable(family).contains(where: { $0.key == key }) else { return }
        var values = answers(for: family); values[key] = value
        if values == draftAnswers(family) { familyInputs.removeValue(forKey: family) } else { familyInputs[family] = values }
    }
}
