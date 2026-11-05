import Foundation

/// Group settings and audience snapshots shared by preparation and the final Apple write check.
public enum TestFlightGroups {
    public typealias Resource = AppStoreConnectClient.Resource
    static let editable: Set<String> = ["name", "feedbackEnabled", "publicLinkEnabled", "publicLinkLimitEnabled", "publicLinkLimit"]
    static func validate(_ group: Resource) throws {
        guard group.type == "betaGroups", !TextSemantics.trim(group.id).isEmpty,
              let name = group.attributes?["name"]?.string, !TextSemantics.trim(name).isEmpty, case .bool? = group.attributes?["isInternalGroup"] else {
            throw PublishFailure.invalid("Apple did not confirm this TestFlight group's name and type.")
        }
    }
    static func attribute(_ item: Resource, _ key: String) -> JSONText { TestFlightAccess.attribute(item, key) }
    static func unique(_ items: [Resource], type: String) throws {
        guard items.allSatisfy({ $0.type == type && !TextSemantics.trim($0.id).isEmpty }), Set(items.map { Data($0.id.utf8) }).count == items.count else {
            throw PublishFailure.invalid("Apple returned unexpected or duplicate TestFlight group members.")
        }
    }
    static func owned(_ items: [Resource], type: String, appId: String) throws {
        try unique(items, type: type)
        for item in items {
            if type == "betaTesters" {
                guard case .array(let apps)? = Planner.resource(item)["relationships"]?["apps"]?["data"], apps.contains(where: { $0["type"]?.text == "apps" && TextSemantics.same($0["id"]?.text, appId) }) else { throw PublishFailure.invalid("Apple returned group testers outside the selected app.") }
            } else { guard Apple.owned(item, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned group resources outside the selected app.") } }
        }
    }
    public static func name(_ value: String) throws -> String {
        let value = TextSemantics.trim(value)
        guard !value.isEmpty, value.utf16.count <= 100, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw PublishFailure.invalid("Enter a group name of 1–100 characters without control characters.") }
        return value
    }
    static func duplicateName(_ name: String, in groups: [Resource], excluding id: String? = nil) -> Bool {
        groups.contains { !TextSemantics.same($0.id, id) && TextSemantics.same($0.attributes?["name"]?.string?.lowercased(), name.lowercased()) }
    }
    public static func creationDigest(appId: String, groups: [Resource]) throws -> String {
        guard !appId.isEmpty else { throw PublishFailure.invalid("Choose an app for this TestFlight group.") }
        try owned(groups, type: "betaGroups", appId: appId)
        for group in groups { try validate(group) }
        let baseline = TestFlightAudience.ordered(groups, id: { $0.id }).map { group in
            JSONText.object([("id", .string(group.id)), ("name", attribute(group, "name")), ("internal", attribute(group, "isInternalGroup"))])
        }
        return JSONText.object([("appId", .string(appId)), ("baseline", .array(baseline))]).sha256
    }
    public static func attributesDigest(_ group: Resource, changes: JSONText) throws -> String {
        try validate(group)
        guard case .object(let fields) = changes, !fields.isEmpty, Set(fields.map(\.0)).count == fields.count, fields.allSatisfy({ editable.contains($0.0) }) else { throw PublishFailure.invalid("Choose valid TestFlight group settings.") }
        var keys = Set(fields.map(\.0))
        if keys.contains("publicLinkLimitEnabled") || keys.contains("publicLinkLimit") { keys.formUnion(["publicLinkLimitEnabled", "publicLinkLimit"]) }
        let baseline = keys.sorted().map { key in JSONText.array([.string(key), Planner.resource(group)["attributes"]?[key] ?? .object([("missing", .bool(true))])]) }
        return JSONText.object([("id", .string(group.id)), ("name", attribute(group, "name")), ("internal", attribute(group, "isInternalGroup")), ("baseline", .array(baseline))]).sha256
    }
    public static func deletionDigest(appId: String, group: Resource, builds: [Resource], testers: [Resource]) throws -> String {
        try validate(group); try owned([group], type: "betaGroups", appId: appId)
        try owned(builds, type: "builds", appId: appId); try owned(testers, type: "betaTesters", appId: appId)
        func members(_ items: [Resource], label: String) -> JSONText {
            .array(TestFlightAudience.ordered(items, id: { $0.id }).map { .object([("id", .string($0.id)), ("label", attribute($0, label))]) })
        }
        let settings = ["feedbackEnabled", "hasAccessToAllBuilds", "publicLinkEnabled", "publicLinkLimitEnabled", "publicLinkLimit"].map { JSONText.array([.string($0), attribute(group, $0)]) }
        return JSONText.object([("appId", .string(appId)), ("group", .object([("id", .string(group.id)), ("name", attribute(group, "name")), ("internal", attribute(group, "isInternalGroup")), ("settings", .array(settings))])),
                                ("builds", members(builds, label: "version")), ("testers", members(testers, label: "email"))]).sha256
    }
    static func state(_ item: Resource, builds: Bool) -> [(String, JSONText)] {
        builds ? [("version", attribute(item, "version")), ("processing", attribute(item, "processingState")), ("expired", attribute(item, "expired")), ("audience", attribute(item, "buildAudienceType"))]
            : [("email", attribute(item, "email")), ("state", attribute(item, "state"))]
    }
    public static func accessDigest(group: Resource, members: [Resource], peers: [Resource], relation: String, target: Resource) throws -> String {
        try validate(group)
        guard ["builds", "betaTesters"].contains(relation), target.type == relation, !TextSemantics.trim(target.id).isEmpty else { throw PublishFailure.invalid("Apple did not confirm this TestFlight group access.") }
        try unique(members, type: relation); try unique(peers, type: relation == "builds" ? "betaTesters" : "builds")
        let audience = TestFlightAudience.ordered(peers, id: { $0.id }).map { JSONText.object([("id", .string($0.id))] + state($0, builds: relation == "betaTesters")) }
        return JSONText.object([("groupId", .string(group.id)), ("name", attribute(group, "name")), ("internal", attribute(group, "isInternalGroup")), ("automatic", attribute(group, "hasAccessToAllBuilds")),
                                ("relation", .string(relation)), ("targetId", .string(target.id)), ("targetState", .object(state(target, builds: relation == "builds"))),
                                ("present", .bool(members.contains { TextSemantics.same($0.id, target.id) })), ("audience", .array(audience))]).sha256
    }
    public static func testerCreationDigest(group: Resource, builds: [Resource], appId: String) throws -> String {
        try validate(group); try owned([group], type: "betaGroups", appId: appId); try owned(builds, type: "builds", appId: appId)
        for (item, key, boolean) in [(group, "hasAccessToAllBuilds", true)] + builds.flatMap({ build in [(build, "version", false), (build, "processingState", false), (build, "expired", true), (build, "buildAudienceType", false)] }) {
            if let value = item.attributes?[key], value != .null {
                guard boolean ? { if case .bool = value { return true }; return false }() : value.string != nil else { throw PublishFailure.invalid("Apple did not confirm this group's build access.") }
            }
        }
        return JSONText.object([("appId", .string(appId)), ("group", .object([("id", .string(group.id)), ("name", attribute(group, "name")), ("internal", attribute(group, "isInternalGroup")), ("automatic", attribute(group, "hasAccessToAllBuilds"))])),
                                ("builds", .array(TestFlightAudience.ordered(builds, id: { $0.id }).map { .object([("id", .string($0.id))] + state($0, builds: true)) }))]).sha256
    }
    static func readable(_ value: JSONText, fallback: String, limit: Int) -> String {
        guard let text = value.text, !TextSemantics.trim(text).isEmpty else { return fallback }
        return String(decoding: TextSemantics.trim(text).utf16.prefix(limit), as: UTF16.self)
    }
    public static func audience(_ peers: [Resource], relation: String) throws -> String {
        guard ["builds", "betaTesters"].contains(relation) else { throw PublishFailure.invalid("Choose TestFlight group access.") }
        let testers = relation == "builds"; try unique(peers, type: testers ? "betaTesters" : "builds")
        let ordered = TestFlightAudience.ordered(peers, id: { $0.id })
        let entries = ordered.prefix(25).map { item in
            testers ? "\(readable(attribute(item, "email"), fallback: "Email unavailable", limit: 254)) · \(item.id) · \(readable(attribute(item, "state"), fallback: "state unavailable", limit: 80))"
                : "Build \(readable(attribute(item, "version"), fallback: "version unavailable", limit: 100)) · \(item.id) · \(readable(attribute(item, "processingState"), fallback: "processing unavailable", limit: 80)) · \(attribute(item, "expired") == .bool(true) ? "expired" : attribute(item, "expired") == .bool(false) ? "unexpired" : "expiry unavailable")"
        }
        return (["Group \(testers ? "testers" : "builds") (\(ordered.count)):"] + (entries.isEmpty ? ["None"] : entries) + (ordered.count > 25 ? ["\(ordered.count - 25) more \(testers ? "testers" : "builds") are included in the approval check. Review the full group list in TestFlight."] : [])).joined(separator: "\n")
    }
    static func comparison(peers: [Resource], relation: String, active: String, inactive: String, wasActive: Bool, willBeActive: Bool) throws -> (before: String, after: String) {
        let impact = try audience(peers, relation: relation)
        return (wasActive ? "\(active)\n\n\(impact)" : inactive, willBeActive ? "\(active)\n\n\(impact)" : inactive)
    }
}

extension WorkspaceSession {
    func verifyTestFlightGroup(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        func keys(_ value: JSONText?, _ expected: Set<String>) -> Bool { guard case .object(let fields)? = value else { return false }; return fields.count == expected.count && Set(fields.map(\.0)) == expected }
        func unchanged(_ digest: String) throws { guard digest == guardValue?["digest"]?.text else { throw PublishFailure.write("The TestFlight group or its audience changed after review. Prepare a new review.") } }
        guard let kind = guardValue?["kind"]?.text, let digest = guardValue?["digest"]?.text, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PublishFailure.write("Unsupported TestFlight group approval guard.") }
        let data = body?["data"]
        guard body == nil || keys(body, ["data"]), ["betaGroups", "betaTesters"].contains(parts.first ?? "") else { throw PublishFailure.write("Unsupported TestFlight group request.") }
        let groups = try await appGroups(appId: appId, client: client)
        if parts == ["betaGroups"], method == "POST" {
            guard kind == "group-creation", keys(guardValue, ["kind", "digest"]), keys(data, ["type", "attributes", "relationships"]), data?["type"]?.text == "betaGroups",
                  keys(data?["attributes"], ["name", "isInternalGroup"]), let proposed = data?["attributes"]?["name"]?.text, case .bool(let internalGroup)? = data?["attributes"]?["isInternalGroup"],
                  data?["relationships"] == .object([("app", Apple.relationship("apps", .string(appId)))]) else { throw PublishFailure.write("Unsupported TestFlight group creation.") }
            let name = try TestFlightGroups.name(proposed)
            guard TextSemantics.same(proposed, name), !TestFlightGroups.duplicateName(name, in: groups), internalGroup || groups.contains(where: { $0.attributes?["isInternalGroup"] == .bool(true) }) else { throw PublishFailure.write("The group name or required internal group changed after review.") }
            try unchanged(TestFlightGroups.creationDigest(appId: appId, groups: groups)); return
        }
        if parts == ["betaTesters"] {
            guard kind == "tester-group-target", keys(guardValue, ["kind", "digest"]), method == "POST", keys(data, ["type", "attributes", "relationships"]), data?["type"]?.text == "betaTesters",
                  keys(data?["attributes"], ["email"]), let email = data?["attributes"]?["email"]?.text, TestFlightAccess.validEmail(email), keys(data?["relationships"], ["betaGroups"]),
                  keys(data?["relationships"]?["betaGroups"], ["data"]), case .array(let links)? = data?["relationships"]?["betaGroups"]?["data"], links.count == 1, keys(links[0], ["type", "id"]), links[0]["type"]?.text == "betaGroups",
                  let group = groups.first(where: { TextSemantics.same($0.id, links[0]["id"]?.text) }) else { throw PublishFailure.write("Unsupported TestFlight group tester creation.") }
            let builds = try await scopedOwners(client.list("/v1/betaGroups/\(TextSemantics.pathComponent(group.id))/builds?limit=200"), type: "builds", appId: appId) { try await client.list($0) }
            try unchanged(TestFlightGroups.testerCreationDigest(group: group, builds: builds, appId: appId))
            if group.attributes?["isInternalGroup"] == .bool(true) { try await requireInternalTester(email: email, appId: appId, client: client) }
            guard try await exactTester(email: email, client: client) == nil else { throw PublishFailure.write("This tester now exists at Apple. Prepare a group assignment instead.") }
            return
        }
        guard parts.count >= 2, parts[0] == "betaGroups", let group = groups.first(where: { TextSemantics.same($0.id, parts[1]) }) else { throw PublishFailure.write("TestFlight group no longer belongs to this app.") }
        try TestFlightGroups.validate(group)
        if parts.count == 2, method == "PATCH" {
            guard kind == "group-attributes", keys(guardValue, ["kind", "digest"]), keys(data, ["type", "id", "attributes"]), data?["type"]?.text == "betaGroups", TextSemantics.same(data?["id"]?.text, group.id),
                  case .object(let fields)? = data?["attributes"], !fields.isEmpty, Set(fields.map(\.0)).count == fields.count, fields.allSatisfy({ TestFlightGroups.editable.contains($0.0) }) else { throw PublishFailure.write("Unsupported TestFlight group settings update.") }
            let changes = data!["attributes"]!
            if let proposed = changes["name"] {
                guard let name = proposed.text, TextSemantics.same(try TestFlightGroups.name(name), name), !TestFlightGroups.duplicateName(name, in: groups, excluding: group.id) else { throw PublishFailure.write("The TestFlight group name is invalid or already in use.") }
            }
            for key in ["feedbackEnabled", "publicLinkEnabled", "publicLinkLimitEnabled"] where changes[key] != nil { guard case .bool? = changes[key] else { throw PublishFailure.write("Invalid TestFlight group setting.") } }
            if let limit = changes["publicLinkLimit"] { guard case .number(let value) = limit, value.isFinite, value.rounded() == value, (1...10_000).contains(value), changes["publicLinkLimitEnabled"] == .bool(true) else { throw PublishFailure.write("Invalid TestFlight public link limit.") } }
            guard changes["publicLinkLimitEnabled"] != .bool(true) || changes["publicLinkLimit"] != nil,
                  group.attributes?["isInternalGroup"] != .bool(true) || !fields.contains(where: { ["publicLinkEnabled", "publicLinkLimitEnabled", "publicLinkLimit"].contains($0.0) }) else { throw PublishFailure.write("This TestFlight group does not support that setting.") }
            try unchanged(TestFlightGroups.attributesDigest(group, changes: changes)); return
        }
        if parts.count == 2, method == "DELETE" {
            guard body == nil, kind == "group-members", keys(guardValue, ["kind", "digest"]) else { throw PublishFailure.write("Unsupported TestFlight group deletion.") }
            let members = try await scopedGroupMembers(appId: appId, groupId: group.id, client: client)
            try unchanged(TestFlightGroups.deletionDigest(appId: appId, group: group, builds: members.builds, testers: members.testers)); return
        }
        guard parts.count == 4, parts[2] == "relationships", ["builds", "betaTesters"].contains(parts[3]), ["POST", "DELETE"].contains(method), kind == "group-access",
              case .array(let links)? = data, links.count == 1, keys(links[0], ["type", "id"]), links[0]["type"]?.text == parts[3], let targetId = links[0]["id"]?.text else { throw PublishFailure.write("Unsupported TestFlight group membership change.") }
        let buildAccess = parts[3] == "builds", adding = method == "POST", target: AppStoreConnectClient.Resource
        if buildAccess {
            guard keys(guardValue, ["kind", "digest"]), let build = try await appBuilds(appId: appId, client: client).first(where: { TextSemantics.same($0.id, targetId) }) else { throw PublishFailure.write("TestFlight group build no longer belongs to this app.") }
            if adding { try await requireAssignableBuild(build, client: client, externalOnly: group.attributes?["isInternalGroup"] != .bool(true)) }
            target = build
        } else {
            let testers = try await appTesters(appId: appId, client: client), appTester = testers.first { TextSemantics.same($0.id, targetId) }
            if let email = guardValue?["email"]?.text {
                guard keys(guardValue, ["kind", "digest", "email", "testerDigest"]), adding, appTester == nil, TestFlightAccess.validEmail(email),
                      let existing = try await exactTester(email: email, client: client), TextSemantics.same(existing.id, targetId), TestFlightAccess.identityDigest(existing) == guardValue?["testerDigest"]?.text else { throw PublishFailure.write("This beta tester identity changed after review.") }
                target = existing
            } else {
                guard keys(guardValue, ["kind", "digest"]), let appTester else { throw PublishFailure.write("This tester no longer belongs to the selected app.") }; target = appTester
            }
            if adding && group.attributes?["isInternalGroup"] == .bool(true) { try await requireInternalTester(email: target.attributes?["email"]?.string ?? "", appId: appId, client: client) }
        }
        let members = try await scopedGroupMembers(appId: appId, groupId: group.id, client: client)
        let assigned = buildAccess ? members.builds : members.testers, peers = buildAccess ? members.testers : members.builds
        guard adding != assigned.contains(where: { TextSemantics.same($0.id, targetId) }) else { throw PublishFailure.write("This TestFlight membership changed after review.") }
        try unchanged(TestFlightGroups.accessDigest(group: group, members: assigned, peers: peers, relation: parts[3], target: target))
    }
    func scopedGroupMembers(appId: String, groupId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> (builds: [AppStoreConnectClient.Resource], testers: [AppStoreConnectClient.Resource]) {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let prefix = "/v1/betaGroups/\(TextSemantics.pathComponent(groupId))"
        let builds = try await scopedOwners(list("\(prefix)/builds?limit=200"), type: "builds", appId: appId, list: list)
        let testers = try await scopedTesters(list("\(prefix)/betaTesters?limit=200"), appId: appId, list: list)
        return (builds, testers)
    }
    func planTestFlightGroup(_ planner: Planner) async throws -> String? {
        let request = planner.request, appId = request.appId, action = request.testflightAction ?? "", client = planner.client
        guard ["create-group", "rename-group", "set-group-setting", "delete-group", "invite-tester", "add-tester", "remove-tester", "add-build", "remove-build"].contains(action) else { return nil }
        let groups = try await appGroups(appId: appId, client: client, planner: planner)
        func reviewGuard(_ kind: String, _ digest: String, extra: [(String, JSONText)] = []) -> JSONText { .object([("kind", .string(kind)), ("digest", .string(digest))] + extra) }
        if action == "create-group" {
            let name = try TestFlightGroups.name(request.groupName ?? ""), internalGroup = request.internalGroup ?? false
            let digest = try TestFlightGroups.creationDigest(appId: appId, groups: groups)
            guard !TestFlightGroups.duplicateName(name, in: groups) else { throw PublishFailure.invalid("A group with this name already exists.") }
            guard internalGroup || groups.contains(where: { $0.attributes?["isInternalGroup"] == .bool(true) }) else { throw PublishFailure.invalid("Create an internal TestFlight group before creating an external group.") }
            let type = internalGroup ? "internal" : "external"
            planner.add(.api, method: "POST", path: [.string("betaGroups")], label: "Create \(type) group", detail: name, before: "No group", after: "\(name) · \(type)",
                        body: .object([("data", .object([("type", .string("betaGroups")), ("attributes", .object([("name", .string(name)), ("isInternalGroup", .bool(internalGroup))])), ("relationships", .object([("app", Apple.relationship("apps", .string(appId)))]))]))]), guard: reviewGuard("group-creation", digest))
            planner.notes.append("Creating a group alone does not invite testers or distribute a build.")
            return "Create TestFlight group · \(name)"
        }
        guard let group = groups.first(where: { TextSemantics.same($0.id, request.groupId) }) else { throw PublishFailure.invalid("Choose an existing group for this app.") }
        try TestFlightGroups.validate(group)
        let groupName = group.attributes!["name"]!.string!, internalGroup = group.attributes?["isInternalGroup"] == .bool(true)
        if action == "rename-group" || action == "set-group-setting" {
            let label: String, before: String, after: String, changes: JSONText
            if action == "rename-group" {
                let name = try TestFlightGroups.name(request.groupName ?? "")
                guard !TestFlightGroups.duplicateName(name, in: groups, excluding: group.id) else { throw PublishFailure.invalid("A group with this name already exists.") }
                label = "Rename TestFlight group"; before = groupName; after = name; changes = .object([("name", .string(name))])
            } else {
                guard let setting = request.groupSetting, let value = request.groupSettingValue else { throw PublishFailure.invalid("Choose a group setting and value.") }
                guard setting == "feedback" || !internalGroup else { throw PublishFailure.invalid("Public links are available only for external TestFlight groups.") }
                if setting == "public-link-limit" {
                    guard case .number(let limit) = value, limit.isFinite, limit.rounded() == limit, limit >= 0, limit <= 10_000 else { throw PublishFailure.invalid("Choose a public link limit of 1–10,000 testers, or unlimited.") }
                    label = "Set public link tester limit"
                    if group.attributes?["publicLinkLimitEnabled"] == .bool(false) { before = "Unlimited" }
                    else if case .number(let current)? = group.attributes?["publicLinkLimit"], group.attributes?["publicLinkLimitEnabled"] == .bool(true), current.isFinite, current.rounded() == current, current > 0, current <= 10_000 { before = "\(Int(current)) testers" }
                    else { before = "Unknown at Apple" }
                    after = limit == 0 ? "Unlimited" : "\(Int(limit)) testers"
                    changes = limit == 0 ? .object([("publicLinkLimitEnabled", .bool(false))]) : .object([("publicLinkLimitEnabled", .bool(true)), ("publicLinkLimit", .number(limit))])
                    planner.notes.append("The limit controls sign-ups through the public link, not testers added by email or other groups.")
                } else {
                    guard case .bool(let flag) = value, ["feedback", "public-link"].contains(setting) else { throw PublishFailure.invalid("Choose a valid TestFlight group setting value.") }
                    let key = setting == "feedback" ? "feedbackEnabled" : "publicLinkEnabled"
                    label = setting == "feedback" ? "Set group feedback" : "Set public link availability"
                    if case .bool(let current)? = group.attributes?[key] { before = current ? "On" : "Off" } else { before = "Unknown at Apple" }
                    after = flag ? "On" : "Off"; changes = .object([(key, .bool(flag))])
                    if setting == "public-link" { planner.notes.append(flag ? "Enabling the public link lets anyone with the link request to test this group's eligible builds. Apple controls acceptance and eligibility." : "Disabling the public link prevents new sign-ups through it; existing testers remain in the group.") }
                }
            }
            let digest = try TestFlightGroups.attributesDigest(group, changes: changes)
            if !TextSemantics.same(before, after) {
                planner.add(.api, method: "PATCH", path: [.string("betaGroups"), .string(group.id)], label: label, detail: action == "rename-group" ? "\(groupName) → \(after)" : groupName, before: before, after: after,
                            body: .object([("data", .object([("type", .string("betaGroups")), ("id", .string(group.id)), ("attributes", changes)]))]), guard: reviewGuard("group-attributes", digest))
            }
            return "\(label) · \(groupName)"
        }
        let members = try await scopedGroupMembers(appId: appId, groupId: group.id, client: client, planner: planner)
        if action == "delete-group" {
            let digest = try TestFlightGroups.deletionDigest(appId: appId, group: group, builds: members.builds, testers: members.testers)
            let before = (["Group: \(groupName)", "Builds (\(members.builds.count)):"] + members.builds.map { "\($0.attributes?["version"]?.string ?? "Unknown version") · \($0.id)" }.sorted()
                          + ["Testers (\(members.testers.count)):"] + members.testers.map { "\($0.attributes?["email"]?.string ?? "Unknown email") · \($0.id)" }.sorted()).joined(separator: "\n")
            planner.add(.api, method: "DELETE", path: [.string("betaGroups"), .string(group.id)], label: "Delete TestFlight group", detail: "\(groupName) · \(members.testers.count) testers · \(members.builds.count) builds", before: before,
                        after: "Group removed; no new build access through this group", guard: reviewGuard("group-members", digest))
            planner.notes.append("Deleting a group removes its access to associated builds. Installed builds may remain usable until they expire, and other groups can still grant access.")
            return "Delete TestFlight group · \(groupName)"
        }
        let buildAccess = action == "add-build" || action == "remove-build", adding = !["remove-build", "remove-tester"].contains(action), relation = buildAccess ? "builds" : "betaTesters"
        let assigned = buildAccess ? members.builds : members.testers, peers = buildAccess ? members.testers : members.builds
        let target: AppStoreConnectClient.Resource?, appTester: AppStoreConnectClient.Resource?
        if buildAccess {
            target = try await appBuilds(appId: appId, client: client, planner: planner).first { TextSemantics.same($0.id, request.buildId) }; appTester = nil
            guard let target else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
            if adding { try await requireAssignableBuild(target, client: client, externalOnly: !internalGroup) }
        } else {
            let testers = try await appTesters(appId: appId, client: client, planner: planner)
            if action == "invite-tester" {
                let email = request.testerEmail!
                if internalGroup { try await requireInternalTester(email: email, appId: appId, client: client) }
                appTester = testers.first { TextSemantics.same($0.attributes?["email"]?.string?.lowercased(), email) }
                if let appTester { target = appTester } else { target = try await exactTester(email: email, client: client) }
            } else {
                appTester = testers.first { TextSemantics.same($0.id, request.testerId) }; target = appTester
                guard target != nil else { throw PublishFailure.invalid("This tester does not belong to the selected app.") }
            }
        }
        if let target {
            let present = assigned.contains { TextSemantics.same($0.id, target.id) }
            if adding != present {
                if !buildAccess && adding && internalGroup { try await requireInternalTester(email: target.attributes?["email"]?.string ?? "", appId: appId, client: client) }
                var extra: [(String, JSONText)] = []
                if action == "invite-tester" && appTester == nil { extra = [("email", .string(request.testerEmail!)), ("testerDigest", .string(TestFlightAccess.identityDigest(target)))] }
                let inactive = buildAccess ? "Not available to group" : action == "invite-tester" && appTester == nil ? "Tester exists at Apple, outside this app" : "Outside group"
                let comparison = try TestFlightGroups.comparison(peers: peers, relation: relation, active: buildAccess ? "Available to group" : "In group", inactive: inactive, wasActive: present, willBeActive: adding)
                planner.add(.api, method: adding ? "POST" : "DELETE", path: [.string("betaGroups"), .string(group.id), .string("relationships"), .string(relation)],
                            label: buildAccess ? (adding ? "Give group build access" : "Remove group build access") : action == "invite-tester" ? "Add existing tester by email" : adding ? "Add tester to group" : "Remove tester from group",
                            detail: "\(groupName) · \(target.attributes?[buildAccess ? "version" : "email"]?.string ?? target.id) · \(peers.count) current group \(buildAccess ? "testers" : "builds")",
                            before: comparison.before, after: comparison.after, body: Self.linkages(relation, target.id),
                            guard: reviewGuard("group-access", try TestFlightGroups.accessDigest(group: group, members: assigned, peers: peers, relation: relation, target: target), extra: extra))
            }
        } else {
            let digest = try TestFlightGroups.testerCreationDigest(group: group, builds: members.builds, appId: appId)
            let access = members.builds.map { "Build \($0.attributes?["version"]?.string ?? $0.id) · \($0.id)" }.sorted()
            let after = (["Added to \(groupName) (\(internalGroup ? "internal" : "external"))", "Current builds (\(access.count)):"] + (access.isEmpty ? ["None"] : access) + ["Automatic build distribution: \(group.attributes?["hasAccessToAllBuilds"] == .bool(true) ? "On" : group.attributes?["hasAccessToAllBuilds"] == .bool(false) ? "Off" : "Unknown")"]).joined(separator: "\n")
            planner.add(.api, method: "POST", path: [.string("betaTesters")], label: internalGroup ? "Create internal tester" : "Create external tester", detail: "\(request.testerEmail!) · \(groupName)", before: "No tester with this email in this app", after: after,
                        body: .object([("data", .object([("type", .string("betaTesters")), ("attributes", .object([("email", .string(request.testerEmail!))])), ("relationships", .object([("betaGroups", Self.linkages("betaGroups", group.id))]))]))]), guard: reviewGuard("tester-group-target", digest))
        }
        planner.notes.append(buildAccess ? "A change to this group's testers requires a new build access review before Apple is updated." : "A change to this group's builds requires a new tester access review before Apple is updated.")
        if buildAccess && !internalGroup { planner.notes.append("Apple may require beta review and export compliance before an external group can test a build.") }
        if buildAccess && internalGroup && group.attributes?["hasAccessToAllBuilds"] == .bool(true) { planner.notes.append("Automatic distribution stays on for this group. Builds created by Xcode Cloud still need manual assignment.") }
        if action == "invite-tester" { planner.notes.append(internalGroup ? "This person must remain an eligible App Store Connect team user with access to this app. Apple controls activation; refresh TestFlight to confirm the tester's state." : "Apple handles the TestFlight invitation and eligibility. Review the tester's state in TestFlight after publishing.") }
        else if !buildAccess { planner.notes.append(adding ? "This adds access through the selected group. Other group and individual assignments stay as they are." : "This removes access through the selected group only. The tester remains in the app and other groups; installed builds may remain usable until they expire.") }
        return "\(adding ? "Add" : "Remove") \(buildAccess ? "build" : "tester") · \(groupName)"
    }
}
