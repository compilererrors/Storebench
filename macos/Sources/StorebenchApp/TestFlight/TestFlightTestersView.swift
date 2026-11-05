import AppKit
import StorebenchCore
import SwiftUI

struct TestFlightTestersView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var working = false
    @State private var preparing = false
    @State private var publishing = false
    @State private var testers: [TestFlightTester] = []
    @State private var state = "loading"
    @State private var review: PublishReview?
    @State private var status = ""
    @State private var email = ""
    @State private var activeEmail = ""
    @State private var currentCursor: String?
    @State private var nextCursor: String?

    @Environment(\.navigationPresentation) private var history
    private struct Choices: Equatable { var email, activeEmail: String; var pageCursor: String? }
    private struct Read: Codable { let activeEmail: String, pageCursor: String?, testers: [TestFlightTester], next: String? }
    private var readKey: String { "testflight-testers/\(account.id)/\(app.id)" }
    private var busy: Bool { working || preparing || publishing }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { Task { await load(cursor: currentCursor) } } }, busyChanged: { publishing = $0 }).storebenchWorking(working || preparing)
            Card(title: "Find a tester", subtitle: "Search Apple's testers within this app by exact email, or clear the filter to see all app testers.") {
                StorebenchInputActions {
                    StorebenchTextField("Tester email", text: $email)
                } actions: {
                    StorebenchFlow(spacing: 8) {
                    Button("Find Tester") { Task { await load(emailFilter: email) } }.fixedSize()
                    if !email.isEmpty || !activeEmail.isEmpty { Button("Clear Filter") { email = ""; Task { await load(emailFilter: "") } }.fixedSize() }
                    Button("Refresh") { Task { await load(cursor: currentCursor) } }.fixedSize()
                    }
                }
            }
            .storebenchWorking(busy)
            Card(title: "All Testers", subtitle: state == "ready" ? "\(testers.count) testers on this page. Each change requires a separate Publish review." : "Testers in this app, including group and direct build access.") {
                switch state {
                case "failed": Text(status).foregroundStyle(StorebenchTheme.muted)
                case "ready" where testers.isEmpty:
                    Text(currentCursor != nil ? "No testers on this page. Return to the first page to check current app access." : activeEmail.isEmpty ? "No testers for this app. Add testers from Groups or invite them to an eligible build." : "No tester with this email. Check the address or clear the filter.").foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                case "ready":
                    StorebenchCollection(items: testers, title: { $0.email }, subtitle: { $0.name + " · " + AppStoreNames.state($0.state) }, empty: "No testers for this app.") { tester in
                        StorebenchFormFooter {

                                if tester.canSendInvitation {
                                    Button(tester.state == "INVITED" ? "Resend Invite" : "Send Invite") { Task { await prepare { $0.testflightAction = "send-invitation"; $0.testerId = tester.id } } }.fixedSize()
                                }
                                Button("Remove from App", role: .destructive) { Task { await prepare { $0.testflightAction = "remove-app-tester"; $0.testerId = tester.id } } }.fixedSize()
                        }
                    }
                default: StorebenchCollectionPlaceholder()
                }
                if currentCursor != nil || (state == "ready" && nextCursor != nil) {
                    HStack(spacing: 12) {
                        if currentCursor != nil { Button("First Page") { Task { await load() } }.fixedSize() }
                        if state == "ready", let nextCursor { Button("Next Page") { Task { await load(cursor: nextCursor) } }.fixedSize() }
                        Spacer()
                    }
                }
                if !status.isEmpty && state != "failed" { Text(status).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            .storebenchWorking(busy)
        }
        .task {
            // Back returns to the same filter and page; the page last read shows while it is read again.
            if testers.isEmpty, let read = history?.rememberedRead(readKey, as: Read.self), read.activeEmail == activeEmail, read.pageCursor == currentCursor { testers = read.testers; nextCursor = read.next; state = "ready" }
            await load(cursor: currentCursor)
        }
        .historyValue("testflight-testers", Binding(get: { Choices(email: email, activeEmail: activeEmail, pageCursor: currentCursor) }, set: { email = $0.email; activeEmail = $0.activeEmail; currentCursor = $0.pageCursor }))
        .trackUnsavedChanges(false, busy: busy)
    }

    private func prepare(_ configure: (inout PublishRequest) -> Void) async {
        guard !busy else { return }
        preparing = true; defer { preparing = false }
        (review, status) = await prepareTestFlight(account, app, session, configure)
    }

    private func load(cursor: String? = nil, emailFilter: String? = nil) async {
        guard !working, let session else { return }
        let filter: String
        do { filter = try TestFlightAppTesters.emailFilter(emailFilter ?? activeEmail) }
        catch let failure as PublishFailure { status = failure.message; return }
        catch { status = "Check the tester email or clear the filter."; return }
        working = true; defer { working = false }
        let samePage = state == "ready" && filter == activeEmail && cursor == currentCursor
        if !samePage { state = "loading"; nextCursor = nil }
        status = ""; activeEmail = filter; currentCursor = cursor
        do {
            let page = try await session.testFlightTesterPage(appId: app.id, email: filter, cursor: cursor, client: try await session.client(for: account))
            testers = page.testers; nextCursor = page.next; state = "ready"
            history?.rememberRead(Read(activeEmail: filter, pageCursor: cursor, testers: page.testers, next: page.next), readKey)
        } catch { status = "TestFlight testers could not be loaded. Refresh to retry, or return to the first page."; state = "failed" }
    }
}
