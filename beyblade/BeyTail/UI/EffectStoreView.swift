import SwiftUI
import StoreKit

struct EffectStoreView: View {

    @Environment(\.dismiss)
    private var dismiss

    @ObservedObject
    private var purchaseStore = EffectPurchaseStore.shared

    @State private var showRestoreResult = false
    @State private var restoreMessage = ""

    private var hasPremiumPack: Bool {
        purchaseStore.purchasedProductIDs.contains(
            EffectType.premiumPackProductID
        )
    }

    private var shouldShowError: Binding<Bool> {
        Binding(
            get: {
                purchaseStore.lastErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    purchaseStore.lastErrorMessage = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        headerSection
                        premiumPackSection
                        individualEffectsSection
                        restoreSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }

                if purchaseStore.isLoadingProducts {
                    loadingOverlay
                }
            }
            .navigationTitle("特效商店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundStyle(.cyan)
                }
            }
            .task {
                await purchaseStore.loadProductsAndEntitlements()
            }
            .alert(
                "恢復購買",
                isPresented: $showRestoreResult
            ) {
                Button("確定", role: .cancel) {}
            } message: {
                Text(restoreMessage)
            }
            .alert(
                "商店訊息",
                isPresented: shouldShowError
            ) {
                Button("確定", role: .cancel) {
                    purchaseStore.lastErrorMessage = nil
                }
            } message: {
                Text(
                    purchaseStore.lastErrorMessage
                        ?? "發生未知錯誤"
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.cyan)

            Text("解鎖更多戰鬥特效")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("可單獨購買特效，或一次解鎖全部付費特效。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Premium pack

    private var premiumPackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("推薦方案")
                .font(.headline)
                .foregroundStyle(.white)

            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .purple.opacity(0.85),
                                        .cyan.opacity(0.85)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)

                        Image(systemName: "crown.fill")
                            .font(.system(size: 29))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("全部特效禮包")
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        Text("一次解鎖全部 9 個付費特效")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))

                        Text("購買後所有單項商品將停止購買")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }

                    Spacer()
                }

                Divider()
                    .overlay(Color.white.opacity(0.12))

                premiumPackButton
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                LinearGradient(
                                    colors: [.purple, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    }
            )
        }
    }

    @ViewBuilder
    private var premiumPackButton: some View {
        if hasPremiumPack {
            Label(
                "全部特效已解鎖",
                systemImage: "checkmark.seal.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.12))
            )
        } else if let product = purchaseStore.premiumPackProduct {
            Button {
                Task {
                    _ = await purchaseStore.purchasePremiumPack()
                }
            } label: {
                HStack(spacing: 8) {
                    if purchaseStore.purchasingProductID == product.id {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "cart.fill")
                    }

                    Text(
                        purchaseStore.purchasingProductID == product.id
                            ? "購買處理中"
                            : "全部解鎖 \(product.displayPrice)"
                    )
                    .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.black)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cyan)
                )
            }
            .disabled(purchaseStore.purchasingProductID != nil)
        } else {
            Text("商品載入中")
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                )
        }
    }

    // MARK: - Individual products

    private var individualEffectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("單一特效")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Text("\(EffectType.shopEffects.count) 個")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            LazyVStack(spacing: 12) {
                ForEach(EffectType.shopEffects) { effect in
                    effectCard(effect)
                }
            }
        }
    }

    private func effectCard(
        _ effect: EffectType
    ) -> some View {
        let productID = effect.productID
        let isIndividuallyPurchased =
            productID.map {
                purchaseStore.purchasedProductIDs.contains($0)
            } ?? false

        let isOwned =
            purchaseStore.isPurchased(effect)

        return HStack(spacing: 14) {
            Text(effect.emoji)
                .font(.system(size: 32))
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(effect.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(effect.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                if hasPremiumPack && !isIndividuallyPurchased {
                    Text("已包含於全部特效禮包")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }

            Spacer(minLength: 8)

            effectAction(
                effect: effect,
                isOwned: isOwned,
                isIndividuallyPurchased: isIndividuallyPurchased
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isOwned
                                ? Color.green.opacity(0.35)
                                : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                }
        )
    }

    @ViewBuilder
    private func effectAction(
        effect: EffectType,
        isOwned: Bool,
        isIndividuallyPurchased: Bool
    ) -> some View {
        if isOwned {
            VStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text(
                    hasPremiumPack && !isIndividuallyPurchased
                        ? "禮包包含"
                        : "已購買"
                )
                .font(.caption2)
                .foregroundStyle(.green)
            }
            .frame(width: 76)
        } else if let product = purchaseStore.product(for: effect) {
            Button {
                Task {
                    _ = await purchaseStore.purchase(effect)
                }
            } label: {
                Group {
                    if purchaseStore.purchasingProductID == product.id {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text(product.displayPrice)
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                    }
                }
                .frame(minWidth: 72)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(
                    Capsule()
                        .fill(Color.cyan)
                )
            }
            .disabled(
                purchaseStore.purchasingProductID != nil
                || purchaseStore.isPurchased(effect)
            )
        } else {
            Text("載入中")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 76)
        }
    }

    // MARK: - Restore

    private var restoreSection: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    let success =
                        await purchaseStore.restorePurchases()

                    restoreMessage = success
                        ? restoredResultMessage
                        : (
                            purchaseStore.lastErrorMessage
                            ?? "恢復購買失敗。"
                        )

                    showRestoreResult = true
                }
            } label: {
                HStack(spacing: 8) {
                    if purchaseStore.isRestoring {
                        ProgressView()
                            .tint(.cyan)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }

                    Text(
                        purchaseStore.isRestoring
                            ? "恢復中"
                            : "恢復購買"
                    )
                }
                .font(.subheadline.bold())
                .foregroundStyle(.cyan)
            }
            .disabled(
                purchaseStore.isRestoring
                || purchaseStore.purchasingProductID != nil
            )

            Text("購買權限會依目前登入 App Store 的 Apple 帳號恢復。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var restoredResultMessage: String {
        if hasPremiumPack {
            return "全部特效禮包已恢復。"
        }

        let restoredCount =
            EffectType.shopEffects.filter {
                purchaseStore.isPurchased($0)
            }.count

        if restoredCount > 0 {
            return "已恢復 \(restoredCount) 個付費特效。"
        }

        return "目前沒有可恢復的購買項目。"
    }

    // MARK: - Loading

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.cyan)

                Text("正在載入商品")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.88))
            )
        }
    }
}
