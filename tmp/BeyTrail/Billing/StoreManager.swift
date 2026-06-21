import Foundation
import StoreKit

/// IAP（StoreKit 2）— 對應 Android BillingManager：
///   - 商品 ID 與 Play 完全一致
///   - entitlement 以 Transaction.currentEntitlements 為準（= Play 的 queryPurchasesAsync，
///     退款後自動消失 → 特效上鎖；本地快取僅供離線啟動）
///   - bundle 購買自動展開解鎖四款單品
@MainActor
final class StoreManager: ObservableObject {

    static let shared = StoreManager()

    static let allProductIds = ["waveeffect", "thundereffect", "vortexeffect",
                                "darkeffect", "bundleeffects"]

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var owned: Set<String> = []

    private var updatesTask: Task<Void, Never>?

    private init() {
        // 啟動先用本地快取（離線可解鎖），再查 StoreKit 覆蓋
        owned = SettingsStore.cachedOwnedProducts
        EffectType.ownedProductIds = owned
        updatesTask = Task { await listenForTransactions() }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updatesTask?.cancel() }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.allProductIds)
            products = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        } catch {
            print("[Store] loadProducts failed: \(error)")
        }
    }

    /// 完整 entitlement 快照（權威來源；退款的購買不在其中 → 自動上鎖）
    func refreshEntitlements() async {
        var current: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil {
                current.insert(t.productID)
            }
        }
        if current.contains(EffectType.bundleProductId) {
            current.formUnion(EffectType.bundleIncludes)
        }
        applyOwned(current)
    }

    func purchase(_ productId: String) async -> Bool {
        guard let product = products[productId] else { return false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    var newOwned = owned
                    newOwned.insert(t.productID)
                    if t.productID == EffectType.bundleProductId {
                        newOwned.formUnion(EffectType.bundleIncludes)
                    }
                    applyOwned(newOwned)
                    return true
                }
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            print("[Store] purchase failed: \(error)")
            return false
        }
    }

    /// 恢復購買
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    var bundleFullyOwned: Bool {
        owned.contains(EffectType.bundleProductId)
            || EffectType.bundleIncludes.isSubset(of: owned)
    }

    func priceText(_ productId: String) -> String {
        products[productId]?.displayPrice ?? "—"
    }

    private func applyOwned(_ set: Set<String>) {
        owned = set
        EffectType.ownedProductIds = set
        SettingsStore.cachedOwnedProducts = set
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let t) = result {
                await t.finish()
                await refreshEntitlements()
            }
        }
    }
}
