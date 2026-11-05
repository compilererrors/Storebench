import Foundation
import Observation

public struct ProductPriceInputs: Sendable, Equatable {
    public var pointId = ""
    public var startDate = ""
    public var planType = ""
    public var subscriberPolicy = ""
    public init() {}
    public func request(accountId: String, appId: String, product: PriceProduct, schedule: ProductPriceSchedule, territory: String, points: [ProductPricePoint], today: String) throws -> PublishRequest {
        let initial = ProductPricePresentation.initialPurchase(kind: product.kind, schedule: schedule)
        guard ProductPricing.calendarDate(today), ProductPricing.territory(territory),
              points.filter({ $0.id == pointId }).count == 1,
              let point = points.first(where: { $0.id == pointId }), point.territory == territory,
              point.customerPrice?.isEmpty == false, point.currency?.isEmpty == false,
              startDate.isEmpty || ProductPricing.calendarDate(startDate) && startDate >= today else {
            throw PublishFailure.invalid("Choose a known Apple price level and a valid date from today onwards.")
        }
        var request = PublishRequest(accountId: accountId, appId: appId, scope: .productPricing)
        if product.kind == .subscription {
            guard ["", "MONTHLY", "UPFRONT"].contains(planType), ["yes", "no"].contains(subscriberPolicy) else {
                throw PublishFailure.invalid("Choose a billing plan and an explicit policy for existing subscribers.")
            }
            request.subscriptionPrice = .init(productId: product.id, territory: territory, pricePointId: point.id, startDate: startDate.isEmpty ? nil : startDate,
                planType: planType.isEmpty ? nil : planType, preserveCurrentPrice: subscriberPolicy == "yes")
        } else {
            let last = "\((Int(today.prefix(4)) ?? 0) + 1)-12-31"
            guard initial || schedule.available && schedule.scheduleId?.isEmpty == false && schedule.baseTerritory?.isEmpty == false && !startDate.isEmpty && startDate <= last else {
                throw PublishFailure.invalid("A complete purchase schedule and a date through the end of next year are required.")
            }
            request.purchasePrice = .init(productId: product.id, territory: territory, pricePointId: point.id, startDate: initial ? nil : startDate)
        }
        return try request.validated()
    }
}

public struct ProductPriceMaterial: Sendable {
    public let scope: RecoveryGuidance.Scope, product: PriceProduct, schedule: ProductPriceSchedule, activeTerritories: [String]?
    public init(scope: RecoveryGuidance.Scope, product: PriceProduct, schedule: ProductPriceSchedule, activeTerritories: [String]?) {
        self.scope = scope; self.product = product; self.schedule = schedule; self.activeTerritories = activeTerritories
    }
}

/// One product reader and unsaved proposal. A retired reader remains busy until its physical operation acknowledges completion.
@MainActor @Observable public final class ProductPricesEditor {
    public let scope: RecoveryGuidance.Scope
    public private(set) var catalog: ProductCatalog?
    public private(set) var material: ProductPriceMaterial?
    public private(set) var selectionKey = ""
    public private(set) var territory = ""
    public private(set) var points: [ProductPricePoint]?
    public private(set) var inputs = ProductPriceInputs()
    public private(set) var amount = ""
    public private(set) var review: PublishReview?
    public private(set) var reading = false
    public private(set) var publishing = false
    public private(set) var active = true
    public private(set) var status = ""
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private var baseline = ProductPriceInputs()
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private let readCatalog: @MainActor () async throws -> ProductCatalog
    @ObservationIgnored private let readMaterial: @MainActor (PriceProduct) async throws -> ProductPriceMaterial
    @ObservationIgnored private let readPoints: @MainActor (PriceProduct, String) async throws -> [ProductPricePoint]
    @ObservationIgnored private let prepareReview: @MainActor (PublishRequest) async throws -> PublishReview
    public var busy: Bool { reading || publishing }
    public var ready: Bool { active && !busy }
    public var dirty: Bool { inputs != baseline }
    public var products: [PriceProduct] { (catalog?.purchases ?? []) + (catalog?.subscriptions ?? []) }
    public var presentation: ProductPricePresentation {
        .init(kind: material?.product.kind, schedule: material?.schedule, today: ProductPricing.day(Date()), activeTerritories: material?.activeTerritories, points: points, amount: amount)
    }
    public init(scope: RecoveryGuidance.Scope, catalog: @escaping @MainActor () async throws -> ProductCatalog,
                material: @escaping @MainActor (PriceProduct) async throws -> ProductPriceMaterial,
                points: @escaping @MainActor (PriceProduct, String) async throws -> [ProductPricePoint],
                prepare: @escaping @MainActor (PublishRequest) async throws -> PublishReview) {
        self.scope = scope; readCatalog = catalog; readMaterial = material; readPoints = points; prepareReview = prepare
    }
    public func update(_ value: ProductPriceInputs) { guard ready else { return }; inputs = value; clearPendingReview(); didChange() }
    public func search(_ value: String) { guard ready else { return }; amount = value; didChange() }
    public func replaceReview(_ value: PublishReview?) {
        guard active else { return }
        guard value == nil || value?.request.accountId == scope.accountId && value?.request.appId == scope.appId && value?.request.scope == .productPricing else { return }
        review = value; didChange()
    }
    public func publishingChanged(_ value: Bool) { publishing = value; didChange() }
    public func discardInputs() { guard ready else { return }; inputs = baseline; clearPendingReview(); didChange() }
    public func retire() { guard active else { return }; active = false; material = nil; points = nil; review = nil; didChange() }
    @discardableResult public func refreshCatalog() async -> Bool {
        guard ready, !dirty else { return false }
        return await run(message: "Reading the app's price products…", read: readCatalog) { value in
            let products = (value.purchases ?? []) + (value.subscriptions ?? [])
            guard Set(products.map(\.selectionKey)).count == products.count else { throw PublishFailure.invalid("Apple returned duplicate price products.") }
            self.catalog = value; self.clearSelection()
        }
    }
    @discardableResult public func select(_ key: String) async -> Bool {
        guard ready, !dirty, !Task.isCancelled else { return false }
        clearSelection(); selectionKey = key
        if key.isEmpty { didChange(); return true }
        guard let selected = products.first(where: { $0.selectionKey == key }) else { status = "Choose a product from this app's current catalog."; didChange(); return false }
        return await run(message: "Reading this product's price schedule…", read: { try await self.readMaterial(selected) }) { value in
            guard value.scope == self.scope, value.product.selectionKey == key else { throw PublishFailure.invalid("The price schedule belongs to a different product or app.") }
            self.material = value
        }
    }
    @discardableResult public func selectTerritory(_ code: String) async -> Bool {
        guard ready, !dirty, !Task.isCancelled, let material, presentation.territories.contains(code) else { return false }
        territory = code; points = nil; resetInputs(); amount = ""
        return await run(message: "Reading this product's allowed price levels…", read: { try await self.readPoints(material.product, code) }) { value in
            guard value.count <= 1200, Set(value.map(\.id)).count == value.count, value.allSatisfy({ $0.territory == code && ProductPricing.opaque($0.id) }) else {
                throw PublishFailure.invalid("Apple returned invalid price levels for this territory.")
            }
            self.points = value; self.inputs.pointId = value.first(where: { $0.customerPrice?.isEmpty == false && $0.currency?.isEmpty == false })?.id ?? ""; self.baseline = self.inputs
        }
    }
    @discardableResult public func prepare(today: String = ProductPricing.day(Date())) async -> Bool {
        guard ready, let material, let points, presentation.territories.contains(territory) else { return false }
        do {
            let request = try inputs.request(accountId: scope.accountId, appId: scope.appId, product: material.product, schedule: material.schedule, territory: territory, points: points, today: today)
            return await run(message: "Preparing the exact price review…", read: { try await self.prepareReview(request) }) { value in
                guard value.request.accountId == self.scope.accountId, value.request.appId == self.scope.appId, value.request.scope == .productPricing else { throw PublishFailure.invalid("The price review belongs to another app.") }
                self.review = value
            }
        } catch { status = (error as? PublishFailure)?.message ?? "The price choices could not be confirmed."; didChange(); return false }
    }
    private func clearPendingReview() { if review?.state != "complete" { review = nil } }
    private func resetInputs() { inputs = .init(); baseline = inputs; clearPendingReview() }
    private func clearSelection() { selectionKey = ""; material = nil; territory = ""; points = nil; amount = ""; resetInputs() }
    private func run<Value: Sendable>(message: String, read: @MainActor () async throws -> Value, apply: @MainActor (Value) throws -> Void) async -> Bool {
        guard ready, !Task.isCancelled else { return false }
        let ticket = UUID(); operation = ticket; reading = true; status = message; didChange()
        defer { if operation == ticket { operation = nil; reading = false; didChange() } }
        do {
            let value = try await read(); try Task.checkCancellation()
            guard active, operation == ticket else { return false }
            try apply(value); status = ""; didChange(); return true
        } catch {
            guard active, operation == ticket else { return false }
            status = Task.isCancelled ? "The read stopped. Existing inputs are kept." : (error as? PublishFailure)?.message ?? "Apple's product prices could not be read completely. Existing inputs are kept."
            didChange(); return false
        }
    }
}

extension ProductPricesEditor {
    public convenience init(account: Account, appId: String, session: WorkspaceSession) throws {
        let scope = try RecoveryGuidance.Scope(accountId: account.id, appId: appId)
        self.init(scope: scope, catalog: {
            let client = try await session.client(for: account)
            return try await session.scopedPriceProducts(account: account, appId: appId, client: client)
        }, material: { product in
            let client = try await session.client(for: account)
            return try await session.scopedProductPriceMaterial(account: account, appId: appId, selected: product, client: client)
        }, points: { product, territory in
            let client = try await session.client(for: account)
            return try await session.scopedProductPricePoints(account: account, appId: appId, selected: product, territory: territory, client: client)
        }, prepare: { request in
            try await session.preparePublishing(account: account, request: request, client: session.client(for: account))
        })
    }
}

extension WorkspaceSession {
    public func scopedPriceProducts(account: Account, appId: String, client: AppStoreConnectClient) async throws -> ProductCatalog {
        try requirePublishingAccount(account, appId: appId, client: client)
        let value = try await priceProducts(appId: appId, client: client)
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client); return value
    }
    public func scopedProductPriceMaterial(account: Account, appId: String, selected: PriceProduct, client: AppStoreConnectClient) async throws -> ProductPriceMaterial {
        try requirePublishingAccount(account, appId: appId, client: client)
        let value = try await productPriceSchedule(appId: appId, productId: selected.id, kind: selected.kind, client: client)
        var active: [String]?
        if ProductPricePresentation.initialPurchase(kind: value.product.kind, schedule: value.schedule) {
            do {
                let items = try ProductPricing.unique(await client.list("/v1/territories?limit=200"), "territories")
                guard !items.isEmpty, items.allSatisfy({ ProductPricing.territory($0.id) && ProductPricing.territory($0.attributes?["currency"]?.string ?? "") }) else { throw PricingFailure.unavailable }
                active = items.map(\.id).sorted()
            } catch { try Task.checkCancellation(); active = nil }
        }
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client)
        return try .init(scope: RecoveryGuidance.Scope(accountId: account.id, appId: appId), product: value.product, schedule: value.schedule, activeTerritories: active)
    }
    public func scopedProductPricePoints(account: Account, appId: String, selected: PriceProduct, territory: String, client: AppStoreConnectClient) async throws -> [ProductPricePoint] {
        let material = try await scopedProductPriceMaterial(account: account, appId: appId, selected: selected, client: client)
        let presentation = ProductPricePresentation(kind: material.product.kind, schedule: material.schedule, today: ProductPricing.day(Date()), activeTerritories: material.activeTerritories, points: nil, amount: "")
        guard presentation.territories.contains(territory) else { throw PublishFailure.invalid("This territory is not available in the product's current price schedule.") }
        let value = try await productPricePoints(product: material.product, territory: territory, client: client)
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client); return value
    }
}
