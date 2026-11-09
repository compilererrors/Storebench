import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// A small stateful App Store Connect double for publishing tests: synthetic resources only.
final class SyntheticApple: @unchecked Sendable {
    let lock = NSLock()
    var versions: [[String: Any]] = [["type": "appStoreVersions", "id": "version-1", "attributes": ["platform": "IOS", "versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    var locales: [[String: Any]] = [["type": "appStoreVersionLocalizations", "id": "version-locale-1", "attributes": ["locale": "en-US", "description": "Second synthetic description", "keywords": "sample,test"], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]]]
    var sets: [[String: Any]] = [["type": "appScreenshotSets", "id": "set-1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"], "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "version-locale-1"]]]]]
    var shots: [[String: Any]] = [["type": "appScreenshots", "id": "shot-1", "attributes": ["fileName": "sample.png", "assetDeliveryState": ["state": "COMPLETE"]], "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": "set-1"]]]]]
    /// The App Asset Library: the imported synthetic screenshot placed on the version, plus Apple's catalog for one iPhone group.
    var library = true
    /// Apple documents upload operations on the reservation response; a later read need not repeat them.
    var readsOmitUploadOperations = false
    /// Apple keeps a committed file in processing, and reading it then fails, so a review stops at its verification.
    var processingAfterCommit = false, failProcessingReads = false, finishProcessingOnRead = false
    /// Apple can leave the version link out of a read of one language.
    var localeReadsOmitOwner = false
    /// Apple adds the next file to the version but its answer is lost, as with a dropped connection.
    var losePlacementAnswers = 0
    var libraryImages: [[String: Any]] = [["type": "appAssetLibraryImages", "id": "image-1", "attributes": ["fileName": "sample.png", "fileSize": 1000, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
        "imageAsset": ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/synthetic/{w}x{h}bb.{f}", "width": 1290, "height": 2796]], "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]]]
    var placements: [[String: Any]] = [["type": "appAssetLibraryPlacements", "id": "shot-1", "attributes": ["mediaType": "IMAGE", "placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_SYNTHETIC_PROFILE", "state": "PARENT_PREPARE_FOR_SUBMISSION"],
        "relationships": ["image": ["data": ["type": "appAssetLibraryImages", "id": "image-1"]], "appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "version-locale-1"]]]]]
    nonisolated(unsafe) static let catalog: [String: Any] = ["type": "appAssetLibraryRefData", "id": "catalog-synthetic", "attributes": [
        "features": [["featureId": "APP_STORE_VERSIONS", "placementPolicies": [["placementType": "APP_SCREENSHOT", "groupLimits": [["groupIds": ["IPHONE_SYNTHETIC_PROFILE"], "maxCount": 10]]]]]],
        "placementProfileGroups": [["placementProfileGroupId": "IPHONE_SYNTHETIC_PROFILE", "platform": "IPHONE_APP_STORE", "displayClassId": "SYNTHETIC_DISPLAY"]],
        "imageSpecs": [["specId": "spec-iphone", "shortName": "i1290x2796", "dimensions": ["minWidth": 1290, "maxWidth": 1290, "minHeight": 2796, "maxHeight": 2796], "fileExtensions": [".png", ".jpg"], "maxFileSize": 52428800, "alphaAllowed": false]],
        "videoSpecs": [], "displayClasses": [],
        "placementTypes": [["placementTypeId": "APP_SCREENSHOT", "acceptsAssetCategories": ["APP_SCREENSHOTS_AND_PREVIEWS"], "specMappings": [["placementGroupId": "IPHONE_SYNTHETIC_PROFILE", "specs": ["spec-iphone"]]]]]]]
    var builds: [[String: Any]] = [["type": "builds", "id": "build-7", "attributes": ["version": "7", "processingState": "VALID", "expired": false, "uploadedDate": "2026-03-01T10:00:00Z", "buildAudienceType": "APP_STORE_ELIGIBLE"],
                                    "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]], "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": "pre-1"]], "buildBetaDetail": ["data": ["type": "buildBetaDetails", "id": "detail-7"]]]]]
    var groupBuilds: [String] = []
    /// Apple's app name for the imported language; the synthetic import has "Sample App Updated".
    var appInfoName = "Sample App Updated"
    var groups: [[String: Any]] = [["type": "betaGroups", "id": "group-1", "attributes": ["name": "Synthetic testers", "isInternalGroup": true], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    var testers: [[String: Any]] = [["type": "betaTesters", "id": "tester-1", "attributes": ["email": "tester@example.com", "firstName": "Synthetic", "lastName": "Tester", "state": "INSTALLED"]]]
    var groupTesters: [String: [String]] = ["group-1": ["tester-1"]]
    var directTesters: [String] = []
    var betaExternalState = "READY_FOR_BETA_TESTING"
    var automaticNotification = false
    var license = "Synthetic beta terms."
    var betaAppLocales: [[String: Any]] = []
    var betaBuildLocales: [[String: Any]] = []
    var betaSubmissions: [[String: Any]] = []
    var betaReviewDetails: [[String: Any]] = [["type": "betaAppReviewDetails", "id": "beta-detail-synthetic", "attributes": ["contactFirstName": "Synthetic", "contactLastName": "Reviewer", "contactPhone": "0000000000", "contactEmail": "review@example.com", "demoAccountRequired": false], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    var iapManual: [[String: Any]] = []
    var subscriptionPrices: [[String: Any]] = [["type": "subscriptionPrices", "id": "sub-price-1", "attributes": ["startDate": NSNull(), "preserved": false],
                                                "relationships": ["subscriptionPricePoint": ["data": ["type": "subscriptionPricePoints", "id": "sub-pp-usa-499"]], "territory": ["data": ["type": "territories", "id": "USA"]]]]]
    var reviewDetails: [[String: Any]] = []
    var rights: Any = NSNull()
    var primary = "GAMES"
    var sweden = true
    var accessibility: [[String: Any]] = []
    var declarations: [[String: Any]] = []
    var documents: [[String: Any]] = []
    /// A complete declaration: Apple adds a version for review only when every Age Ratings question is answered.
    var ageAnswers: [String: Any] = Dictionary(uniqueKeysWithValues: AgeRating.frequency.map { ($0.0, "NONE" as Any) } + AgeRating.boolean.map { ($0.0, false as Any) })
    var attachments: [[String: Any]] = []
    var writes: [(String, String, [String: Any]?)] = []
    var uploaded = Data()
    var counter = 0

    func page(_ data: Any) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
    func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }

    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if method != "GET" {
            let json = (try? JSONSerialization.jsonObject(with: body(request))) as? [String: Any]
            writes.append((method, path, json))
            let data = json?["data"] as? [String: Any]
            switch (method, path) {
            case ("POST", "/v1/appStoreVersions"):
                counter += 1
                var created = data!; created["id"] = "version-new-\(counter)"
                var attributes = created["attributes"] as! [String: Any]; attributes["appVersionState"] = "PREPARE_FOR_SUBMISSION"; created["attributes"] = attributes
                versions.append(created); return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("POST", "/v1/appAssetLibraryImages"):
                counter += 1
                let attributes = data!["attributes"] as! [String: Any], size = attributes["fileSize"] as! Int
                let created: [String: Any] = ["type": "appAssetLibraryImages", "id": "image-new-\(counter)", "attributes": ["fileName": attributes["fileName"]!, "fileSize": size, "category": attributes["category"]!, "state": "AWAITING_UPLOAD",
                    "uploadOperations": [["method": "PUT", "url": "https://synthetic.blobstore.apple.com/part1", "offset": 0, "length": size, "requestHeaders": [["name": "Content-Type", "value": "image/png"]]]]],
                    "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]]
                libraryImages.append(created); return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("PATCH", let target) where target.hasPrefix("/v1/appAssetLibraryImages/image-new-"):
                guard let index = libraryImages.firstIndex(where: { "/v1/appAssetLibraryImages/\($0["id"] as! String)" == target }) else { return (404, [:], Data()) }
                var attributes = libraryImages[index]["attributes"] as! [String: Any]; attributes["state"] = processingAfterCommit ? "UPLOAD_COMPLETE" : "PREPARE_FOR_SUBMISSION"; attributes["specId"] = "spec-iphone"; attributes["uploadOperations"] = nil
                attributes["imageAsset"] = ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/synthetic-new/{w}x{h}bb.{f}", "width": 1290, "height": 2796]; libraryImages[index]["attributes"] = attributes
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": libraryImages[index]]))
            case ("POST", "/v1/appAssetLibraryPlacements"):
                counter += 1
                var attributes = data!["attributes"] as! [String: Any]; attributes["mediaType"] = "IMAGE"; attributes["state"] = "PARENT_PREPARE_FOR_SUBMISSION"
                let created: [String: Any] = ["type": "appAssetLibraryPlacements", "id": "placement-new-\(counter)", "attributes": attributes, "relationships": data!["relationships"]!]
                placements.append(created)
                if losePlacementAnswers > 0 { losePlacementAnswers -= 1; return (502, [:], Data()) }
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("DELETE", let target) where target.hasPrefix("/v1/appAssetLibraryImages/"):
                libraryImages.removeAll { "/v1/appAssetLibraryImages/\($0["id"] as! String)" == target }; return (204, [:], Data())
            case ("DELETE", let target) where target.hasPrefix("/v1/appAssetLibraryPlacements/"):
                placements.removeAll { "/v1/appAssetLibraryPlacements/\($0["id"] as! String)" == target }; return (204, [:], Data())
            case ("POST", "/v1/appAssetLibraryPlacementOrderingRequests"):
                let ids = ((((data?["relationships"] as? [String: Any])?["orderedPlacements"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                placements.sort { (ids.firstIndex(of: $0["id"] as! String) ?? Int.max) < (ids.firstIndex(of: $1["id"] as! String) ?? Int.max) }
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "appAssetLibraryPlacementOrderingRequests", "id": "ordering-\(counter)"]]))
            case ("PATCH", let target) where target.hasPrefix("/v1/appStoreVersionLocalizations/"):
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": locales[0]]))
            case ("PATCH", "/v1/appStoreVersions/version-1"):
                var attributes = versions[0]["attributes"] as! [String: Any]
                for (key, value) in (data?["attributes"] as? [String: Any]) ?? [:] { attributes[key] = value }
                versions[0]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": versions[0]]))
            case ("PATCH", "/v1/builds/build-7"):
                var attributes = builds[0]["attributes"] as! [String: Any]
                for (key, value) in (data?["attributes"] as? [String: Any]) ?? [:] { attributes[key] = value }
                builds[0]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": builds[0]]))
            case ("POST", "/v1/betaGroups/group-1/relationships/builds"):
                groupBuilds += ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }; return (204, [:], Data())
            case ("PATCH", "/v1/apps/1000000001"):
                rights = ((data?["attributes"] as? [String: Any])?["contentRightsDeclaration"]) ?? NSNull(); return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "apps", "id": "1000000001"]]))
            case ("PATCH", "/v1/appInfos/info-1"):
                if let value = (((data?["relationships"] as? [String: Any])?["primaryCategory"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String { primary = value }
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "appInfos", "id": "info-1"]]))
            case ("POST", "/v1/appEncryptionDeclarations"):
                var attributes = data!["attributes"] as! [String: Any]; attributes["appEncryptionDeclarationState"] = "CREATED"; attributes["platform"] = "IOS"
                let created: [String: Any] = ["type": "appEncryptionDeclarations", "id": "decl-1", "attributes": attributes]; declarations = [created]
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("POST", "/v1/appEncryptionDeclarationDocuments"):
                let attributes = data!["attributes"] as! [String: Any], size = attributes["fileSize"] as! Int
                let created: [String: Any] = ["type": "appEncryptionDeclarationDocuments", "id": "doc-1", "attributes": ["fileName": attributes["fileName"]!, "fileSize": size, "assetDeliveryState": ["state": "AWAITING_UPLOAD"],
                    "uploadOperations": [["method": "PUT", "url": "https://synthetic.blobstore.apple.com/document", "offset": 0, "length": size, "requestHeaders": []]]],
                    "relationships": ["appEncryptionDeclaration": ["data": ["type": "appEncryptionDeclarations", "id": "decl-1"]]]]
                documents = [created]; return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("PATCH", "/v1/appEncryptionDeclarationDocuments/doc-1"):
                var attributes = documents[0]["attributes"] as! [String: Any]; attributes["assetDeliveryState"] = ["state": "COMPLETE"]; documents[0]["attributes"] = attributes
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": documents[0]]))
            case ("POST", "/v1/accessibilityDeclarations"):
                var attributes = data!["attributes"] as! [String: Any]; attributes["state"] = "DRAFT"
                let created: [String: Any] = ["type": "accessibilityDeclarations", "id": "access-1", "attributes": attributes]; accessibility = [created]
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("PATCH", "/v1/accessibilityDeclarations/access-1"):
                var attributes = accessibility[0]["attributes"] as! [String: Any]
                if (data?["attributes"] as? [String: Any])?["publish"] as? Bool == true { attributes["state"] = "PUBLISHED" }
                accessibility[0]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": accessibility[0]]))
            case ("PATCH", "/v1/ageRatingDeclarations/age-1"):
                for (key, value) in (data?["attributes"] as? [String: Any]) ?? [:] { ageAnswers[key] = value }
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "ageRatingDeclarations", "id": "age-1"]]))
            case ("PATCH", "/v1/territoryAvailabilities/ta-swe"):
                sweden = ((data?["attributes"] as? [String: Any])?["available"] as? Bool) ?? sweden; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "territoryAvailabilities", "id": "ta-swe"]]))
            case ("POST", "/v1/appStoreReviewDetails"):
                var created = data!; created["id"] = "detail-1"; reviewDetails = [created]
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("POST", "/v1/appStoreReviewAttachments"):
                let attributes = data!["attributes"] as! [String: Any], size = attributes["fileSize"] as! Int
                let created: [String: Any] = ["type": "appStoreReviewAttachments", "id": "attachment-1", "attributes": ["fileName": attributes["fileName"]!, "fileSize": size, "assetDeliveryState": ["state": "AWAITING_UPLOAD"],
                    "uploadOperations": [["method": "PUT", "url": "https://synthetic.blobstore.apple.com/attachment", "offset": 0, "length": size, "requestHeaders": []]]],
                    "relationships": ["appStoreReviewDetail": ["data": ["type": "appStoreReviewDetails", "id": "detail-1"]]]]
                attachments = [created]; return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": created]))
            case ("PATCH", "/v1/appStoreReviewAttachments/attachment-1"):
                var attributes = attachments[0]["attributes"] as! [String: Any]; attributes["assetDeliveryState"] = ["state": "COMPLETE"]; attributes["sourceFileChecksum"] = (data?["attributes"] as? [String: Any])?["sourceFileChecksum"]
                attachments[0]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": attachments[0]]))
            case ("DELETE", let target) where target.hasPrefix("/v1/appStoreReviewAttachments/"):
                attachments.removeAll { "/v1/appStoreReviewAttachments/\($0["id"] as! String)" == target }; return (204, [:], Data())
            case ("POST", "/v1/analyticsReportRequests"): return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "analyticsReportRequests", "id": "request-1", "attributes": ["accessType": "ONGOING"]]]))
            case ("POST", "/v1/appPriceSchedules"): return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "appPriceSchedules", "id": "schedule-2"]]))
            case ("POST", "/v1/betaGroups"):
                counter += 1; let id = "group-\(counter + 1)"
                groups.append(["type": "betaGroups", "id": id, "attributes": data?["attributes"] ?? [:], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]); groupTesters[id] = []
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": groups.last!]))
            case ("POST", let target) where target.hasPrefix("/v1/betaGroups/") && target.hasSuffix("/relationships/betaTesters"),
                 ("DELETE", let target) where target.hasPrefix("/v1/betaGroups/") && target.hasSuffix("/relationships/betaTesters"):
                let id = target.split(separator: "/")[2].description, ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                groupTesters[id] = method == "POST" ? (groupTesters[id] ?? []) + ids : (groupTesters[id] ?? []).filter { !ids.contains($0) }
                return (204, [:], Data())
            case ("PATCH", let target) where target.hasPrefix("/v1/betaGroups/"):
                guard let index = groups.firstIndex(where: { "/v1/betaGroups/\($0["id"] as! String)" == target }) else { return (404, [:], Data()) }
                var attributes = groups[index]["attributes"] as! [String: Any]; for (key, value) in data?["attributes"] as? [String: Any] ?? [:] { attributes[key] = value }
                groups[index]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": groups[index]]))
            case ("DELETE", let target) where target.hasPrefix("/v1/betaGroups/"):
                groups.removeAll { "/v1/betaGroups/\($0["id"] as! String)" == target }; return (204, [:], Data())
            case ("POST", "/v1/betaTesters"):
                counter += 1; let id = "tester-\(counter + 1)", email = (data?["attributes"] as? [String: Any])?["email"] as? String ?? ""
                testers.append(["type": "betaTesters", "id": id, "attributes": ["email": email, "state": "INVITED"]])
                for group in ((data?["relationships"] as? [String: Any])?["betaGroups"] as? [String: Any])?["data"] as? [[String: Any]] ?? [] { groupTesters[group["id"] as! String, default: []].append(id) }
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": testers.last!]))
            case ("POST", "/v1/betaTesterInvitations"): return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "betaTesterInvitations", "id": "invitation-1"]]))
            case ("DELETE", "/v1/apps/1000000001/relationships/betaTesters"):
                let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                testers.removeAll { ids.contains($0["id"] as! String) }; for key in groupTesters.keys { groupTesters[key]!.removeAll { ids.contains($0) } }
                return (204, [:], Data())
            case ("PATCH", "/v1/betaLicenseAgreements/license-1"):
                license = (data?["attributes"] as? [String: Any])?["agreementText"] as? String ?? license
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "betaLicenseAgreements", "id": "license-1"]]))
            case ("POST", "/v1/betaAppLocalizations"), ("POST", "/v1/betaBuildLocalizations"):
                let type = path.hasSuffix("betaAppLocalizations") ? "betaAppLocalizations" : "betaBuildLocalizations"
                let item: [String: Any] = ["type": type, "id": "\(type)-1", "attributes": data?["attributes"] ?? [:], "relationships": data?["relationships"] ?? [:]]
                if type == "betaAppLocalizations" { betaAppLocales.append(item) } else { betaBuildLocales.append(item) }
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": item]))
            case ("PATCH", "/v1/betaBuildLocalizations/betaBuildLocalizations-1"):
                var attributes = betaBuildLocales[0]["attributes"] as! [String: Any]; for (key, value) in data?["attributes"] as? [String: Any] ?? [:] { attributes[key] = value }
                betaBuildLocales[0]["attributes"] = attributes; return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": betaBuildLocales[0]]))
            case ("POST", "/v1/betaAppReviewSubmissions"):
                betaSubmissions.append(["type": "betaAppReviewSubmissions", "id": "beta-review-1", "attributes": ["betaReviewState": "WAITING_FOR_REVIEW"], "relationships": data?["relationships"] ?? [:]])
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": betaSubmissions[0]]))
            case ("POST", "/v1/inAppPurchasePriceSchedules"):
                iapManual = (json?["included"] as? [[String: Any]] ?? []).enumerated().map { index, item in
                    ["type": "inAppPurchasePrices", "id": "iap-price-\(index + 1)", "attributes": item["attributes"] ?? [:], "relationships": ["inAppPurchasePricePoint": (item["relationships"] as! [String: Any])["inAppPurchasePricePoint"]!]]
                }
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "inAppPurchasePriceSchedules", "id": "iap-schedule-1"]]))
            case ("POST", "/v1/subscriptionPrices"):
                let relationships = data?["relationships"] as! [String: Any]
                subscriptionPrices.append(["type": "subscriptionPrices", "id": "sub-price-\(subscriptionPrices.count + 1)", "attributes": ["startDate": (data?["attributes"] as! [String: Any])["startDate"] ?? NSNull(), "preserved": false],
                                           "relationships": ["subscriptionPricePoint": relationships["subscriptionPricePoint"]!, "territory": ["data": ["type": "territories", "id": "USA"]]]])
                return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": subscriptionPrices.last!]))
            case ("POST", "/v1/buildBetaNotifications"): return (201, [:], try! JSONSerialization.data(withJSONObject: ["data": ["type": "buildBetaNotifications", "id": "notice-1"]]))
            default: return (409, [:], Data())
            }
        }
        switch path {
        case "/v1/apps/1000000001": return page(["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App", "contentRightsDeclaration": rights]])
        case "/v1/apps/1000000001/appInfos": return page([["type": "appInfos", "id": "info-1", "attributes": ["state": "PREPARE_FOR_SUBMISSION"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]])
        case "/v1/appInfos/info-1": return page(["type": "appInfos", "id": "info-1", "attributes": ["state": "PREPARE_FOR_SUBMISSION"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]], "primaryCategory": ["data": ["type": "appCategories", "id": primary]],
            "primarySubcategoryOne": ["data": NSNull()], "primarySubcategoryTwo": ["data": NSNull()], "secondaryCategory": ["data": NSNull()], "secondarySubcategoryOne": ["data": NSNull()], "secondarySubcategoryTwo": ["data": NSNull()]]])
        case "/v1/apps/1000000001/accessibilityDeclarations": return page(accessibility)
        case "/v1/apps/1000000001/appEncryptionDeclarations": return page(declarations)
        case "/v1/appEncryptionDeclarations/decl-1/appEncryptionDeclarationDocument": return documents.isEmpty ? (404, [:], Data()) : page(documents[0])
        case "/v1/appEncryptionDeclarationDocuments/doc-1": return documents.isEmpty ? (404, [:], Data()) : page(documents[0])
        // Apple's app information for the imported language, the same as the synthetic import, so a Save changes it only when a test edits it.
        case "/v1/appInfos/info-1/appInfoLocalizations": return page([["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": appInfoName, "subtitle": "Sample subtitle"],
                                                                        "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]])
        case "/v1/appInfos/info-1/ageRatingDeclaration": return page(["type": "ageRatingDeclarations", "id": "age-1", "attributes": ageAnswers])
        case "/v1/appCategories": return page([["type": "appCategories", "id": "GAMES", "attributes": ["platforms": ["IOS", "MAC_OS"]]], ["type": "appCategories", "id": "PRODUCTIVITY", "attributes": ["platforms": ["IOS", "MAC_OS"]]]])
        case "/v1/apps/1000000001/appAvailabilityV2": return page(["type": "appAvailabilities", "id": "availability-1", "attributes": ["availableInNewTerritories": true]])
        case "/v2/appAvailabilities/availability-1/territoryAvailabilities":
            return page([["type": "territoryAvailabilities", "id": "ta-swe", "attributes": ["available": sweden, "preOrderEnabled": false, "contentStatuses": ["AVAILABLE"]], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]],
                         ["type": "territoryAvailabilities", "id": "ta-usa", "attributes": ["available": true, "preOrderEnabled": false, "contentStatuses": ["AVAILABLE"]], "relationships": ["territory": ["data": ["type": "territories", "id": "USA"]]]]])
        case "/v1/apps/1000000001/appStoreVersions": return page(versions)
        case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return page(locales)
        case "/v1/apps/1000000001/assetLibrary": return library ? page(["type": "appAssetLibraries", "id": "library-1"]) : (404, [:], Data())
        case "/v1/appAssetLibraryRefData": return library ? page([Self.catalog]) : (404, [:], Data())
        case "/v1/appAssetLibraries/library-1/images": return page(libraryImages)
        case "/v1/appAssetLibraries/library-1/videos": return page([])
        case let target where target.hasPrefix("/v1/appStoreVersionLocalizations/") && target.hasSuffix("/placements"):
            guard library else { return (404, [:], Data()) }
            func link(_ item: [String: Any], _ name: String) -> String? { (((item["relationships"] as? [String: Any])?[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String }
            let locale = target.split(separator: "/")[2].description, placed = placements.filter { link($0, "appStoreVersionLocalization") == locale }
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": placed, "included": libraryImages.filter { image in placed.contains { link($0, "image") == image["id"] as? String } }, "links": [:]]))
        case "/v1/appStoreVersionLocalizations/version-locale-1/appScreenshotSets": return page(sets)
        case "/v1/appScreenshotSets/set-1/appScreenshots": return page(shots)
        case "/v1/apps/1000000001/analyticsReportRequests": return page([])
        case "/v1/apps/1000000001/builds": return page(builds)
        case "/v1/appStoreVersions/version-1/appStoreReviewDetail": return reviewDetails.isEmpty ? (404, [:], Data()) : page(reviewDetails[0])
        case "/v1/appStoreReviewDetails/detail-1": return reviewDetails.isEmpty ? (404, [:], Data()) : page(reviewDetails[0])
        case "/v1/appStoreReviewDetails/detail-1/appStoreReviewAttachments": return page(attachments)
        case "/v1/appStoreReviewAttachments/attachment-1": return attachments.isEmpty ? (404, [:], Data()) : page(attachments[0])
        case "/v1/builds":
            if let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "filter[betaAppReviewSubmission.betaReviewState]" })?.value {
                return page(betaSubmissions.contains { ($0["attributes"] as? [String: Any])?["betaReviewState"] as? String == state } ? builds : [])
            }
            let detailState = (builds[0]["attributes"] as! [String: Any])["usesNonExemptEncryption"] == nil ? "MISSING_EXPORT_COMPLIANCE" : "READY_FOR_BETA_SUBMISSION"
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": builds, "included": [["type": "preReleaseVersions", "id": "pre-1", "attributes": ["version": "2.0", "platform": "IOS"]],
                ["type": "buildBetaDetails", "id": "detail-7", "attributes": ["externalBuildState": detailState, "internalBuildState": detailState, "autoNotifyEnabled": automaticNotification]]], "links": [:]]))
        case "/v1/betaGroups":
            let build = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[builds]" }?.value
            return page(build == nil ? groups : groups.filter { $0["id"] as? String == "group-1" && groupBuilds.contains(build!) })
        case "/v1/builds/build-7/individualTesters": return page(testers.filter { directTesters.contains($0["id"] as! String) })
        case "/v1/builds/build-7/buildBetaDetail": return page(["type": "buildBetaDetails", "id": "detail-7", "attributes": ["externalBuildState": betaExternalState, "autoNotifyEnabled": automaticNotification], "relationships": ["build": ["data": ["type": "builds", "id": "build-7"]]]])
        case "/v1/betaGroups/group-1/builds": return page(builds.filter { groupBuilds.contains($0["id"] as! String) })
        case let target where target.hasPrefix("/v1/betaGroups/") && target.hasSuffix("/builds"): return page([])
        case let target where target.hasPrefix("/v1/betaGroups/") && target.hasSuffix("/betaTesters"):
            let ids = groupTesters[target.split(separator: "/")[2].description] ?? []
            return page(testers.filter { ids.contains($0["id"] as! String) })
        case "/v1/betaTesters":
            let email = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[email]" }?.value
            return page(email == nil ? testers : testers.filter { (($0["attributes"] as? [String: Any])?["email"] as? String)?.lowercased() == email!.lowercased() })
        case let target where target.hasPrefix("/v1/betaTesters/") && target.hasSuffix("/betaGroups"):
            let id = target.split(separator: "/")[2].description
            return page(groups.filter { groupTesters[$0["id"] as! String]?.contains(id) == true })
        case let target where target.hasPrefix("/v1/betaTesters/") && target.hasSuffix("/builds"):
            let id = target.split(separator: "/")[2].description
            return page(directTesters.contains(id) ? builds.filter { $0["id"] as? String == "build-7" } : [])
        case let target where target.hasPrefix("/v1/betaTesters/") && target.hasSuffix("/relationships/apps"):
            return page([["type": "apps", "id": "1000000001"]])
        case "/v1/apps/1000000001/betaLicenseAgreement": return page(["type": "betaLicenseAgreements", "id": "license-1", "attributes": ["agreementText": license]])
        case "/v1/betaLicenseAgreements/license-1/relationships/app", "/v1/betaAppLocalizations/betaAppLocalizations-1/relationships/app": return page(["type": "apps", "id": "1000000001"])
        case "/v1/betaBuildLocalizations/betaBuildLocalizations-1/relationships/build": return page(["type": "builds", "id": "build-7"])
        case "/v1/betaAppLocalizations": return page(betaAppLocales)
        case "/v1/builds/build-7/betaBuildLocalizations": return page(betaBuildLocales)
        case "/v1/betaAppReviewSubmissions": return page(betaSubmissions)
        case "/v1/apps/1000000001/betaAppReviewDetail": return page(betaReviewDetails)
        case "/v1/apps/1000000001/inAppPurchasesV2": return page([["type": "inAppPurchases", "id": "iap-1", "attributes": ["productId": "com.example.coins", "name": "Coins", "state": "READY_TO_SUBMIT", "inAppPurchaseType": "CONSUMABLE"]]])
        case "/v1/apps/1000000001/subscriptionGroups": return page([["type": "subscriptionGroups", "id": "sg-1", "attributes": ["referenceName": "Premium"]]])
        case "/v1/subscriptionGroups/sg-1/subscriptions":
            return page([["type": "subscriptions", "id": "sub-1", "attributes": ["productId": "com.example.monthly", "name": "Monthly", "state": "APPROVED", "subscriptionPeriod": "ONE_MONTH"], "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "sg-1"]]]]])
        case "/v2/inAppPurchases/iap-1/iapPriceSchedule": return iapManual.isEmpty ? (404, [:], Data()) : page(["type": "inAppPurchasePriceSchedules", "id": "iap-schedule-1"])
        case "/v1/inAppPurchasePriceSchedules/iap-schedule-1/baseTerritory": return page(["type": "territories", "id": "USA", "attributes": ["currency": "USD"]])
        case "/v1/inAppPurchasePriceSchedules/iap-schedule-1/manualPrices", "/v1/inAppPurchasePriceSchedules/iap-schedule-1/automaticPrices", "/v1/subscriptions/sub-1/prices":
            let rows = path.hasSuffix("manualPrices") ? iapManual : path.hasSuffix("automaticPrices") ? [] : subscriptionPrices
            let kind = path.hasSuffix("/prices") ? "subscriptionPricePoints" : "inAppPurchasePricePoints"
            let points = Set(rows.compactMap { (($0["relationships"] as? [String: Any])?.values.compactMap { ($0 as? [String: Any])?["data"] as? [String: Any] }.first { $0["type"] as? String == kind })?["id"] as? String })
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": rows, "links": [:], "included": points.sorted().map { ["type": kind, "id": $0, "attributes": ["customerPrice": $0.hasSuffix("099") ? "0.99" : $0.hasSuffix("199") ? "1.99" : $0.hasSuffix("499") ? "4.99" : "5.99", "proceeds": "0.70"],
                "relationships": ["territory": ["data": ["type": "territories", "id": "USA"]]]] } + [["type": "territories", "id": "USA", "attributes": ["currency": "USD"]]]]))
        // The purchase and the subscription are already available in the United States and Sweden.
        case "/v2/inAppPurchases/iap-1/inAppPurchaseAvailability": return page(["type": "inAppPurchaseAvailabilities", "id": "iap-availability-1", "attributes": ["availableInNewTerritories": true]])
        case "/v1/subscriptions/sub-1/subscriptionAvailability": return page(["type": "subscriptionAvailabilities", "id": "sub-availability-1", "attributes": ["availableInNewTerritories": true]])
        case "/v1/inAppPurchaseAvailabilities/iap-availability-1/availableTerritories", "/v1/subscriptionAvailabilities/sub-availability-1/availableTerritories":
            return page([["type": "territories", "id": "USA", "attributes": ["currency": "USD"]], ["type": "territories", "id": "SWE", "attributes": ["currency": "SEK"]]])
        case "/v2/inAppPurchases/iap-1/pricePoints", "/v1/subscriptions/sub-1/pricePoints":
            let kind = path.hasPrefix("/v2") ? "inAppPurchasePricePoints" : "subscriptionPricePoints", ids = path.hasPrefix("/v2") ? ["iap-pp-usa-099", "iap-pp-usa-199"] : ["sub-pp-usa-499", "sub-pp-usa-599"]
            // A request for Sweden also gets the purchase's Swedish price point.
            let filter = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[territory]" }?.value ?? "USA"
            let swedish: [[String: Any]] = path.hasPrefix("/v2") && filter.contains("SWE") ? [["type": kind, "id": "iap-pp-swe-10", "attributes": ["customerPrice": "10"], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]]] : []
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": (filter.contains("USA") ? ids.map { ["type": kind, "id": $0, "attributes": ["customerPrice": $0.hasSuffix("099") ? "0.99" : $0.hasSuffix("199") ? "1.99" : $0.hasSuffix("499") ? "4.99" : "5.99"],
                "relationships": ["territory": ["data": ["type": "territories", "id": "USA"]]]] } : []) + swedish, "included": [["type": "territories", "id": "USA", "attributes": ["currency": "USD"]]], "links": [:]]))
        case "/v1/apps/1000000001/appPriceSchedule": return page(["type": "appPriceSchedules", "id": "schedule-1", "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]])
        case "/v1/appPriceSchedules/schedule-1/baseTerritory": return page(["type": "territories", "id": "USA", "attributes": ["currency": "USD"]])
        case "/v1/appPriceSchedules/schedule-1/manualPrices":
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [["type": "appPrices", "id": "price-usa", "attributes": ["startDate": NSNull(), "endDate": NSNull()], "relationships": ["territory": ["data": ["type": "territories", "id": "USA"]], "appPricePoint": ["data": ["type": "appPricePoints", "id": "pp-usa-499"]]]]],
                "included": [["type": "territories", "id": "USA", "attributes": ["currency": "USD"]], ["type": "appPricePoints", "id": "pp-usa-499", "attributes": ["customerPrice": "4.99", "proceeds": "3.49"]]], "links": [:]]))
        case "/v1/appPriceSchedules/schedule-1/automaticPrices":
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [["type": "appPrices", "id": "price-swe", "attributes": [:], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]], "appPricePoint": ["data": ["type": "appPricePoints", "id": "pp-swe-55"]]]]],
                "included": [["type": "territories", "id": "SWE", "attributes": ["currency": "SEK"]], ["type": "appPricePoints", "id": "pp-swe-55", "attributes": ["customerPrice": "55", "proceeds": "33"]]], "links": [:]]))
        case "/v1/territories": return page([["type": "territories", "id": "USA", "attributes": ["currency": "USD"]], ["type": "territories", "id": "SWE", "attributes": ["currency": "SEK"]]])
        case "/v1/apps/1000000001/appPricePoints":
            return page([["type": "appPricePoints", "id": "pp-swe-49", "attributes": ["customerPrice": "49"], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]],
                         ["type": "appPricePoints", "id": "pp-swe-45", "attributes": ["customerPrice": "45"], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]]])
        default:
            for (prefix, items) in [("/v1/appStoreVersions/", versions), ("/v1/appStoreVersionLocalizations/", locales), ("/v1/appScreenshotSets/", sets), ("/v1/appScreenshots/", shots), ("/v1/appAssetLibraryImages/", libraryImages), ("/v1/appAssetLibraryPlacements/", placements)] where path.hasPrefix(prefix) {
                if var item = items.first(where: { prefix + ($0["id"] as! String) == path }) {
                    if failProcessingReads, (item["attributes"] as? [String: Any])?["state"] as? String == "UPLOAD_COMPLETE" { return (500, [:], Data()) }
                    if finishProcessingOnRead, prefix == "/v1/appAssetLibraryImages/", var attributes = item["attributes"] as? [String: Any], attributes["state"] as? String == "UPLOAD_COMPLETE",
                       let index = libraryImages.firstIndex(where: { $0["id"] as? String == item["id"] as? String }) {
                        attributes["state"] = "PREPARE_FOR_SUBMISSION"; item["attributes"] = attributes; libraryImages[index] = item
                    }
                    if localeReadsOmitOwner, prefix == "/v1/appStoreVersionLocalizations/" { item["relationships"] = [:] }
                    if readsOmitUploadOperations, var attributes = item["attributes"] as? [String: Any] { attributes["uploadOperations"] = nil; item["attributes"] = attributes }
                    return page(item)
                }
            }
            return (404, [:], Data())
        }
    }
}

extension WorkspaceSession {
    func waitForLibraryProcessing(_ wait: LibraryProcessingWait) { libraryProcessingWait = wait }
}

@Suite(.serialized) struct PublishingTests {
    init() throws { _ = try TestIsolation.require() }
    func client(_ account: Account, host: String) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func agreementFailureAfterApprovalRetainsOnlyPublicGuidanceAndConsumesReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "agreement-publishing.appstoreconnect.test", app = "1000000001"
        let body = JSONText.object([("errors", .array([.object([("code", .string("FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED")), ("detail", .string("Synthetic upstream text must not be saved"))])]))]).data
        StubProtocol.handle(host) { request in
            if request.httpMethod == "GET" { return apple.handle(request) }
            return (403, ["Content-Type": "application/json"], body)
        }
        _ = try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .release), client: client)
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
        let result = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(result.state == "failed")
        #expect(result.error?.contains("Apple requires updated terms") == true)
        #expect(result.error?.contains("Synthetic upstream text") == false)
        #expect(result.error?.contains("prepare a new review") == true)
        #expect(StubProtocol.requests(host).filter { $0.httpMethod != "GET" }.count == 1)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(StubProtocol.requests(host).filter { $0.httpMethod != "GET" }.count == 1)
    }

    @Test func publishingRefusesAnotherClientOrChangedConfiguredCredentials() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "account-scope.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let current = try client(account, host: host)
        let foreignAccount = Account(id: "another-synthetic-account", name: "Synthetic other account", keyId: "SAMPLE0002", keyType: account.keyType, issuerId: account.issuerId, appIds: [app], appNames: nil)
        let foreign = try client(foreignAccount, host: host)
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: foreign) }
        #expect(try await session.publishHistory(accountId: account.id, appId: app).isEmpty)
        let review = try await session.preparePublishing(account: account, request: request, client: current)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: foreign) }
        try await session.storeAccess { store in
            try store.transaction { read in
                let document = try #require(try read("accounts", "all")), items = WorkspaceSession.items(try JSONText.parse(document.payload))
                return [.put(namespace: "accounts", key: "all", json: JSONText.array(items.map { $0["id"]?.text == account.id ? $0.setting("keyId", .string("SAMPLE0002")) : $0 }).data)]
            }
        }
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: current) }
        #expect(apple.writes.isEmpty)
        #expect(try await session.publishReview(accountId: account.id, appId: app, id: review.id).state == "prepared")
    }

    @Test func aPlannedVersionIsCreatedOnlyAfterOneApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "release.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .release), client: client)
        #expect(review.title == "Create version 2.0" && review.steps.map(\.label) == ["Create iOS version 2.0"] && apple.writes.isEmpty)
        await #expect(throws: PublishFailure.expired) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: String(repeating: "0", count: 64), client: client) }
        #expect(apple.writes.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete" && done.steps.allSatisfy { $0.state == "done" } && done.steps[0].resultId == "version-new-1")
        #expect(apple.writes.count == 1 && apple.writes[0].1 == "/v1/appStoreVersions")
        let attributes = (apple.writes[0].2?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        #expect(attributes?["versionString"] as? String == "2.0" && attributes?["releaseType"] as? String == "MANUAL" && attributes?["platform"] as? String == "IOS")
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(try await session.publishHistory(accountId: account.id, appId: "1000000001").first?.state == "complete")
    }

    /// A Save that stopped before its upload leaves a reservation at Apple. The next review removes this Mac's own leftover and
    /// reserves the file again, so old attempts never block saving.
    @Test func aStoppedUploadIsCleanedUpByTheNextReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material-retry.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 7)
        var blobFails = true
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            apple.lock.withLock {
                if blobFails { return (500, [:], Data()) }
                apple.uploaded = apple.body(request); return (200, [:], Data())
            }
        }
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("retry.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")

        let first = try await session.preparePublishing(account: account, request: request, client: client)
        let stopped = try await session.approvePublishing(account: account, appId: "1000000001", id: first.id, fingerprint: first.fingerprint, client: client)
        #expect(stopped.state == "failed")
        #expect(apple.lock.withLock { apple.libraryImages.map { ($0["id"] as! String, ($0["attributes"] as! [String: Any])["state"] as! String) }.last.map { $0.1 } } == "AWAITING_UPLOAD")

        apple.lock.withLock { blobFails = false }
        let retry = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(retry.steps.map(\.label).contains("Remove unfinished upload · retry.png"))
        #expect(retry.steps.firstIndex { $0.label == "Remove unfinished upload · retry.png" }! < retry.steps.firstIndex { $0.label == "Upload retry.png · en-US" }!)
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: retry.id, fingerprint: retry.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == png)
        let states = apple.lock.withLock { apple.libraryImages.map { ($0["attributes"] as! [String: Any])["state"] as! String } }
        #expect(!states.contains("AWAITING_UPLOAD"))
        // Nothing is left to clean up afterwards.
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.allSatisfy { !$0.label.hasPrefix("Remove unfinished upload") })
    }

    /// Every file is uploaded before the review waits for Apple's processing, and a file an earlier Save left processing is
    /// waited for instead of uploaded again.
    @Test func filesUploadBeforeProcessingIsAwaitedAndProcessingFilesAreNotUploadedAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material-processing.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let files = [("first.png", syntheticPNG(width: 1290, height: 2796, seed: 11)), ("second.png", syntheticPNG(width: 1290, height: 2796, seed: 12))]
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")

        let first = try await session.preparePublishing(account: account, request: request, client: client)
        let media = first.steps.map(\.label).filter { $0.contains("first.png") || $0.contains("second.png") }
        #expect(media == ["Upload first.png · en-US", "Upload first.png", "Complete upload · first.png", "Upload second.png · en-US", "Upload second.png", "Complete upload · second.png", "Verify first.png", "Verify second.png"])

        // Apple is still processing when the review checks the first file, and every read of it fails until the wait ends:
        // the review stops there.
        await session.waitForLibraryProcessing(LibraryProcessingWait(limit: .seconds(1), retry: .milliseconds(10), poll: .milliseconds(10)))
        apple.lock.withLock { apple.processingAfterCommit = true; apple.failProcessingReads = true }
        let stopped = try await session.approvePublishing(account: account, appId: "1000000001", id: first.id, fingerprint: first.fingerprint, client: client)
        #expect(stopped.state == "failed" && stopped.steps.first { $0.state == "failed" }?.label == "Verify first.png")
        #expect(stopped.error?.contains("still processing") == true, "\(stopped.error ?? "")")

        // The next review waits for both processing files instead of reserving and uploading them again.
        apple.lock.withLock { apple.failProcessingReads = false }
        let retry = try await session.preparePublishing(account: account, request: request, client: client)
        let labels = retry.steps.map(\.label)
        #expect(labels.contains("Verify first.png") && labels.contains("Verify second.png"))
        #expect(!labels.contains { $0.hasPrefix("Upload first.png") || $0.hasPrefix("Upload second.png") || $0.hasPrefix("Remove unfinished upload") })
        apple.lock.withLock { apple.finishProcessingOnRead = true }
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: retry.id, fingerprint: retry.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.count } == 2)
        #expect(PublishingReviewPresentation.progress(stopped).hasPrefix("6 of ") && PublishingReviewPresentation.progress(stopped).contains("Stopped at: Verify first.png"))
    }

    @Test func anAssetLibraryUploadOnlyUploadsAndTheSaveAfterItAddsTheFiles() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "upload-stage.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 44)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic promotion"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)

        // The upload neither changes the version nor waits for Apple's processing, so a slow file cannot stop it.
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        let staged = try await session.preparePublishing(account: account, request: upload, client: client)
        #expect(staged.title.hasPrefix("Upload to Asset Library") && staged.steps.map(\.label) == ["Upload staged.png · en-US", "Upload staged.png", "Complete upload · staged.png"])
        #expect(ReleaseMediaProgress(staged)?.files.map(ReleaseMediaProgress(staged)!.status) == ["Upload to Asset Library"])
        let uploaded = try await session.approvePublishing(account: account, appId: "1000000001", id: staged.id, fingerprint: staged.fingerprint, client: client)
        #expect(uploaded.state == "complete" && apple.uploaded == png, "\(uploaded.error ?? "")")
        #expect(!apple.writes.contains { $0.1.hasPrefix("/v1/appAssetLibraryPlacement") || $0.1.hasPrefix("/v1/appStoreVersionLocalizations") })
        #expect(ReleaseMediaProgress(uploaded)?.summary == "1 of 1 files in Asset Library")
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: upload, client: client) }

        // Save then adds the uploaded file to the version with the text, without uploading it again, even when Apple's read of
        // the language leaves out its version link.
        apple.lock.withLock { apple.localeReadsOmitOwner = true }
        let save = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"), client: client)
        #expect(!save.steps.contains { $0.kind == .upload } && save.steps.contains { $0.label == "Add screenshot · en-US" } && save.steps.contains { $0.label == "Update version text · en-US" })
        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: save.id, fingerprint: save.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(ReleaseMediaProgress(saved)?.files.map(ReleaseMediaProgress(saved)!.status) == ["Added to this version"])
    }

    @Test func applesRefusalBecomesProblemsWithCodesFieldsAndPlacesToFixThem() throws {
        let body = try JSONSerialization.data(withJSONObject: ["errors": [
            ["status": "409", "code": "STATE_ERROR.ENTITY_STATE_INVALID", "title": "Synthetic private title", "detail": "Synthetic App Name is missing things",
             "meta": ["associatedErrors": [
                "/v1/ageRatingDeclarations/synthetic-1": [["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "detail": "synthetic detail", "source": ["pointer": "/data/attributes/lootBox"]]],
                "/v1/appStoreReviewDetails/synthetic-2": [["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "source": ["pointer": "/data/attributes/contactEmail"]]],
                "/v1/syntheticThings/synthetic-3": [["code": "ENTITY_ERROR.SYNTHETIC_UNKNOWN"], ["code": "lowercase-not-a-code"], ["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "source": ["pointer": "/data/attributes/x?token=synthetic"]]]]]]]])
        let problems = AppleProblem.parse(data: body, contentType: "application/json")
        let areas: [String] = problems.map { $0.area.rawValue }
        #expect(areas.count == 4 && Set(areas) == ["age-rating", "review-info", "other"])
        #expect(problems.first { $0.area == .ageRating }?.label == "Loot boxes or randomized items" && problems.first { $0.area == .reviewInformation }?.label == "Email")
        #expect(AppleProblem.Area.ageRating.check == "age-rating" && AppleProblem.Area.other.check == nil && AppleProblem.Area.privacy.action == "Answer App Privacy" && AppleProblem.Area.tax.action == "Choose Tax Category")
        // Unsafe field paths and malformed codes never become codes, resources or fields; Apple's reason is kept apart as one plain line.
        let text = problems.map { "\($0.code) \($0.resource ?? "") \($0.field ?? "")" }.joined()
        #expect(!text.contains("Synthetic") && !text.contains("token") && !text.contains("lowercase"))
        #expect(problems.first { $0.area == .ageRating }?.detail == "synthetic detail")
        #expect(AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", resource: nil, field: nil, detail: "Line one\n\u{0007}line\ttwo ").detail == "Line one line two")
        #expect(problems.allSatisfy { AppleProblem(json: $0.json) == $0 })
        #expect(AppleProblem.summary(problems, status: 409).hasPrefix("Apple needs 4 answers before it accepts this change, in Age Ratings, App Review Information, Other."))
        #expect(AppleProblem.parse(data: Data("not json".utf8), contentType: "application/json").isEmpty)
        // Apple's state codes that name a whole section get its words and the place to fix it.
        let privacy = AppleProblem(code: "STATE_ERROR.APP_DATA_USAGES_REQUIRED", resource: nil, field: nil), price = AppleProblem(code: "STATE_ERROR.APP_PRICING_REQUIRED", resource: nil, field: nil)
        #expect(privacy.area == .privacy && privacy.label == "App Privacy answers are not published")
        #expect(price.area == .pricing && price.label == "No price is set" && AppleProblem.Area.pricing.action == "Open Pricing")
        #expect(AppleProblem(code: "STATE_ERROR.SYNTHETIC_THING_REQUIRED", resource: nil, field: nil).label == "Synthetic thing required")
    }

    /// A refusal that names no field still belongs to the record the write sent, and its one reason is the stop's sentence.
    @Test func aRefusalWithoutAFieldBelongsToTheSentRecordAndSaysApplesReason() throws {
        let body = try JSONSerialization.data(withJSONObject: ["errors": [["status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "Synthetic declarations need another answer."]]])
        let problems = AppleProblem.parse(data: body, contentType: "application/json", resource: "appEncryptionDeclarations")
        #expect(problems.count == 1 && problems[0].area == .exportCompliance && problems[0].resource == "appEncryptionDeclarations")
        #expect(AppleProblem.summary(problems, status: 409) == "Apple refused this change in Export Compliance: Synthetic declarations need another answer.")
        #expect(AppleProblem.parse(data: body, contentType: "application/json", resource: "not a name?")[0].area == .other)
        #expect(AppleProblem(json: problems[0].json) == problems[0])
        let pointed = AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", resource: nil, field: "availableOnFrenchStore")
        #expect(pointed.area == .exportCompliance && pointed.label == "Available on the App Store in France")
    }

    @Test func unansweredAgeRatingsAreNamedBeforeAddForReview() throws {
        var answers: [(String, JSONText)] = AgeRating.frequency.map { ($0.0, .string("NONE")) } + AgeRating.boolean.map { ($0.0, .bool(false)) }
        #expect(AgeRating.unanswered(.object(answers)).isEmpty)
        answers.removeAll { $0.0 == "lootBox" }; answers.append(("gambling", .null))
        #expect(Set(AgeRating.unanswered(.object(answers))) == ["lootBox", "gambling"])
        // Age restricted social media is asked only when the app has social media.
        answers = answers.map { $0.0 == "socialMedia" ? ($0.0, .bool(true)) : $0 }.filter { $0.0 != "socialMediaAgeRestricted" }
        #expect(AgeRating.unanswered(.object(answers)).contains("socialMediaAgeRestricted"))
    }

    @Test func step2SavesOnlyScreenshotsAndStep3OnlyText() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "split-stages.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 46)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic split promotion"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("split.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        func request(_ stage: String) -> PublishRequest { var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); request.mediaStage = stage; return request }

        let screenshots = try await session.preparePublishing(account: account, request: request(PublishRequest.screenshotsStage), client: client)
        #expect(screenshots.title.hasPrefix("Save to App Previews and Screenshots") && screenshots.steps.contains { $0.label == "Add screenshot · en-US" })
        #expect(!screenshots.steps.contains { $0.label.hasPrefix("Update version text") })
        #expect(screenshots.notes.contains { $0.hasSuffix("Text and copyright are saved in step 3.") })
        let texts = try await session.preparePublishing(account: account, request: request(PublishRequest.textStage), client: client)
        #expect(texts.steps.contains { $0.label == "Update version text · en-US" })
        #expect(!texts.steps.contains { $0.path.first?.text?.hasPrefix("appAssetLibrary") == true || $0.kind == .upload || $0.kind == .verify })

        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: screenshots.id, fingerprint: screenshots.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(!apple.writes.contains { $0.1.hasPrefix("/v1/appStoreVersionLocalizations") })
        // Saved again with nothing new, the screenshots Save has nothing to send.
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: request(PublishRequest.screenshotsStage), client: client) }
    }

    @Test func step3SendsANameOnlyOnThisMacEvenWithoutADraftAsItsCheckReportsIt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "step3-app-information.appstoreconnect.test"
        apple.appInfoName = "Synthetic older name"
        StubProtocol.handle(host) { apple.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: "00000000-0000-4000-8000-000000000002", versionId: "version-1")
        request.mediaStage = PublishRequest.textStage
        let review = try await session.preparePublishing(account: account, request: request, client: try client(account, host: host))
        let info = try #require(review.steps.first { $0.label == "Update app information · en-US" })
        #expect(info.detail == "name" && info.after?.contains("Sample App Updated") == true && info.before?.contains("Synthetic older name") == true && apple.writes.isEmpty)
    }

    @Test func step2AddsALanguageNewToTheVersionWithItsTextAndSaysSo() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "split-new-language.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); request.mediaStage = PublishRequest.screenshotsStage
        let review = try await session.preparePublishing(account: account, request: request, client: try client(account, host: host))
        let added = try #require(review.steps.first { $0.label == "Add language · sv" })
        #expect(added.body?["data"]?["attributes"]?["description"]?.text?.isEmpty == false)
        #expect(review.notes.contains { $0.contains("also adds sv with its text") && $0.hasSuffix("Copyright and other text changes are saved in step 3.") })
    }

    /// Uploaded in App Store Connect, so no Save from this Mac knows it: Apple lists it with the same name and size as `png`.
    func webLibraryImage(_ apple: SyntheticApple, _ png: Data) {
        apple.libraryImages.append(["type": "appAssetLibraryImages", "id": "image-web", "attributes": ["fileName": "staged.png", "fileSize": png.count, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
            "imageAsset": ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/synthetic/{w}x{h}bb.{f}", "width": 1290, "height": 2796]], "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]])
    }

    @Test func aFileWithOnlyTheSameNameAndSizeIsUploadedInsteadOfReused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "library-name-only.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 45)
        webLibraryImage(apple, png)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        let review = try await session.preparePublishing(account: account, request: upload, client: try client(account, host: host))
        #expect(review.steps.contains { $0.guardValue?["kind"]?.text == "release-media-reserve" })
        #expect(!review.steps.contains { $0.body?.stringify().contains("image-web") == true })
    }

    @Test func aFileChosenFromAssetLibraryIsAddedWithoutUploadingItAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "library-match.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 45)
        webLibraryImage(apple, png)
        _ = try await session.addScreenshotsWithReceipt(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)], assetIds: ["image-web"])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: upload, client: client) }
        let save = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"), client: client)
        #expect(!save.steps.contains { $0.kind == .upload || $0.guardValue?["kind"]?.text == "release-media-reserve" } && save.steps.contains { $0.label == "Add screenshot · en-US" })
        // Apple adds the file but its answer is lost: the Save finds the placement instead of adding the file a second time.
        apple.lock.withLock { apple.losePlacementAnswers = 1 }
        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: save.id, fingerprint: save.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.filter { (($0["relationships"] as? [String: Any])?["image"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == "image-web" }.count } == 1)
        #expect(apple.lock.withLock { apple.placements.contains { (($0["relationships"] as? [String: Any])?["image"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == "image-web" } })
    }

    @Test @MainActor func removingEveryScreenshotPreparesOnlyVersionRemovalAndKeepsTheLibraryOriginal() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "clear-media.appstoreconnect.test"
        let revisionId = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let revision = try #require(try await session.revisions(accountId: account.id, appId: "1000000001").first { $0.id == revisionId })
        let localization = try #require(revision.versions.first?.localizations.first { $0.id == "version-locale-1" })
        let model = MediaListingEditor(scope: .init(accountId: account.id, appId: "1000000001", revisionId: revisionId), localization: localization, platform: "IOS", session: session)
        await model.load(); model.removeAllScreenshots()
        #expect((await model.run()).complete)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revisionId, versionId: "version-1")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty)
        #expect(review.steps.filter { $0.method == "DELETE" }.map { $0.path.first?.text } == ["appAssetLibraryPlacements"])
        #expect(!review.steps.contains { $0.kind == .upload || $0.label.hasPrefix("Add screenshot") })
        let result = try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(result.state == "complete")
        #expect(apple.lock.withLock { apple.placements.isEmpty && apple.libraryImages.map { $0["id"] as? String } == ["image-1"] })
        await #expect(throws: PublishFailure.self) {
            try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        }
    }

    @Test func mediaBatchesKeepReservationsDeletesAndFinalOrderAcrossLostPlacementAnswers() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "batch-media.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        apple.lock.withLock {
            let original = apple.placements[0]
            for index in 1..<5 { var extra = original; extra["id"] = "synthetic-old-placement-\(index)"; apple.placements.append(extra) }
            apple.readsOmitUploadOperations = true; apple.losePlacementAnswers = 1
        }
        StubProtocol.handle(host) { apple.handle($0) }
        final class Uploads: @unchecked Sendable { let lock = NSLock(); var data: [Data] = [] }
        let uploads = Uploads()
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == nil)
            let data = StubProtocol.body(request); uploads.lock.withLock { uploads.data.append(data) }; return (200, [:], Data())
        }
        let files = (0..<5).map { ("synthetic-batch-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8($0 + 70))) }
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let layout = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, revisionId: revision, versionId: "version-1")
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty)
        let result = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(result.state == "complete", "\(result.error ?? "")")
        let writes = apple.lock.withLock { apple.writes }
        let firstCommit = try #require(writes.firstIndex { $0.0 == "PATCH" && $0.1.hasPrefix("/v1/appAssetLibraryImages/") })
        #expect(!writes[..<firstCommit].filter { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryImages" }.isEmpty)
        let lastRemoval = try #require(writes.lastIndex { $0.0 == "DELETE" && $0.1.hasPrefix("/v1/appAssetLibraryPlacements/") })
        let firstPlacement = try #require(writes.firstIndex { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryPlacements" })
        #expect(lastRemoval < firstPlacement && writes.filter { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryPlacements" }.count == 5)
        #expect(writes.last?.1 == "/v1/appAssetLibraryPlacementOrderingRequests")
        let names = apple.lock.withLock {
            apple.placements.map { placement in
                let asset = (((placement["relationships"] as? [String: Any])?["image"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
                return (apple.libraryImages.first { $0["id"] as? String == asset }?["attributes"] as? [String: Any])?["fileName"] as? String
            }
        }
        #expect(names == files.map { Optional($0.0) })
        #expect(uploads.lock.withLock { Set(uploads.data) } == Set(files.map(\.1)))
        #expect(result.steps.allSatisfy { $0.state == "done" && ($0.guardValue?["kind"]?.text != "release-media-reserve" || $0.resultId != nil) })
        #expect(apple.lock.withLock { apple.libraryImages.contains { $0["id"] as? String == "image-1" } })
    }

    @Test func aFailedMediaWaveKeepsSuccessfulReservationsAndStartsNoDependentUploads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "batch-media-failure.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { request in
            if request.httpMethod == "POST" && request.url?.path == "/v1/appAssetLibraryImages" {
                let data = StubProtocol.body(request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let item = json["data"] as? [String: Any],
                   (item["attributes"] as? [String: Any])?["fileName"] as? String == "synthetic-fail-0.png" { return (403, [:], Data()) }
                var copy = request; copy.httpBodyStream = nil; copy.httpBody = data; return apple.handle(copy)
            }
            return apple.handle(request)
        }
        let files = (0..<6).map { ("synthetic-fail-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8($0 + 80))) }
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let layout = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, revisionId: revision, versionId: "version-1")
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        let failed = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(failed.state == "failed" && !failed.steps.contains { $0.state == "running" })
        #expect(failed.steps.filter { $0.guardValue?["kind"]?.text == "release-media-reserve" && $0.state == "done" }.count == 3)
        #expect(failed.steps.filter { $0.kind == .upload }.allSatisfy { $0.state == "pending" })
        #expect(apple.lock.withLock { apple.writes.allSatisfy { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryImages" } })
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: failed.id, fingerprint: failed.fingerprint, client: client) }
    }

    @Test func textAndScreenshotsArePublishedAsReviewedAndChangesConflict() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 42)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == nil)
            apple.lock.withLock { apple.uploaded = apple.body(request) }
            return (200, [:], Data())
        }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic promotion"; fields["whatsNew"] = "Synthetic release notes"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("new.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)

        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Update version text · en-US", "Upload new.png · en-US", "Upload new.png", "Complete upload · new.png", "Verify new.png", "Remove screenshot · en-US", "Add screenshot · en-US"])

        // Apple changes after the review was prepared: approval is refused and nothing is written.
        let conflictReview = review
        apple.lock.withLock { var attributes = apple.locales[0]["attributes"] as! [String: Any]; attributes["description"] = "Changed in App Store Connect"; apple.locales[0]["attributes"] = attributes }
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: "1000000001", id: conflictReview.id, fingerprint: conflictReview.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        #expect(try await session.publishReview(accountId: account.id, appId: "1000000001", id: conflictReview.id).state == "conflict")

        let fresh = try await session.preparePublishing(account: account, request: request, client: client)
        // The upload follows the operations from the reservation response, even when reading the image again omits them.
        apple.lock.withLock { apple.readsOmitUploadOperations = true }
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: fresh.id, fingerprint: fresh.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == png)
        // The file is saved once in Asset Library and committed with `uploaded` alone; removal takes only the placement off the version.
        let complete = apple.writes.first { $0.0 == "PATCH" && $0.1.hasPrefix("/v1/appAssetLibraryImages/") }?.2?["data"] as? [String: Any]
        #expect(complete?["attributes"] as? [String: Bool] == ["uploaded": true])
        #expect(apple.writes.allSatisfy { !ReleaseMedia.legacyRoots.contains($0.1.split(separator: "/").dropFirst().first.map(String.init) ?? "") })
        let placed = apple.lock.withLock { apple.placements.map { ((($0["relationships"] as? [String: Any])?["image"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String } }
        #expect(placed == ["image-new-1"] && apple.lock.withLock { apple.libraryImages.map { $0["id"] as! String } } == ["image-1", "image-new-1"])

        // A later review places the uploaded file instead of uploading it again; the order follows the saved layout.
        let earlier = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1").items.map(\.id)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("second.png", syntheticPNG(width: 1290, height: 2796, seed: 43))])
        let edited = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        let added = try #require(earlier.first { $0 != "shot-1" }), second = try #require(edited.items.map(\.id).first { !earlier.contains($0) })
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: [second, added, "shot-1"], hidden: ["shot-1"], expected: edited.signature)
        let next = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(next.steps.filter { $0.path.first?.text?.hasPrefix("appAssetLibrary") == true }.map(\.label) == ["Upload second.png · en-US", "Upload second.png", "Complete upload · second.png", "Verify second.png", "Add screenshot · en-US", "Set screenshots order · en-US · Iphone Synthetic Profile"])
        let ordered = try await session.approvePublishing(account: account, appId: "1000000001", id: next.id, fingerprint: next.fingerprint, client: client)
        #expect(ordered.state == "complete", "\(ordered.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.map { $0["id"] as! String } } == ["placement-new-4", "placement-new-2"])
        let textWrite = apple.writes.first { $0.1 == "/v1/appStoreVersionLocalizations/version-locale-1" }?.2?["data"] as? [String: Any]
        #expect((textWrite?["attributes"] as? [String: Any])?["promotionalText"] as? String == "Synthetic promotion")
        // The app's only version is its first: Apple has no What's New there, so it is not sent.
        #expect((textWrite?["attributes"] as? [String: Any])?["whatsNew"] == nil)
        // Once Apple holds an earlier version of the platform, What's New is sent with the rest of the text.
        apple.lock.withLock { apple.versions.append(["type": "appStoreVersions", "id": "version-0", "attributes": ["platform": "IOS", "versionString": "0.9", "appVersionState": "READY_FOR_SALE", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]) }
        let notes = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(try await session.approvePublishing(account: account, appId: "1000000001", id: notes.id, fingerprint: notes.fingerprint, client: client).state == "complete")
        let notesWrite = apple.writes.last { $0.1 == "/v1/appStoreVersionLocalizations/version-locale-1" }?.2?["data"] as? [String: Any]
        #expect((notesWrite?["attributes"] as? [String: Any])?["whatsNew"] as? String == "Synthetic release notes")
    }

    @Test func versionMediaWaitsWhileAppleListsItOnlyInTheDeprecatedSets() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "legacy-media.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        apple.lock.withLock { apple.placements = [] }
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("new.png", syntheticPNG(width: 1290, height: 2796, seed: 7))])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")
        do { _ = try await session.preparePublishing(account: account, request: request, client: client); Issue.record("Deprecated set media must block the review") }
        catch let failure as PublishFailure { #expect(failure.message.contains("outside Asset Library")) }
        #expect(apple.writes.isEmpty)

        // Once Apple lists no deprecated media for that display size, the same draft is placed through Asset Library and nothing is removed.
        apple.lock.withLock { apple.shots = [] }
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.contains { $0.label == "Add screenshot · en-US" } && !review.steps.contains { $0.method == "DELETE" })
        #expect(review.steps.allSatisfy { !ReleaseMedia.legacyRoots.contains($0.path.first?.text ?? "") })
    }

    @Test func copyrightAnalyticsAndPricesArePublishedWithTheirGuards() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "more.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)

        let copyright = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: " 2026 Synthetic Studio "), client: client)
        #expect(copyright.steps.map(\.after) == ["2026 Synthetic Studio"])
        apple.lock.withLock { var attributes = apple.versions[0]["attributes"] as! [String: Any]; attributes["copyright"] = "2025 Someone Else"; apple.versions[0]["attributes"] = attributes }
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: copyright.id, fingerprint: copyright.fingerprint, client: client) }
        let again = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: again.id, fingerprint: again.fingerprint, client: client).state == "complete")

        let analytics = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .analyticsOngoing), client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: analytics.id, fingerprint: analytics.fingerprint, client: client).state == "complete")
        #expect(apple.writes.last?.1 == "/v1/analyticsReportRequests")

        // A Swedish country draft becomes one manual schedule; the US base price and its point stay as they are.
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "49")], startDate: nil, endDate: nil)
        let prices = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .pricing), client: client)
        #expect(prices.steps.count == 1 && prices.steps[0].after == "SWE: 49 SEK · Now → ongoing\nUSA: 4.99 USD · Now → ongoing")
        let done = try await session.approvePublishing(account: account, appId: app, id: prices.id, fingerprint: prices.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        let body = apple.writes.last?.2
        let included = body?["included"] as? [[String: Any]]
        #expect(included?.compactMap { (($0["relationships"] as? [String: Any])?["appPricePoint"] as? [String: Any])?["data"] as? [String: Any] }.compactMap { $0["id"] as? String } == ["pp-swe-49", "pp-usa-499"])
        #expect(included?.first?["id"] as? String == "${price-0}")
    }

    @Test func missingComplianceIsAnsweredAndBuildsJoinGroupsThroughReviews() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "testflight.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let builds = try await session.testFlightBuilds(appId: app, client: client)
        #expect(builds.map(\.title) == ["Build 7 · iOS 2.0"] && builds[0].missingCompliance)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7")
        request.testflightAction = "set-encryption-use"; request.usesNonExemptEncryption = false
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.before) == ["No answer at Apple"] && review.steps.map(\.after) == ["Uses non-exempt encryption: No"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.missingCompliance == false)

        let groups = try await session.testFlightGroups(appId: app, client: client)
        #expect(groups.map(\.name) == ["Synthetic testers"])
        var assign = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); assign.testflightAction = "add-build"; assign.groupId = "group-1"
        let assignment = try await session.preparePublishing(account: account, request: assign, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: assignment.id, fingerprint: assignment.fingerprint, client: client).state == "complete")
        let members = try await session.groupMembers(appId: app, groupId: "group-1", client: client)
        #expect(members.builds == ["build-7"] && members.testers.map(\.email) == ["tester@example.com"])
        let again = try await session.preparePublishing(account: account, request: assign, client: client)
        #expect(again.steps.isEmpty)
    }

    @Test func appReviewInformationIsPublishedWithItsAttachment() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        var fields = ReviewInformation()
        fields.contactFirstName = " Synthetic "; fields.contactLastName = "Reviewer"; fields.contactPhone = "+1 555 0100"; fields.contactEmail = "review@example.com"; fields.notes = "Synthetic notes"
        let pdf = Data("%PDF-1.4 synthetic".utf8)
        let saved = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: ("guide.pdf", pdf), keepAttachment: false, expectedRevision: 0)
        #expect(saved.revision == 1 && saved.fields.contactFirstName == "Synthetic" && saved.attachment?.fileName == "guide.pdf")
        await #expect(throws: PublishFailure.self) { try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: nil, keepAttachment: true, expectedRevision: 0) }

        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"), client: client)
        #expect(review.steps.map(\.label) == ["Add App Review Information", "Attach guide.pdf for App Review", "Upload guide.pdf", "Complete guide.pdf", "Verify guide.pdf"])
        #expect(review.steps[0].after?.contains("Demo account required: No") == true)
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == pdf)
        let created = apple.writes.first { $0.1 == "/v1/appStoreReviewDetails" }?.2?["data"] as? [String: Any]
        #expect((created?["attributes"] as? [String: Any])?["contactFirstName"] as? String == "Synthetic")
    }

    @Test func appInformationAndRegionsAreChangedWithTheirGuards() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "info.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let state = try await session.appInformationState(appId: app, client: client)
        #expect(state.contentRights == nil && (state.categories?["primaryCategory"] ?? nil) == "GAMES" && state.territories.map(\.id) == ["SWE", "USA"])

        var request = PublishRequest(accountId: account.id, appId: app, scope: .appInformation)
        request.contentRightsDeclaration = "DOES_NOT_USE_THIRD_PARTY_CONTENT"
        var selection = Dictionary(uniqueKeysWithValues: AppInformation.categoryFields.map { ($0, String?.none) }); selection["primaryCategory"] = "PRODUCTIVITY"
        request.categorySelection = selection
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Update content rights declaration", "Update App Store categories"] && review.steps[1].after == "Primary category: Productivity")
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(apple.primary == "PRODUCTIVITY" && apple.rights as? String == "DOES_NOT_USE_THIRD_PARTY_CONTENT")

        var region = PublishRequest(accountId: account.id, appId: app, scope: .availability); region.territoryId = "SWE"; region.territoryAvailable = false
        let regionReview = try await session.preparePublishing(account: account, request: region, client: client)
        #expect(regionReview.steps.map(\.after) == ["Not selected for distribution"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: regionReview.id, fingerprint: regionReview.fingerprint, client: client).state == "complete")
        #expect(!apple.sweden)
        var bad = PublishRequest(accountId: account.id, appId: app, scope: .appInformation)
        var invalid = selection; invalid["primaryCategory"] = nil; bad.categorySelection = invalid
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: bad, client: client) }
    }

    @Test func ageRatingAnswersAreChangedOnlyWhereTheyDiffer() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "age.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        #expect(try await session.ageRatingAnswers(appId: app, client: client)["advertising"] == .bool(false))
        var request = PublishRequest(accountId: account.id, appId: app, scope: .ageRating)
        request.ageRatingChanges = [("violenceCartoonOrFantasy", .string("INFREQUENT")), ("advertising", .bool(false))]
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.after) == ["Cartoon or fantasy violence: infrequent"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(apple.ageAnswers["violenceCartoonOrFantasy"] as? String == "INFREQUENT")
        var invalid = PublishRequest(accountId: account.id, appId: app, scope: .ageRating); invalid.ageRatingChanges = [("violenceRealistic", .string("SOMETIMES"))]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: invalid, client: client) }
    }

    @Test func accessibilityDraftsAreCreatedThenPublished() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "access.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var save = PublishRequest(accountId: account.id, appId: app, scope: .accessibility)
        save.accessibilityAction = "save-draft"; save.accessibilityFamily = "MAC"
        save.accessibilityAnswers = AccessibilityDeclarations.applicable("MAC").map { ($0.key, $0.key == "supportsVoiceover") }
        let draft = try await session.preparePublishing(account: account, request: save, client: client)
        #expect(draft.steps.map(\.label) == ["Create accessibility draft"] && draft.steps[0].after?.contains("Larger Text") == false)
        #expect(try await session.approvePublishing(account: account, appId: app, id: draft.id, fingerprint: draft.fingerprint, client: client).state == "complete")
        var publish = PublishRequest(accountId: account.id, appId: app, scope: .accessibility); publish.accessibilityAction = "publish-draft"; publish.accessibilityFamily = "MAC"
        let review = try await session.preparePublishing(account: account, request: publish, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.accessibilityDeclarations(appId: app, client: client).first?.state == "PUBLISHED")
        var incomplete = save; incomplete.accessibilityAnswers = [("supportsVoiceover", true)]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: incomplete, client: client) }
    }

    @Test func exportComplianceDeclarationsAndDocumentsAreSentOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "export.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let client = try client(account, host: host)
        var answers = EncryptionAnswers(); answers.appDescription = " Uses standard HTTPS only. "; answers.containsThirdPartyCryptography = true; answers.availableOnFrenchStore = true
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance); request.encryptionDeclaration = answers
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.first?.after?.hasPrefix("App description: Uses standard HTTPS only.") == true)
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.isEmpty)

        let pdf = Data("%PDF-1.7 synthetic declaration".utf8)
        await #expect(throws: PublishFailure.self) { try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: "decl-1", expectedRevision: 0, fileName: "not.pdf", data: Data("plain".utf8)) }
        let staged = try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: "decl-1", expectedRevision: 0, fileName: "Declaration.pdf", data: pdf)
        var document = PublishRequest(accountId: account.id, appId: app, scope: .exportDocument); document.declarationId = "decl-1"; document.documentRevision = staged.revision
        let upload = try await session.preparePublishing(account: account, request: document, client: client)
        #expect(upload.steps.map(\.label) == ["Reserve Declaration.pdf at Apple", "Upload Declaration.pdf", "Complete Declaration.pdf", "Verify Declaration.pdf"])
        let done = try await session.approvePublishing(account: account, appId: app, id: upload.id, fingerprint: upload.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == pdf)
    }

    @Test func testFlightGroupsTestersAndInformationAreChangedThroughReviews() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "testflight-actions.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        func publish(_ configure: (inout PublishRequest) -> Void, build: String? = nil) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: build); configure(&request)
            let review = try await session.preparePublishing(account: account, request: request, client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        var mixed = PublishRequest(accountId: account.id, appId: app, scope: .testflight); mixed.testflightAction = "create-group"; mixed.groupName = "Beta"; mixed.agreementText = "Terms"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: mixed, client: client) }

        #expect(try await publish { $0.testflightAction = "create-group"; $0.groupName = "External beta"; $0.internalGroup = false }.state == "complete")
        let external = try #require(apple.groups.last?["id"] as? String)
        #expect(try await publish { $0.testflightAction = "rename-group"; $0.groupId = external; $0.groupName = "Public beta" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "set-group-setting"; $0.groupId = external; $0.groupSetting = "public-link-limit"; $0.groupSettingValue = .number(500) }.state == "complete")
        #expect((apple.groups.last?["attributes"] as? [String: Any])?["name"] as? String == "Public beta" && (apple.groups.last?["attributes"] as? [String: Any])?["publicLinkLimit"] as? Int == 500)

        #expect(try await publish { $0.testflightAction = "invite-tester"; $0.groupId = external; $0.testerEmail = "new.tester@example.com" }.state == "complete")
        let invited = try #require(apple.testers.last?["id"] as? String)
        #expect(apple.groupTesters[external] == [invited])
        #expect(try await publish { $0.testflightAction = "add-tester"; $0.groupId = external; $0.testerId = "tester-1" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "send-invitation"; $0.testerId = invited }.state == "complete")
        var installed = PublishRequest(accountId: account.id, appId: app, scope: .testflight); installed.testflightAction = "send-invitation"; installed.testerId = "tester-1"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: installed, client: client) }

        #expect(try await publish({ $0.testflightAction = "save-build-notes"; $0.locale = "en-US"; $0.whatsNew = "Try the synthetic flow." }, build: "build-7").state == "complete")
        #expect(try await publish({ $0.testflightAction = "save-build-notes"; $0.locale = "en-US"; $0.whatsNew = "Try the second synthetic flow." }, build: "build-7").state == "complete")
        #expect((apple.betaBuildLocales[0]["attributes"] as? [String: Any])?["whatsNew"] as? String == "Try the second synthetic flow.")
        #expect(try await publish { $0.testflightAction = "save-beta-info"; $0.locale = "en-US"; $0.betaDescription = "A synthetic app."; $0.feedbackEmail = "feedback@example.com" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "save-beta-license"; $0.agreementText = "Updated synthetic terms." }.state == "complete")
        #expect(apple.license == "Updated synthetic terms.")
        #expect(try await publish({ $0.testflightAction = "set-encryption-use"; $0.usesNonExemptEncryption = false }, build: "build-7").state == "complete")
        apple.lock.withLock { apple.betaExternalState = "READY_FOR_BETA_SUBMISSION" }
        #expect(try await publish({ $0.testflightAction = "submit-beta-review" }, build: "build-7").state == "complete")
        apple.lock.withLock { apple.betaExternalState = "READY_FOR_BETA_TESTING" }
        #expect(try await publish({ $0.testflightAction = "notify-build-testers" }, build: "build-7").state == "complete")
        var resubmit = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); resubmit.testflightAction = "submit-beta-review"
        #expect(try await session.preparePublishing(account: account, request: resubmit, client: client).steps.isEmpty)

        var rename = PublishRequest(accountId: account.id, appId: app, scope: .testflight); rename.testflightAction = "rename-group"; rename.groupId = external; rename.groupName = "Renamed"
        let stale = try await session.preparePublishing(account: account, request: rename, client: client)
        apple.lock.withLock { var attributes = apple.groups.last!["attributes"] as! [String: Any]; attributes["name"] = "Changed elsewhere"; apple.groups[apple.groups.count - 1]["attributes"] = attributes }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(try await session.publishReview(accountId: account.id, appId: app, id: stale.id).state == "conflict")
        #expect(apple.writes.count == writes)

        #expect(try await publish { $0.testflightAction = "remove-tester"; $0.groupId = external; $0.testerId = "tester-1" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "remove-app-tester"; $0.testerId = invited }.state == "complete")
        #expect(try await publish { $0.testflightAction = "delete-group"; $0.groupId = external }.state == "complete")
        #expect(apple.groups.map { $0["id"] as! String } == ["group-1"] && apple.testers.map { $0["id"] as! String } == ["tester-1"])
    }

    @Test func inAppPurchaseAndSubscriptionPricesArePublishedWithTheirSchedules() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "product-prices.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let catalog = try await session.priceProducts(appId: app, client: client)
        #expect(catalog.purchases?.map(\.name) == ["Coins"] && catalog.subscriptions?.map(\.group) == ["Premium"])
        let tomorrow = ReportTables.dayFormat.string(from: Date().addingTimeInterval(86_400))
        func publish(_ configure: (inout PublishRequest) -> Void) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .productPricing); configure(&request)
            let review = try await session.preparePublishing(account: account, request: request, client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        var both = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        both.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: nil)
        both.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-599", startDate: tomorrow, planType: nil, preserveCurrentPrice: true)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: both, client: client) }
        var dated = PublishRequest(accountId: account.id, appId: app, scope: .productPricing); dated.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: tomorrow)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: dated, client: client) }

        #expect(try await publish { $0.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: nil) }.state == "complete")
        let first = try await session.productPriceSchedule(appId: app, productId: "iap-1", client: client)
        #expect(first.schedule.baseTerritory == "USA" && first.schedule.rows.map(\.customerPrice) == ["0.99"])
        #expect(try await publish { $0.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-199", startDate: tomorrow) }.state == "complete")
        let scheduled = try await session.productPriceSchedule(appId: app, productId: "iap-1", client: client)
        #expect(scheduled.schedule.rows.map(\.customerPrice) == ["0.99", "1.99"])
        let phases = ProductPricing.phases(scheduled.schedule.rows, today: ReportTables.dayFormat.string(from: Date()))
        #expect(scheduled.schedule.rows.map { phases[$0.key] } == [.current, .future])

        // Prices per country or region join the same reviewed schedule; a price point from another country is refused before any write.
        let later2 = ReportTables.dayFormat.string(from: Date().addingTimeInterval(3 * 86_400))
        var byCountry = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        byCountry.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: later2, territoryPoints: ["SWE": "iap-pp-swe-10"])
        let countryReview = try await session.preparePublishing(account: account, request: byCountry, client: client)
        var included: [JSONText] = []
        if case .array(let items)? = countryReview.steps.first?.body?["included"] { included = items }
        #expect(included.contains { $0["id"]?.text == "new-price-SWE" && $0["relationships"]?["inAppPurchasePricePoint"]?["data"]?["id"]?.text == "iap-pp-swe-10" })
        var foreign = byCountry; foreign.purchasePrice?.territoryPoints = ["SWE": "iap-pp-usa-199"]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: foreign, client: client) }

        #expect(try await publish { $0.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-599", startDate: tomorrow, planType: nil, preserveCurrentPrice: true) }.state == "complete")
        #expect(apple.subscriptionPrices.count == 2)

        var later = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        later.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-499", startDate: ReportTables.dayFormat.string(from: Date().addingTimeInterval(2 * 86_400)), planType: nil, preserveCurrentPrice: false)
        let stale = try await session.preparePublishing(account: account, request: later, client: client)
        apple.lock.withLock { apple.subscriptionPrices.removeLast() }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.count == writes)
    }
    @Test func listingReviewIncludesOnlyItsSelectedLanguage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "language-scope.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        _ = try await session.addLanguage(accountId: account.id, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        apple.appInfoName = "Synthetic remote name"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, targetMode: "apple-version", revisionId: revision, versionId: "version-1")
        request.mediaStage = PublishRequest.textStage; request.listingLocale = "en-US"
        #expect(try PublishRequest(request.json)?.validated() == request)
        let english = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(!english.steps.isEmpty && english.steps.allSatisfy { $0.label.contains("en-US") })
        #expect(english.request.listingLocale == "en-US" && apple.writes.isEmpty)
        request.listingLocale = "sv"
        let swedish = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(!swedish.steps.isEmpty && swedish.steps.allSatisfy { $0.label.contains("sv") })
        #expect(apple.writes.isEmpty)
        request.listingLocale = "unsupported"
        #expect(throws: PublishFailure.self) { try request.validated() }
        request.listingLocale = "de-DE"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
    }

}
