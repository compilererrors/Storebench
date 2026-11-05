import Foundation

public enum ReportingSource: String, CaseIterable, Sendable { case api, reporter }
public enum ReporterSetupFailure: Error, Equatable {
    case invalid, unavailable, changed, keychain, storage, busy
    public var message: String {
        switch self {
        case .invalid: "Choose a valid reporting account, vendor and Reporter access token."
        case .unavailable: "Reporter access could not be verified. Check the token and reporting permissions, then retry or import a report file."
        case .changed: "The saved reporting connection changed. Read the current connection and explicitly retry. Existing reports are kept."
        case .keychain: "The reporting token could not be saved or removed in Keychain. Unlock your login keychain and retry Keychain access for this Apple account."
        case .storage: "The reporting connection could not be saved. Check local storage access and retry. Existing reports are kept."
        case .busy: "Another process is changing this account's reporting connection. Wait for it to finish, then explicitly retry."
        }
    }
}
public struct ReportingConnection: Equatable, Sendable {
    public let accountId, vendorNumber: String
    public let reporter: Reporter?
    public struct Reporter: Equatable, Sendable {
        public let accountNumber, vendorNumber, connectedAt: String
        let credentialId: String
        var json: JSONText { .object([("accountNumber", .string(accountNumber)), ("vendorNumber", .string(vendorNumber)), ("credentialId", .string(credentialId)), ("connectedAt", .string(connectedAt))]) }
    }
    static func validAccount(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil }
    public static func validVendor(_ value: String) -> Bool { value.range(of: #"^[0-9]{6,20}\z"#, options: .regularExpression) != nil }
    public init(json: JSONText) throws {
        guard case .object(let fields) = json, fields.allSatisfy({ ["schemaVersion", "accountId", "vendorNumber", "reporter"].contains($0.0) }),
              json["schemaVersion"] == .number(1), let account = json["accountId"]?.text, Self.validAccount(account),
              let vendor = json["vendorNumber"]?.text, Self.validVendor(vendor) else { throw ReporterSetupFailure.invalid }
        accountId = account; vendorNumber = vendor
        if let value = json["reporter"] {
            guard case .object(let fields) = value, fields.allSatisfy({ ["accountNumber", "vendorNumber", "credentialId", "connectedAt"].contains($0.0) }),
                  let account = value["accountNumber"]?.text, account.range(of: #"^[0-9]{1,20}\z"#, options: .regularExpression) != nil,
                  let vendor = value["vendorNumber"]?.text, Self.validVendor(vendor), let credential = value["credentialId"]?.text,
                  credential.range(of: #"^[a-f0-9-]{36}\z"#, options: .regularExpression) != nil, let date = value["connectedAt"]?.text,
                  (try? CustomerReview.isoDate(date)) != nil else { throw ReporterSetupFailure.invalid }
            reporter = Reporter(accountNumber: account, vendorNumber: vendor, connectedAt: date, credentialId: credential)
        } else { reporter = nil }
    }
    init(accountId: String, vendorNumber: String, reporter: Reporter?) { self.accountId = accountId; self.vendorNumber = vendorNumber; self.reporter = reporter }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("vendorNumber", .string(vendorNumber))]
        if let reporter { fields.append(("reporter", reporter.json)) }; return .object(fields)
    }
}
public struct ReportingConnectionState: Equatable, Sendable {
    public let accountId: String, revision: Int, connection: ReportingConnection?
}
public enum ReporterSetupResult: Sendable {
    case chooseAccount([ReporterAccount])
    case chooseVendor(accounts: [ReporterAccount], account: String, vendors: [String])
    case connected(ReportingConnectionState)
}

extension WorkspaceSession {
    func reportingMutex(accountId: String) throws -> URL {
        guard ReportingConnection.validAccount(accountId) else { throw ReporterSetupFailure.invalid }
        return try storeAccess { $0.directory.appendingPathComponent("reporter_" + JSONText.string(accountId).rawSHA256.prefix(32) + ".mutex") }
    }
    func requireReportingScope(_ account: Account, appId: String) throws {
        let current = try currentAccount(account)
        guard current.appIds.contains(appId), account.appIds.contains(appId) else { throw AccountFailure.notFound }
    }
    func readReportingState(accountId: String) throws -> ReportingConnectionState {
        guard ReportingConnection.validAccount(accountId) else { throw ReporterSetupFailure.invalid }
        guard let document = try storeAccess({ try $0.document(namespace: "sales_connection", key: accountId) }) else { return ReportingConnectionState(accountId: accountId, revision: 0, connection: nil) }
        let connection = try ReportingConnection(json: JSONText.parse(document.payload))
        guard connection.accountId == accountId else { throw ReporterSetupFailure.invalid }
        return ReportingConnectionState(accountId: accountId, revision: document.revision, connection: connection)
    }
    public func reportingConnection(account: Account, appId: String) throws -> ReportingConnectionState {
        try requireReportingScope(account, appId: appId)
        return try FileMutex.withLock(reportingMutex(accountId: account.id)) { try readReportingState(accountId: account.id) }
    }
    func requireReportingState(_ baseline: ReportingConnectionState, accountId: String) throws {
        guard baseline.accountId == accountId, try readReportingState(accountId: accountId) == baseline else { throw ReporterSetupFailure.changed }
    }
    public func saveApiReportingVendor(account: Account, appId: String, vendorNumber: String, baseline: ReportingConnectionState) throws -> ReportingConnectionState {
        let vendor = TextSemantics.trim(vendorNumber)
        guard account.keyType == "team", ReportingConnection.validVendor(vendor) else { throw ReporterSetupFailure.invalid }
        return try FileMutex.withLock(reportingMutex(accountId: account.id)) {
            try storeAccess { store in
                try store.transaction { _ in
                    try requireReportingScope(account, appId: appId); try requireReportingState(baseline, accountId: account.id)
                    let next = ReportingConnection(accountId: account.id, vendorNumber: vendor, reporter: baseline.connection?.reporter)
                    return [.put(namespace: "sales_connection", key: account.id, json: next.json.data)]
                }
                return try readReportingState(accountId: account.id)
            }
        }
    }
    /// Every continuation rediscovers the token's accounts and vendors. Ambiguous choices never save a token.
    public func connectReporter(account: Account, appId: String, token: String, baseline: ReportingConnectionState,
                                selectedAccount: String = "", selectedVendor: String = "", writer: VaultWriter,
                                origin: URL = URL(string: "https://reportingitc-reporter.apple.com")!, configuration: sending URLSessionConfiguration = .ephemeral,
                                now: Date = Date()) async throws -> ReporterSetupResult {
        try requireReportingScope(account, appId: appId); try requireReportingState(baseline, accountId: account.id)
        let token = TextSemantics.trim(token), client = try ReporterClient(token: token, origin: origin, configuration: configuration, selection: nil, accessCheck: sessionRequestCheck())
        ReplyDiagnostics.clear(.reporterSales)
        let accounts = try await client.accounts(); try Task.checkCancellation()
        if !selectedAccount.isEmpty, !accounts.contains(where: { $0.number == selectedAccount }) { throw ReporterSetupFailure.changed }
        let accountNumber = selectedAccount.isEmpty ? (accounts.count == 1 ? accounts[0].number : nil) : selectedAccount
        guard let accountNumber else { return .chooseAccount(accounts) }
        let vendors = try await client.vendors(account: accountNumber); try Task.checkCancellation()
        if !selectedVendor.isEmpty, !vendors.contains(selectedVendor) { throw ReporterSetupFailure.changed }
        let vendor = selectedVendor.isEmpty ? (vendors.count == 1 ? vendors[0] : nil) : selectedVendor
        guard let vendor else { return .chooseVendor(accounts: accounts, account: accountNumber, vendors: vendors) }
        do {
            return try FileMutex.withLock(reportingMutex(accountId: account.id)) {
                let credentialId = UUID().uuidString.lowercased(), key = "reporter:\(credentialId)"
                var installed: VaultWriter.Capture?
                do {
                    try storeAccess { store in
                        try store.transaction { _ in
                            try requireReportingScope(account, appId: appId); try requireReportingState(baseline, accountId: account.id); try Task.checkCancellation()
                            do { installed = try writer.writeCredential(key, root: root, value: token, expected: nil, adding: true) }
                            catch { if error is PasswordVaultStorage.Failure { throw error }; throw ReporterSetupFailure.keychain }
                            try Task.checkCancellation()
                            let next = ReportingConnection(accountId: account.id, vendorNumber: vendor, reporter: ReportingConnection.Reporter(accountNumber: accountNumber, vendorNumber: vendor, connectedAt: CustomerReview.isoString(now), credentialId: credentialId))
                            return [.put(namespace: "sales_connection", key: account.id, json: next.json.data)]
                        }
                    }
                } catch {
                    if let installed { _ = try? writer.removeCredential(key, root: root, expected: token, expectedVersion: installed.credentialVersion) }
                    credentialSnapshot = nil
                    if error is ReporterSetupFailure || error is AccountFailure || error is PasswordVaultStorage.Failure || error is CancellationError { throw error }
                    throw ReporterSetupFailure.storage
                }
                if let installed { acceptCredential(installed, key: key, writer: writer) }
                if let previous = baseline.connection?.reporter {
                    let oldKey = "reporter:\(previous.credentialId)", value = installed?.snapshot.vault.entries[oldKey]
                    if let removed = try? writer.removeCredential(oldKey, root: root, expected: value) { acceptCredential(removed, key: oldKey, writer: writer) }
                }
                return .connected(try readReportingState(accountId: account.id))
            }
        } catch FileMutex.Failure.timeout { throw ReporterSetupFailure.busy }
    }
    /// Disconnect saves metadata first; a failed credential removal restores the prior connection while holding its mutex.
    public func disconnectReporter(account: Account, appId: String, baseline: ReportingConnectionState, writer: VaultWriter) throws -> ReportingConnectionState {
        do {
            return try FileMutex.withLock(reportingMutex(accountId: account.id)) {
                try requireReportingScope(account, appId: appId); try requireReportingState(baseline, accountId: account.id)
                guard let connection = baseline.connection, let reporter = connection.reporter else { return baseline }
                let key = "reporter:\(reporter.credentialId)"
                let token: String?
                do { token = try credentialCapture(key, writer: writer, allowMissing: true) }
                catch { if error is PasswordVaultStorage.Failure { throw error }; throw ReporterSetupFailure.keychain }
                let version = credentialVersions[key]
                try storeAccess { store in
                    try store.transaction { _ in
                        try requireReportingScope(account, appId: appId); try requireReportingState(baseline, accountId: account.id)
                        return [.put(namespace: "sales_connection", key: account.id, json: ReportingConnection(accountId: account.id, vendorNumber: connection.vendorNumber, reporter: nil).json.data)]
                    }
                }
                do { acceptCredential(try writer.removeCredential(key, root: root, expected: token, expectedVersion: version), key: key, writer: writer) }
                catch {
                    try storeAccess { store in try store.transaction { read in
                        guard try read("sales_connection", account.id)?.revision == baseline.revision + 1 else { throw ReporterSetupFailure.changed }
                        return [.put(namespace: "sales_connection", key: account.id, json: connection.json.data)]
                    } }
                    credentialSnapshot = nil; credentialFailures.insert(key)
                    if error is PasswordVaultStorage.Failure { throw error }; throw ReporterSetupFailure.keychain
                }
                return try readReportingState(accountId: account.id)
            }
        } catch FileMutex.Failure.timeout { throw ReporterSetupFailure.busy }
    }
}
