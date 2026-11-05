import Darwin
import Foundation

public struct StagedBuildPackage: Equatable, Sendable, Identifiable {
    public let id, fileName, uti, sha256, createdAt: String
    public let size: Int
    public static let maximumBytes = 16 * 1024 * 1024 * 1024
    static let uuid = "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"

    var json: JSONText { .object([("id", .string(id)), ("fileName", .string(fileName)), ("uti", .string(uti)), ("size", .number(Double(size))), ("sha256", .string(sha256)), ("createdAt", .string(createdAt))]) }
    static func type(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf16.count <= 120, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\" }) else { throw PublishFailure.invalid("Choose a build file with a safe name.") }
        if name.lowercased().hasSuffix(".ipa") { return "com.apple.ipa" }
        if name.lowercased().hasSuffix(".pkg") { return "com.apple.pkg" }
        throw PublishFailure.invalid("Choose an IPA or PKG build file.")
    }
    init(_ value: JSONText) throws {
        guard let id = value["id"]?.text, id.range(of: Self.uuid, options: .regularExpression) != nil, let name = value["fileName"]?.text, let uti = value["uti"]?.text,
              case .number(let size)? = value["size"], size.isFinite, size.rounded() == size, size >= 4, size <= Double(Self.maximumBytes),
              let hash = value["sha256"]?.text, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let date = value["createdAt"]?.text,
              (ISO8601DateFormatter.storebench.date(from: date) ?? ISO8601DateFormatter().date(from: date)) != nil, try Self.type(name) == uti else { throw PublishFailure.invalid("The saved build package is invalid.") }
        self.id = id; fileName = name; self.uti = uti; self.size = Int(size); sha256 = hash; createdAt = date
    }
}

extension WorkspaceSession {
    struct BuildPackageScope {
        let key, mutex, stage, publishing: String
        init(_ account: String, _ app: String) throws {
            guard account.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, app.range(of: "^[0-9]{1,32}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid build package scope.") }
            let opaque = String(JSONText.string("\(account)\u{0}\(app)").rawSHA256.prefix(48))
            key = "\(account):\(app)"; mutex = "build_package_\(opaque).mutex"; stage = "build_stage_\(opaque)"; publishing = "publishing_\(opaque)"
        }
    }
    func packageMedia(_ id: String) throws -> EncryptedMediaStore {
        guard id.range(of: StagedBuildPackage.uuid, options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid build package storage.") }
        let parent = try storeAccess { $0.directory }.appendingPathComponent("build-packages")
        try TestIsolation.check(parent)
        if mkdir(parent.path, 0o700) != 0, errno != EEXIST { throw EncryptedMediaStore.Failure.notPrivate }
        try Backups.privateDirectory(parent)
        return try EncryptedMediaStore(directory: parent.appendingPathComponent(id), key: databaseKey, maximumBytes: StagedBuildPackage.maximumBytes)
    }
    func discardPackage(_ id: String) throws {
        let media = try packageMedia(id), directory = try storeAccess { $0.directory }
        try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try FileManager.default.removeItem(at: media.directory) }
    }
    static func packageActivity(_ value: JSONText) throws -> (id: String, kind: String) {
        guard let id = value["id"]?.text, id.range(of: StagedBuildPackage.uuid, options: .regularExpression) != nil,
              let kind = value["kind"]?.text, ["staging", "removing"].contains(kind) else { throw PublishFailure.invalid("The saved build package activity is invalid.") }
        return (id, kind)
    }
    public func stagedBuildPackage(accountId: String, appId: String, id: String? = nil) throws -> StagedBuildPackage? {
        let scope = try BuildPackageScope(accountId, appId)
        guard let document = try storeAccess({ try $0.document(namespace: "build_packages", key: scope.key) }) else { return nil }
        let item = try StagedBuildPackage(JSONText.parse(document.payload))
        if let id, item.id != id { return nil }
        guard try packageMedia(item.id).metadata(item.sha256) == item.size else { throw PublishFailure.invalid("The saved build package changed size.") }
        return item
    }

    /// A single owned staging job streams encryption outside the actor, then commits under publishing/package locks.
    public func stageBuildPackage(accountId: String, appId: String, fileName: String, expectedSize: Int, file: URL, now: Date = Date()) async throws -> StagedBuildPackage {
        try requireSessionAccess()
        let lease = try lifetime.admit(.transfer); defer { lease.finish() }
        return try await SessionContext.$lease.withValue(lease) {
            try await stageBuildPackageAdmitted(accountId: accountId, appId: appId, fileName: fileName, expectedSize: expectedSize, file: file, now: now)
        }
    }
    private func stageBuildPackageAdmitted(accountId: String, appId: String, fileName: String, expectedSize: Int, file: URL, now: Date) async throws -> StagedBuildPackage {
        let scope = try BuildPackageScope(accountId, appId), uti = try StagedBuildPackage.type(fileName), directory = try storeAccess { $0.directory }
        guard expectedSize >= 4, expectedSize <= StagedBuildPackage.maximumBytes else { throw PublishFailure.invalid("Choose a build file up to 16 GiB.") }
        let id = UUID().uuidString.lowercased()
        guard let releaseStage = try JobLock.acquire(directory: directory, name: scope.stage, id: id) else { throw PublishFailure.invalid("Wait for the active local build staging job before choosing another.") }
        defer { releaseStage() }
        var committed = false
        defer {
            if !committed { try? FileMutex.withLock(directory.appendingPathComponent(scope.mutex)) {
                try storeAccess { store in
                    if let activity = try store.document(namespace: "build_package_activity", key: scope.key), try Self.packageActivity(JSONText.parse(activity.payload)).id == id {
                        try discardPackage(id); try store.delete(namespace: "build_package_activity", key: scope.key)
                    }
                }
            } }
        }
        try FileMutex.withLock(directory.appendingPathComponent(scope.mutex)) {
            try storeAccess { store in
                let saved = try store.document(namespace: "build_packages", key: scope.key)
                if let previous = try store.document(namespace: "build_package_activity", key: scope.key) {
                    let activity = try Self.packageActivity(JSONText.parse(previous.payload))
                    if let saved, try StagedBuildPackage(JSONText.parse(saved.payload)).id == activity.id { throw PublishFailure.invalid("The saved build package is still in use.") }
                    try discardPackage(activity.id); try store.delete(namespace: "build_package_activity", key: scope.key)
                }
                guard saved == nil else { throw PublishFailure.invalid("Remove the previous staged build package before choosing another.") }
                try store.insertIfAbsent(namespace: "build_package_activity", key: scope.key, json: JSONText.object([("id", .string(id)), ("kind", .string("staging"))]).data)
            }
        }
        let media = try packageMedia(id), signature = uti == "com.apple.ipa" ? Data([0x50, 0x4b, 0x03, 0x04]) : Data("xar!".utf8)
        let worker = Task.detached { try media.write(fileAt: file, limit: expectedSize, expectedSize: expectedSize, signature: signature) }
        let written = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        let item = try StagedBuildPackage(.object([("id", .string(id)), ("fileName", .string(fileName)), ("uti", .string(uti)), ("size", .number(Double(written.length))), ("sha256", .string(written.hash)), ("createdAt", .string(CustomerReview.isoString(now)))]))
        guard let releasePublishing = try JobLock.acquire(directory: directory, name: scope.publishing, id: id) else { throw PublishFailure.busy }
        defer { releasePublishing() }
        try FileMutex.withLock(directory.appendingPathComponent(scope.mutex)) {
            try storeAccess { store in
                try store.transaction { read in
                    guard try read("build_packages", scope.key) == nil, let activity = try read("build_package_activity", scope.key), try Self.packageActivity(JSONText.parse(activity.payload)) == (id, "staging") else { throw PublishFailure.conflict }
                    return [.put(namespace: "build_packages", key: scope.key, json: item.json.data), .delete(namespace: "build_package_activity", key: scope.key)]
                }
            }
            committed = true
        }
        return item
    }

    public func removeStagedBuildPackage(accountId: String, appId: String, id: String) throws {
        guard id.range(of: StagedBuildPackage.uuid, options: .regularExpression) != nil else { throw PublishFailure.invalid("Choose a staged build package.") }
        let scope = try BuildPackageScope(accountId, appId), directory = try storeAccess { $0.directory }
        guard let release = try JobLock.acquire(directory: directory, name: scope.publishing, id: id) else { throw PublishFailure.busy }
        defer { release() }
        try FileMutex.withLock(directory.appendingPathComponent(scope.mutex)) {
            try storeAccess { store in
                try store.transaction { read in
                    guard let document = try read("build_packages", scope.key), try StagedBuildPackage(JSONText.parse(document.payload)).id == id, try read("build_package_activity", scope.key) == nil else { throw PublishFailure.conflict }
                    return [.delete(namespace: "build_packages", key: scope.key), .put(namespace: "build_package_activity", key: scope.key, json: JSONText.object([("id", .string(id)), ("kind", .string("removing"))]).data)]
                }
                try discardPackage(id)
                if let activity = try store.document(namespace: "build_package_activity", key: scope.key), try Self.packageActivity(JSONText.parse(activity.payload)).id == id { try store.delete(namespace: "build_package_activity", key: scope.key) }
            }
        }
    }
}
