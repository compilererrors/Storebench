import Foundation

public enum PublishFailure: Error, Equatable {
    case invalid(String), busy, used, expired, conflict, noChanges, versionRequired, write(String)
    /// Apple refused a change and named what it wants, field by field; each problem's area opens where it is answered.
    case refused(String, problems: [AppleProblem])

    public var message: String {
        switch self {
        case .invalid(let text), .write(let text), .refused(let text, _): text
        case .busy: "Another publishing review is active for this app. Wait for it to finish."
        case .used: "This review has already been used. Prepare a new review."
        case .expired: "This review expired or does not match your approval. Prepare a new review."
        case .conflict: "Apple data or local drafts changed after review. Prepare a new review before publishing."
        case .noChanges: "There are no changes to publish."
        case .versionRequired: "Create the planned version in App Store changes first, then review Languages & media."
        }
    }
}

/// What to publish: one app, one scope and its selection, as stored.
public struct PublishRequest: Equatable, Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        case release, metadata, submit, cancelSubmission = "cancel-submission", releaseVersion = "release-version", versionCopyright = "version-copyright", pricing, productPricing = "product-pricing"
        /// Sets up how the app earns money: the app price, a temporary price, new in-app purchases and subscriptions, their prices and offers.
        case pricingSetup = "pricing-setup"
        /// App Privacy answers, sent with the signed-in Apple ID because the API key cannot answer them.
        case appPrivacy = "app-privacy"
        /// The app's tax category, saved with the signed-in Apple ID because the API key cannot set it.
        case taxCategory = "tax-category"
        case analyticsOngoing = "analytics-ongoing", analyticsSnapshot = "analytics-snapshot", testflight, reviewInfo = "review-info", appInformation = "app-information", availability, ageRating = "age-rating", accessibility, exportCompliance = "export-compliance", exportDocument = "export-document", assetLibrary = "asset-library"
        /// Adds a build to an editable App Store version, as App Store Connect's Add Build does, without submitting it.
        case versionBuild = "version-build"
    }
    public let accountId, appId: String
    public let scope: Scope
    public var targetMode: String?, revisionId: String?, versionId: String?, buildId: String?, copyright: String?, profileId: String?
    public var testflightAction: String?, usesNonExemptEncryption: Bool?, groupId: String?
    public var autoNotifyEnabled: Bool?
    public var contentRightsDeclaration: String?, categorySelection: [String: String?]?, territoryId: String?, territoryAvailable: Bool?
    public var ageRatingChanges: [(String, JSONText)]?
    public var reviewAttachmentId: String?
    public var accessibilityAction: String?, accessibilityFamily: String?, accessibilityAnswers: [(String, Bool)]?
    public var encryptionDeclaration: EncryptionAnswers?
    public var declarationId: String?, documentRevision: Int?
    public var groupName: String?, internalGroup: Bool?, groupSetting: String?, groupSettingValue: JSONText?, testerId: String?, testerEmail: String?
    public var subscriptionPrice: SubscriptionPriceChange?, purchasePrice: PurchasePriceChange?
    public var pricingSetup: PricingSetupChange?
    public var appPrivacy: AppPrivacyAnswers?
    /// True publishes the App Privacy answers on the product page, as Publish does in App Store Connect; otherwise they are only saved.
    public var appPrivacyPublish: Bool?
    public var taxCategory: TaxCategoryChoice?
    public var locale: String?, whatsNew: String?, betaDescription: String?, feedbackEmail: String?, agreementText: String?
    public var betaMarketingUrl: String?, betaPrivacyPolicyUrl: String?, betaTvOsPrivacyPolicy: String?
    public var buildUploadId: String?, packageId: String?, buildVersion: String?, buildNumber: String?, buildPlatform: String?
    public var assetLibraryChange: AssetLibrary.Change?
    /// "upload" limits a Languages & media review to uploading its screenshots and app previews to Asset Library, as App Store
    /// Connect's Upload does. The full review then adds them to App Previews and Screenshots with the text.
    public var mediaStage: String?
    public static let uploadStage = "upload"
    /// Release step 2: uploads missing files to Asset Library and adds them to App Previews and Screenshots in the saved order. No text is sent.
    public static let screenshotsStage = "screenshots"
    /// Release step 3: saves the version's text and app information only. Screenshots and app previews are left to step 2.
    public static let textStage = "text"
    /// Quick Release: saves only Description, Subtitle, Keywords and What's New. Screenshots and other local drafts stay on this Mac.
    public static let quickStage = "quick"
    public static func == (a: PublishRequest, b: PublishRequest) -> Bool { a.json == b.json }

    public init(accountId: String, appId: String, scope: Scope, targetMode: String? = nil, revisionId: String? = nil, versionId: String? = nil, buildId: String? = nil, copyright: String? = nil, profileId: String? = nil) {
        self.accountId = accountId; self.appId = appId; self.scope = scope; self.targetMode = targetMode; self.revisionId = revisionId; self.versionId = versionId; self.buildId = buildId
        self.copyright = copyright; self.profileId = profileId
    }

    public var json: JSONText {
        var fields: [(String, JSONText)] = [("accountId", .string(accountId)), ("appId", .string(appId)), ("scope", .string(scope.rawValue))]
        if let copyright { fields.append(("copyright", .string(copyright))) }
        for (key, value) in [("targetMode", targetMode), ("revisionId", revisionId), ("versionId", versionId), ("profileId", profileId), ("buildId", buildId), ("groupId", groupId), ("testflightAction", testflightAction),
                             ("buildUploadId", buildUploadId), ("packageId", packageId), ("buildVersion", buildVersion), ("buildNumber", buildNumber), ("buildPlatform", buildPlatform)] { if let value { fields.append((key, .string(value))) } }
        if let autoNotifyEnabled { fields.append(("autoNotifyEnabled", .bool(autoNotifyEnabled))) }
        if let usesNonExemptEncryption { fields.append(("usesNonExemptEncryption", .bool(usesNonExemptEncryption))) }
        if let contentRightsDeclaration { fields.append(("contentRightsDeclaration", .string(contentRightsDeclaration))) }
        if let categorySelection { fields.append(("categorySelection", .object(AppInformation.categoryFields.map { field in (field, categorySelection[field].flatMap { $0 }.map { .string($0) } ?? .null) }))) }
        if let territoryId { fields.append(("territoryId", .string(territoryId))) }
        if let territoryAvailable { fields.append(("territoryAvailable", .bool(territoryAvailable))) }
        if let ageRatingChanges { fields.append(("ageRatingChanges", .object(ageRatingChanges))) }
        if let reviewAttachmentId { fields.append(("reviewAttachmentId", .string(reviewAttachmentId))) }
        if let accessibilityAction { fields.append(("accessibilityAction", .string(accessibilityAction))) }
        if let accessibilityFamily { fields.append(("accessibilityFamily", .string(accessibilityFamily))) }
        if let encryptionDeclaration { fields.append(("encryptionDeclaration", encryptionDeclaration.json)) }
        if let declarationId { fields.append(("declarationId", .string(declarationId))) }
        if let documentRevision { fields.append(("documentRevision", .number(Double(documentRevision)))) }
        if let accessibilityAnswers { fields.append(("accessibilityAnswers", .object(accessibilityAnswers.map { ($0.0, .bool($0.1)) }))) }
        for (key, value) in [("groupName", groupName), ("groupSetting", groupSetting), ("testerId", testerId), ("testerEmail", testerEmail), ("locale", locale), ("whatsNew", whatsNew),
                             ("betaDescription", betaDescription), ("feedbackEmail", feedbackEmail), ("agreementText", agreementText), ("betaMarketingUrl", betaMarketingUrl), ("betaPrivacyPolicyUrl", betaPrivacyPolicyUrl), ("betaTvOsPrivacyPolicy", betaTvOsPrivacyPolicy)] { if let value { fields.append((key, .string(value))) } }
        if let internalGroup { fields.append(("internalGroup", .bool(internalGroup))) }
        if let groupSettingValue { fields.append(("groupSettingValue", groupSettingValue)) }
        if let subscriptionPrice { fields.append(("subscriptionPrice", subscriptionPrice.json)) }
        if let purchasePrice { fields.append(("purchasePrice", purchasePrice.json)) }
        if let pricingSetup { fields.append(("pricingSetup", pricingSetup.json)) }
        if let appPrivacy { fields.append(("appPrivacy", appPrivacy.json)) }
        if let appPrivacyPublish { fields.append(("appPrivacyPublish", .bool(appPrivacyPublish))) }
        if let taxCategory { fields.append(("taxCategory", taxCategory.json)) }
        if let assetLibraryChange { fields.append(("assetLibraryChange", assetLibraryChange.json)) }
        if let mediaStage { fields.append(("mediaStage", .string(mediaStage))) }
        return .object(fields)
    }

    init?(_ value: JSONText) {
        guard let account = value["accountId"]?.text, let app = value["appId"]?.text, let scope = value["scope"]?.text.flatMap(Scope.init) else { return nil }
        self.init(accountId: account, appId: app, scope: scope, targetMode: value["targetMode"]?.text, revisionId: value["revisionId"]?.text, versionId: value["versionId"]?.text, buildId: value["buildId"]?.text,
                  copyright: value["copyright"]?.text, profileId: value["profileId"]?.text)
        testflightAction = value["testflightAction"]?.text; groupId = value["groupId"]?.text
        if case .bool(let flag)? = value["autoNotifyEnabled"] { autoNotifyEnabled = flag }
        if case .bool(let flag)? = value["usesNonExemptEncryption"] { usesNonExemptEncryption = flag }
        contentRightsDeclaration = value["contentRightsDeclaration"]?.text; territoryId = value["territoryId"]?.text
        if case .bool(let flag)? = value["territoryAvailable"] { territoryAvailable = flag }
        if case .object(let pairs)? = value["ageRatingChanges"] { ageRatingChanges = pairs }
        reviewAttachmentId = value["reviewAttachmentId"]?.text
        accessibilityAction = value["accessibilityAction"]?.text; accessibilityFamily = value["accessibilityFamily"]?.text
        declarationId = value["declarationId"]?.text
        if case .number(let revision)? = value["documentRevision"] { documentRevision = Int(revision) }
        if let declaration = value["encryptionDeclaration"] {
            var answers = EncryptionAnswers(); answers.appDescription = declaration["appDescription"]?.text ?? ""
            answers.containsProprietaryCryptography = declaration["containsProprietaryCryptography"] == .bool(true); answers.containsThirdPartyCryptography = declaration["containsThirdPartyCryptography"] == .bool(true)
            answers.availableOnFrenchStore = declaration["availableOnFrenchStore"] == .bool(true); encryptionDeclaration = answers
        }
        if case .object(let pairs)? = value["accessibilityAnswers"] { accessibilityAnswers = pairs.compactMap { pair in if case .bool(let flag) = pair.1 { return (pair.0, flag) }; return nil } }
        groupName = value["groupName"]?.text; groupSetting = value["groupSetting"]?.text; testerId = value["testerId"]?.text; testerEmail = value["testerEmail"]?.text
        locale = value["locale"]?.text; whatsNew = value["whatsNew"]?.text; betaDescription = value["betaDescription"]?.text; feedbackEmail = value["feedbackEmail"]?.text; agreementText = value["agreementText"]?.text
        betaMarketingUrl = value["betaMarketingUrl"]?.text; betaPrivacyPolicyUrl = value["betaPrivacyPolicyUrl"]?.text; betaTvOsPrivacyPolicy = value["betaTvOsPrivacyPolicy"]?.text
        buildUploadId = value["buildUploadId"]?.text; packageId = value["packageId"]?.text; buildVersion = value["buildVersion"]?.text; buildNumber = value["buildNumber"]?.text; buildPlatform = value["buildPlatform"]?.text
        if case .bool(let flag)? = value["internalGroup"] { internalGroup = flag }
        groupSettingValue = value["groupSettingValue"]
        if let change = value["assetLibraryChange"] { guard let parsed = try? AssetLibrary.Change(change) else { return nil }; assetLibraryChange = parsed }
        mediaStage = value["mediaStage"]?.text
        subscriptionPrice = value["subscriptionPrice"].flatMap(SubscriptionPriceChange.init); purchasePrice = value["purchasePrice"].flatMap(PurchasePriceChange.init)
        if let change = value["pricingSetup"] { guard let parsed = PricingSetupChange(change) else { return nil }; pricingSetup = parsed }
        if let answers = value["appPrivacy"] { guard let parsed = AppPrivacyAnswers(answers) else { return nil }; appPrivacy = parsed }
        if let flag = value["appPrivacyPublish"] { guard case .bool(let publish) = flag else { return nil }; appPrivacyPublish = publish }
        if let choice = value["taxCategory"] { guard let parsed = TaxCategoryChoice(choice) else { return nil }; taxCategory = parsed }
        if let selection = value["categorySelection"] { categorySelection = Dictionary(uniqueKeysWithValues: AppInformation.categoryFields.map { ($0, selection[$0]?.text) }) }
    }

    func validated() throws -> PublishRequest {
        guard accountId.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid publishing selection.") }
        if scope == .assetLibrary {
            guard let change = assetLibraryChange, case .object(let fields) = json, Set(fields.map(\.0)) == ["accountId", "appId", "scope", "assetLibraryChange"] else { throw PublishFailure.invalid("Choose only one Asset Library action.") }
            var result = self; result.assetLibraryChange = try change.validated(); return result
        }
        guard assetLibraryChange == nil else { throw PublishFailure.invalid("Choose Asset Library changes in their own review.") }
        for value in [revisionId, versionId, buildId, profileId, groupId, testerId, buildUploadId, packageId, declarationId, reviewAttachmentId] { if let value, value.range(of: "^[a-zA-Z0-9_-]{1,256}$", options: .regularExpression) == nil { throw PublishFailure.invalid("Invalid publishing selection.") } }
        if let mediaStage, scope != .metadata || ![Self.uploadStage, Self.screenshotsStage, Self.textStage, Self.quickStage].contains(mediaStage) { throw PublishFailure.invalid("Choose a valid Asset Library upload.") }
        if mediaStage == Self.quickStage, targetMode != "release-plan" { throw PublishFailure.invalid("Quick Release saves the text of the planned version only.") }
        if reviewAttachmentId != nil && scope != .reviewInfo { throw PublishFailure.invalid("Choose App Review attachment removal in its own review.") }
        if let targetMode, scope != .metadata || !["apple-version", "release-plan"].contains(targetMode) { throw PublishFailure.invalid("Choose a valid Apple target version.") }
        if scope == .cancelSubmission && (versionId == nil || revisionId != nil || buildId != nil || targetMode != nil) { throw PublishFailure.invalid("Choose only one Apple version whose App Review submission should be canceled.") }
        if (scope == .submit || scope == .releaseVersion || scope == .reviewInfo) && versionId == nil { throw PublishFailure.invalid("Choose an Apple version.") }
        if scope == .versionBuild && (versionId == nil || buildId == nil || revisionId != nil || targetMode != nil) { throw PublishFailure.invalid("Choose one Apple version and the build to add to it.") }
        var result = self
        if scope == .productPricing {
            guard (subscriptionPrice == nil) != (purchasePrice == nil), [targetMode, revisionId, versionId, buildId, copyright, profileId].allSatisfy({ $0 == nil }) else { throw PublishFailure.invalid("Choose only one product price change.") }
            result.subscriptionPrice = try subscriptionPrice?.validated(); result.purchasePrice = try purchasePrice?.validated()
        } else if subscriptionPrice != nil || purchasePrice != nil { throw PublishFailure.invalid("Choose product pricing in its own Apple review.") }
        if scope == .pricingSetup {
            guard let change = pricingSetup, case .object(let fields) = json, Set(fields.map(\.0)) == ["accountId", "appId", "scope", "pricingSetup"] else { throw PublishFailure.invalid("Choose one pricing change.") }
            result.pricingSetup = try change.validated()
        } else if pricingSetup != nil { throw PublishFailure.invalid("Choose the pricing change in its own review.") }
        if scope == .appPrivacy {
            guard let answers = appPrivacy, case .object(let fields) = json, Set(fields.map(\.0)).subtracting(["appPrivacyPublish"]) == ["accountId", "appId", "scope", "appPrivacy"] else { throw PublishFailure.invalid("Choose the App Privacy answers.") }
            result.appPrivacy = try answers.validated()
        } else if appPrivacy != nil || appPrivacyPublish != nil { throw PublishFailure.invalid("Choose App Privacy in its own review.") }
        if scope == .taxCategory {
            guard let choice = taxCategory, case .object(let fields) = json, Set(fields.map(\.0)) == ["accountId", "appId", "scope", "taxCategory"] else { throw PublishFailure.invalid("Choose a tax category.") }
            result.taxCategory = try choice.validated()
        } else if taxCategory != nil { throw PublishFailure.invalid("Choose the tax category in its own review.") }
        if scope == .testflight {
            guard let action = testflightAction, TestFlightActions.all.contains(action) else { throw PublishFailure.invalid("Choose a TestFlight action.") }
            if action == "upload-build" {
                guard let packageId, packageId.range(of: StagedBuildPackage.uuid, options: .regularExpression) != nil, let buildVersion, let buildNumber,
                      [buildVersion, buildNumber].allSatisfy({ $0.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil }), ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(buildPlatform ?? ""),
                      [buildUploadId, buildId, groupId, testerId, revisionId, versionId, targetMode, profileId].allSatisfy({ $0 == nil }) else { throw PublishFailure.invalid("Choose a staged package and matching version, build number and platform.") }
            } else if packageId != nil || buildVersion != nil || buildNumber != nil || buildPlatform != nil { throw PublishFailure.invalid("Choose build delivery fields in their own upload review.") }
            if ["delete-build-upload", "delete-failed-upload"].contains(action) {
                guard buildUploadId != nil, [buildId, groupId, testerId, revisionId, versionId, targetMode, profileId].allSatisfy({ $0 == nil }) else { throw PublishFailure.invalid("Choose only one pending or failed build upload.") }
            } else if buildUploadId != nil { throw PublishFailure.invalid("Choose the Apple build upload in its own deletion review.") }
            if action == "set-encryption-use" && (buildId == nil || usesNonExemptEncryption == nil) { throw PublishFailure.invalid("Choose a build and explicitly answer whether it uses non-exempt encryption.") }
            if ["add-build", "remove-build"].contains(action) && (buildId == nil || groupId == nil) { throw PublishFailure.invalid("Choose a group and a build.") }
            if ["expire-build", "submit-beta-review", "notify-build-testers", "save-build-notes", "set-auto-notify", "assign-individual-tester", "remove-individual-tester", "invite-individual-tester", "assign-encryption-declaration"].contains(action) && buildId == nil { throw PublishFailure.invalid("Choose a TestFlight build.") }
            if TestFlightActions.groupActions.subtracting(["create-group"]).contains(action) && groupId == nil { throw PublishFailure.invalid("Choose a TestFlight group.") }
            if ["add-tester", "remove-tester", "send-invitation", "remove-app-tester", "assign-individual-tester", "remove-individual-tester"].contains(action) && testerId == nil { throw PublishFailure.invalid("Choose a TestFlight tester.") }
            let fields: [String: Bool] = ["groupName": groupName != nil, "internalGroup": internalGroup != nil, "groupSetting": groupSetting != nil || groupSettingValue != nil, "testerEmail": testerEmail != nil,
                                          "locale": locale != nil, "whatsNew": whatsNew != nil, "betaInfo": betaDescription != nil || feedbackEmail != nil || betaMarketingUrl != nil || betaPrivacyPolicyUrl != nil || betaTvOsPrivacyPolicy != nil, "agreementText": agreementText != nil, "autoNotifyEnabled": autoNotifyEnabled != nil]
            let allowed: [String: Set<String>] = ["create-group": ["groupName", "internalGroup"], "rename-group": ["groupName"], "set-group-setting": ["groupSetting"], "invite-tester": ["testerEmail"],
                                                  "save-build-notes": ["locale", "whatsNew"], "save-beta-info": ["locale", "betaInfo"], "save-beta-license": ["agreementText"], "set-auto-notify": ["autoNotifyEnabled"], "invite-individual-tester": ["testerEmail"]]
            guard fields.filter(\.value).keys.allSatisfy({ allowed[action]?.contains($0) == true }) else { throw PublishFailure.invalid("Choose only the fields for this TestFlight action.") }
            if action == "save-beta-info" {
                guard StoreLocales.codes.contains(locale ?? ""), let betaDescription, let feedbackEmail, TestFlightAccess.validEmail(feedbackEmail) else { throw PublishFailure.invalid("Enter a supported TestFlight language, description and feedback email.") }
                result.betaDescription = try TestFlightMetadata.text(betaDescription, label: "a beta description")
                result.feedbackEmail = feedbackEmail.lowercased()
                result.betaMarketingUrl = try betaMarketingUrl.map { try TestFlightMetadata.url($0, label: "marketing URL") }
                result.betaPrivacyPolicyUrl = try betaPrivacyPolicyUrl.map { try TestFlightMetadata.url($0, label: "privacy policy URL") }
                result.betaTvOsPrivacyPolicy = try betaTvOsPrivacyPolicy.map(TestFlightMetadata.privacyPolicy)
            }
            if action == "save-build-notes" {
                guard TestFlightActions.buildLocales.contains(locale ?? ""), let whatsNew else { throw PublishFailure.invalid("Choose a supported TestFlight build language and enter What to Test text.") }
                result.whatsNew = try TestFlightMetadata.text(whatsNew, label: "What to Test text")
            }
            if action == "assign-encryption-declaration" {
                guard declarationId != nil, groupId == nil, testerId == nil, versionId == nil, revisionId == nil, targetMode == nil, profileId == nil, usesNonExemptEncryption == nil else { throw PublishFailure.invalid("Choose only one build and its approved declaration.") }
            } else if declarationId != nil { throw PublishFailure.invalid("Choose the declaration in its own build review.") }
            if action == "save-beta-review-details", [buildId, groupId, testerId, revisionId, versionId, targetMode, profileId].contains(where: { $0 != nil }) || usesNonExemptEncryption != nil { throw PublishFailure.invalid("Beta review information applies to this app, without a selected build or version.") }
            if action == "set-auto-notify", autoNotifyEnabled == nil { throw PublishFailure.invalid("Choose On or Off for automatic build notification.") }
            if ["create-group", "rename-group"].contains(action) { result.groupName = try TestFlightGroups.name(groupName ?? "") }
            if action == "invite-tester" {
                guard let email = testerEmail.map(TextSemantics.trim)?.lowercased(), TestFlightAccess.validEmail(email), testerId == nil else { throw PublishFailure.invalid("Enter a valid tester email for this group.") }
                result.testerEmail = email
            }
            if action == "invite-individual-tester" {
                guard let email = testerEmail.map(TextSemantics.trim)?.lowercased(), TestFlightAccess.validEmail(email), testerId == nil, groupId == nil else { throw PublishFailure.invalid("Enter a valid tester email for one build.") }
                result.testerEmail = email
            }
            if ["assign-individual-tester", "remove-individual-tester", "set-auto-notify"].contains(action), groupId != nil { throw PublishFailure.invalid("Choose one build in this review.") }
            if action == "set-auto-notify", testerId != nil { throw PublishFailure.invalid("Automatic notification applies to the build's assigned testers.") }
            if let groupSetting, !["feedback", "public-link", "public-link-limit"].contains(groupSetting) { throw PublishFailure.invalid("Choose a valid TestFlight group setting.") }
        } else if autoNotifyEnabled != nil || testflightAction != nil || usesNonExemptEncryption != nil || groupId != nil || testerId != nil || groupName != nil || internalGroup != nil || groupSetting != nil || groupSettingValue != nil
                    || testerEmail != nil || locale != nil || whatsNew != nil || betaDescription != nil || feedbackEmail != nil || agreementText != nil || betaMarketingUrl != nil || betaPrivacyPolicyUrl != nil || betaTvOsPrivacyPolicy != nil
                    || buildUploadId != nil || packageId != nil || buildVersion != nil || buildNumber != nil || buildPlatform != nil { throw PublishFailure.invalid("Choose TestFlight changes in their own review.") }
        if scope == .availability {
            guard let territoryId, territoryId.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, territoryAvailable != nil else { throw PublishFailure.invalid("Choose one country or region and an explicit availability setting.") }
        } else if territoryId != nil || territoryAvailable != nil { throw PublishFailure.invalid("Choose region availability in its own review.") }
        if scope == .appInformation {
            guard contentRightsDeclaration != nil || categorySelection != nil else { throw PublishFailure.invalid("Choose app information changes in the app information review.") }
            if let rights = contentRightsDeclaration, !["DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"].contains(rights) { throw PublishFailure.invalid("Choose the app's content rights declaration explicitly.") }
            if let selection = categorySelection { try AppInformation.validate(selection) }
        } else if contentRightsDeclaration != nil || categorySelection != nil { throw PublishFailure.invalid("Choose app information changes in the app information review.") }
        if scope == .exportDocument {
            guard let declarationId, declarationId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil, let documentRevision, documentRevision >= 1 else { throw PublishFailure.invalid("Choose one encryption declaration and its staged PDF.") }
        } else if documentRevision != nil { throw PublishFailure.invalid("Choose the encryption PDF in its own review.") }
        if scope == .exportCompliance {
            guard let answers = encryptionDeclaration else { throw PublishFailure.invalid("Complete the export compliance declaration before review.") }
            // A build is optional: with one, the new declaration is attached to that build in the same review.
            guard [versionId, revisionId, declarationId, profileId, targetMode].allSatisfy({ $0 == nil }) else { throw PublishFailure.invalid("Choose only the declaration answers and, optionally, one build.") }
            result.encryptionDeclaration = try answers.validated()
        }
        else if encryptionDeclaration != nil { throw PublishFailure.invalid("Choose export compliance in its own review.") }
        if scope == .accessibility {
            guard ["save-draft", "publish-draft", "delete-draft"].contains(accessibilityAction ?? ""), AccessibilityDeclarations.families.contains(where: { $0.0 == accessibilityFamily }) else { throw PublishFailure.invalid("Choose one accessibility declaration action and device family.") }
            if accessibilityAction == "save-draft" { try AccessibilityDeclarations.validate(accessibilityAnswers ?? [], family: accessibilityFamily!) }
            else if accessibilityAnswers != nil { throw PublishFailure.invalid("Feature answers belong in a separate draft review.") }
        } else if accessibilityAction != nil || accessibilityFamily != nil || accessibilityAnswers != nil { throw PublishFailure.invalid("Choose accessibility declarations in their own review.") }
        if scope == .ageRating { guard let changes = ageRatingChanges else { throw PublishFailure.invalid("Choose age rating answers in the age rating review.") }; try AgeRating.validate(changes) }
        else if ageRatingChanges != nil { throw PublishFailure.invalid("Choose age rating answers in the age rating review.") }
        if scope == .versionCopyright && (versionId == nil || copyright == nil) || scope != .versionCopyright && copyright != nil { throw PublishFailure.invalid("Choose an Apple version and copyright in the version copyright review.") }
        if let copyright {
            let trimmed = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, copyright.utf16.count <= 200, !copyright.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw PublishFailure.invalid("Enter version copyright with the year and rights holder, up to 200 characters.") }
            result.copyright = trimmed
        }
        return result
    }
}

/// One operation in a review, exactly as the user approves it.
public struct PublishStep: Sendable {
    public enum Kind: String, Sendable { case api, upload, verify }
    public let key: String
    public var group: String?
    public let label, detail: String
    public let before, after: String?
    public let kind: Kind
    let method: String?
    let path: [JSONText]
    let body: JSONText?
    let asset: JSONText?
    let guardValue: JSONText?
    public internal(set) var state: String
    var resultId: String?

    var json: JSONText {
        var fields: [(String, JSONText)] = [("key", .string(key))]
        if let group { fields.append(("group", .string(group))) }
        fields += [("label", .string(label)), ("detail", .string(detail))]
        if let before { fields.append(("before", .string(before))) }
        if let after { fields.append(("after", .string(after))) }
        fields.append(("kind", .string(kind.rawValue)))
        if let method { fields.append(("method", .string(method))) }
        fields.append(("path", .array(path)))
        if let body { fields.append(("body", body)) }
        if let asset { fields.append(("asset", asset)) }
        if let guardValue { fields.append(("guard", guardValue)) }
        fields.append(("state", .string(state)))
        if let resultId { fields.append(("resultId", .string(resultId))) }
        return .object(fields)
    }

    init(key: String, group: String?, label: String, detail: String, before: String?, after: String?, kind: Kind, method: String?, path: [JSONText], body: JSONText?, asset: JSONText?, guardValue: JSONText?, state: String, resultId: String?) {
        self.key = key; self.group = group; self.label = label; self.detail = detail; self.before = before; self.after = after; self.kind = kind
        self.method = method; self.path = path; self.body = body; self.asset = asset; self.guardValue = guardValue; self.state = state; self.resultId = resultId
    }

    init?(_ value: JSONText) {
        guard let key = value["key"]?.text, let label = value["label"]?.text, let detail = value["detail"]?.text, let kind = value["kind"]?.text.flatMap(Kind.init),
              let state = value["state"]?.text, case .array(let path)? = value["path"] else { return nil }
        self.init(key: key, group: value["group"]?.text, label: label, detail: detail, before: value["before"]?.text, after: value["after"]?.text, kind: kind, method: value["method"]?.text,
                  path: path, body: value["body"], asset: value["asset"], guardValue: value["guard"], state: state, resultId: value["resultId"]?.text)
    }
}

/// A prepared review: the plan, its fingerprint and its one-time lifecycle.
public struct PublishReview: Sendable, Identifiable {
    public let id, title, fingerprint, createdAt, expiresAt: String
    public let request: PublishRequest
    public internal(set) var steps: [PublishStep]
    public let notes: [String]
    /// Screenshot and app preview files Apple already had where this review wanted them; nothing was sent for them.
    public let settled: [String]
    /// What Apple refused, field by field, saved with the review so its Attention panel can show and open each fix after a restart.
    public internal(set) var problems: [AppleProblem] = []
    public internal(set) var state, updatedAt: String
    public internal(set) var approvedAt, sentAt, completedAt, error: String?
    var pid: Int32?
    /// Prepared and not expired, so Save in it can still send it.
    public var waitingForSave: Bool { state == "prepared" && (ISO8601DateFormatter.storebench.date(from: expiresAt).map { $0 > Date() } ?? false) }

    var json: JSONText {
        var fields: [(String, JSONText)] = [("title", .string(title)), ("request", request.json), ("fingerprint", .string(fingerprint)), ("steps", .array(steps.map(\.json))),
                                            ("notes", .array(notes.map { .string($0) })), ("settled", .array(settled.map { .string($0) })), ("problems", .array(problems.map(\.json))), ("id", .string(id)), ("createdAt", .string(createdAt)), ("updatedAt", .string(updatedAt)),
                                            ("expiresAt", .string(expiresAt)), ("state", .string(state))]
        for (key, value) in [("approvedAt", approvedAt), ("sentAt", sentAt), ("completedAt", completedAt), ("error", error)] { if let value { fields.append((key, .string(value))) } }
        if let pid { fields += [("pid", .number(Double(pid))), ("lockProtocol", .number(2))] }
        return .object(fields)
    }

    /// A saved review read back from its stored form.
    public init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let title = value["title"]?.text, let fingerprint = value["fingerprint"]?.text, let created = value["createdAt"]?.text, let expires = value["expiresAt"]?.text,
              let request = value["request"].flatMap(PublishRequest.init), let state = value["state"]?.text, let updated = value["updatedAt"]?.text, case .array(let steps)? = value["steps"] else { return nil }
        self.id = id; self.title = title; self.fingerprint = fingerprint; self.createdAt = created; self.expiresAt = expires; self.request = request
        self.steps = steps.compactMap(PublishStep.init); self.notes = WorkspaceSession.strings(value["notes"]); settled = WorkspaceSession.strings(value["settled"]); if case .array(let saved)? = value["problems"] { problems = saved.prefix(60).compactMap(AppleProblem.init(json:)) }; self.state = state; self.updatedAt = updated
        approvedAt = value["approvedAt"]?.text; sentAt = value["sentAt"]?.text; completedAt = value["completedAt"]?.text; error = value["error"]?.text
        if case .number(let pid)? = value["pid"] { self.pid = Int32(pid) }
        guard self.steps.count == steps.count else { return nil }
    }

    init(plan: PublishPlan, id: String, now: Date) {
        self.id = id; title = plan.title; fingerprint = plan.fingerprint; request = plan.request; steps = plan.steps; notes = plan.notes; settled = plan.settled
        createdAt = CustomerReview.isoString(now); updatedAt = createdAt; expiresAt = CustomerReview.isoString(now.addingTimeInterval(15 * 60)); state = "prepared"
    }
}

struct PublishPlan { let title: String; let request: PublishRequest; let fingerprint: String; let steps: [PublishStep]; let notes: [String]; var settled: [String] = [] }
