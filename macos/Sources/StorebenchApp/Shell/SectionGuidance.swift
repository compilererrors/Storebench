import StorebenchCore

extension AppNavigation.Section {
    var purpose: String {
        switch self {
        case .overview: ""
        case .information: "Content rights, category, age rating and export compliance for this app, as in App Store Connect's App Information."
        case .history: "What every version said on the App Store, with name and subtitle changes. Compare saved imports to see exactly what changed."
        case .journal: "Changes to this app's listing over time, with your notes on why you made them and what happened next."
        case .transfer: "Import or export language text, screenshot layouts, prices and Fastlane metadata. Every import shows its changes before anything is saved."
        case .quickRelease: "The next version of a published app in five steps: version number, creating it in App Store Connect, Description, Subtitle, Keywords and What's New, the build, and Add for Review. Each change at App Store Connect waits for your approval."
        case .release: "Create a new version step by step, in App Store Connect's order. Next saves your work on this Mac; nothing reaches Apple until you approve it."
        case .localizations: "Edit each language's name, subtitle, description, keywords and What's New. Counters show Apple's limits as you type."
        case .keywords: "Collect keyword ideas with their sources, review them and use them in a language's Keywords field."
        case .media: "The saved screenshots and app previews for each language and device size. They are added and ordered in Release step 2."
        case .pricing: "Plan prices across countries from one model, protect the countries you want to keep and review every change before it reaches Apple."
        case .reviewInfo: "Contact details, sign-in information and notes for Apple's reviewer, for the selected version."
        case .startTesting: "Get a build to testers, one step at a time: build, export compliance, test information, a group and its testers."
        case .setUpReports: "Connect the reports Storebench reads, one step at a time: Sales and Trends, Payments and Financial Reports, and Analytics."
        case .pricingAvailability: "The app's price, scheduled price changes and the countries or regions where it is available."
        case .appPrivacy: "Your privacy policy, what data the app collects and the app's tax category."
        case .accessibility: "The accessibility features your app supports, shown on its App Store page."
        case .inAppPurchases: "Consumable and non-consumable In-App Purchases and their prices."
        case .subscriptions: "Subscription groups, subscriptions, their prices and offers such as free trials."
        case .feedback: "Screenshots and crash reports that testers sent from TestFlight."
        case .groups: "Groups for your App Store Connect team. Builds reach them without Beta App Review."
        case .externalTesting: "Groups for anyone with an email address or a public link. The first build for them needs Beta App Review."
        case .publish: "Every change for App Store Connect, including those prepared in Release, waits here as a review. Check the exact changes, then approve them. Nothing is sent before you approve."
        case .assetLibrary: "Images and videos for this app at Apple, with their processing and review state. Reading never uploads anything."
        case .createMedia: "Turn app screenshots into App Store cards with a background, titles and text. Cards are saved on this Mac and added to Asset Library as local originals; nothing is uploaded."
        case .builds: "Uploaded builds, their processing and beta review state, and who can test each build."
        case .testers: "Individual testers, their invitations and the builds they can install."
        case .testInformation: "What testers see in TestFlight: description, feedback email, links and beta review contact."
        case .sales: "Paid purchases, proceeds and refunds by period and country, from Apple's Sales reports."
        case .analytics: "Impressions, product page views and downloads from App Analytics, by territory, source and device."
        case .aso: "How search, product page views and downloads moved after each listing change, compared with the same number of days before."
        case .asoDiff: "Exactly what changed in your listing between saved versions, side by side."
        case .finance: "Final proceeds by fiscal period and territory, from Apple's financial reports."
        case .reviews: "Written customer reviews and ratings by territory, with themes you can follow over releases."
        }
    }

    /// A topic id from the bundled help catalog, or empty when the purpose explains the section by itself.
    var helpTopic: String {
        switch self {
        case .overview: "sync"
        case .transfer: "imports"
        case .release, .quickRelease: "versions"
        case .localizations: "listing"
        case .keywords: "keywords"
        case .media, .assetLibrary, .createMedia: "media"
        case .pricing, .pricingAvailability, .inAppPurchases, .subscriptions: "model"
        case .reviewInfo: "review-information"
        case .publish: "publishing"
        case .builds, .groups, .testers, .testInformation, .startTesting, .feedback, .externalTesting: "testflight"
        case .sales, .setUpReports: "sales"
        case .analytics: "analytics"
        case .aso: "aso-progress"
        case .finance: "finance"
        case .reviews: "reviews"
        case .information, .history, .journal, .asoDiff, .appPrivacy, .accessibility: ""
        }
    }
}
