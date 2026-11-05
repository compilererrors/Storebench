import Darwin
import Foundation

/// A separate workspace of synthetic apps for exploring Storebench before connecting Apple.
/// It lives in its own folder beside the data folder, opens with a key held only in memory,
/// and is discarded when it closes. It has no credentials, so nothing in it can reach Apple.
public enum SampleWorkspace {
    public enum Failure: Error, Equatable {
        case sample, busy
        public var message: String {
            switch self {
            case .sample: "Sample data is not connected to Apple. Close sample data to use your own workspace."
            case .busy: "Sample data is already open in another Storebench window."
            }
        }
    }

    public static let accountId = "sample"

    /// `Storebench Sample` beside the data folder, so backups of the data folder never include it.
    public static func container(beside root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + " Sample", isDirectory: true)
    }

    struct Opened {
        let session: WorkspaceSession, lock: FileMutex.Held, root: URL
    }

    /// Replaces any earlier sample folder with a freshly filled one. The permanent `sample.mutex` beside it is held
    /// while the sample is open, so only its owner ever creates or removes the folder.
    static func open(beside root: URL, now: Date = Date()) async throws -> Opened {
        let container = container(beside: root), workspaceRoot = container.appendingPathComponent("workspace", isDirectory: true)
        try TestIsolation.check(container)
        if mkdir(container.path, 0o700) != 0 && errno != EEXIST { throw Setup.Failure.notPrivate }
        guard let lock = try FileMutex.tryLock(container.appendingPathComponent("sample.mutex")) else { throw Failure.busy }
        let session: WorkspaceSession
        do {
            try remove(workspaceRoot)
            var key = try Setup.random(32)
            defer { key.resetBytes(in: 0..<key.count) }
            let directory = try Setup.privateDirectory(root: workspaceRoot)
            try Setup.replaceGeneration(directory)
            _ = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: workspaceRoot), key: key, create: true)
            let record = try KeyEnvelope.wrap(key, password: nil).record(ready: true)
            let vault = try CredentialVault(json: JSONText.object([("version", .number(1)),
                                                                   ("entries", .object([(CredentialVault.databaseEntry(root: workspaceRoot), .string(record))]))]).data)
            session = try WorkspaceSession(workspace: Workspace(root: workspaceRoot), vault: vault, password: nil, credentialWriter: nil, sample: true)
        } catch { try? remove(workspaceRoot); lock.release(); throw error }
        do { try await session.fillSample(now: now) }
        catch { try? await session.signOut(); try? remove(workspaceRoot); lock.release(); throw error }
        return Opened(session: session, lock: lock, root: workspaceRoot)
    }

    /// Call after the sample session has closed.
    static func discard(_ opened: Opened) {
        try? remove(opened.root)
        opened.lock.release()
    }

    private static func remove(_ url: URL) throws {
        try TestIsolation.check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Synthetic content

    struct App {
        let id, name, bundleId, sku, platform: String
        let locales: [String]
        /// Listing changes, oldest first: days before today, version, subtitle, keywords, description and What's New per change.
        let changes: [Change]
        let territories: [(sales: String, analytics: String, weight: Double)]
        let dailyFirstDownloads: Double, paidShare: Double
    }
    struct Change {
        let daysAgo: Int, version: String, subtitle: String, keywords: String, description: String, whatsNew: String, promotional: String
        /// The lift this change gives impressions and downloads afterwards.
        let lift: Double
    }

    static let apps: [App] = [
        App(id: "1000000001", name: "Driftwood Journal", bundleId: "com.example.driftwood", sku: "DRIFTWOOD", platform: "IOS",
            locales: ["en-US", "de-DE", "sv-SE"],
            changes: [
                Change(daysAgo: 88, version: "2.2", subtitle: "A private daily journal", keywords: "journal,diary,notes,private,writing",
                       description: "Driftwood Journal is a calm place to write every day.\n\nKeep entries private on your device, add photos and look back on any day.",
                       whatsNew: "Bug fixes and improvements.", promotional: "Your private journal.", lift: 1),
                Change(daysAgo: 52, version: "2.3", subtitle: "Daily journal & mood diary", keywords: "journal,diary,mood,tracker,prompts,private",
                       description: "Driftwood Journal is a calm place to write every day.\n\nTrack your mood, keep entries private on your device and look back on any day.",
                       whatsNew: "Mood tracking: tag each entry and see how your week felt.", promotional: "New: track your mood with every entry.", lift: 1.18),
                Change(daysAgo: 21, version: "2.4", subtitle: "Daily journal & mood diary", keywords: "journal,diary,mood,prompts,gratitude,habit",
                       description: "Start writing in seconds with a daily prompt.\n\nDriftwood Journal keeps your entries and moods private on your device. Pin favourite entries, search by mood and export any month to PDF.",
                       whatsNew: "Pin journal entries, search by mood and export to PDF.", promotional: "New: daily prompts that help you start writing.", lift: 1.32),
            ],
            territories: [("USA", "US", 0.42), ("GBR", "GB", 0.18), ("DEU", "DE", 0.16), ("SWE", "SE", 0.12), ("JPN", "JP", 0.12)],
            dailyFirstDownloads: 140, paidShare: 0.09),
        App(id: "1000000002", name: "Tidepool Timer", bundleId: "com.example.tidepool", sku: "TIDEPOOL", platform: "MAC_OS",
            locales: ["en-US", "fr-FR"],
            changes: [
                Change(daysAgo: 75, version: "1.6", subtitle: "Focus timer for your desk", keywords: "timer,focus,pomodoro,menu bar",
                       description: "Tidepool Timer keeps focus sessions in your menu bar.\n\nChoose a length, start a session and take a short break when the tide turns.",
                       whatsNew: "Bug fixes and improvements.", promotional: "Calm focus sessions in your menu bar.", lift: 1),
                Change(daysAgo: 30, version: "1.7", subtitle: "Pomodoro focus in the menu bar", keywords: "pomodoro,focus,timer,menu bar,break,productivity",
                       description: "Tidepool Timer keeps pomodoro sessions in your menu bar.\n\nPlan your day in focus blocks, see weekly totals and get a gentle reminder to take a break.",
                       whatsNew: "Weekly focus totals and gentle break reminders.", promotional: "New: weekly focus totals.", lift: 1.24),
            ],
            territories: [("USA", "US", 0.48), ("FRA", "FR", 0.2), ("GBR", "GB", 0.17), ("CAN", "CA", 0.15)],
            dailyFirstDownloads: 45, paidShare: 0.22),
    ]

    static let account = Account(id: accountId, name: "Sample data", keyId: "SAMPLE0000", keyType: "individual", issuerId: nil,
                                 appIds: apps.map(\.id), appNames: Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.name) }))

    /// Synthetic translations of the English sample text; anything without one stays in English.
    static let translations: [String: [String: String]] = [
        "de-DE": [
            "A private daily journal": "Dein privates Tagebuch",
            "Daily journal & mood diary": "Tagebuch & Stimmungen",
            "Your private journal.": "Dein privates Tagebuch.",
            "New: track your mood with every entry.": "Neu: Halte bei jedem Eintrag deine Stimmung fest.",
            "New: daily prompts that help you start writing.": "Neu: Tägliche Impulse für den Einstieg ins Schreiben.",
            "Bug fixes and improvements.": "Fehlerbehebungen und Verbesserungen.",
            "Mood tracking: tag each entry and see how your week felt.": "Stimmungen: Markiere Einträge und sieh, wie sich deine Woche angefühlt hat.",
            "Pin journal entries, search by mood and export to PDF.": "Einträge anheften, nach Stimmung suchen und als PDF exportieren.",
            "Driftwood Journal is a calm place to write every day.\n\nKeep entries private on your device, add photos and look back on any day.":
                "Driftwood Journal ist ein ruhiger Ort zum täglichen Schreiben.\n\nDeine Einträge bleiben privat auf deinem Gerät. Füge Fotos hinzu und blicke auf jeden Tag zurück.",
            "Driftwood Journal is a calm place to write every day.\n\nTrack your mood, keep entries private on your device and look back on any day.":
                "Driftwood Journal ist ein ruhiger Ort zum täglichen Schreiben.\n\nHalte deine Stimmung fest, behalte Einträge privat auf deinem Gerät und blicke auf jeden Tag zurück.",
            "Start writing in seconds with a daily prompt.\n\nDriftwood Journal keeps your entries and moods private on your device. Pin favourite entries, search by mood and export any month to PDF.":
                "Beginne in Sekunden mit einem täglichen Impuls.\n\nDriftwood Journal bewahrt Einträge und Stimmungen privat auf deinem Gerät. Hefte Lieblingseinträge an, suche nach Stimmung und exportiere jeden Monat als PDF.",
        ],
        "sv-SE": [
            "A private daily journal": "Din privata dagbok",
            "Daily journal & mood diary": "Dagbok & humördagbok",
            "Your private journal.": "Din privata dagbok.",
            "New: track your mood with every entry.": "Nytt: följ ditt humör i varje anteckning.",
            "New: daily prompts that help you start writing.": "Nytt: dagliga skrivförslag som hjälper dig komma igång.",
            "Bug fixes and improvements.": "Felrättningar och förbättringar.",
            "Mood tracking: tag each entry and see how your week felt.": "Humör: tagga varje anteckning och se hur veckan kändes.",
            "Pin journal entries, search by mood and export to PDF.": "Fäst anteckningar, sök på humör och exportera till PDF.",
            "Driftwood Journal is a calm place to write every day.\n\nKeep entries private on your device, add photos and look back on any day.":
                "Driftwood Journal är en lugn plats att skriva varje dag.\n\nAnteckningarna stannar privat på din enhet. Lägg till bilder och se tillbaka på vilken dag som helst.",
            "Driftwood Journal is a calm place to write every day.\n\nTrack your mood, keep entries private on your device and look back on any day.":
                "Driftwood Journal är en lugn plats att skriva varje dag.\n\nFölj ditt humör, håll anteckningarna privata på din enhet och se tillbaka på vilken dag som helst.",
            "Start writing in seconds with a daily prompt.\n\nDriftwood Journal keeps your entries and moods private on your device. Pin favourite entries, search by mood and export any month to PDF.":
                "Börja skriva på några sekunder med ett dagligt skrivförslag.\n\nDriftwood Journal håller anteckningar och humör privata på din enhet. Fäst favoriter, sök på humör och exportera valfri månad till PDF.",
        ],
        "fr-FR": [
            "Focus timer for your desk": "Minuteur de concentration",
            "Pomodoro focus in the menu bar": "Pomodoro dans la barre",
            "Calm focus sessions in your menu bar.": "Des sessions de concentration dans votre barre des menus.",
            "New: weekly focus totals.": "Nouveau : vos totaux de concentration par semaine.",
            "Bug fixes and improvements.": "Corrections de bugs et améliorations.",
            "Weekly focus totals and gentle break reminders.": "Totaux hebdomadaires et rappels de pause en douceur.",
            "Tidepool Timer keeps focus sessions in your menu bar.\n\nChoose a length, start a session and take a short break when the tide turns.":
                "Tidepool Timer garde vos sessions de concentration dans la barre des menus.\n\nChoisissez une durée, lancez une session et faites une courte pause quand la marée tourne.",
            "Tidepool Timer keeps pomodoro sessions in your menu bar.\n\nPlan your day in focus blocks, see weekly totals and get a gentle reminder to take a break.":
                "Tidepool Timer garde vos sessions pomodoro dans la barre des menus.\n\nPlanifiez votre journée en blocs, consultez vos totaux de la semaine et recevez un rappel de pause.",
        ],
    ]

    static func localized(_ text: String, locale: String) -> String { translations[locale]?[text] ?? text }

    static func revision(_ app: App, through index: Int, now: Date) -> (id: String, json: JSONText, importedAt: String) {
        let change = app.changes[index], id = UUID().uuidString.lowercased()
        // Apple's identifiers use only letters, digits, hyphens and underscores.
        let prefix = app.sku.lowercased(), slug = change.version.replacingOccurrences(of: ".", with: "-")
        let importedAt = CustomerReview.isoString(now.addingTimeInterval(-Double(change.daysAgo) * 86_400 + 3_600))
        let created = CustomerReview.isoString(now.addingTimeInterval(-Double(change.daysAgo + 3) * 86_400))
        let infoLocales = app.locales.map { locale in
            JSONText.object([("id", .string("\(prefix)-info-\(locale)")), ("fields", .object([
                ("locale", .string(locale)), ("name", .string(app.name)), ("subtitle", .string(localized(change.subtitle, locale: locale))),
                ("privacyPolicyUrl", .string("https://example.com/\(app.sku.lowercased())/privacy")), ("privacyChoicesUrl", .null), ("privacyPolicyText", .null),
            ]))])
        }
        let versionLocales = app.locales.map { locale in
            JSONText.object([("id", .string("\(prefix)-\(slug)-\(locale)")), ("fields", .object([
                ("locale", .string(locale)), ("description", .string(localized(change.description, locale: locale))),
                ("keywords", .string(change.keywords)), ("marketingUrl", .string("https://example.com/\(app.sku.lowercased())")),
                ("promotionalText", .string(localized(change.promotional, locale: locale))), ("supportUrl", .string("https://example.com/\(app.sku.lowercased())/support")),
                ("whatsNew", index == 0 ? .null : .string(localized(change.whatsNew, locale: locale))),
            ])), ("screenshotSets", .array([]))])
        }
        let version = JSONText.object([("id", .string("\(prefix)-version-\(slug)")), ("fields", .object([
            ("platform", .string(app.platform)), ("versionString", .string(change.version)), ("appStoreState", .string("READY_FOR_SALE")),
            ("appVersionState", .string("READY_FOR_DISTRIBUTION")), ("copyright", .string("2026 Example Studio")), ("createdDate", .string(created)),
        ])), ("localizations", .array(versionLocales))])
        let json = JSONText.object([
            ("schemaVersion", .number(1)), ("id", .string(id)), ("importedAt", .string(importedAt)),
            ("account", .object([("id", .string(accountId)), ("name", .string(account.name))])),
            ("app", .object([("id", .string(app.id)), ("name", .string(app.name)), ("bundleId", .string(app.bundleId)), ("sku", .string(app.sku)), ("primaryLocale", .string("en-US"))])),
            ("appInfos", .array([.object([("id", .string("\(prefix)-info")), ("fields", .object([("appStoreState", .string("READY_FOR_SALE")), ("state", .string("READY_FOR_DISTRIBUTION"))])),
                                          ("localizations", .array(infoLocales))])])),
            ("versions", .array([version])),
        ])
        return (id, json, importedAt)
    }

    /// A repeatable wave plus a small deterministic wobble, so charts look like real activity without randomness.
    static func activity(_ app: App, day: Int, daysAgo: Int) -> Double {
        let lift = app.changes.last(where: { $0.daysAgo >= daysAgo })?.lift ?? 1
        let weekly = 1 + 0.12 * sin(Double(day) * 2 * .pi / 7), wobble = 1 + 0.06 * sin(Double(day) * 1.7 + Double(app.id.suffix(1))!)
        return app.dailyFirstDownloads * lift * weekly * wobble
    }

    static func days(now: Date) -> [(date: String, daysAgo: Int, day: Int)] {
        let today = Int(now.timeIntervalSince1970 / 86_400)
        // Apple delivers reports a day or two late, so the newest sample day is two days ago.
        return (2...100).reversed().map { ago in (ReportTables.dayFormat.string(from: Date(timeIntervalSince1970: Double(today - ago) * 86_400)), ago, today - ago) }
    }

    static func salesCsv(_ app: App, now: Date) -> Data {
        var rows: [[String]] = []
        for entry in days(now: now) {
            let total = activity(app, day: entry.day, daysAgo: entry.daysAgo) * app.paidShare
            for territory in app.territories {
                rows.append([app.id, entry.date, entry.date, territory.sales, String(max(0, Int((total * territory.weight).rounded())))])
            }
        }
        return Data(Delimited.write(Delimited.Table(columns: SalesFileFormats.columns, rows: rows)).utf8)
    }

    static func analyticsHistory(_ app: App, now: Date) -> Data {
        let stamp = CustomerReview.isoString(now), device = app.platform == "MAC_OS" ? "Desktop" : "iPhone", os = app.platform == "MAC_OS" ? "macOS 15.4" : "iOS 18.4"
        var partitions: [AnalyticsPartition] = []
        for entry in days(now: now) {
            let first = activity(app, day: entry.day, daysAgo: entry.daysAgo), processing = ReportTables.dayFormat.string(from: Date(timeIntervalSince1970: Double(entry.day + 1) * 86_400))
            var downloads: [[String]] = [], engagement: [[String]] = []
            for territory in app.territories {
                let share = first * territory.weight
                func count(_ value: Double) -> String { String(max(0, Int(value.rounded()))) }
                downloads.append([entry.date, app.name, app.id, device, os, "App Store search", "Product page", territory.analytics, count(share), "First-time Download", app.changes.last!.version, "No"])
                downloads.append([entry.date, app.name, app.id, device, os, "App Store search", "Product page", territory.analytics, count(share * 0.21), "Redownload", app.changes.last!.version, "No"])
                engagement.append([entry.date, app.name, app.id, device, os, "App Store search", "Product page", territory.analytics, count(share * 31), "Impression", "", count(share * 24)])
                engagement.append([entry.date, app.name, app.id, device, os, "App Store search", "Product page", territory.analytics, count(share * 4.6), "Page view", "", count(share * 3.9)])
                engagement.append([entry.date, app.name, app.id, device, os, "App Store search", "Product page", territory.analytics, count(share * 1.15), "Tap", "Get", count(share * 1.1)])
            }
            partitions.append(AnalyticsPartition(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: processing, date: entry.date, importedAt: stamp, segments: 1,
                                                 source: ReportTable(columns: AnalyticsReports.baseColumns + AnalyticsReports.downloadColumns, rows: downloads)))
            partitions.append(AnalyticsPartition(kind: "engagement", level: "standard", granularity: "DAILY", processingDate: processing, date: entry.date, importedAt: stamp, segments: 1,
                                                 source: ReportTable(columns: AnalyticsReports.baseColumns + AnalyticsReports.engagementColumns, rows: engagement)))
        }
        return AnalyticsFileFormats.history(accountId: accountId, appId: app.id, partitions: partitions).data
    }
}

extension WorkspaceSession {
    nonisolated func requireOwnWorkspace() throws {
        if isSample { throw SampleWorkspace.Failure.sample }
    }

    /// Fills a new sample workspace through the same saves as imports: the account, each app's saved listing revisions,
    /// then its sales and Analytics reports.
    func fillSample(now: Date) async throws {
        guard isSample else { throw SampleWorkspace.Failure.sample }
        let account = SampleWorkspace.account
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([Self.json(account)]).data)] }
            }
        }
        for app in SampleWorkspace.apps {
            var writes: [EncryptedDocumentStore.Write] = [], latest: (id: String, importedAt: String)?
            for index in app.changes.indices {
                let revision = SampleWorkspace.revision(app, through: index, now: now)
                writes.append(.put(namespace: "revisions", key: "\(account.id):\(app.id):\(revision.id)", json: revision.json.data))
                latest = (revision.id, revision.importedAt)
            }
            if let latest {
                writes.append(.put(namespace: "latest_imports", key: "\(account.id):\(app.id)",
                                   json: JSONText.object([("schemaVersion", .number(1)), ("revisionId", .string(latest.id)), ("importedAt", .string(latest.importedAt))]).data))
            }
            try storeAccess { store in try store.transaction { _ in writes } }
            _ = try await importSalesFile(account: account, appId: app.id, data: SampleWorkspace.salesCsv(app, now: now), now: now)
            let input = AnalyticsFileInput(files: [SampleWorkspace.analyticsHistory(app, now: now)])
            let review = try previewAnalyticsFiles(account: account, appId: app.id, input: input, now: now)
            _ = try saveAnalyticsFiles(review, input: input, now: now)
        }
    }
}
