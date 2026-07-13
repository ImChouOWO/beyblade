import SwiftUI

private let quickEffectAccentColor = Color(
    red: 0,
    green: 245.0 / 255.0,
    blue: 1
)

struct QuickEffectMenuView: View {
    @Binding var selectedEffect: EffectType
    @Binding var isVisible: Bool

    @ObservedObject private var purchaseStore =
        EffectPurchaseStore.shared

    var dragLocation: CGPoint? = nil

    /// 保留既有 API；旋轉仍由 ContentView 父層負責。
    var rotation: Angle = .zero

    @AppStorage(EffectQuickMenuStore.storageKey)
    private var effectMenuIDsRaw: String = ""

    @State private var rowFrames: [EffectType: CGRect] = [:]
    @State private var menuFrame: CGRect = .zero
    @State private var hoveredEffect: EffectType?

    private var menuEffects: [EffectType] {
        Array(
            EffectQuickMenuStore
                .decode(effectMenuIDsRaw)
                .filter {
                    purchaseStore.isPurchased($0)
                }
                .prefix(EffectQuickMenuStore.maximumCount)
        )
    }

    private var displayedEffects: [EffectType] {
        Array(menuEffects.reversed())
    }

    private var menuHeight: CGFloat {
        let count = max(displayedEffects.count, 1)
        return 16
            + CGFloat(count) * 50
            + CGFloat(max(count - 1, 0)) * 5
    }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(displayedEffects, id: \.self) { effect in
                QuickEffectRowView(
                    effect: effect,
                    isSelected: effect == selectedEffect,
                    isHovered: effect == hoveredEffect,
                    onTap: {
                        selectEffect(effect)
                    }
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key:
                                    QuickEffectRowFramePreferenceKey.self,
                                value: [
                                    effect:
                                        proxy.frame(in: .global)
                                ]
                            )
                    }
                )
            }
        }
        .padding(.vertical, 8)
        .frame(width: 220)
        .frame(height: menuHeight)
        .background(menuBackground)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key:
                            QuickEffectMenuFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onPreferenceChange(
            QuickEffectRowFramePreferenceKey.self
        ) { frames in
            rowFrames = frames

            DispatchQueue.main.async {
                updateSelectionByDragLocation(
                    dragLocation
                )
            }
        }
        .onPreferenceChange(
            QuickEffectMenuFramePreferenceKey.self
        ) { frame in
            menuFrame = frame
        }
        .onChange(of: dragLocation) { newLocation in
            updateSelectionByDragLocation(newLocation)
        }
        .onChange(of: effectMenuIDsRaw) { _ in
            normalizePersistedOrder()
            removeInvalidSelectionIfNeeded()
        }
        .onChange(
            of: purchaseStore.purchasedProductIDs
        ) { _ in
            removeInvalidSelectionIfNeeded()
        }
        .onAppear {
            initializeDefaultMenuIfNeeded()
            normalizePersistedOrder()
            removeInvalidSelectionIfNeeded()
        }
        .onDisappear {
            hoveredEffect = nil
            rowFrames.removeAll()
            menuFrame = .zero
        }
        .transition(
            .asymmetric(
                insertion:
                    .move(edge: .bottom)
                    .combined(with: .opacity),
                removal:
                    .move(edge: .bottom)
                    .combined(with: .opacity)
            )
        )
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(white: 0.04).opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        quickEffectAccentColor.opacity(0.18),
                        lineWidth: 1
                    )
            )
    }

    private func selectEffect(_ effect: EffectType) {
        guard menuEffects.contains(effect) else {
            return
        }

        selectedEffect = effect

        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
    }

    private func initializeDefaultMenuIfNeeded() {
        guard UserDefaults.standard.object(
            forKey: EffectQuickMenuStore.storageKey
        ) == nil else {
            return
        }

        effectMenuIDsRaw = EffectQuickMenuStore.encode(
            EffectType.defaultMenuEffects
        )
    }

    private func normalizePersistedOrder() {
        let normalizedRaw =
            EffectQuickMenuStore.normalizeRaw(
                effectMenuIDsRaw
            )

        if normalizedRaw != effectMenuIDsRaw {
            effectMenuIDsRaw = normalizedRaw
        }
    }

    private func removeInvalidSelectionIfNeeded() {
        guard !menuEffects.isEmpty else {
            selectedEffect =
                EffectType.defaultMenuEffects.first
                ?? .lightning
            return
        }

        if !menuEffects.contains(selectedEffect) {
            selectedEffect =
                menuEffects.first
                ?? EffectType.defaultMenuEffects.first
                ?? .lightning
        }
    }

    private func squaredDistance(
        from point: CGPoint,
        to frame: CGRect
    ) -> CGFloat {
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }

    private func updateSelectionByDragLocation(
        _ location: CGPoint?
    ) {
        guard let location else {
            hoveredEffect = nil
            return
        }

        guard !rowFrames.isEmpty else {
            return
        }

        let visibleMenuFrame = menuFrame.insetBy(
            dx: -4,
            dy: -4
        )

        let visibleRows = rowFrames.filter {
            $0.value.intersects(visibleMenuFrame)
        }

        let candidates = visibleRows.isEmpty
            ? rowFrames
            : visibleRows

        let nearestEffect = candidates.min {
            squaredDistance(
                from: location,
                to: $0.value
            )
            <
            squaredDistance(
                from: location,
                to: $1.value
            )
        }?.key

        guard let nearestEffect,
              menuEffects.contains(nearestEffect) else {
            return
        }

        hoveredEffect = nearestEffect

        if selectedEffect != nearestEffect {
            selectedEffect = nearestEffect
        }
    }
}

private struct QuickEffectMenuFramePreferenceKey:
    PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(
        value: inout CGRect,
        nextValue: () -> CGRect
    ) {
        let nextFrame = nextValue()
        if !nextFrame.isEmpty {
            value = nextFrame
        }
    }
}

private struct QuickEffectRowFramePreferenceKey:
    PreferenceKey {
    static var defaultValue:
        [EffectType: CGRect] = [:]

    static func reduce(
        value: inout [EffectType: CGRect],
        nextValue: () -> [EffectType: CGRect]
    ) {
        value.merge(nextValue()) { _, newValue in
            newValue
        }
    }
}

private struct QuickEffectRowView: View {
    let effect: EffectType
    let isSelected: Bool
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(effect.emoji)
                    .font(.system(size: 20))

                VStack(
                    alignment: .leading,
                    spacing: 1
                ) {
                    Text(effect.displayName)
                        .font(
                            .system(
                                size: 13,
                                weight: .semibold
                            )
                        )
                        .foregroundColor(
                            Color(white: 0.92)
                        )
                        .lineLimit(1)

                    Text(effect.description)
                        .font(.system(size: 9))
                        .foregroundColor(
                            Color(white: 0.55)
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(
                            .system(
                                size: 12,
                                weight: .bold
                            )
                        )
                        .foregroundColor(
                            quickEffectAccentColor
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(rowBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                rowBorderColor,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var rowBackgroundColor: Color {
        guard isSelected || isHovered else {
            return .clear
        }

        return quickEffectAccentColor.opacity(
            isSelected ? 0.12 : 0.08
        )
    }

    private var rowBorderColor: Color {
        if isSelected {
            return quickEffectAccentColor.opacity(0.4)
        }

        if isHovered {
            return quickEffectAccentColor.opacity(0.25)
        }

        return Color.white.opacity(0.07)
    }
}
