# Storebench

![Storebench with a saved ASO timeline and listing changes overlaid on reports](docs/images/aso-progress.png)

Storebench is a native Mac app for developers managing several apps in App Store Connect. Set country prices from one guide price, keep your listing history and see what changed after each update. Release apps step by step, bump an existing version, translate your listings and create screenshot cards by hand or with AI, all in one encrypted local workspace.

Edits stay on your Mac until you prepare a review and approve sending them to Apple. A local save, an upload and a public release are separate steps.

**[Download for Mac](https://github.com/compilererrors/Storebench/releases/latest)** · [Requirements and editions](#requirements) · [License](#license) · [See all screenshots](#screenshots)

## Set country prices without working through them one by one

Set one guide price and choose how the other countries follow it: **World Bank purchasing power (PPP)**, **Big Mac Index**, **currency conversion** or **Same for all**, such as 4.99 in every currency.

Want your own rules? Save **country percentages**, **your own index** or a mix of models as a reusable profile. You can also choose **Apple's comparable prices** or **enter country prices yourself**, including from CSV.

The Price Model selector stays at the top of Prices by Country or Region. Choosing a model shows its own settings and country preview, while Countries with No or Few Purchases stays available. Initial App Price setup remains available when needed. Once the app has a paid price, Apple's price editor appears only for Apple's comparable prices; current Apple prices can also be shown explicitly for comparison. CSV input belongs to Enter Prices Manually. Storebench rounds to Apple's price points and shows the changes before you approve sending them.

PPP and Big Mac observations are saved in the encrypted database and refreshed in the background after startup reads. Apple's price points are read country by country, six at a time, and only as far up as each country's price needs: while Apple's pages rise in price, reading stops at the first price point at or above the model price, so nearest, up and down rounding choose exactly as from the full list. Pages that do not rise are read to the end. Each country's list is saved for a day and reused when it reaches the amount needed. The model amounts appear first, each country shows its Apple price as soon as it is read, and the count of matched countries moves as they arrive. Source reads have a six-second limit, and the whole preview stops after two minutes; Cancel Calculation stops it sooner, and the countries already read are kept for the next try. A failed refresh keeps validated, dated index data for up to a year. When neither a download nor a saved copy can be read, such as on a first start without a connection, Storebench uses the observations built into the app and says so with their date. They hold each country's newest World Bank PPP and official exchange rate factors, from the [World Bank](https://data.worldbank.org/indicator/PA.NUS.PPP) under CC BY 4.0, and the latest Big Mac prices from [The Economist](https://github.com/TheEconomist/big-mac-data) under CC BY 4.0. The country table keeps search, sorting, filters and rows per page together; calculation details remain available from each value.

Each country uses its newest World Bank observation, so a country without this year's figure keeps last year's instead of losing its price. For a country where App Store prices are in USD while PPP is reported in the national currency, Storebench divides the PPP factor by the same year's [official currency-per-USD factor](https://data.worldbank.org/indicator/PA.NUS.FCRF). Where App Store prices use another foreign currency, such as euros, the same division gives the country's price level, which is compared with the guide country's and converted at the current exchange rate. The Big Mac Index works the same way: each country uses its newest observation from the last two years, euro area members use The Economist's euro area price, and a country billed in another currency is priced by the burger's dollar price relative to the guide country's, at the exchange rate. A country an index does not cover at all is converted at the exchange rate instead, and the preview says how many countries do so. The source, year and method remain visible in each country's calculation details. Without an exchange rate for such a country, its model price stays unavailable.

[See the pricing choices and country preview](#pricing-models).

## Keep your listing history and see what happened after a change

You changed a subtitle or replaced some keywords. Which wording was there before, when was the new listing first seen, and did impressions, page views or downloads move afterwards?

Storebench saves each listing revision you import for each app, together with downloaded reports, in your encrypted workspace. Later syncs add new snapshots without replacing the earlier ones. You can go back to the saved text and screenshots, compare versions, and read the history on your Mac.

In **ASO Progress**, choose a language and the listing fields you want to compare. Overlay up to four report measures on the same graph: impressions, App Store product page views, Get taps, first-time downloads or purchases, including search-specific measures where available. Use the indexed scale to compare measures with different sizes, draw the graph as lines, bars or areas, and pick the dates with 7, 30 or 90 days, 6 months, 1 year, this year, all saved dates or your own range. Markers show where a changed released listing was first observed at a sync, colored by what changed: keywords, name or subtitle, screenshots or other text. Add your own dated notes, such as a campaign or a price change, and they appear on the same graph. Click a marker to open that version or note.

Select a change to read the old and new text and compare the same number of days before and after it. For example, compare seven days around a keyword update, then inspect the next update on the same timeline. This helps you decide what to try next from your own saved history.

The comparison shows observed changes, not proof that an ASO edit caused them. Other listing updates and your notes in the same window are identified, whichever language or field you are viewing. Missing reports stay missing, and the observed date is not a verified publication time. History builds from the listings and reports you import; text from before your first saved snapshot cannot be reconstructed.

[See the ASO timeline and before/after comparison](#aso-history).

## Follow a full release from setup to App Review

From the questions about your app to releasing it, **Release** keeps the work in one flow. App details, age rating and required declarations, text, screenshots, build, export compliance and App Review: go step by step, with the checks and editors together. See what's missing, fix it there and continue, without hunting through views and tabs.

App already out and you just need to bump the version? **Quick Release** has four steps in the same grid as Release: **Prepare Release**, **What's New in This Version**, **Add Build** and **Add for Review**. Green checks show what is ready, yellow marks pending checks or sync, and red identifies missing required information. It always prepares the next version: step 1 reads which version came last and suggests the next number, and a version that is already submitted is shown as done rather than opened again. It reuses the existing listing. Other text, screenshots and release settings stay collapsed until needed. Saving drafts, syncing, Back and Next keep you in Quick Release.

[See Release and Quick Release](#release-and-quick-release).

## Prepare screenshots without moving between tools

Add screenshots from files or Asset Library in **Release → Text and Screenshots**. Check the language and display size, drag screenshots into the order you want, and save the layout. Upload prepares a review of what will change at Apple.

Use **Create Media** to make your own App Store cards with layouts, headlines, fonts and colors, beside a live preview. It works in five numbered steps: display size and cards, screenshots, text and background, saving to Asset Library and adding the cards in Release. Or add your screenshots to **Create AI Cards**, describe the look and message, and choose a service and model. Re-create a card with a new prompt until it feels right; earlier versions stay saved.

Translate the finished card set into more languages while keeping its layout and screenshots. Save the PNGs to **Asset Library**, ready to use in a release.

[See screenshot ordering and card creation](#screenshots-and-card-creation), or [see Asset Library](#asset-library).

## Requirements

Storebench runs on macOS 14 or later, on Apple silicon and Intel Macs. Connecting an app requires an App Store Connect API key with access to that app. Available actions depend on the account's permissions and the app's current state at Apple.

Storebench comes in two editions with the same features. The direct edition is a universal app from [GitHub Releases](https://github.com/compilererrors/Storebench/releases/latest): download the ZIP, extract it and move Storebench.app to Applications. The Mac App Store edition runs in the App Sandbox, so a backup folder outside the app's own storage is chosen once in the folder dialog and remembered from then on. The two editions keep separate workspaces; move one to the other with a backup.

## Getting started

Choose **Use Keychain** or **Use Password** when Storebench first opens. Both options encrypt saved data and media. Password storage requires your Storebench password to unlock the workspace; keep it safe, because it cannot be recovered.

Connect your API key during setup or in **Settings → Apple accounts**. Choose the original `.p8` file and supply its Key ID if Storebench cannot read it from the filename. Team keys also need their Issuer ID. You can connect several accounts, refresh their app lists and reconnect a key without removing saved app history. **Skip for now** opens an empty workspace so you can connect later.

Use **Overview** or **Apps** to download app material and reports. In Overview's Data status, each app shows a short status without being expanded: how many sources are synced, what needs attention and when it last synced. The sidebar opens each app's editing, release, TestFlight and reporting sections. **Help** contains searchable guidance for setup, permissions and common problems.

Overview keeps releases in compact cards. Expand a card for its requirements or minimize it to keep the overview focused; each version remembers your choice, and the card heading keeps its position while the details change. New versions start expanded unless you choose Minimized in **Settings → General → Release Cards**. After you minimize every card, a compact native popup can offer to make that the default without moving the page. **Ask Later** postpones the question for a day; **No** turns it off. Settings also has a search field: search for a setting or a familiar term and open its section directly.

## Releases and localizations

Prepare a version from existing app material, copy an earlier version or start with an empty local plan. Edit listing text across languages, select a build and check what is still needed before submitting the version.

Each language has Save Draft and Sync to Apple beside its text. Drafts can keep unfinished or over-limit copy locally while you edit. Sync saves changed text first, then opens that language's approval review. Missing screenshots, an unfinished other language and later submission requirements do not block text sync. If preparation fails, the draft stays saved so you can correct the problem and try again. Matching text is not sent twice.

**Localizations** keeps each language's text and character limits together. Pick one source language, select the languages you want and populate them in one go with **Apple Intelligence**, your **ChatGPT plan** or your own **OpenAI, Claude or Gemini model**. **View Changes** shows all changed fields with added and removed words, compared with the Apple import or the loaded draft. Review the drafts and sync when ready. Existing wording stays unless you choose to replace it; names and links are preserved. Translation results distinguish saved drafts, skipped languages and failures, so only failed work needs another request.

Every translation request includes the field's maximum length, counting spaces, punctuation and line breaks, with room below the limit. Translations are checked against each complete field's limit, including the shared 100-byte keyword budget and comma separators. If wording is too long, Storebench asks the selected model to rephrase it concisely, with up to three adjustment rounds, rather than cutting off text. Remote services receive the complete translation request first; only overflowing fields need another request. Apple Intelligence tries each complete text field first and splits it only if Apple reports that its context window was exceeded, then checks the combined translation length. If the result still does not fit, the language is left unchanged and the message identifies the field and its length. Review the wording before syncing.

You can also write the text yourself, reuse saved wording or start a language with Apple's on-device translation. Source comparisons stay beside the edits.

In Release, **Edit** opens the relevant section and focuses its input. **Done** saves that language's text and checks the release step again. **Sync to Apple** opens a review for that language's text independently of screenshots or unfinished edits in other languages. Media has its own save and review actions. Step 3 compares all remaining saved text and media with Apple; content already synced individually is not sent again. When the step is complete, it shows Up to Date. Copyright can be entered and reviewed directly in Release, with an Open Copyright action beside a missing-field warning. Missing submission requirements remain on the release checklist; they do not prevent reviewing an individual text update.

Local drafts and release plans remain separate from what Apple currently has. **History** preserves imported material and saved revisions; **Change journal** records before-and-after values and lets you add local notes. A detected change does not establish when it became public on the App Store.

[See language editing](#localizations).

## Screenshots, app previews and Asset Library

Add screenshots and app previews to a version and language, change their order and review the saved selection. Image editing supports cropping, rotation and resizing while retaining the original.

Click a media card to select it, Command-click to select several or Shift-click for a range. Drag the selection into the highlighted gap; selected items keep their relative order. Right-click a card or open its Actions menu to move the selection to the beginning or end, or one position earlier or later. Double-click a screenshot to open it. Reordering animates the cards into place and respects Reduce Motion. Selection and drag feedback do not save changes; the existing draft and reviewed upload actions still apply.

**Asset Library** keeps encrypted local originals and reads assets already at Apple. Processed assets can be reused across compatible placements. Uploads, placement changes and asset deletion each require an approved review.

**Create Cards** is the visual editor: add your screenshots, pick a layout and style the text beside the preview. Use system fonts, installed fonts or a font file of your own. Save finished cards to Asset Library or export PNGs.

**Create AI Cards** has two ways to start. **Quick** asks only for screenshots: AI writes each card from the screenshot and your app's own App Store name, subtitle, description and keywords, so the cards stay about your app. **Guided** adds a brief, a message for each card and creative directions. Add screenshots from files or from Asset Library, where each screenshot can keep a description and tags that become its card's message. Choose the service and model, generate a set, then adjust any text, layout or color yourself. **Re-create Card** opens the brief and screenshot for another iteration, keeping earlier card sets. **Other Languages** translates the finished set into the languages you choose, keeping the layout and originals and saving each language's cards to Asset Library. Settings → AI → Screenshot Cards sets how new card sets start.

Add creative directions, your own **Prompt Instructions**, notes for individual cards or an exact **Card Colors** palette. The original screenshot stays visible unless you allow cropping. **AI History** in Settings keeps the saved requests and responses so you can return to earlier work.

In **Settings → AI**, use Apple Intelligence on this Mac, connect your ChatGPT plan or add your own OpenAI, Claude or Gemini API key. Choose a model for each job without changing saved defaults. Apple Intelligence requires a compatible Mac with macOS 26 or later. ChatGPT uses your plan's permissions and limits; API connections use the provider's API billing. Selected text and screenshots go only to the service you choose. Credentials stay in protected storage and are excluded from backups.

## Pricing

Manage the app's download price separately from subscriptions and in-app purchases. Read current and scheduled prices, prepare changes by country or region, and compare proposed prices before sending them.

Country prices show saved data immediately and read missing or older schedules automatically. After an approved app-price change, Storebench reads the schedule back from Apple and updates open pricing views without resetting local edits or table selections. If that read fails, the last saved prices remain visible and later visits retry with a short backoff; publishing is never repeated automatically.

Price strategies include Apple's comparable prices, currency conversion, purchasing-power models, the Big Mac Index, saved profiles and manually entered country prices. Apple's comparable prices follow the base country or region you choose; any of Apple's countries or regions can be the base. Saved profiles are recipes that can mix two methods, adjust countries by percentage, keep prices within a lowest and highest price, and use your own index values.

Country prices, country percentages and your own index can be imported from CSV files that use Apple's three-letter territory codes. Prices use the columns of Storebench's own price export, so an exported file can be edited and read back. Copy CSV Format copies each format with example rows, and the pricing help describes every column. Importing only fills in the editor; nothing is saved or sent. Storebench matches proposed amounts to the product's available Apple price points and identifies missing data. Protected app prices are kept out of model and country-draft changes.

Shared profiles and local pricing drafts detect conflicting saves. Reading newer saved values leaves your edits in place until you explicitly choose which baseline to use. Price changes and offers go through the same approval process as other App Store Connect changes.

## App information, App Privacy and App Review

Edit supported app information, age-rating answers, accessibility declarations, availability, export compliance and App Review information. Storebench checks the selected app and the information required for each change.

**App Privacy answers** and **Tax Category** use a separate Apple ID sign-in because they are not available through the API-key connection. Sign-in asks for the Apple ID, password and any required two-factor code. Saving the password for a later sign-in is optional. **Sign Out** in the Apple ID form removes the saved Apple ID session.

## TestFlight

Keep beta testing with the app's release work. Read builds and processing states, handle export compliance, manage internal and external groups and testers, edit test information, and inspect feedback and metrics. **Start Testing** walks through the setup in order, including what is still needed before a build can reach testers. Like every guide, it keeps a bar at the bottom of the window with the open step, Back and Next.

Changes to TestFlight settings, group access, tester assignments and Beta App Review submissions are reviewed before being sent. Apple still controls build processing and beta review.

[See TestFlight builds and groups](#testflight-builds-and-groups).

## Reports and sync

Read **Sales and Trends**, **Analytics**, **Financial Reports** and **Ratings and Reviews**. Sales and Finance can use the API connection or a separately configured Reporter token. Reporter downloads use HTTPS directly.

Sync downloads data and keeps saved drafts. It shows incomplete sources separately so a partial download is not presented as a complete sync. Missing reports and unverified values remain unknown. An explicit, validated day without sales is recorded separately from a report Apple has not delivered.

Sales, Analytics and ASO views share the same date choices: 7, 30 or 90 days, 6 months, 1 year, this year, all saved dates or your own range. Sales analysis shows report coverage, original currencies, trends and country totals. Analytics and ASO views help compare reported activity with recorded changes while retaining coverage and source information. Generating Analytics reports at Apple requires an approved review. Financial downloads have a separate local review before replacing saved reports.

## Keyword ideas

Keep a local notebook of keyword ideas by language and territory, with evidence notes, filters and bulk changes. Preview selected ideas against a listing's current keywords and UTF-8 byte budget before applying them to the unsaved text. Notebook imports and exports support CSV and JSON.

## Reviewing changes at Apple

**App Store changes** shows the exact operations prepared for one account and app. Preparing a review does not send those operations. Approval applies once to that review, and Storebench reads Apple again to check that the reviewed state is still current.

A changed draft, changed Apple state or expired review requires a new review. If publishing is interrupted, some earlier operations may already have reached Apple. Storebench records the result and requires a new review instead of replaying the interrupted run.

[See the review before sending](#review-before-sending).

## Storage and backups

Saved metadata, drafts, revisions and reports live in an encrypted local SQLCipher database. Media files are encrypted separately. Credentials use the storage provider selected for the workspace: macOS Keychain or a password-encrypted credential file. Security settings also offer Mac authentication and protected Keychain access.

Use a private local disk for the workspace. A network share or file-synchronization folder is not supported for live workspace data. Saved material survives restarts; unsaved form edits still need to be saved.

Every screenshot, preview and other media file is kept once, however many imports, drafts and saved versions use it; each of them names the file by its checksum. Encrypted backups include saved workspace data and media and require a restore passphrase. A backup also keeps one copy of each unchanged media file where the disk allows it: on the same APFS disk as the data it shares the file's storage, and on another APFS disk each new backup shares unchanged files with the one before. Every backup is still complete on its own and is checked file by file. Automatic backups use a folder you choose. Keep the passphrase separately from the backup and reconnect Apple credentials when restoring on another Mac. The workspace itself is not a backup.

CSV and JSON imports preview their local changes before saving. Exports can contain private app information and should be stored accordingly. Importing local material does not publish it to Apple.

## Settings and navigation

Settings cover accounts, reporting connections, storage protection, backups, appearance, editing, keyboard shortcuts and performance. Storage Cleanup removes two things by itself, each after a number of days you choose: reviews that were prepared but never sent, 30 days after they expired, and the images kept with AI requests, 90 days after the request ended. Either can be turned off. A review with a note in Change Journal is kept, an AI request keeps its text and answer, and nothing sent to Apple, no saved listing, no draft and no report is ever removed. After a cleanup that frees a large part of the database file, the file is made smaller. The Performance setting controls cache budgets and how long background reads are reused. Its Background Activity level sets how many requests go to App Store Connect at once, how often background checks run and how many apps are prepared ahead: Full, Balanced or Light, or Automatic, which lowers it in Low Power Mode or when the Mac runs hot. The lowest level also waits while another app is in front and draws changes without animation. Screens show cached results before checking Apple again, sharing requests already in progress. Saved screen results can be restored from encrypted SQL after memory eviction, with decoding away from the interface thread.

AI settings show ChatGPT and Claude connections directly. Connect ChatGPT in your browser to use your plan, or add your own Claude API key and choose a model. Apple Intelligence runs on this Mac; OpenAI and Gemini API connections are available under Other API Services. Each task can choose its own service and model.

Background Preparation sets how many apps are prepared ahead, the most used first, and Always Prepare names apps that are prepared every time, right after the open one. Importing an app's material reads only the versions that can still change, a few languages side by side; versions a newer one replaced are kept from the previous import. At startup each prepared app's saved import is compared with Apple's version list in one small read; while they match, Release and Quick Release start from it at once, and only a new version, number or state at Apple downloads the material again. Visible reads take priority over preparation in the background. Within the same priority, small metadata requests go before larger pages and downloads, with a bounded wait for older requests. Local history arrives before remote preparation starts. Manual refresh replaces affected reads; publishing approval always checks fresh information.

While Storebench is open and unlocked, lightweight background checks run after unlocking, when returning to the app and periodically. App discovery is reused for 15 minutes across sessions; connecting an account already counts as a successful discovery. Failed accounts keep their saved apps and retry with increasing delays, while other accounts continue. Manual **Refresh Apps** bypasses that waiting period. Preparation checks a bounded number of recent release plans about every 10 minutes, following the **Apps to prepare** setting and the remaining Apple request budget. These checks reuse the existing read queue and status stores; report downloads and material imports keep their own workflows. A changed app list waits until open editors are ready before replacing their navigation context. Locking or quitting stops the scheduled reads.

Unsaved editors ask you to save, discard or keep editing before leaving. Back and Forward retain navigation history. Keyboard shortcuts can be changed in Settings, and Command–Comma opens Settings.

## Build from source

Building requires Xcode or the Xcode Command Line Tools with Swift 6. Resolve the pinned SQLCipher dependency, then build the app and unsigned installer:

```bash
swift package resolve --package-path macos --disable-keychain --disable-netrc
scripts/package-mac.sh
```

The public packaging command builds a universal app with placeholder version metadata and ad-hoc signatures for local execution. The installer is unsigned. Packaging does not start, install or upload the app.

The app's screens are built from shared design components. [Design components](docs/design-components.md) describes how buttons, labels, button groups and status rows are sized and placed, so new screens look and behave like the rest of the app.

## Tests

Run tests through the isolated runner:

```bash
scripts/test-swift.sh unit
```

The runner uses synthetic data in a fresh owned workspace. Its macOS sandbox blocks networking, private home data and writes outside that run. Tests do not launch the app, access real Keychain entries or use real Apple accounts. The pinned dependency must already be available locally.

## License

Storebench is source-available. Personal and other non-commercial use is free. Business use requires an active subscription for each person who uses Storebench, available through the Mac App Store, or another commercial license from the licensor. Business use ends with the subscription. See [LICENSE](LICENSE).

## Screenshots

These screenshots show Storebench's native Mac interface with synthetic app data and example model names.

### Pricing models

One guide price, several ways to price the world. Choose PPP, Big Mac Index, currency conversion, Same for all, your own profiles, Apple's comparable prices or manual prices.

![Prices by Country or Region with a prominent Price Model selector, only the selected PPP model's settings, and Countries with No or Few Purchases](docs/images/pricing-models.png)

Preview the countries together, rounded to Apple's available price points.

![Country-pricing preview from a saved profile, with synthetic model prices beside the Apple price points they round to](docs/images/pricing.png)

### ASO history

Follow listing changes on the report timeline, then compare the same number of days before and after an update.

![ASO timeline with listing-change markers, a campaign note and four report measures on an indexed scale](docs/images/aso-progress.png)

![Saved listing revisions with changes in report measures over equal periods before and after each update](docs/images/storebench.png)

### Release and Quick Release

**Release** takes you from the questions about your app to App Review and release. Checks and editors stay together: fix what's missing and move to the next step.

![The Release guide showing the saved version, starting material and numbered release steps](docs/images/release-guide.png)

**Quick Release** keeps a version bump small. Follow four numbered steps beside the working pane: prepare the version, add What's New, choose the build, then Add for Review. Carry over your listing and keep other settings collapsed. If an existing Apple version prevents a new one, its status and Open Version link show what to resolve while your local draft stays saved.

![The Quick Release page with numbered steps for a saved version](docs/images/quick-release.png)

Need an ASO tweak? Open **Other Listing Text** for Description, Subtitle and Keywords. Each step ends with **Save Draft**, which keeps your work on this Mac, and **Sync to Apple**, which opens a review of the exact change, such as creating the version or adding the build, before anything is sent. **Add for Review** opens the submission review. Until everything is ready, Add for Review lists what is still needed, each with a button that does it: **Sync to Apple** for text Apple doesn't have yet, **Add Build** for the build, or **Edit**. Need a newer build while the version waits for review? Replace the Build removes it from review, then keeps checking App Store Connect for the newer upload, shows it as soon as Apple has received it and while it is processed, and chooses it when it is ready. Every build shows the day and time it was uploaded. Add Build adds the new build and Add for Review sends it again, each after your approval. After you approve a sync, its dialog shows the progress; **Run in Background** lets you keep working while it goes on, with its progress at the bottom of the window on every page. Everything stays in Quick Release.

![Quick Release with Other Listing Text expanded in the working pane](docs/images/quick-release-text.png)

### TestFlight builds and groups

![Uploaded TestFlight build with testing status and export compliance actions](docs/images/testflight.png)

### Screenshots and card creation

![A release's screenshot order for one language and display size, with thumbnails and reorder controls](docs/images/screenshots.png)

**Create Cards:** pick a layout, write the headline and style your card beside the preview.

![Create Media with an App Store card preview, editable title and card styling controls](docs/images/create-media.png)

**Create AI Cards:** start Quick from your screenshots and your app's App Store text, or Guided with a brief and a message per card, then iterate with Re-create Card. Your screenshots and earlier versions stay saved.

![Create AI Cards with an editable brief, creative directions and the previous card kept for another iteration](docs/images/create-ai-cards.png)

Choose a service and model for the job. Translate the finished set for more languages while keeping its design and screenshots.

![AI card creation with a model choice, a selected original screenshot and the Generate Cards action](docs/images/create-ai-models.png)

### Asset Library

![A saved local screenshot original with its preview, dimensions and upload review action in Asset Library](docs/images/asset-library.png)

### Review before sending

![The exact App Store Connect changes and before/after values before they are sent](docs/images/review-changes.png)

### Localizations

One source, several languages. Choose Apple Intelligence, your ChatGPT plan or a connected OpenAI, Claude or Gemini model, then translate the selected languages together. In Release step 2 you can translate screenshots too: card sets made in Create Media are translated, rendered as new PNGs and placed in each language's matching display size. Text is fitted to App Store limits by rewording, then by leaving out whole closing sentences or the last keywords, never mid-word. Review the drafts before syncing.

![Translate Languages with AI with a source language, target-language selection and the open AI Service menu](docs/images/localizations-ai.png)

![Localizations with listing fields and character limits for each language](docs/images/localizations.png)

### Sales and Trends

![Paid app purchase totals, countries and report coverage for saved Sales reports](docs/images/sales.png)
