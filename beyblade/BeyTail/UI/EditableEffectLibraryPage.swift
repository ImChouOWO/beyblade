import SwiftUI

/// 新版特效商店頁。
///
/// 整個 pageContent 僅在此層套用一次 rotationEffect，
/// 快捷選單編輯器本身不再重複旋轉。
struct EditableEffectLibraryPage: View {
    @Binding var selectedEffect: EffectType
    @Binding var isPresented: Bool

    let rotation: Angle

    @ObservedObject private var purchaseStore =
        EffectPurchaseStore.shared

    @ObservedObject private var quickMenuStore =
        EffectQuickMenuStore.shared

    @State private var trialEffect: EffectType?
    @State private var alertMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var ownedEffects: [EffectType] {
        EffectType.allCases.filter {
            purchaseStore.isPurchased($0)
        }
    }

    private var shopEffects: [EffectType] {
        EffectType.shopEffects.filter {
            !purchaseStore.isPurchased($0)
        }
    }

    private var packContentsText: String {
        EffectType.premiumPackEffects
            .map(\.displayName)
            .joined(separator: " + ")
    }

    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let contentSize = Self.contentSize(
                screenSize: screenSize,
                rotation: rotation
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                pageContent
                    .frame(
                        width: contentSize.width,
                        height: contentSize.height
                    )
                    .clipped()
                    .contentShape(Rectangle())
                    .rotationEffect(rotation)
                    .position(
                        x: screenSize.width / 2,
                        y: screenSize.height / 2
                    )
            }
        }
        .task {
            quickMenuStore.reload()
            await purchaseStore.loadProductsAndEntitlements()
            synchronizeQuickMenuOwnership()
        }
        .onChange(
            of: purchaseStore.purchasedProductIDs
        ) { _ in
            synchronizeQuickMenuOwnership()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { trialEffect != nil },
                set: { presented in
                    if !presented {
                        trialEffect = nil
                    }
                }
            )
        ) {
            if let trialEffect {
                VideoRenderPage(
                    initialEffect: trialEffect,
                    trialEffect: trialEffect,
                    onClose: {
                        self.trialEffect = nil
                    }
                )
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
            }
        }
        .alert(
            "特效商店",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { presented in
                    if !presented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(Color.white.opacity(0.12))

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 22
                ) {
                    limitedPackCard

                    if !shopEffects.isEmpty {
                        sectionTitle("單件特效")

                        LazyVGrid(
                            columns: columns,
                            spacing: 14
                        ) {
                            ForEach(
                                shopEffects,
                                id: \.self
                            ) { effect in
                                EditableEffectShopCard(
                                    effect: effect,
                                    isOwned: false,
                                    isInMenu: false,
                                    displayPrice:
                                        purchaseStore
                                        .displayPrice(for: effect),
                                    isBusy:
                                        purchaseStore
                                        .purchasingProductID
                                        == effect.productID,
                                    onPrimary: {
                                        purchase(effect)
                                    },
                                    onTrial: {
                                        trialEffect = effect
                                    }
                                )
                            }
                        }
                    }

                    sectionTitle("已擁有")

                    QuickEffectMenuRow(
                        quickMenuStore: quickMenuStore,
                        ownedEffects: ownedEffects,
                        selectedEffect: $selectedEffect
                    )

                    LazyVGrid(
                        columns: columns,
                        spacing: 14
                    ) {
                        ForEach(
                            ownedEffects,
                            id: \.self
                        ) { effect in
                            EditableEffectShopCard(
                                effect: effect,
                                isOwned: true,
                                isInMenu:
                                    quickMenuStore.contains(effect),
                                displayPrice:
                                    effect.isDefaultOwned
                                    ? "免費"
                                    : "已購買",
                                isBusy: false,
                                onPrimary: {
                                    toggleMenuEffect(effect)
                                },
                                onTrial: nil
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .background(Color.black)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))

                    Text("返回")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
            }

            Spacer()

            Text("特效商店")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            Button {
                restorePurchases()
            } label: {
                HStack(spacing: 5) {
                    if purchaseStore.isRestoring {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }

                    Text("恢復")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: 82, height: 36)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
            }
            .disabled(purchaseStore.isRestoring)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var limitedPackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("🎁")
                    .font(.system(size: 42))

                VStack(alignment: .leading, spacing: 5) {
                    Text("限定特效包")
                        .font(.system(size: 22, weight: .black))
                        .foregroundColor(.white)

                    Text(packContentsText)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)

                    Text(
                        purchaseStore.ownsPremiumPackContent
                        ? "已擁有限定特效包內容"
                        : purchaseStore.premiumPackDisplayPrice
                    )
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(Color(hex: 0x00F5FF))
                }

                Spacer()
            }

            Button {
                purchaseLimitedPack()
            } label: {
                HStack(spacing: 8) {
                    if purchaseStore.purchasingProductID
                        == EffectType.premiumPackProductID {
                        ProgressView()
                            .tint(.white)
                    }

                    Text(
                        purchaseStore.ownsPremiumPackContent
                        ? "已擁有"
                        : "購買限定特效包"
                    )
                    .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xBF5FFF),
                            Color(hex: 0x00F5FF)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: 10)
                )
            }
            .disabled(
                purchaseStore.ownsPremiumPackContent
                || purchaseStore.purchasingProductID != nil
            )
            .opacity(
                purchaseStore.ownsPremiumPackContent
                ? 0.45
                : 1
            )
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    Color(hex: 0x07111F)
                        .opacity(0.95)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            Color(hex: 0x00F5FF)
                                .opacity(0.32),
                            lineWidth: 1.4
                        )
                )
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white.opacity(0.55))
    }

    private func toggleMenuEffect(_ effect: EffectType) {
        guard purchaseStore.isPurchased(effect) else {
            return
        }

        if quickMenuStore.contains(effect) {
            _ = quickMenuStore.remove(effect)

            if selectedEffect == effect {
                selectedEffect =
                    quickMenuStore.effects.first
                    ?? EffectType.defaultMenuEffects.first
                    ?? .lightning
            }
            return
        }

        guard !quickMenuStore.isFull else {
            alertMessage = "快捷選單最多 6 個特效"
            return
        }

        if quickMenuStore.add(effect) {
            selectedEffect = effect
        }
    }

    private func synchronizeQuickMenuOwnership() {
        quickMenuStore.removeUnownedEffects {
            purchaseStore.isPurchased($0)
        }

        if !purchaseStore.isPurchased(selectedEffect) {
            selectedEffect =
                quickMenuStore.effects.first
                ?? EffectType.defaultMenuEffects.first
                ?? .lightning
        }
    }

    private func purchase(_ effect: EffectType) {
        Task {
            _ = await purchaseStore.purchase(effect)

            if let message =
                purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
    }

    private func purchaseLimitedPack() {
        Task {
            _ = await purchaseStore.purchasePremiumPack()

            if let message =
                purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
    }

    private func restorePurchases() {
        Task {
            let restored =
                await purchaseStore.restorePurchases()

            if restored {
                alertMessage = "購買紀錄已恢復"
            } else if let message =
                purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
    }

    private static func contentSize(
        screenSize: CGSize,
        rotation: Angle
    ) -> CGSize {
        if isQuarterTurn(rotation) {
            return CGSize(
                width: screenSize.height,
                height: screenSize.width
            )
        }
        return screenSize
    }

    private static func isQuarterTurn(
        _ angle: Angle
    ) -> Bool {
        let degrees = normalizedDegrees(angle.degrees)
        return abs(degrees - 90) < 0.5
            || abs(degrees - 270) < 0.5
    }

    private static func normalizedDegrees(
        _ degrees: Double
    ) -> Double {
        var value = degrees.truncatingRemainder(
            dividingBy: 360
        )
        if value < 0 {
            value += 360
        }
        return value
    }
}

private struct EditableEffectShopCard: View {
    let effect: EffectType
    let isOwned: Bool
    let isInMenu: Bool
    let displayPrice: String
    let isBusy: Bool
    let onPrimary: () -> Void
    let onTrial: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(effect.emoji)
                    .font(.system(size: 34))

                Spacer()

                Text(isOwned ? displayPrice : "付費")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.62))
            }

            Text(effect.displayName)
                .font(.system(size: 17, weight: .black))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(effect.description)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 38)

            Spacer(minLength: 2)

            Button(action: onPrimary) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    }

                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(primaryBackground)
                .clipShape(
                    RoundedRectangle(cornerRadius: 9)
                )
            }
            .disabled(isBusy)

            if let onTrial, !isOwned {
                Button(action: onTrial) {
                    Text("試用 10 秒")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: 0x00F5FF))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.065))
                        .clipShape(
                            RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(
                                    Color(hex: 0x00F5FF)
                                        .opacity(0.35),
                                    lineWidth: 1
                                )
                        )
                }
            }
        }
        .padding(14)
        .frame(height: isOwned ? 226 : 262)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.065))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    private var primaryTitle: String {
        if !isOwned {
            return displayPrice
        }
        return isInMenu
            ? "從選單移除"
            : "加入選單"
    }

    private var primaryBackground: LinearGradient {
        if !isOwned {
            return LinearGradient(
                colors: [
                    Color(hex: 0xBF5FFF),
                    Color(hex: 0x00F5FF)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        if isInMenu {
            return LinearGradient(
                colors: [
                    Color.red.opacity(0.55),
                    Color.red.opacity(0.35)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        return LinearGradient(
            colors: [
                Color(hex: 0x00F5FF).opacity(0.55),
                Color(hex: 0x0088FF).opacity(0.55)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
