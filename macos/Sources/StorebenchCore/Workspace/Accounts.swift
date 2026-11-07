import Foundation

public enum AccountFailure: Error, Equatable {
    case invalid, keyContent, purchaseKey, issuerRequired, keychain, auth, access, agreement, empty, importFailed, notFound, stale, mismatch
    public var message: String {
        switch self {
        case .invalid: "Check the account name, Issuer ID, Key ID and original P-256 .p8 file. A team key needs its Issuer ID."
        case .keyContent: "This is not an App Store Connect API private key. Choose the original .p8 file downloaded for your Individual API key or Team API key; it starts with BEGIN PRIVATE KEY."
        case .purchaseKey: "This is an In-App Purchase key, which cannot read or update apps. Choose the .p8 file of an Individual API key or Team API key: a team key from Users and Access → Integrations → App Store Connect API, or your individual key from your name → Edit Profile."
        case .issuerRequired: "A Team API key needs its Issuer ID. Copy it from above the Team Keys list under Users and Access → Integrations → App Store Connect API, or choose Individual key for an Individual API key."
        case .keychain: "Keychain could not be accessed. Unlock your login keychain, then choose Retry Keychain Access before trying again."
        case .auth: "Apple did not accept this key. Check the Key ID, Issuer ID and .p8 file, and whether the key is active in App Store Connect (Users and Access → Integrations for a team key, or your name → Edit Profile for an individual key). A Team API key needs Team API key and its Issuer ID; an Individual API key has none."
        case .access: "Apple did not allow this key to list apps. In App Store Connect, check the key's role under Users and Access → Integrations and agreements under Business → Agreements."
        case .agreement: ReportingMessages.appleAgreement + " Then test the connection again."
        case .empty: "Apple returned no apps for this key. In App Store Connect, check your app access under Users and Access → People."
        case .importFailed: "Apple's connection could not be verified. Check the network connection and retry."
        case .notFound: "The account was not found. Reload accounts and retry."
        case .stale: "The account changed during this operation. Reload accounts and explicitly retry with the current connection."
        case .mismatch: "This key did not return any of this account's saved apps. Choose the original key for this connection."
        }
    }
    static func classify(_ error: Error) -> Error {
        switch error {
        case let value as AccountFailure: value
        case let value as CredentialAccessFailure: value
        case let value as PasswordVaultStorage.Failure: value
        case is CancellationError: error
        case AppStoreConnectClient.Failure.status(401): AccountFailure.auth
        case AppStoreConnectClient.Failure.status(403): AccountFailure.access
        case AppStoreConnectClient.Failure.agreement: AccountFailure.agreement
        case is CredentialVault.Failure, is VaultWriter.Failure: AccountFailure.keychain
        default: AccountFailure.importFailed
        }
    }
}

extension WorkspaceSession {
    func currentAccount(_ expected: Account, client: AppStoreConnectClient? = nil, exact: Bool = false) throws -> Account {
        guard let current = try accounts().first(where: { $0.id == expected.id }) else { throw AccountFailure.notFound }
        func same(_ other: Account) -> Bool {
            TextSemantics.same(current.keyId, other.keyId) && TextSemantics.same(current.keyType, other.keyType) && TextSemantics.same(current.issuerId, other.issuerId) && current.id == other.id
        }
        guard same(expected), client.map({ same($0.token.account) }) ?? true,
              !exact || Self.json(current) == Self.json(expected) else { throw AccountFailure.stale }
        return current
    }
    static func appSelection(_ apps: [AppStoreConnectClient.Resource]) throws -> (ids: [String], names: [String: String]) {
        var ids: [String] = [], names: [String: String] = [:]
        for app in apps where app.type == "apps" {
            guard app.id.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else { throw AccountFailure.invalid }
            if !ids.contains(app.id) { ids.append(app.id) }
            if let name = app.attributes?["name"]?.string {
                guard name.utf16.count <= 200 else { throw AccountFailure.invalid }
                names[app.id] = name
            }
        }
        return (ids, names)
    }
    /// Apple reads finish before the account mutex and encrypted-store transaction begin.
    public func connectAccount(name: String, keyType: String, issuerId: String?, keyId: String, privateKeyPEM: String, writer: VaultWriter,
                               origin: URL = AppStoreConnectClient.base, configuration: sending URLSessionConfiguration = .ephemeral) async throws -> Account {
        try requireOwnWorkspace()
        try requireSessionAccess()
        let lease = try lifetime.admit(.connection); defer { lease.finish() }
        return try await SessionContext.$lease.withValue(lease) {
            try await connectAccountAdmitted(name: name, keyType: keyType, issuerId: issuerId, keyId: keyId, privateKeyPEM: privateKeyPEM, writer: writer, origin: origin, configuration: configuration)
        }
    }
    private func connectAccountAdmitted(name: String, keyType: String, issuerId: String?, keyId: String, privateKeyPEM: String, writer: VaultWriter,
                                       origin: URL, configuration: sending URLSessionConfiguration) async throws -> Account {
        let privateKeyPEM = try AppleAccountInputs.privateKey(privateKeyPEM)
        let account = try AppleAccountInputs.account(name: name, keyType: keyType, issuerId: issuerId, keyId: keyId, pem: privateKeyPEM), key = "apple:\(account.id)"
        do { acceptCredential(try writer.writeCredential(key, root: root, value: privateKeyPEM, expected: nil, adding: true), key: key, writer: writer) }
        catch { credentialFailures.insert(key); if error is PasswordVaultStorage.Failure { throw error }; throw AccountFailure.keychain }
        let installedVersion = credentialVersions[key]
        do {
            let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: privateKeyPEM), origin: origin, configuration: configuration, accessCheck: sessionRequestCheck())
            let selection = try Self.appSelection(await client.list("/v1/apps?limit=200"))
            try Task.checkCancellation()
            guard !selection.ids.isEmpty else { throw AccountFailure.empty }
            let connected = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: keyType, issuerId: account.issuerId, appIds: selection.ids, appNames: selection.names)
            try storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                    try store.transaction { current in
                        var saved: [JSONText] = []
                        if let document = try current("accounts", "all") { guard case .array(let items) = try JSONText.parse(document.payload) else { throw AccountFailure.invalid }; saved = items }
                        guard !saved.contains(where: { $0["id"]?.text == connected.id }) else { throw AccountFailure.invalid }
                        return [.put(namespace: "accounts", key: "all", json: JSONText.array(saved + [Self.json(connected)]).data)]
                    }
                }
            }
            return connected
        } catch {
            // Remove only the key this attempt installed, preserving a concurrent replacement.
            do { acceptCredential(try writer.removeCredential(key, root: root, expected: privateKeyPEM, expectedVersion: installedVersion), key: key, writer: writer) }
            catch { credentialSnapshot = nil; credentialFailures.insert(key) }
            throw AccountFailure.classify(error)
        }
    }
    static func json(_ account: Account) -> JSONText {
        var fields: [(String, JSONText)] = [("id", .string(account.id)), ("name", .string(account.name)), ("keyId", .string(account.keyId)), ("appIds", .array(account.appIds.map { .string($0) }))]
        if let names = account.appNames { fields.append(("appNames", .object(account.appIds.compactMap { id in names[id].map { (id, .string($0)) } }))) }
        fields.append(("keyType", .string(account.keyType)))
        if account.keyType == "team", let issuer = account.issuerId { fields.append(("issuerId", .string(issuer))) }
        fields.append(("credentialSource", .string("keychain"))); return .object(fields)
    }
    /// An empty successful response verifies access; testing never changes the saved app list.
    public func testAccountConnection(_ account: Account, client: AppStoreConnectClient) async throws {
        do {
            _ = try currentAccount(account, client: client)
            _ = try await client.get("/v1/apps?limit=1")
            _ = try currentAccount(account, client: client)
        } catch { throw AccountFailure.classify(error) }
    }
    /// An empty successful app list clears the selection, while saved app history remains available.
    public func refreshAccountApps(_ account: Account, client: AppStoreConnectClient) async throws -> Account {
        do {
            _ = try currentAccount(account, client: client, exact: true)
            let selection = try await ScreenReads.reading(fresh: true) { try Self.appSelection(await client.list("/v1/apps?limit=200")) }
            try Task.checkCancellation()
            let updated = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: selection.ids, appNames: selection.names)
            try storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                    try store.transaction { read in
                        _ = try currentAccount(account, client: client, exact: true)
                        guard let document = try read("accounts", "all"), case .array(var items) = try JSONText.parse(document.payload),
                              let index = items.firstIndex(where: { $0["id"]?.text == account.id }), case .object(var fields) = items[index] else { throw AccountFailure.notFound }
                        let ids = JSONText.array(selection.ids.map(JSONText.string)), names = JSONText.object(selection.ids.compactMap { id in selection.names[id].map { (id, .string($0)) } })
                        fields = fields.map { $0.0 == "appIds" ? ($0.0, ids) : $0.0 == "appNames" ? ($0.0, names) : $0 }
                        if !fields.contains(where: { $0.0 == "appNames" }), let at = fields.firstIndex(where: { $0.0 == "appIds" }) { fields.insert(("appNames", names), at: at + 1) }
                        items[index] = .object(fields)
                        return [.put(namespace: "accounts", key: "all", json: JSONText.array(items).data)]
                    }
                }
            }
            return updated
        } catch { throw AccountFailure.classify(error) }
    }
    /// Reconnect the original Key ID and issuer. App selections, imports, reports and drafts stay in the encrypted store.
    public func reconnectAccount(_ account: Account, privateKeyPEM: String, writer: VaultWriter,
                                 origin: URL = AppStoreConnectClient.base, configuration: sending URLSessionConfiguration = .ephemeral) async throws {
        try requireOwnWorkspace()
        try requireSessionAccess()
        let lease = try lifetime.admit(.connection); defer { lease.finish() }
        try await SessionContext.$lease.withValue(lease) {
            try await reconnectAccountAdmitted(account, privateKeyPEM: privateKeyPEM, writer: writer, origin: origin, configuration: configuration)
        }
    }
    private func reconnectAccountAdmitted(_ account: Account, privateKeyPEM: String, writer: VaultWriter,
                                         origin: URL, configuration: sending URLSessionConfiguration) async throws {
        let privateKeyPEM = try AppleAccountInputs.privateKey(privateKeyPEM)
        _ = try currentAccount(account, exact: true)
        let key = "apple:\(account.id)"
        let previous = try credentialCapture(key, writer: writer, allowMissing: true)
        let previousVersion = credentialVersions[key]
        do {
            let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: privateKeyPEM), origin: origin, configuration: configuration, accessCheck: sessionRequestCheck())
            let apps = Set(try await client.list("/v1/apps?limit=200").filter { $0.type == "apps" }.map(\.id))
            guard !apps.isEmpty, account.appIds.isEmpty || account.appIds.contains(where: apps.contains) else { throw AccountFailure.mismatch }
            try storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                    try store.transaction { _ in
                        _ = try currentAccount(account, exact: true)
                        do {
                            let replacement = try writer.writeCredential(key, root: root, value: privateKeyPEM, expected: previous, expectedVersion: previousVersion)
                            acceptCredential(replacement, key: key, writer: writer)
                        } catch CredentialAccessFailure.changed { throw CredentialAccessFailure.changed }
                        catch { credentialFailures.insert(key); credentialSnapshot = nil; if error is PasswordVaultStorage.Failure { throw error }; throw AccountFailure.keychain }
                        return []
                    }
                }
            }
        } catch {
            if error is CredentialVault.Failure || error is VaultWriter.Failure { credentialFailures.insert(key); credentialSnapshot = nil }
            throw AccountFailure.classify(error)
        }
    }
}
