import Foundation

extension WorkspaceSession {
    func planBuildDelivery(_ planner: Planner) async throws -> String {
        let request = planner.request, appId = request.appId
        let uploads = try await appBuildUploads(appId: appId, client: planner.client, planner: planner)
        if request.testflightAction != "upload-build" {
            guard let upload = uploads.first(where: { $0.id == request.buildUploadId }), try BuildDelivery.removable(upload, failedOnly: request.testflightAction == "delete-failed-upload") else { throw PublishFailure.invalid("Choose a pending or failed, unlinked build upload belonging to this app.") }
            let summary = try BuildDelivery.summary(upload), failed = try BuildDelivery.state(upload)?["state"]?.string == "FAILED"
            planner.add(.api, method: "DELETE", path: [.string("buildUploads"), .string(upload.id)], label: failed ? "Delete failed build upload" : "Cancel pending build upload",
                        detail: "\(summary.platform) \(summary.version) · build \(summary.buildNumber) · upload \(upload.id)", before: failed ? "Failed delivery record at Apple" : "Awaiting file upload at Apple", after: "Delivery record removed",
                        guard: .object([("kind", .string("build-upload-state")), ("digest", .string(try BuildDelivery.removableDigest(upload)))]))
            return "\(failed ? "Delete failed" : "Cancel pending") build upload · \(summary.version) (\(summary.buildNumber))"
        }
        guard let version = request.buildVersion, let number = request.buildNumber, let platform = request.buildPlatform,
              let package = try stagedBuildPackage(accountId: request.accountId, appId: appId, id: request.packageId) else { throw PublishFailure.invalid("Choose a staged build package for this app.") }
        let digest = try BuildDelivery.digest(appId: appId, version: version, number: number, platform: platform, package: package)
        let media = try packageMedia(package.id)
        let validation = Task.detached { try media.stream(package.sha256) { _ in } }
        try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
        planner.evidence.append(.object([("buildPackage", package.json)]))
        let matching = try uploads.filter { try $0.attributes?["cfBundleShortVersionString"]?.string == version && $0.attributes?["cfBundleVersion"]?.string == number && $0.attributes?["platform"]?.string == platform && BuildDelivery.state($0)?["state"]?.string != "FAILED" }
        guard matching.count <= 1, try matching.allSatisfy({ try BuildDelivery.state($0)?["state"]?.string == "AWAITING_UPLOAD" && BuildDelivery.removable($0) }) else { throw PublishFailure.invalid("Apple already has a delivery for this platform, version and build number. Check Build delivery before uploading again.") }
        let existing = matching.first
        var file: AppStoreConnectClient.Resource?
        if let existing, let linked = try Self.reservedFile(existing) {
            let values = try await planner.get(Self.apiPath([.string("buildUploadFiles"), .string(linked)], ids: [:]))
            guard values.count == 1, let saved = values.first, saved.type == "buildUploadFiles", saved.id == linked,
                  saved.attributes?["assetType"]?.string == "ASSET", saved.attributes?["fileName"]?.string == package.fileName,
                  saved.attributes?["fileSize"] == .number(Double(package.size)), saved.attributes?["uti"]?.string == package.uti else { throw PublishFailure.invalid("Apple's pending build file does not match the staged package.") }
            if let checksums = saved.attributes?["sourceFileChecksums"] {
                let value = try JSONText.parse(JSONEncoder().encode(checksums))
                guard value["file"]?["algorithm"]?.text == "SHA_256", value["file"]?["hash"]?.text == package.sha256 else { throw PublishFailure.invalid("Apple's pending build checksum does not match the staged package.") }
            }
            file = saved
        }
        if let existing { try Self.checkReservedFiles(existing, fileId: file?.id) }
        let label = "\(platform) \(version) · build \(number)"
        let uploadId = existing.map { JSONText.string($0.id) } ?? Apple.ref(planner.add(.api, method: "POST", path: [.string("buildUploads")], label: "Create build delivery", detail: label,
            before: "No active delivery for this build", after: "Build upload reserved at Apple", body: .object([("data", .object([("type", .string("buildUploads")), ("attributes", .object([("cfBundleShortVersionString", .string(version)), ("cfBundleVersion", .string(number)), ("platform", .string(platform))])), ("relationships", .object([("app", Apple.relationship("apps", .string(appId)))]))]))])))
        var reservationGuard: [(String, JSONText)] = [("kind", .string("build-upload-reservation")), ("digest", .string(digest)), ("checksum", .string(package.sha256))]
        if let existing { reservationGuard.append(("uploadId", .string(existing.id))) }
        let fileId = file.map { JSONText.string($0.id) } ?? Apple.ref(planner.add(.api, method: "POST", path: [.string("buildUploadFiles")], label: "Reserve build binary", detail: "\(package.fileName) · \(package.size) bytes",
            before: "No file reservation", after: "Exact file size and format reserved at Apple", body: .object([("data", .object([("type", .string("buildUploadFiles")), ("attributes", .object([("assetType", .string("ASSET")), ("fileName", .string(package.fileName)), ("fileSize", .number(Double(package.size))), ("uti", .string(package.uti))])), ("relationships", .object([("buildUpload", Apple.relationship("buildUploads", uploadId))]))]))]), guard: .object(reservationGuard)))
        let asset = JSONText.object([("storage", .string("build-package")), ("packageId", .string(package.id)), ("hash", .string(package.sha256)), ("checksum", .string(package.sha256)), ("size", .number(Double(package.size))), ("fileName", .string(package.fileName)), ("extension", .string(package.uti == "com.apple.ipa" ? "ipa" : "pkg")), ("deliveryDigest", .string(digest))])
        planner.add(.upload, path: [.string("buildUploadFiles"), fileId], label: file == nil ? "Upload build binary" : "Resume build binary upload", detail: "\(package.fileName) · SHA-256 \(package.sha256)", before: "Stored privately in Storebench", after: "Encrypted source streamed to Apple's signed file endpoints", asset: asset)
        var commitGuard: [(String, JSONText)] = [("kind", .string("build-upload-commit")), ("digest", .string(digest))]
        if let existing { commitGuard.append(("uploadId", .string(existing.id))) }; if let file { commitGuard.append(("fileId", .string(file.id))) }
        planner.add(.api, method: "PATCH", path: [.string("buildUploadFiles"), fileId], label: "Finish build delivery", detail: "\(label) · SHA-256 \(package.sha256)", before: "Binary parts uploaded", after: "Apple starts asynchronous build processing",
                    body: .object([("data", .object([("type", .string("buildUploadFiles")), ("id", fileId), ("attributes", .object([("uploaded", .bool(true)), ("sourceFileChecksums", .object([("file", .object([("algorithm", .string("SHA_256")), ("hash", .string(package.sha256))]))]))]))]))]), guard: .object(commitGuard))
        if let existing { planner.notes.append("This review resumes Apple delivery \(existing.id). It uploads the entire staged file again before committing it.") }
        planner.notes += ["Check the version, build number, platform and SHA-256 digest against the signed package. Apple validates the package after delivery; processing may take time.", "This approval sends the staged binary to Apple. It does not submit the build for beta review or App Review."]
        return "Upload build · \(label)"
    }

    static func reservedFile(_ upload: AppStoreConnectClient.Resource) throws -> String? {
        guard let value = upload.relationships?["assetFile"] else { return nil }
        guard case .object(let relation) = value else { throw PublishFailure.invalid("Apple returned an unsupported build file reservation.") }
        guard let data = relation["data"], data != .null else { return nil }
        guard case .object(let item) = data, item["type"]?.string == "buildUploadFiles", let id = item["id"]?.string, !id.isEmpty, id.utf8.count <= 512 else { throw PublishFailure.invalid("Apple returned an unsupported build file reservation.") }
        return id
    }
    static func checkReservedFiles(_ upload: AppStoreConnectClient.Resource, fileId: String?) throws {
        guard let relation = upload.relationships?["buildUploadFiles"] else { return }
        guard case .object(let fields) = relation else { throw PublishFailure.write("Apple returned unexpected build file reservations.") }
        guard let value = fields["data"], value != .null else { return }
        guard case .array(let files) = value, files.allSatisfy({ if case .object(let item) = $0 { return item["type"]?.string == "buildUploadFiles" && item["id"]?.string == fileId && fileId != nil }; return false }) else { throw PublishFailure.write("Apple has other reserved files for this delivery.") }
    }
    func ownedBuildUploadFile(_ id: String, appId: String, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource {
        let uploads = try await appBuildUploads(appId: appId, client: client).filter { Apple.owned($0, "assetFile", "buildUploadFiles", id) }
        guard uploads.count == 1, let upload = uploads.first, try BuildDelivery.state(upload)?["state"]?.string == "AWAITING_UPLOAD", try BuildDelivery.removable(upload) else { throw PublishFailure.write("Build upload is no longer awaiting this file.") }
        try Self.checkReservedFiles(upload, fileId: id)
        let files = try await client.get(Self.apiPath([.string("buildUploadFiles"), .string(id)], ids: [:]))
        guard files.count == 1, let file = files.first, file.type == "buildUploadFiles", file.id == id, file.attributes?["assetType"]?.string == "ASSET",
              Apple.owner(file, "buildUpload").map({ $0 == ("buildUploads", upload.id) }) ?? true else { throw PublishFailure.write("Build file reservation belongs to another delivery.") }
        return file
    }

    func verifyBuildPackageUpload(_ asset: JSONText, file: AppStoreConnectClient.Resource, appId: String, client: AppStoreConnectClient) async throws {
        let uploads = try await appBuildUploads(appId: appId, client: client), fields = Planner.resource(file)["attributes"]
        guard let upload = uploads.first(where: { Apple.owned($0, "assetFile", "buildUploadFiles", file.id) }), try BuildDelivery.removable(upload),
              try BuildDelivery.state(upload)?["state"]?.string == "AWAITING_UPLOAD", file.attributes?["uploaded"] != .bool(true),
              fields?["fileName"] == asset["fileName"], fields?["fileSize"] == asset["size"],
              fields?["uti"]?.text == (asset["extension"]?.text == "pkg" ? "com.apple.pkg" : "com.apple.ipa"),
              fields?["sourceFileChecksums"] == nil || fields?["sourceFileChecksums"]?["file"]?["algorithm"]?.text == "SHA_256" && fields?["sourceFileChecksums"]?["file"]?["hash"] == asset["hash"],
              let version = upload.attributes?["cfBundleShortVersionString"]?.string, let number = upload.attributes?["cfBundleVersion"]?.string, let platform = upload.attributes?["platform"]?.string,
              let name = asset["fileName"]?.text, case .number(let size)? = asset["size"], size.isFinite, size >= 4, size <= Double(StagedBuildPackage.maximumBytes), size.rounded() == size,
              let checksum = asset["hash"]?.text, let uti = fields?["uti"]?.text,
              try BuildDelivery.digest(appId: appId, version: version, number: number, platform: platform, fileName: name, fileSize: Int(size), uti: uti, checksum: checksum) == asset["deliveryDigest"]?.text else { throw PublishFailure.write("Apple's build file reservation changed after approval.") }
        try Self.checkReservedFiles(upload, fileId: file.id)
    }

    func verifyBuildUploadWrite(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        let uploads = try await appBuildUploads(appId: appId, client: client)
        func keys(_ value: JSONText?, _ allowed: Set<String>) -> Bool { if case .object(let pairs)? = value { return Set(pairs.map(\.0)) == allowed && pairs.count == allowed.count }; return false }
        let data = body?["data"], attributes = data?["attributes"]
        func awaiting(_ upload: AppStoreConnectClient.Resource) throws -> Bool { try BuildDelivery.state(upload)?["state"]?.string == "AWAITING_UPLOAD" && BuildDelivery.removable(upload) }
        func digest(_ upload: AppStoreConnectClient.Resource, _ file: JSONText?, checksum: String) throws -> String {
            guard let version = upload.attributes?["cfBundleShortVersionString"]?.string, let number = upload.attributes?["cfBundleVersion"]?.string, let platform = upload.attributes?["platform"]?.string,
                  let name = file?["fileName"]?.text, case .number(let size)? = file?["fileSize"], size.isFinite, size >= 4, size <= Double(StagedBuildPackage.maximumBytes), size.rounded() == size, let uti = file?["uti"]?.text else { throw PublishFailure.write("Build file reservation changed after review.") }
            return try BuildDelivery.digest(appId: appId, version: version, number: number, platform: platform, fileName: name, fileSize: Int(size), uti: uti, checksum: checksum)
        }
        switch (parts.first, parts.count, method) {
        case ("buildUploads", 1, "POST"):
            guard keys(body, ["data"]), keys(data, ["type", "attributes", "relationships"]), data?["type"]?.text == "buildUploads", keys(attributes, ["cfBundleShortVersionString", "cfBundleVersion", "platform"]), keys(data?["relationships"], ["app"]),
                  data?["relationships"]?["app"] == Apple.relationship("apps", .string(appId)), let version = attributes?["cfBundleShortVersionString"]?.text, let number = attributes?["cfBundleVersion"]?.text, let platform = attributes?["platform"]?.text,
                  [version, number].allSatisfy({ $0.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil }), ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform) else { throw PublishFailure.write("Unsupported build upload creation.") }
            guard try !uploads.contains(where: { try $0.attributes?["cfBundleShortVersionString"]?.string == version && $0.attributes?["cfBundleVersion"]?.string == number && $0.attributes?["platform"]?.string == platform && BuildDelivery.state($0)?["state"]?.string != "FAILED" }) else { throw PublishFailure.write("Apple already has a delivery for this build.") }
        case ("buildUploads", 2, "DELETE"):
            guard body == nil, let upload = uploads.first(where: { $0.id == parts[1] }), guardValue?["kind"]?.text == "build-upload-state", try BuildDelivery.removableDigest(upload) == guardValue?["digest"]?.text else { throw PublishFailure.write("Build upload changed after review or belongs to another app.") }
        case ("buildUploadFiles", 1, "POST"):
            guard keys(body, ["data"]), keys(data, ["type", "attributes", "relationships"]), data?["type"]?.text == "buildUploadFiles", keys(attributes, ["assetType", "fileName", "fileSize", "uti"]), attributes?["assetType"]?.text == "ASSET",
                  keys(data?["relationships"], ["buildUpload"]), let parent = data?["relationships"]?["buildUpload"]?["data"]?["id"]?.text, data?["relationships"]?["buildUpload"] == Apple.relationship("buildUploads", .string(parent)),
                  let upload = uploads.first(where: { $0.id == parent }), try awaiting(upload), try Self.reservedFile(upload) == nil,
                  guardValue?["kind"]?.text == "build-upload-reservation", guardValue?["uploadId"] == nil || guardValue?["uploadId"]?.text == parent, let checksum = guardValue?["checksum"]?.text,
                  try digest(upload, attributes, checksum: checksum) == guardValue?["digest"]?.text else { throw PublishFailure.write("Build file reservation approval could not be confirmed.") }
            try Self.checkReservedFiles(upload, fileId: nil)
        case ("buildUploadFiles", 2, "PATCH"):
            guard keys(body, ["data"]), keys(data, ["type", "id", "attributes"]), data?["type"]?.text == "buildUploadFiles", data?["id"]?.text == parts[1], keys(attributes, ["uploaded", "sourceFileChecksums"]), attributes?["uploaded"] == .bool(true),
                  keys(attributes?["sourceFileChecksums"], ["file"]), keys(attributes?["sourceFileChecksums"]?["file"], ["algorithm", "hash"]), attributes?["sourceFileChecksums"]?["file"]?["algorithm"]?.text == "SHA_256", let hash = attributes?["sourceFileChecksums"]?["file"]?["hash"]?.text,
                  guardValue?["kind"]?.text == "build-upload-commit", guardValue?["fileId"] == nil || guardValue?["fileId"]?.text == parts[1], let upload = uploads.first(where: { Apple.owned($0, "assetFile", "buildUploadFiles", parts[1]) }),
                  guardValue?["uploadId"] == nil || guardValue?["uploadId"]?.text == upload.id else { throw PublishFailure.write("Unsupported build file commit.") }
            let file = try await ownedBuildUploadFile(parts[1], appId: appId, client: client), fields = Planner.resource(file)["attributes"]
            guard file.attributes?["uploaded"] != .bool(true), fields?["sourceFileChecksums"] == nil || fields?["sourceFileChecksums"]?["file"]?["algorithm"]?.text == "SHA_256" && fields?["sourceFileChecksums"]?["file"]?["hash"]?.text == hash,
                  try digest(upload, fields, checksum: hash) == guardValue?["digest"]?.text else { throw PublishFailure.write("Build delivery changed after review. Prepare a new review.") }
        default: throw PublishFailure.write("Unsupported build upload change.")
        }
    }
}
