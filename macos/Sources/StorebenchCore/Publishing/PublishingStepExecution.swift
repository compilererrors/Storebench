import Foundation

struct PublishStepOutput: Sendable {
    let id: String?
    let operations: JSONValue?
}

extension WorkspaceSession {
    /// Serial and parallel steps use exactly the same fresh scope checks, upload validation and lost-answer recovery.
    func performPublishingStep(_ step: PublishStep, ids: [String: String], operations: [String: JSONValue], account: Account,
                               appId: String, client: AppStoreConnectClient, grant: PublishGrant) async throws -> PublishStepOutput {
        try Task.checkCancellation()
        try requirePublishingAccount(account, appId: appId, client: client)
        let path = try Self.apiPath(step.path, ids: ids)
        var resultId: String?, returnedOperations: JSONValue?
        switch step.kind {
        case .api:
            let body = try step.body.map { try Self.resolve($0, ids: ids) }
            try await verifyWrite(method: step.method ?? "", path: path, body: body, guardValue: step.guardValue, appId: appId, client: client)
            try requirePublishingAccount(account, appId: appId, client: client)
            var result: AppStoreConnectClient.Resource?, placed: String?
            for attempt in 1...3 {
                do {
                    try Task.checkCancellation()
                    // App Privacy and Tax Category have no API key endpoint; their reviewed writes use the signed-in Apple ID.
                    if ["app-privacy", "tax-category"].contains(step.guardValue?["kind"]?.text) { result = try await appleWebClient(account: account, appId: appId).write(step.method ?? "", path, body: body, grant: grant) }
                    else { result = try await client.write(step.method ?? "", path, body: body, grant: grant) }
                    break
                }
                catch where attempt < 3 && step.guardValue?["kind"]?.text == "release-media-placement" && Self.transient(error) {
                    // Apple may have added the file before its answer was lost: look for it first, so it is never added twice.
                    try await Task.sleep(for: .seconds(3))
                    if let id = try await placedReleaseMedia(body: body, guardValue: step.guardValue, appId: appId, client: client) { placed = id; break }
                    try await verifyWrite(method: step.method ?? "", path: path, body: body, guardValue: step.guardValue, appId: appId, client: client)
                    try requirePublishingAccount(account, appId: appId, client: client)
                }
            }
            resultId = result?.id ?? placed
            if let reserved = result?.attributes?["uploadOperations"], case .array = reserved { returnedOperations = reserved }
        case .upload:
            if step.guardValue?["kind"]?.text == "release-media-upload" {
                try await uploadReleaseMedia(path: path, step: step, reserved: Self.reservation(step.path).flatMap { operations[$0] }, accountId: account.id, appId: appId, client: client, grant: grant)
                break
            }
            if step.asset?["storage"]?.text == "asset-library" {
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count == 3, let asset = step.asset else { throw PublishFailure.conflict }
                let reserved = try await libraryReader(appId: appId, client: client).asset(parts[2], kind: parts[1] == AssetLibrary.Kind.image.resource ? .image : .video)
                try verifyLibraryUpload(reserved, guardValue: step.guardValue, accountId: account.id, appId: appId)
                let resources = try await client.get(path)
                guard let resource = resources.first, resource.id == reserved.id else { throw PublishFailure.conflict }
                try await uploadLibraryFile(asset, operations: Self.reservation(step.path).flatMap { operations[$0] } ?? resource.attributes?["uploadOperations"], accountId: account.id, appId: appId, client: client)
                break
            }
            guard let asset = step.asset, let resource = try await ownedMedia(path: path, appId: appId, client: client) else { throw PublishFailure.write("Apple upload reservation is missing.") }
            if asset["storage"]?.text == "build-package" { try await verifyBuildPackageUpload(asset, file: resource, appId: appId, client: client) }
            try await uploadAsset(asset, operations: resource.attributes?["uploadOperations"], accountId: account.id, appId: appId, client: client, grant: grant)
        case .verify:
            if step.guardValue?["kind"]?.text == "asset-library-processed" {
                try await verifyLibraryProcessing(path: path, guardValue: step.guardValue!, appId: appId, client: client)
                break
            }
            var complete = false
            let deadline = ContinuousClock.now + .seconds(5 * 60)
            while ContinuousClock.now < deadline {
                let state = try await ownedMedia(path: path, appId: appId, client: client).map(Apple.delivery) ?? "FAILED"
                if state == "COMPLETE" { complete = true; break }
                if state == "FAILED" { throw PublishFailure.write("Apple could not process this media file. Prepare a new review.") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard complete else { throw PublishFailure.write("Apple is still processing this media file. Prepare a new review; do not upload a duplicate.") }
        }
        return PublishStepOutput(id: resultId, operations: returnedOperations)
    }
}
