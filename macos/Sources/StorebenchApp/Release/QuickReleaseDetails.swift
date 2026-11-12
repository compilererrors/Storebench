import StorebenchCore
import SwiftUI

enum QuickReleaseDetail: String, CaseIterable, Identifiable {
    case listing, media, copyright, reviewInformation, information, accessibility, privacy, availability
    var id: String { rawValue }
    var title: String {
        switch self {
        case .listing: "Listing Text"
        case .media: "Previews and Screenshots"
        case .copyright: "Copyright"
        case .reviewInformation: "App Review Information"
        case .information: "App Information and Age Rating"
        case .accessibility: "Accessibility"
        case .privacy: "App Privacy and Tax Category"
        case .availability: "Country or Region Availability"
        }
    }
    init?(check: String) {
        switch check {
        case "copyright": self = .copyright
        case "review-info", "review-information": self = .reviewInformation
        case "app-configuration", "age-rating": self = .information
        case "accessibility": self = .accessibility
        case "privacy", "tax": self = .privacy
        case "territories": self = .availability
        default: if check.hasPrefix("media:") { self = .media } else { return nil }
        }
    }
}

/// Existing release forms, loaded only when asked for and kept in the Quick Release workspace.
struct QuickReleaseDetails: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, plan: ReleasePlan
    let listing: VersionListingEditor?, snapshot: ReleaseReadinessSnapshot?
    @Binding var expanded: Set<QuickReleaseDetail>
    let editText: () -> Void
    let afterApple: () -> Void
    @State private var mediaReview: PublishReview?
    @State private var mounted: Set<QuickReleaseDetail> = []
    @State private var showingChecks = false
    @State private var checksMounted = false
    var body: some View {
        Card(title: "Other Release Details", subtitle: "The saved listing and settings are reused. Expand a section to check or change it without leaving Quick Release.") {
            let checks = QuickReleaseDetail.allCases.map(check)
            let missing = checks.filter { $0.status == .missing }.count, ready = checks.filter { $0.status == .ready }.count
            StorebenchCheckLabel(text: missing > 0 ? "\(missing) Required Details Need Action" : "\(ready) of \(checks.count) Ready",
                                 tone: missing > 0 ? .problem : ready == checks.count ? .success : .caution)
            DisclosureGroup("View Checks and Settings", isExpanded: $showingChecks) {
                if checksMounted || showingChecks {
                    ForEach(QuickReleaseDetail.allCases) { detail in
                        let state = check(detail)
                        StorebenchStatusRow(title: detail.title, detail: "", separator: detail != QuickReleaseDetail.allCases.last) {
                            StorebenchCheckLabel(text: state.label, tone: state.status.tone)
                        } action: {
                            if detail == .listing { Button("Edit", action: editText) }
                            else {
                                StorebenchDisclosureCommand(title: expanded.contains(detail) ? "Done" : "Edit") {
                                    if expanded.contains(detail) { expanded.remove(detail) }
                                    else { expanded.insert(detail) }
                                }
                            }
                        } details: {
                            if mounted.contains(detail) || expanded.contains(detail) {
                                content(detail).onAppear { mounted.insert(detail) }.collectionVisibility(expanded.contains(detail))
                            }
                        }.id("quick-detail-" + detail.rawValue).storebenchControlID("quick.detail." + detail.rawValue)
                    }
                }
            }.onChange(of: showingChecks, initial: true) { if showingChecks { checksMounted = true } }
            .onChange(of: expanded, initial: true) { if !expanded.isEmpty { showingChecks = true; checksMounted = true } }
            Text("Green: ready. Yellow: needs checking, syncing or approval. Red: required information is missing or invalid.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func check(_ detail: QuickReleaseDetail) -> QuickRelease.Check {
        let steps = snapshot?.steps ?? []
        if detail == .listing {
            let local = steps.filter { $0.id.hasPrefix("local:") || $0.id.hasPrefix("editorial:") }
            let remote = snapshot?.targetVersionId == nil ? [] : steps.filter { $0.id.hasPrefix("apple-info:") || $0.id.hasPrefix("apple-text:") }
            return QuickRelease.check(local + remote, excluding: ["whatsNew", "screenshots"])
        }
        if detail == .media, snapshot?.parts.contains(.versions) == true, snapshot?.targetVersionId == nil {
            return QuickRelease.check(steps.filter { $0.id.hasPrefix("local:") }, excluding: Set(TextDrafts.labels.keys))
        }
        if detail == .copyright, snapshot?.targetVersionId == nil, let value = listing?.version?.fields["copyright"]?.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(.ready, "Ready to Reuse", "The starting version has saved copyright. It will be checked on the new version.")
        }
        return QuickRelease.check(steps.filter { QuickReleaseDetail(check: $0.id) == detail })
    }
    @ViewBuilder private func content(_ detail: QuickReleaseDetail) -> some View {
        switch detail {
        case .listing: EmptyView()
        case .copyright:
            if let version = snapshot?.targetVersionId {
            PublishActionPanel(account: account, app: app, session: session, actions: [.copyright],
                initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .versionCopyright, versionId: version),
                guided: ("Copyright", "Enter the year and rights holder, then review the change before sending it to Apple."), done: { _ in afterApple() })
            } else { Text("Prepare the version in step 1 first, then enter its copyright here.").font(.sbCallout).fixedSize(horizontal: false, vertical: true) }
        case .reviewInformation:
            if let version = snapshot?.targetVersionId { ReviewInformationView(account: account, app: app, session: session, fixedVersionId: version, didSync: afterApple) }
            else { Text("Prepare the version in step 1 first. App Review Information belongs to that version.").font(.sbCallout).fixedSize(horizontal: false, vertical: true) }
        case .information:
            AppInformationView(account: account, app: app, session: session, parts: [.categories, .ageRating], changed: afterApple)
        case .accessibility:
            AppInformationView(account: account, app: app, session: session, parts: [.accessibility], changed: afterApple)
        case .privacy:
            AppPrivacyView(account: account, app: app, session: session, done: afterApple, showsPolicy: false)
        case .availability:
            AppInformationView(account: account, app: app, session: session, parts: [.availability], changed: afterApple)
        case .media:
            if let listing, let version = listing.version {
                let scope = Editing(accountId: account.id, appId: app.id, revisionId: plan.sourceRevisionId, local: false)
                ForEach(version.localizations) { localization in
                    Card(title: StoreLocales.name(localization.locale), subtitle: "Saved previews and screenshots for this version.") {
                        MediaListingView(account: account, version: version, scope: scope, localization: localization,
                            others: version.localizations.filter { $0.id != localization.id }, targetMode: "release-plan", session: session,
                            openReview: { mediaReview = $0.review; return true }, didSync: afterApple)
                    }
                }
                ReviewPanel(account: account, app: app, session: session, review: $mediaReview, done: { if mediaReview?.state == "complete" { afterApple() } })
            } else { StorebenchLoadingStatus(message: "Reading the saved listing…", surface: false) }
        }
    }
}
