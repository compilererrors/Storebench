import Foundation

/// A backup editor keeps its save revision until the user explicitly chooses a newly read baseline.
public struct BackupSettingsEditor: Sendable {
    public struct Inputs: Sendable {
        public var enabled = false
        public var destination = ""
        public var intervalHours = 24
        public var retain = 7
        public init() {}
        init(_ value: BackupSettings) { enabled = value.enabled; destination = value.destination; intervalHours = value.intervalHours; retain = value.retain }
        func matches(_ value: BackupSettings) -> Bool {
            enabled == value.enabled && TextSemantics.same(destination, value.destination) && intervalHours == value.intervalHours && retain == value.retain
        }
    }
    public struct Change: Sendable, Identifiable, Equatable {
        public let id, label, saved, edited: String
    }
    public struct SaveIntent: Sendable {
        public let revision: String, inputs: Inputs, passphrase, confirmation: String?, selectedFolder: BackupFolderSelection?
    }
    public private(set) var saved: BackupSettings?
    public private(set) var latest: BackupSettings?
    public private(set) var status: BackupStatus?
    public private(set) var selectedFolder: BackupFolderSelection?
    public var inputs = Inputs()
    public var passphrase = "", confirmation = ""
    public init() {}
    public var ready: Bool { saved != nil }
    public var dirty: Bool { saved.map { !inputs.matches($0) || selectedFolder != nil || !passphrase.isEmpty || !confirmation.isEmpty } ?? false }
    public var canSave: Bool { (try? saveIntent()) != nil }
    public var canRun: Bool { ready && !dirty && latest == nil && saved?.enabled == true && saved?.hasPassphrase == true && saved?.destination.isEmpty == false }
    public mutating func load(_ value: BackupSettings) {
        guard saved == nil else { return }
        saved = value; inputs = Inputs(value)
    }
    public mutating func receiveStatus(_ value: BackupStatus) { status = value }
    public mutating func readLatest(_ value: BackupSettings) throws {
        guard ready else { throw BackupSettingsFailure.invalid("Read backup settings before comparing a newer save.") }
        latest = value
    }
    public mutating func chooseLatest(keepEdits: Bool) {
        guard let latest else { return }
        saved = latest
        if !keepEdits { inputs = Inputs(latest); selectedFolder = nil; passphrase = ""; confirmation = "" }
        self.latest = nil
    }
    public mutating func chooseFolder(_ value: BackupFolderSelection) { selectedFolder = value; inputs.destination = value.url.path }
    public mutating func acknowledgeSave(_ value: BackupSettings) {
        saved = value; inputs = Inputs(value); latest = nil; selectedFolder = nil; passphrase = ""; confirmation = ""
    }
    public func saveIntent() throws -> SaveIntent {
        guard let saved else { throw BackupSettingsFailure.invalid("Read backup settings before saving changes.") }
        guard BackupSettings.intervals.contains(inputs.intervalHours), (1...100).contains(inputs.retain), inputs.destination.utf16.count <= 4096,
              !inputs.destination.utf8.contains(0), inputs.destination.isEmpty || inputs.destination.hasPrefix("/") else { throw BackupSettingsFailure.invalid("Choose a supported schedule and an absolute backup folder path.") }
        if !passphrase.isEmpty || !confirmation.isEmpty {
            guard (12...256).contains(passphrase.utf16.count), TextSemantics.same(passphrase, confirmation) else { throw BackupSettingsFailure.invalid("Enter the same restore passphrase twice, between 12 and 256 characters.") }
        }
        guard !inputs.enabled || !inputs.destination.isEmpty && (saved.hasPassphrase || !passphrase.isEmpty) else { throw BackupSettingsFailure.invalid("Choose a backup folder and set a restore passphrase before enabling backups.") }
        return SaveIntent(revision: saved.revision, inputs: inputs, passphrase: passphrase.isEmpty ? nil : passphrase, confirmation: confirmation.isEmpty ? nil : confirmation, selectedFolder: selectedFolder)
    }
    public var changes: [Change]? {
        guard let latest else { return nil }
        var rows: [Change] = [
            .init(id: "enabled", label: "Automatic backups", saved: latest.enabled ? "On" : "Off", edited: inputs.enabled ? "On" : "Off"),
            .init(id: "destination", label: "Backup folder", saved: latest.destination.isEmpty ? "Not set" : latest.destination, edited: inputs.destination.isEmpty ? "Not set" : inputs.destination),
            .init(id: "interval", label: "Interval", saved: "\(latest.intervalHours) hours", edited: "\(inputs.intervalHours) hours"),
            .init(id: "retain", label: "Retained backups", saved: String(latest.retain), edited: String(inputs.retain))
        ]
        if !passphrase.isEmpty { rows.append(.init(id: "passphrase", label: "Restore passphrase", saved: latest.hasPassphrase ? "Saved securely" : "Not set", edited: "New passphrase entered (hidden)")) }
        return rows.filter { !TextSemantics.same($0.saved, $0.edited) }
    }
}

extension WorkspaceSession {
    /// Read only configuration metadata; unavailable folder grants never prevent reviewing or disabling the schedule.
    public func backupSettings() throws -> BackupSettings {
        try requireSessionAccess()
        return try FileMutex.withLock(root.appendingPathComponent("backup-settings.mutex")) { try requireSessionAccess(); try Task.checkCancellation(); return try BackupSchedule.read(root: root) }
    }
    public func saveBackupSettings(_ intent: BackupSettingsEditor.SaveIntent, writer: VaultWriter, folderAccess: BackupFolderAccess = .system) throws -> BackupSettings {
        try requireSessionAccess()
        guard LocalPaths.lexical(writer.directory) == LocalPaths.lexical(root.appendingPathComponent("credential-state")) else { throw BackupSettingsFailure.storage }
        return try BackupSchedule.save(root: root, writer: writer, revision: intent.revision, enabled: intent.inputs.enabled, destination: intent.inputs.destination,
            intervalHours: intent.inputs.intervalHours, retain: intent.inputs.retain, passphrase: intent.passphrase, confirmation: intent.confirmation,
            selectedFolder: intent.selectedFolder, folderAccess: folderAccess, check: { try self.requireSessionAccess(); try Task.checkCancellation() })
    }
}
