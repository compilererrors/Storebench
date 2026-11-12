import Foundation
import StorebenchCore

/// A small stateful App Store Connect double for publishing tests: synthetic resources only.
package final class SyntheticApple: @unchecked Sendable {
    package init() { precondition((try? TestIsolation.require()) != nil) }
    package let lock = NSLock()
    package func setVersionState(_ state: String) {
        lock.lock(); defer { lock.unlock() }
        var attributes = versions[0]["attributes"] as! [String: Any]
        attributes["appVersionState"] = state; versions[0]["attributes"] = attributes
    }
    package var versions: [[String: Any]] = [["type": "appStoreVersions", "id": "version-1", "attributes": ["platform": "IOS", "versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    package var locales: [[String: Any]] = [["type": "appStoreVersionLocalizations", "id": "version-locale-1", "attributes": ["locale": "en-US", "description": "Second synthetic description", "keywords": "sample,test"], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]]]
    package var sets: [[String: Any]] = [["type": "appScreenshotSets", "id": "set-1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"], "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "version-locale-1"]]]]]
    package var shots: [[String: Any]] = [["type": "appScreenshots", "id": "shot-1", "attributes": ["fileName": "sample.png", "assetDeliveryState": ["state": "COMPLETE"]], "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": "set-1"]]]]]
    /// The App Asset Library: the imported synthetic screenshot placed on the version, plus Apple's catalog for one iPhone group.
    package var library = true
    /// Apple documents upload operations on the reservation response; a later read need not repeat them.
    package var readsOmitUploadOperations = false
    /// Apple keeps a committed file in processing, and reading it then fails, so a review stops at its verification.
    package var processingAfterCommit = false, failProcessingReads = false, finishProcessingOnRead = false
    /// Apple can leave the version link out of a read of one language.
    package var localeReadsOmitOwner = false
    /// Apple adds the next file to the version but its answer is lost, as with a dropped connection.
    package var losePlacementAnswers = 0
    package var libraryImages: [[String: Any]] = [["type": "appAssetLibraryImages", "id": "image-1", "attributes": ["fileName": "sample.png", "fileSize": 1000, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
        "imageAsset": ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/synthetic/{w}x{h}bb.{f}", "width": 1290, "height": 2796]], "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]]]
    package var placements: [[String: Any]] = [["type": "appAssetLibraryPlacements", "id": "shot-1", "attributes": ["mediaType": "IMAGE", "placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_SYNTHETIC_PROFILE", "state": "PARENT_PREPARE_FOR_SUBMISSION"],
        "relationships": ["image": ["data": ["type": "appAssetLibraryImages", "id": "image-1"]], "appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "version-locale-1"]]]]]
    package nonisolated(unsafe) static let catalog: [String: Any] = ["type": "appAssetLibraryRefData", "id": "catalog-synthetic", "attributes": [
        "features": [["featureId": "APP_STORE_VERSIONS", "placementPolicies": [["placementType": "APP_SCREENSHOT", "groupLimits": [["groupIds": ["IPHONE_SYNTHETIC_PROFILE"], "maxCount": 10]]]]]],
        "placementProfileGroups": [["placementProfileGroupId": "IPHONE_SYNTHETIC_PROFILE", "platform": "IPHONE_APP_STORE", "displayClassId": "SYNTHETIC_DISPLAY"]],
        "imageSpecs": [["specId": "spec-iphone", "shortName": "i1290x2796", "dimensions": ["minWidth": 1290, "maxWidth": 1290, "minHeight": 2796, "maxHeight": 2796], "fileExtensions": [".png", ".jpg"], "maxFileSize": 52428800, "alphaAllowed": false]],
        "videoSpecs": [], "displayClasses": [],
        "placementTypes": [["placementTypeId": "APP_SCREENSHOT", "acceptsAssetCategories": ["APP_SCREENSHOTS_AND_PREVIEWS"], "specMappings": [["placementGroupId": "IPHONE_SYNTHETIC_PROFILE", "specs": ["spec-iphone"]]]]]]]
    package var builds: [[String: Any]] = [["type": "builds", "id": "build-7", "attributes": ["version": "7", "processingState": "VALID", "expired": false, "uploadedDate": "2026-03-01T10:00:00Z", "buildAudienceType": "APP_STORE_ELIGIBLE"],
                                    "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]], "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": "pre-1"]], "buildBetaDetail": ["data": ["type": "buildBetaDetails", "id": "detail-7"]]]]]
    package var groupBuilds: [String] = []
    /// Apple's app name for the imported language; the synthetic import has "Sample App Updated".
    package var appInfoName = "Sample App Updated"
    package var groups: [[String: Any]] = [["type": "betaGroups", "id": "group-1", "attributes": ["name": "Synthetic testers", "isInternalGroup": true], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    package var testers: [[String: Any]] = [["type": "betaTesters", "id": "tester-1", "attributes": ["email": "tester@example.com", "firstName": "Synthetic", "lastName": "Tester", "state": "INSTALLED"]]]
    package var groupTesters: [String: [String]] = ["group-1": ["tester-1"]]
    package var directTesters: [String] = []
    package var betaExternalState = "READY_FOR_BETA_TESTING"
    package var automaticNotification = false
    package var license = "Synthetic beta terms."
    package var betaAppLocales: [[String: Any]] = []
    package var betaBuildLocales: [[String: Any]] = []
    package var betaSubmissions: [[String: Any]] = []
    package var betaReviewDetails: [[String: Any]] = [["type": "betaAppReviewDetails", "id": "beta-detail-synthetic", "attributes": ["contactFirstName": "Synthetic", "contactLastName": "Reviewer", "contactPhone": "0000000000", "contactEmail": "review@example.com", "demoAccountRequired": false], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
    package var iapManual: [[String: Any]] = []
    package var subscriptionPrices: [[String: Any]] = [["type": "subscriptionPrices", "id": "sub-price-1", "attributes": ["startDate": NSNull(), "preserved": false],
                                                "relationships": ["subscriptionPricePoint": ["data": ["type": "subscriptionPricePoints", "id": "sub-pp-usa-499"]], "territory": ["data": ["type": "territories", "id": "USA"]]]]]
    package var reviewDetails: [[String: Any]] = []
    /// A resource read may omit its reverse owner while the version's scoped path still identifies it.
    package var reviewReadsOmitOwner = false
    package var reviewDirectResource: [String: Any]?
    package var rights: Any = NSNull()
    package var primary = "GAMES"
    package var sweden = true
    package var accessibility: [[String: Any]] = []
    package var declarations: [[String: Any]] = []
    package var documents: [[String: Any]] = []
    /// A complete declaration: Apple adds a version for review only when every Age Ratings question is answered.
    package var ageAnswers: [String: Any] = Dictionary(uniqueKeysWithValues: AgeRating.frequency.map { ($0.0, "NONE" as Any) } + AgeRating.boolean.map { ($0.0, false as Any) })
    package var attachments: [[String: Any]] = []
    package var writes: [(String, String, [String: Any]?)] = []
    package var uploaded = Data()
    package var counter = 0

    private func reviewRead(_ item: [String: Any]) -> [String: Any] {
        guard reviewReadsOmitOwner else { return item }
        var result = item; result["relationships"] = nil; return result
    }
    package func page(_ data: Any) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
    package func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }

    package func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
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
            case ("PATCH", "/v1/appStoreReviewDetails/detail-1"):
                var attributes = reviewDetails[0]["attributes"] as! [String: Any]
                for (key, value) in (data?["attributes"] as? [String: Any]) ?? [:] { attributes[key] = value }
                reviewDetails[0]["attributes"] = attributes
                return page(reviewDetails[0])
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
        case "/v1/appStoreVersions/version-1/appStoreReviewDetail": return reviewDetails.isEmpty ? (404, [:], Data()) : page(reviewRead(reviewDetails[0]))
        case "/v1/appStoreReviewDetails/detail-1": return reviewDirectResource.map(page) ?? (reviewDetails.isEmpty ? (404, [:], Data()) : page(reviewRead(reviewDetails[0])))
        case "/v1/appStoreReviewDetails/detail-1/appStoreReviewAttachments": return page(attachments.map(reviewRead))
        case "/v1/appStoreReviewAttachments/attachment-1": return attachments.isEmpty ? (404, [:], Data()) : page(reviewRead(attachments[0]))
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
