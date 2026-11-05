import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBuildApple: @unchecked Sendable {
    let lock = NSLock(), base = SyntheticApple()
    var uploads: [[String: Any]] = [], file: [String: Any]?
    var writes: [(String, String)] = [], received: [Data] = []
    var incompleteScope = false, failPart = false, unsafeOperation = false, wrongReservation = false
    let blobHost = "build-stream.blobstore.apple.com"
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if request.url?.host == blobHost {
            guard method == "PUT", request.value(forHTTPHeaderField: "Authorization") == nil, let stream = request.httpBodyStream else { return (400, [:], Data()) }
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 32768)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while stream.streamStatus != .atEnd, stream.streamStatus != .error, ContinuousClock.now < deadline {
                if !stream.hasBytesAvailable { Thread.sleep(forTimeInterval: 0.001); continue }
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { return (400, [:], Data()) }; if count == 0 { break }
                bytes.append(buffer, count: count)
                if bytes.count > 4 * 1024 * 1024 { return (413, [:], Data()) }
            }
            received.append(bytes)
            if failPart { failPart = false; return (503, [:], Data()) }
            return bytes.count == Int(request.value(forHTTPHeaderField: "Content-Length") ?? "") ? (200, [:], Data()) : (400, [:], Data())
        }
        if method == "GET" {
            switch path {
            case "/v1/apps/1000000001/buildUploads": return base.page(uploads)
            case "/v1/apps/1000000001/relationships/buildUploads": return base.page(incompleteScope ? [] : uploads.map { ["type": "buildUploads", "id": $0["id"]!] })
            case "/v1/buildUploadFiles/file-synthetic": return file.map { base.page($0) } ?? (404, [:], Data())
            default: return base.handle(request)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: base.body(request))) as? [String: Any], data = body?["data"] as? [String: Any]
        switch (method, path) {
        case ("POST", "/v1/buildUploads"):
            writes.append((method, path)); var created = data!
            created["id"] = "upload-synthetic"; var attributes = created["attributes"] as! [String: Any]; attributes["state"] = ["state": "AWAITING_UPLOAD"]; created["attributes"] = attributes
            uploads = [created]; return base.page(created)
        case ("POST", "/v1/buildUploadFiles"):
            writes.append((method, path)); var created = data!, attributes = created["attributes"] as! [String: Any]
            let size = attributes["fileSize"] as! Int
            if wrongReservation { attributes["fileName"] = "different-synthetic.ipa" }
            attributes["uploadOperations"] = [["method": "PUT", "url": "https://\(blobHost)/first", "offset": 0, "length": size, "requestHeaders": unsafeOperation ? [["name": "Authorization", "value": "synthetic-forbidden"]] : []]]
            created["id"] = "file-synthetic"; created["attributes"] = attributes; file = created
            var relationships = uploads[0]["relationships"] as! [String: Any]
            relationships["assetFile"] = ["data": ["type": "buildUploadFiles", "id": "file-synthetic"]]; uploads[0]["relationships"] = relationships
            return base.page(created)
        case ("PATCH", "/v1/buildUploadFiles/file-synthetic"):
            writes.append((method, path)); var attributes = file!["attributes"] as! [String: Any]
            for (key, value) in data!["attributes"] as! [String: Any] { attributes[key] = value }; file!["attributes"] = attributes
            var upload = uploads[0]["attributes"] as! [String: Any]; upload["state"] = ["state": "PROCESSING"]; uploads[0]["attributes"] = upload
            return base.page(file!)
        case ("DELETE", "/v1/buildUploads/upload-synthetic"):
            writes.append((method, path)); uploads = []; return (204, [:], Data())
        default: return (501, [:], Data())
        }
    }
}

@Suite(.serialized) struct BuildPackageTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func fixture(_ name: String) throws -> URL { try TestIsolation.require().appendingPathComponent("native-fixtures/\(name)") }
    func staged(_ session: WorkspaceSession, account: Account) async throws -> StagedBuildPackage {
        let source = try fixture("synthetic.ipa"), size = try Data(contentsOf: source).count
        return try await session.stageBuildPackage(accountId: account.id, appId: app, fileName: "synthetic.ipa", expectedSize: size, file: source)
    }
    func client(_ account: Account, _ apple: SyntheticBuildApple, host: String) throws -> AppStoreConnectClient {
        StubProtocol.handle(host) { apple.handle($0) }; StubProtocol.handle(apple.blobHost) { apple.handle($0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    func request(_ account: Account, _ package: StagedBuildPackage) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight)
        value.testflightAction = "upload-build"; value.packageId = package.id; value.buildVersion = "1.0"; value.buildNumber = "42"; value.buildPlatform = "IOS"
        return value
    }

    @Test func webBuildPackagesAndDeliveryVectorsMatchSwift() throws {
        let package = try StagedBuildPackage(JSONText.parse(Data(contentsOf: fixture("build-package.json"))))
        let media = try EncryptedMediaStore(directory: fixture("build-package-store/build-packages/\(package.id)"), key: Data(0..<32), maximumBytes: StagedBuildPackage.maximumBytes)
        #expect(try media.metadata(package.sha256) == package.size)
        let expected = try Data(contentsOf: fixture("synthetic.ipa")), range = 1_048_567..<2_097_169
        var actual = Data(), largest = 0
        try media.stream(package.sha256, range: range) { actual.append($0); largest = max(largest, $0.count) }
        #expect(actual == expected.subdata(in: range) && largest <= 1_048_576)
        try media.stream(package.sha256) { _ in }
        let vector = try JSONText.parse(Data(contentsOf: fixture("build-delivery.json")))
        let resources = try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(vector["resources"]).data)
        #expect(try JSONText.array(resources.map { try BuildDelivery.summary($0).json }) == vector["summaries"])
        #expect(try JSONText.array(BuildDelivery.summaries(resources).map(\.json)) == vector["summaries"])
        #expect(try JSONText.array(resources.prefix(2).map { .string(try BuildDelivery.removableDigest($0)) }) == vector["removals"])
        #expect(try BuildDelivery.digest(appId: app, version: "1.0", number: "42", platform: "IOS", package: package) == vector["digest"]?.text)
        #expect(throws: (any Error).self) { try media.read(package.sha256, range: -1..<4) }
    }

    @Test func stagingLocksExactRemovalRecoveryAndBackupAreCompatible() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), scope = try WorkspaceSession.BuildPackageScope(account.id, app)
        let directory = root.appendingPathComponent("state-v2"), source = try fixture("synthetic.ipa"), size = try Data(contentsOf: source).count
        let releaseStage = try #require(try JobLock.acquire(directory: directory, name: scope.stage, id: UUID().uuidString))
        await #expect(throws: (any Error).self) { try await staged(session, account: account) }; releaseStage()
        await #expect(throws: (any Error).self) { try await session.stageBuildPackage(accountId: account.id, appId: app, fileName: "synthetic.pkg", expectedSize: size, file: source) }
        #expect(try await session.storeAccess { try $0.document(namespace: "build_package_activity", key: scope.key) } == nil)
        let abandoned = "00000000-0000-4000-8000-000000000099"
        _ = try await session.packageMedia(abandoned).write(Data("synthetic orphan".utf8))
        try await session.storeAccess { try $0.insertIfAbsent(namespace: "build_package_activity", key: scope.key, json: JSONText.object([("id", .string(abandoned)), ("kind", .string("staging"))]).data) }
        let package = try await staged(session, account: account)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("build-packages/\(abandoned)").path))
        await #expect(throws: (any Error).self) { try await staged(session, account: account) }
        await #expect(throws: PublishFailure.conflict) { try await session.removeStagedBuildPackage(accountId: account.id, appId: app, id: abandoned) }
        let releasePublish = try #require(try JobLock.acquire(directory: directory, name: scope.publishing, id: UUID().uuidString))
        await #expect(throws: PublishFailure.busy) { try await session.removeStagedBuildPackage(accountId: account.id, appId: app, id: package.id) }; releasePublish()
        let parent = try TestIsolation.require().appendingPathComponent("synthetic-build-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: parent) }
        let backup = parent.appendingPathComponent("backup"), password = "synthetic build backup phrase"
        let result = try await session.createBackup(destination: backup, password: password)
        #expect(result.files == 2)
        #expect(try Backups.verify(backup, password: password) == result)
        let writer = VaultWriter(dataRoot: parent, storage: MemoryVaultStorage()), restored = parent.appendingPathComponent("restored")
        _ = try Backups.restore(backup, to: restored, password: password, writer: writer)
        let reopened = try WorkspaceSession(workspace: Workspace(root: restored), vault: writer.read(), password: password)
        #expect(try await reopened.stagedBuildPackage(accountId: account.id, appId: app)?.json == package.json)
        try await session.removeStagedBuildPackage(accountId: account.id, appId: app, id: package.id)
        #expect(try await session.stagedBuildPackage(accountId: account.id, appId: app) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("build-packages/\(package.id)").path))
    }

    @Test func approvedUploadStreamsExactBytesAndConsumesApprovalOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), package = try await staged(session, account: account), apple = SyntheticBuildApple()
        let client = try client(account, apple, host: "build-upload.appstoreconnect.test"), review = try await session.preparePublishing(account: account, request: request(account, package), client: client)
        #expect(review.steps.map(\.kind) == [.api, .api, .upload, .api] && apple.writes.isEmpty && apple.received.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.received == [try Data(contentsOf: fixture("synthetic.ipa"))])
        #expect(apple.writes.map(\.0) == ["POST", "POST", "PATCH"])
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(try await session.buildDeliveries(appId: app, client: client).first?.state == "Processing")
    }

    @Test func separateSessionsCoordinateStagingAndRejectUnsafeFiles() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), other = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let source = try fixture("synthetic.ipa"), size = try Data(contentsOf: source).count
        let results = await withTaskGroup(of: Bool.self) { group in
            for editor in [session, other] { group.addTask { do { _ = try await staged(editor, account: account); return true } catch { return false } } }
            var values: [Bool] = []; for await result in group { values.append(result) }; return values
        }
        #expect(results.filter { $0 }.count == 1)
        let saved = try #require(try await session.stagedBuildPackage(accountId: account.id, appId: app))
        #expect(try await other.stagedBuildPackage(accountId: account.id, appId: app)?.id == saved.id)
        try await other.removeStagedBuildPackage(accountId: account.id, appId: app, id: saved.id)
        let link = root.appendingPathComponent("synthetic-link.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: (any Error).self) { try await session.stageBuildPackage(accountId: account.id, appId: app, fileName: "synthetic.ipa", expectedSize: size, file: link) }
        await #expect(throws: (any Error).self) { try await session.stageBuildPackage(accountId: account.id, appId: app, fileName: "synthetic.ipa", expectedSize: size - 1, file: source) }
        let fifo = root.appendingPathComponent("synthetic-pipe.ipa")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: (any Error).self) { try await session.stageBuildPackage(accountId: account.id, appId: app, fileName: "synthetic.ipa", expectedSize: 4, file: fifo) }
        #expect(try await session.stagedBuildPackage(accountId: account.id, appId: app) == nil)
    }

    @Test func interruptedBinaryResumesWithANewReviewAndExistingReservation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), package = try await staged(session, account: account), apple = SyntheticBuildApple()
        apple.failPart = true
        let client = try client(account, apple, host: "build-resume.appstoreconnect.test"), request = request(account, package)
        let initial = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: initial.id, fingerprint: initial.fingerprint, client: client).state == "failed")
        #expect(apple.writes.map(\.0) == ["POST", "POST"])
        let resumed = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(resumed.steps.map(\.kind) == [.upload, .api])
        let done = try await session.approvePublishing(account: account, appId: app, id: resumed.id, fingerprint: resumed.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.writes.map(\.0) == ["POST", "POST", "PATCH"] && apple.received.count == 2 && apple.received[0] == apple.received[1])
    }

    @Test func foreignScopeChangedPackageAndUnsafeOperationsFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), package = try await staged(session, account: account), apple = SyntheticBuildApple()
        let client = try client(account, apple, host: "build-guards.appstoreconnect.test"), request = request(account, package)
        apple.uploads = [["type": "buildUploads", "id": "upload-foreign", "attributes": ["state": ["state": "FAILED"]]]]; apple.incompleteScope = true
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request, client: client) }
        #expect(apple.writes.isEmpty)
        apple.uploads = []; apple.incompleteScope = false
        let stale = try await session.preparePublishing(account: account, request: request, client: client)
        try await session.removeStagedBuildPackage(accountId: account.id, appId: app, id: package.id)
        _ = try await staged(session, account: account)
        await #expect(throws: (any Error).self) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        let freshPackage = try #require(try await session.stagedBuildPackage(accountId: account.id, appId: app))
        apple.unsafeOperation = true
        let unsafe = try await session.preparePublishing(account: account, request: self.request(account, freshPackage), client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: unsafe.id, fingerprint: unsafe.fingerprint, client: client).state == "failed")
        #expect(apple.writes.map(\.0) == ["POST", "POST"] && apple.received.isEmpty)
    }

    @Test func pendingDeletionRequiresFreshUnlinkedStateAndExplicitApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticBuildApple()
        apple.uploads = [["type": "buildUploads", "id": "upload-synthetic", "attributes": ["cfBundleShortVersionString": "1.0", "cfBundleVersion": "42", "platform": "IOS", "state": ["state": "AWAITING_UPLOAD"]]]]
        let client = try client(account, apple, host: "build-delete.appstoreconnect.test")
        var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight); request.testflightAction = "delete-build-upload"; request.buildUploadId = "upload-synthetic"
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty)
        var attributes = apple.uploads[0]["attributes"] as! [String: Any]; attributes["state"] = ["state": "PROCESSING"]; apple.uploads[0]["attributes"] = attributes
        await #expect(throws: (any Error).self) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        attributes["state"] = ["state": "FAILED"]; apple.uploads[0]["attributes"] = attributes
        let fresh = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: fresh.id, fingerprint: fresh.fingerprint, client: client).state == "complete")
        #expect(apple.writes.map(\.0) == ["DELETE"])
    }

    @Test func changedReservationIsRejectedBeforeAnyBinaryLeavesTheStore() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), package = try await staged(session, account: account), apple = SyntheticBuildApple()
        apple.wrongReservation = true
        let client = try client(account, apple, host: "build-reservation.appstoreconnect.test")
        let prepared = try await session.preparePublishing(account: account, request: request(account, package), client: client)
        let done = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(done.state == "failed" && apple.writes.map(\.0) == ["POST", "POST"] && apple.received.isEmpty)
    }

    @Test func uploadRangesRejectNonIntegersGapsOverflowAndUnsafeHeaders() throws {
        func operation(_ offset: Double = 0, _ length: Double = 4, _ url: String = "https://build-stream.blobstore.apple.com/part", headers: [JSONValue] = []) -> JSONValue {
            .object(["method": .string("PUT"), "url": .string(url), "offset": .number(offset), "length": .number(length), "requestHeaders": .array(headers)])
        }
        #expect(try BuildUploadOperation.validate(.array([operation()]), size: 4).first?.range == 0..<4)
        for values in [[operation(0.5, 3.5)], [operation(0, .infinity)], [operation(0, Double.greatestFiniteMagnitude)], [operation(1, 3)], [operation(0, 3)], [operation(), operation()], [operation(0, 4, "https://unowned.example.invalid/part")], [operation(headers: [.object(["name": .string("Cookie"), "value": .string("synthetic")])])]] {
            #expect(throws: (any Error).self) { try BuildUploadOperation.validate(.array(values), size: 4) }
        }
    }

    /// Apple's upload addresses differ by service, and an operation may need no extra headers. A refusal names its reason without the signed address.
    @Test func appleOwnedUploadHostsAndOperationsWithoutHeadersAreAcceptedAndRefusalsSayWhy() throws {
        let plain: JSONValue = .object(["method": .string("PUT"), "url": .string("https://synthetic-assets.storage.apple.com:443/part?signature=synthetic"), "offset": .number(0), "length": .number(4)])
        #expect(try BuildUploadOperation.validate(.array([plain]), size: 4).first?.headers.isEmpty == true)
        func refusal(_ operation: [String: JSONValue]) -> String {
            do { _ = try BuildUploadOperation.validate(.array([.object(operation)]), size: 4); return "" } catch let failure as PublishFailure { return failure.message } catch { return "" }
        }
        let base: [String: JSONValue] = ["method": .string("PUT"), "url": .string("https://synthetic.blobstore.apple.com/part?signature=synthetic-secret"), "offset": .number(0), "length": .number(4)]
        var foreign = base; foreign["url"] = .string("https://uploads.example.invalid/part?signature=synthetic-secret")
        #expect(refusal(foreign).contains("an upload host outside apple.com (uploads.example.invalid)") && !refusal(foreign).contains("synthetic-secret"))
        var post = base; post["method"] = .string("POST")
        #expect(refusal(post).contains("method POST"))
        var range = base; range["length"] = .number(9)
        #expect(refusal(range).contains("a byte range outside the 4-byte file"))
        var headers = base; headers["requestHeaders"] = .string("Content-Type: image/png")
        #expect(refusal(headers).contains("request headers that are not a list"))
    }
}
