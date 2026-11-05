import Foundation

/// Start Testing: getting a build to testers as numbered steps in App Store Connect's words. Each step's status comes from what
/// App Store Connect has now; moving between steps changes nothing at Apple.
public enum TestFlightFlow {
    public enum StepId: String, Sendable, CaseIterable {
        case build, compliance = "export-compliance", information = "test-information", group, testers, betaReview = "beta-app-review"
    }

    /// What App Store Connect returned for the app's TestFlight.
    public struct Facts: Sendable, Equatable {
        public struct Membership: Sendable, Equatable {
            public let builds: [String]
            public let testers: Int
            public init(builds: [String], testers: Int) { self.builds = builds; self.testers = testers }
        }
        public var builds: [TestFlightBuild] = []
        public var groups: [TestFlightGroup] = []
        public var members: [String: Membership] = [:]
        public var localizations: [TestFlightLocalization] = []
        public var review: ReviewInformation?
        /// Steps whose part of App Store Connect could not be read, with the reason. The other steps still show their status.
        public var unread: [StepId: String] = [:]
        public init(builds: [TestFlightBuild] = [], groups: [TestFlightGroup] = [], members: [String: Membership] = [:], localizations: [TestFlightLocalization] = [], review: ReviewInformation? = nil) {
            self.builds = builds; self.groups = groups; self.members = members; self.localizations = localizations; self.review = review
        }

        /// The build the guide follows: the latest processed build.
        public var build: TestFlightBuild? { builds.filter(\.processed).max { $0.uploadedDate < $1.uploadedDate } }
        /// Groups that can install the followed build.
        public var testingGroups: [TestFlightGroup] {
            guard let build else { return [] }
            return groups.filter { $0.hasAccessToAllBuilds == true || members[$0.id]?.builds.contains(build.id) == true }
        }
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public let id: StepId
        public let number: Int
        public let done, current, optional: Bool
        public let needed: [String]
        public var title: String { TestFlightFlow.title(id) }
        public var purpose: String { TestFlightFlow.purpose(id) }
    }

    /// App Store Connect's names for each step.
    public static func title(_ id: StepId) -> String {
        switch id {
        case .build: "Build"
        case .compliance: "Export Compliance"
        case .information: "Test Information"
        case .group: "Group"
        case .testers: "Testers"
        case .betaReview: "Beta App Review"
        }
    }

    public static func purpose(_ id: StepId) -> String {
        switch id {
        case .build: "Upload a build with Xcode or Transporter. It appears here once Apple has processed it."
        case .compliance: "Tell Apple whether the build uses encryption. Testers can install it only after this answer."
        case .information: "What testers see in TestFlight, and who Apple contacts during Beta App Review."
        case .group: "Testers get builds through a group. Internal Testing is for your team; External Testing is for anyone with an email address or a public link."
        case .testers: "Add testers by email to a group that has the build, or turn on the group's public link."
        case .betaReview: "Only for External Testing. Apple reviews the first build of each version before external testers can install it."
        }
    }

    /// What App Store Connect still lacks for a step, one short line each; empty when the step is done.
    public static func needed(_ id: StepId, facts: Facts) -> [String] {
        if let problem = facts.unread[id] { return [problem] }
        let build = facts.build
        let name = build?.title ?? "the build"
        switch id {
        case .build:
            if build != nil { return [] }
            return facts.builds.contains { $0.processingState == "PROCESSING" }
                ? ["Apple is still processing your build. Refresh in a few minutes."]
                : ["Upload a build from Xcode or Transporter."]
        case .compliance:
            guard let build else { return ["Upload a build first."] }
            return build.missingCompliance ? ["Answer the export compliance question for \(name)."] : []
        case .information:
            var missing: [String] = []
            let filled = facts.localizations.first { !$0.description.isEmpty } ?? facts.localizations.first
            if filled?.description.isEmpty != false { missing.append("Beta App Description") }
            if filled?.feedbackEmail.isEmpty != false { missing.append("Feedback Email") }
            if let review = facts.review, !review.contactFirstName.isEmpty, !review.contactLastName.isEmpty, !review.contactPhone.isEmpty, !review.contactEmail.isEmpty {}
            else { missing.append("Beta App Review Information: first name, last name, phone number and email") }
            return missing
        case .group:
            guard build != nil else { return ["Upload a build first."] }
            if !facts.testingGroups.isEmpty { return [] }
            return facts.groups.isEmpty ? ["Create a group in Internal Testing or External Testing."] : ["Add \(name) to a group."]
        case .testers:
            let groups = facts.testingGroups
            guard !groups.isEmpty else { return ["Add the build to a group first."] }
            return groups.contains { ($0.publicLinkEnabled == true) || (facts.members[$0.id]?.testers ?? 0) > 0 } ? [] : ["Add testers to a group that has \(name), or turn on its public link."]
        case .betaReview:
            guard let build, facts.testingGroups.contains(where: { $0.internalGroup == false }) else { return [] }
            if build.externalState == "READY_FOR_BETA_TESTING" || build.betaReviewState == "APPROVED" { return [] }
            if build.rejected { return ["Apple rejected \(name). Read the reason in App Store Connect, fix it and upload a new build."] }
            if ["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"].contains(build.externalState ?? "") { return ["Apple is reviewing \(name). This usually takes a day or less."] }
            return ["Submit \(name) for Beta App Review."]
        }
    }

    /// Beta App Review is needed only when an External Testing group has the build.
    static func optional(_ id: StepId, facts: Facts) -> Bool {
        id == .betaReview && !facts.testingGroups.contains { $0.internalGroup == false }
    }

    /// The steps with their status: done when App Store Connect has it, the first step that isn't as the next step.
    public static func steps(_ facts: Facts) -> [Step] {
        let next = StepId.allCases.first { !optional($0, facts: facts) && !needed($0, facts: facts).isEmpty }
        return StepId.allCases.enumerated().map { index, id in
            let missing = needed(id, facts: facts), skip = optional(id, facts: facts)
            return Step(id: id, number: index + 1, done: missing.isEmpty && !skip, current: id == next, optional: skip, needed: missing)
        }
    }
}

extension WorkspaceSession {
    /// The app's TestFlight builds, read with the account's read client.
    public func testFlightBuilds(account: Account, appId: String) async throws -> [TestFlightBuild] {
        try await testFlightBuilds(appId: appId, client: readClient(for: account))
    }

    /// Everything Start Testing checks, read from App Store Connect with the account's read client.
    public func testFlightFacts(account: Account, appId: String, fresh: Bool) async throws -> TestFlightFlow.Facts {
        if fresh { await invalidateAppleReads() }
        let client = try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await testFlightFacts(appId: appId, client: client) }
    }

    /// Groups read at the same time for their members.
    static let memberReadsAtOnce = 4

    /// Builds, groups, test information and beta review details are read side by side; each group's members follow its group list.
    /// Only the builds are needed for every step. Another part that cannot be read marks its steps with the reason.
    func testFlightFacts(appId: String, client: AppStoreConnectClient) async throws -> TestFlightFlow.Facts {
        async let buildsRead = testFlightBuilds(appId: appId, client: client)
        async let informationRead = Self.part { try await self.testFlightAppInformation(appId: appId, client: client) }
        async let reviewRead = Self.part { try await self.testFlightReviewInformationFromApple(appId: appId, client: client) }
        async let groupsRead = Self.part { try await self.testFlightGroups(appId: appId, client: client) }
        var facts = TestFlightFlow.Facts()
        switch try await groupsRead {
        case .success(let groups): facts.groups = groups
        case .failure(let error):
            let reason = ProductPricing.readProblem(error, reading: "the TestFlight groups")
            facts.unread[.group] = reason; facts.unread[.testers] = reason
        }
        var missingMembers: String?
        try await withThrowingTaskGroup(of: (String, Result<TestFlightFlow.Facts.Membership, any Error>).self) { tasks in
            var waiting = facts.groups.map(\.id)[...]
            func start() {
                guard let id = waiting.popFirst() else { return }
                tasks.addTask {
                    (id, try await Self.part {
                        let value = try await self.groupMembers(appId: appId, groupId: id, client: client)
                        return TestFlightFlow.Facts.Membership(builds: value.builds, testers: value.testers.count)
                    })
                }
            }
            for _ in 0..<Self.memberReadsAtOnce { start() }
            while let (id, value) = try await tasks.next() {
                switch value {
                case .success(let membership): facts.members[id] = membership
                case .failure(let error): missingMembers = missingMembers ?? ProductPricing.readProblem(error, reading: "the testers in each group")
                }
                start()
            }
        }
        facts.builds = try await buildsRead
        if let missingMembers {
            facts.unread[.testers] = missingMembers
            if facts.testingGroups.isEmpty { facts.unread[.group] = missingMembers }
        }
        switch try await informationRead {
        case .success(let localizations): facts.localizations = localizations
        case .failure(let error): facts.unread[.information] = ProductPricing.readProblem(error, reading: "the Test Information")
        }
        switch try await reviewRead {
        case .success(let review): facts.review = review
        case .failure(let error): facts.unread[.information] = facts.unread[.information] ?? ProductPricing.readProblem(error, reading: "the Beta App Review Information")
        }
        return facts
    }

    /// Reads ahead what the later Start Testing steps show for the followed build: its testers, What to Test, metrics and export compliance,
    /// the app's testers and its beta license. Each step then opens from the shared reads. Only reads at Apple, and only while the hourly request limit leaves room.
    public func prewarmTestFlightSteps(account: Account, appId: String, build: TestFlightBuild?) async {
        guard AppleRequestBudget.allowsReadingAhead(keyId: account.keyId), let client = try? readClient(for: account) else { return }
        async let testers: Void = Self.warm { _ = try await self.allTesters(appId: appId, client: client) }
        async let license: Void = Self.warm { _ = try await self.testFlightBetaLicense(appId: appId, client: client) }
        if let build {
            async let access: Void = Self.warm { _ = try await self.individualBuildTesters(appId: appId, buildId: build.id, client: client) }
            async let notes: Void = Self.warm { _ = try await self.whatToTest(appId: appId, buildId: build.id, client: client) }
            async let metrics: Void = Self.warm { _ = try await self.testFlightMetrics(appId: appId, buildId: build.id, client: client) }
            async let compliance: Void = Self.warm { _ = try await self.buildExportCompliance(appId: appId, buildId: build.id, platform: build.platform, client: client) }
            _ = await (access, notes, metrics, compliance)
        }
        _ = await (testers, license)
    }
    nonisolated static func warm(_ read: @Sendable () async throws -> Void) async { try? await read() }

    /// One part's answer or its failure. A cancelled read is passed on, so the caller reads again instead of showing it as Apple's answer.
    nonisolated static func part<T: Sendable>(_ read: @Sendable () async throws -> T) async throws -> Result<T, any Error> {
        do { return .success(try await read()) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return .failure(error)
        }
    }
}
