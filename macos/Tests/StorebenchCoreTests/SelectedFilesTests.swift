import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SelectedFilesTests {
    init() throws { _ = try TestIsolation.require() }
    private func directory() throws -> URL {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-selected-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func append(_ data: Data, to url: URL) throws {
        let writer = try FileHandle(forWritingTo: url); defer { try? writer.close() }
        try writer.seekToEnd(); try writer.write(contentsOf: data)
    }

    @Test func dialogDismissalCannotLoseOrReplaceTheSelectedTarget() {
        var choice = FileDialogSelection<String>()
        let firstStarted = choice.begin("synthetic-first")
        #expect(firstStarted)
        choice.isPresented = false
        #expect(choice.pending)
        let replaced = choice.begin("synthetic-second")
        #expect(!replaced)
        let firstFinished = choice.finish()
        #expect(firstFinished == "synthetic-first")
        let duplicate = choice.finish()
        #expect(!choice.pending && !choice.isPresented && duplicate == nil)
        let secondStarted = choice.begin("synthetic-second")
        #expect(secondStarted)
        let secondFinished = choice.finish()
        #expect(secondFinished == "synthetic-second")
    }

    @Test func cancellationClearsOnlyTheFinishedSelectionAndReleasesBusyProtection() {
        var choice = FileDialogSelection<String>()
        var policy = EditorProtectionPolicy()
        choice.begin("synthetic-cancelled")
        choice.isPresented = false
        policy.update(id: "synthetic-file-picker", dirty: false, busy: choice.pending)
        #expect(policy.decision == .wait)
        _ = choice.finish()
        policy.update(id: "synthetic-file-picker", dirty: false, busy: choice.pending)
        #expect(policy.decision == .ready)
        let followingStarted = choice.begin("synthetic-following")
        #expect(followingStarted)
        let followingFinished = choice.finish()
        #expect(followingFinished == "synthetic-following")
    }

    @Test func productionLimitsAndExactByteBoundariesRemainIntact() throws {
        #expect(SelectedFiles.Purpose.transfer.limits.fileBytes == 4_000_000)
        #expect(SelectedFiles.Purpose.screenshots.limits.fileBytes == 20_000_000)
        #expect(SelectedFiles.Purpose.screenshots.limits.totalBytes == 50_000_000)
        #expect(SelectedFiles.Purpose.screenshots.limits.files == 10)
        #expect(SelectedFiles.Purpose.encryptionDocument.limits.fileBytes == StagedEncryptionDocument.maximumBytes)
        #expect(StagedEncryptionDocument.maximumBytes == 50_000_000)
        #expect(SelectedFiles.Purpose.reviewAttachment.limits.fileBytes == 50_000_000)
        #expect(SelectedFiles.Purpose.reviewAttachment.limits.totalBytes == 50_000_000)
        #expect(SelectedFiles.Purpose.reviewAttachment.limits.files == 1)
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"), bytes = Data(String(repeating: "🧪", count: 8).utf8)
        try bytes.write(to: file)
        let limits = SelectedFiles.Limits(fileBytes: 32, totalBytes: 32, files: 1)
        #expect(try SelectedFiles.readFixture([file], limits: limits, afterMetadata: { _ in }).first?.data == bytes)
        try append(Data([65]), to: file)
        #expect(throws: SelectedFiles.Failure.fileSize) { try SelectedFiles.readFixture([file], limits: limits, afterMetadata: { _ in Issue.record("Oversized file reached the reader") }) }
        try Data().write(to: file)
        #expect(throws: SelectedFiles.Failure.fileSize) { try SelectedFiles.read([file], purpose: .transfer) }
        #expect(throws: SelectedFiles.Failure.count) { try SelectedFiles.read([], purpose: .transfer) }
        #expect(throws: SelectedFiles.Failure.count) { try SelectedFiles.read([file, file], purpose: .transfer) }
    }

    @Test func actualGrowthCannotExceedEitherTheFileOrBatchLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin"), second = root.appendingPathComponent("second.bin")
        try Data(repeating: 65, count: 16).write(to: first)
        #expect(throws: SelectedFiles.Failure.fileSize) {
            try SelectedFiles.readFixture([first], limits: .init(fileBytes: 32, totalBytes: 64, files: 1)) { url in
                try append(Data(repeating: 66, count: 17), to: url)
            }
        }
        try Data(repeating: 65, count: 16).write(to: first); try Data(repeating: 66, count: 16).write(to: second)
        #expect(throws: SelectedFiles.Failure.batchSize) {
            try SelectedFiles.readFixture([first, second], limits: .init(fileBytes: 64, totalBytes: 40, files: 2)) { url in
                if url == second { try append(Data(repeating: 67, count: 16), to: url) }
            }
        }
        try Data(repeating: 65, count: 8).write(to: first)
        let within = try SelectedFiles.readFixture([first], limits: .init(fileBytes: 16, totalBytes: 16, files: 1)) { url in
            try append(Data(repeating: 66, count: 8), to: url)
        }
        #expect(within.first?.data == Data(repeating: 65, count: 8) + Data(repeating: 66, count: 8))
    }

    @Test func anOpenedDescriptorDoesNotSwitchToAReplacementPath() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"), original = Data("original synthetic bytes".utf8), replacement = Data("replacement synthetic bytes".utf8)
        try original.write(to: file)
        let result = try SelectedFiles.readFixture([file], limits: .init(fileBytes: 128, totalBytes: 128, files: 1)) { url in
            let incoming = root.appendingPathComponent("synthetic-replacement.txt")
            try replacement.write(to: incoming)
            #expect(rename(incoming.path, url.path) == 0)
        }
        #expect(result.first?.name == "synthetic.txt" && result.first?.data == original)
        #expect(try Data(contentsOf: file) == replacement)
        #expect(throws: SelectedFiles.Failure.fileSize) {
            try SelectedFiles.readFixture([file], limits: .init(fileBytes: 128, totalBytes: 128, files: 1)) { url in try Data().write(to: url) }
        }
    }

    @Test func linksPipesDirectoriesAndForeignLocationsFailBeforeReading() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"), link = root.appendingPathComponent("synthetic-link"), fifo = root.appendingPathComponent("synthetic-pipe")
        try Data("synthetic".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for invalid in [link, fifo, root] { #expect(throws: SelectedFiles.Failure.read) { try SelectedFiles.read([invalid], purpose: .transfer) } }
        let outside = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("synthetic-outside.txt")
        #expect(throws: TestIsolation.Failure.self) { try SelectedFiles.read([outside], purpose: .transfer) }
        #expect(throws: SelectedFiles.Failure.read) { try SelectedFiles.read([URL(string: "https://example.com/synthetic.txt")!], purpose: .transfer) }
    }

    @Test func cancellationBeforeOrDuringReadingCannotReturnACompletedBatch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"); try Data("synthetic".utf8).write(to: file)
        let early = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await SelectedFiles.readAsync([file], purpose: .transfer) }
        await #expect(throws: CancellationError.self) { try await early.value }
        let during = Task {
            try SelectedFiles.readFixture([file], limits: .init(fileBytes: 32, totalBytes: 32, files: 1)) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { try await during.value }
        #expect(try await SelectedFiles.readAsync([file], purpose: .transfer).first?.data == Data("synthetic".utf8))
    }

    @Test @MainActor func progressOnlyCompletesAValidWholeBatch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("synthetic-first.png"), second = root.appendingPathComponent("synthetic-second.png")
        let bytes = Data(repeating: 7, count: 180_000)
        try bytes.write(to: first); try bytes.write(to: second)
        var updates: [SelectedFiles.ReadProgress] = []
        let files = try await SelectedFiles.readAsync([first, second], purpose: .screenshotEditing) { updates.append($0) }
        let final = try #require(updates.last)
        #expect(files.count == 2 && final.completedFiles == 2 && final.totalFiles == 2 && final.bytesRead == bytes.count * 2 && final.fraction == 1)
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.bytesRead <= $1.bytesRead && $0.fraction <= $1.fraction })
        try Data().write(to: second); updates = []
        await #expect(throws: SelectedFiles.Failure.fileSize) {
            try await SelectedFiles.readAsync([first, second], purpose: .screenshotEditing) { updates.append($0) }
        }
        #expect(!updates.isEmpty && updates.allSatisfy { $0.completedFiles < 2 && $0.fraction < 1 })
    }

    @Test @MainActor func cancellingFromProgressCannotReturnFilesOrCompleteTheSelection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-progress.bin")
        try Data(repeating: 4, count: 2_000_000).write(to: file)
        let read = Task {
            try await SelectedFiles.readAsync([file], purpose: .transfer) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test func boundedUtf8ReadsPreserveTransferFormatsAndRejectRepairedText() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let table = Delimited.Table(columns: Transfer.columns[.languages]!, rows: [["1000000001", "synthetic-version", "sv", "version", "description", "=Synthetic Café 🧪\n\"quoted\""]])
        for format in TransferFormat.allCases {
            let file = root.appendingPathComponent("synthetic.\(format.rawValue)"), text = Transfer.text(.languages, table, format: format)
            try Data(("\u{FEFF}" + text).utf8).write(to: file)
            let bytes = try await SelectedFiles.readAsync([file], purpose: .transfer)[0].data
            #expect(try Transfer.parse(.languages, SelectedFiles.text(bytes), format: format) == table)
        }
        #expect(try SelectedFiles.text(Data("\u{FEFF}synthetic\u{FEFF}text".utf8)) == "synthetic\u{FEFF}text")
        #expect(throws: SelectedFiles.Failure.encoding) { try SelectedFiles.text(Data([0xf0, 0x28, 0x8c, 0xbc])) }
    }

    @Test func aPdfReadCannotSilentlyReplaceANewerStagedRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.pdf"), account = try #require(try await session.accounts().first)
        let app = "1000000001", declaration = "synthetic-declaration", candidate = Data("%PDF-1.7 synthetic candidate".utf8)
        try candidate.write(to: file)
        let baseline = try await session.stagedEncryptionDocument(accountId: account.id, appId: app, declarationId: declaration)?.revision ?? 0
        let newer = try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: declaration, expectedRevision: baseline,
                                                             fileName: "newer.pdf", data: Data("%PDF-1.7 synthetic newer".utf8))
        let input = try await SelectedFiles.readAsync([file], purpose: .encryptionDocument)[0]
        await #expect(throws: PublishFailure.self) {
            try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: declaration, expectedRevision: baseline, fileName: input.name, data: input.data)
        }
        await #expect(throws: PublishFailure.self) {
            try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: declaration, expectedRevision: newer.revision, fileName: "invalid.pdf", data: Data("synthetic non-PDF".utf8))
        }
        #expect(try await session.stagedEncryptionDocument(accountId: account.id, appId: app, declarationId: declaration) == newer)
    }
}
