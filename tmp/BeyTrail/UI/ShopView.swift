import SwiftUI

/// 特效商店（對應 Android ShopBottomSheetFragment）：
/// 特效包卡片（全擁有自動隱藏）、單品購買（下架不顯示）、已擁有 + 快捷選單管理、20 秒試用。
struct ShopView: View {
    var onPreview: (EffectType) -> Void
    @StateObject private var store = StoreManager.shared
    @State private var quickMenu = SettingsStore.quickMenu
    @Environment(\.dismiss) private var dismiss

    private var purchasable: [EffectType] {
        EffectType.allCases.filter { $0.locked && !$0.delisted }
    }
    private var ownedEffects: [EffectType] {
        EffectType.allCases.filter { !$0.locked }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // ── 限定特效包（全擁有自動隱藏，防重複購買） ──
                    if !store.bundleFullyOwned {
                        bundleCard
                    }

                    if !purchasable.isEmpty {
                        Text("單件特效").font(.caption).foregroundColor(.gray)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                  spacing: 10) {
                            ForEach(purchasable) { effect in purchasableCard(effect) }
                        }
                    }

                    Text("已擁有").font(.caption).foregroundColor(.gray)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 10) {
                        ForEach(ownedEffects) { effect in ownedCard(effect) }
                    }

                    Text("快捷選單 \(quickMenu.count)/6")
                        .font(.caption).foregroundColor(.gray)
                    HStack {
                        ForEach(0..<6, id: \.self) { i in
                            Text(i < quickMenu.count ? quickMenu[i].emoji : "—")
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.11))
            .navigationTitle("特效商店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var bundleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("🎁").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("限定特效包").bold().foregroundColor(.white)
                    Text("滔天浪潮 + 不滅鋼盾 + 爆刃亂舞 + 狂暴冰裂")
                        .font(.caption2).foregroundColor(.gray)
                }
            }
            Button {
                Task { _ = await store.purchase(EffectType.bundleProductId) }
            } label: {
                Text("立即購買  \(store.priceText(EffectType.bundleProductId))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(LinearGradient(
                        colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(10)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private func purchasableCard(_ effect: EffectType) -> some View {
        VStack(spacing: 4) {
            Text(effect.emoji).font(.largeTitle)
                .onTapGesture { onPreview(effect) }   // 點 emoji = 20 秒試用
            Text(effect.displayName).font(.caption).bold().foregroundColor(.white)
            Text(effect.blurb).font(.system(size: 9)).foregroundColor(.gray)
            Button {
                Task { _ = await store.purchase(effect.productId ?? "") }
            } label: {
                Text(store.priceText(effect.productId ?? ""))
                    .font(.caption).bold().foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color.cyan.opacity(0.4)).cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06)).cornerRadius(12)
    }

    private func ownedCard(_ effect: EffectType) -> some View {
        let inMenu = quickMenu.contains(effect)
        return VStack(spacing: 4) {
            Text(effect.emoji).font(.largeTitle)
                .onTapGesture { onPreview(effect) }
            Text(effect.displayName).font(.caption).bold().foregroundColor(.white)
            Button {
                if inMenu { quickMenu.removeAll { $0 == effect } }
                else if quickMenu.count < 6 { quickMenu.append(effect) }
                SettingsStore.quickMenu = quickMenu
            } label: {
                Text(inMenu ? "從選單移除" : "＋ 加入選單")
                    .font(.system(size: 10))
                    .foregroundColor(inMenu ? .red : .cyan)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color.white.opacity(0.08)).cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06)).cornerRadius(12)
    }
}
