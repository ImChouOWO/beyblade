import Foundation
import StoreKit
import Combine

@MainActor
final class EffectPurchaseStore: ObservableObject {
    static let shared = EffectPurchaseStore()

    @Published private(set) var productsByID: [String: Product] = [:]
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var isRestoring = false
    @Published var lastErrorMessage: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    private init() {
        transactionUpdatesTask = Task.detached(
            priority: .background
        ) { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else {
                    continue
                }
                await transaction.finish()
                await self?.refreshPurchasedProducts()
            }
        }

        Task {
            await loadProductsAndEntitlements()
        }
    }

    func loadProductsAndEntitlements() async {
        await loadProducts()
        await refreshPurchasedProducts()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }

        isLoadingProducts = true
        lastErrorMessage = nil
        defer { isLoadingProducts = false }

        let requestedIDs = EffectType.allProductIDs

        do {
            let products = try await Product.products(
                for: Array(requestedIDs)
            )
            productsByID = Dictionary(
                uniqueKeysWithValues: products.map {
                    ($0.id, $0)
                }
            )

            let missingIDs = requestedIDs.subtracting(
                Set(products.map(\.id))
            )
            if !missingIDs.isEmpty {
                lastErrorMessage =
                    "StoreKit 有 \(missingIDs.count) 個商品未載入"
            }
        } catch {
            productsByID = [:]
            lastErrorMessage =
                "無法載入商品：\(error.localizedDescription)"
        }
    }

    func refreshPurchasedProducts() async {
        var purchased = Set<String>()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else {
                continue
            }
            purchased.insert(transaction.productID)
        }

        purchasedProductIDs = purchased
    }

    var hasPurchasedPremiumPack: Bool {
        purchasedProductIDs.contains(
            EffectType.premiumPackProductID
        )
    }

    var ownsPremiumPackContent: Bool {
        EffectType.premiumPackEffects.allSatisfy {
            isPurchased($0)
        }
    }

    func isPurchased(_ effect: EffectType) -> Bool {
        if effect.isDefaultOwned {
            return true
        }

        if hasPurchasedPremiumPack,
           effect.isIncludedInPremiumPack {
            return true
        }

        guard let productID = effect.productID else {
            return false
        }

        return purchasedProductIDs.contains(productID)
    }

    func product(for effect: EffectType) -> Product? {
        guard let productID = effect.productID else {
            return nil
        }
        return productsByID[productID]
    }

    var premiumPackProduct: Product? {
        productsByID[EffectType.premiumPackProductID]
    }

    func displayPrice(for effect: EffectType) -> String {
        effect.isDefaultOwned
        ? "免費"
        : product(for: effect)?.displayPrice ?? "載入價格中"
    }

    var premiumPackDisplayPrice: String {
        premiumPackProduct?.displayPrice ?? "載入價格中"
    }

    func purchase(_ effect: EffectType) async -> Bool {
        guard !effect.isDefaultOwned else { return true }

        guard let productID = effect.productID else {
            lastErrorMessage = "特效缺少 StoreKit 商品 ID"
            return false
        }

        if isPurchased(effect) {
            return true
        }

        if productsByID[productID] == nil {
            await loadProducts()
        }

        guard let product = productsByID[productID] else {
            lastErrorMessage = "App Store 找不到商品：\(productID)"
            return false
        }

        return await purchase(product)
    }

    func purchasePremiumPack() async -> Bool {
        if hasPurchasedPremiumPack {
            return true
        }

        if premiumPackProduct == nil {
            await loadProducts()
        }

        guard let product = premiumPackProduct else {
            lastErrorMessage = "App Store 找不到限定特效包"
            return false
        }

        return await purchase(product)
    }

    func restorePurchases() async -> Bool {
        guard !isRestoring else { return false }

        isRestoring = true
        lastErrorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshPurchasedProducts()
            return true
        } catch {
            lastErrorMessage =
                "恢復購買失敗：\(error.localizedDescription)"
            return false
        }
    }

    private func purchase(_ product: Product) async -> Bool {
        purchasingProductID = product.id
        lastErrorMessage = nil
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verificationResult):
                guard case .verified(let transaction) =
                    verificationResult else {
                    lastErrorMessage = "交易驗證失敗"
                    return false
                }

                await transaction.finish()
                await refreshPurchasedProducts()
                return true

            case .pending:
                lastErrorMessage =
                    "交易等待核准，核准完成後會自動解鎖"
                return false

            case .userCancelled:
                return false

            @unknown default:
                lastErrorMessage = "App Store 回傳未知交易狀態"
                return false
            }
        } catch {
            lastErrorMessage =
                "購買失敗：\(error.localizedDescription)"
            return false
        }
    }
}
