import SwiftUI
import Combine

private let quickEffectMenuAutoScrollTimer = Timer
    .publish(
        every: 0.12,
        on: .main,
        in: .common
    )
    .autoconnect()

private let quickEffectAccentColor = Color(
    red: 0.0,
    green: 245.0 / 255.0,
    blue: 1.0
)

struct QuickEffectMenuView: View {

    @Binding var selectedEffect: EffectType
    @Binding var isVisible: Bool

    @ObservedObject private var purchaseStore =
        EffectPurchaseStore.shared

    /// ContentView 傳入的全螢幕 global 手指位置。
    var dragLocation: CGPoint? = nil

    @AppStorage("effectMenuIDs")
    private var effectMenuIDsRaw: String = ""

    @State private var rowFrames: [EffectType: CGRect] = [:]
    @State private var menuFrame: CGRect = .zero
    @State private var hoveredEffect: EffectType?
    @State private var autoScrollDirection: AutoScrollDirection?

    private let maximumVisibleEffects = 6
    private let autoScrollEdgeSize: CGFloat = 54

    private enum AutoScrollDirection {
        case up
        case down
    }

    private var menuEffects: [EffectType] {
        let configuredEffects = configuredMenuEffects

        let purchasedEffects = configuredEffects.filter {
            purchaseStore.isPurchased($0)
        }

        let fallbackEffects = EffectType.defaultMenuEffects.filter {
            purchaseStore.isPurchased($0)
        }

        let resolvedEffects = purchasedEffects.isEmpty
            ? fallbackEffects
            : purchasedEffects

        return Array(
            resolvedEffects.prefix(maximumVisibleEffects)
        )
    }

    private var configuredMenuEffects: [EffectType] {
        let configuredIDs = Set(
            effectMenuIDsRaw
                .split(separator: ",")
                .map(String.init)
        )

        guard !configuredIDs.isEmpty else {
            return Array(
                EffectType.defaultMenuEffects
                    .prefix(maximumVisibleEffects)
            )
        }

        return Array(
            EffectType.allCases
                .filter {
                    configuredIDs.contains($0.rawValue)
                }
                .prefix(maximumVisibleEffects)
        )
    }

    private var displayedEffects: [EffectType] {
        Array(menuEffects.reversed())
    }

    private var menuHeight: CGFloat {
        let count = max(displayedEffects.count, 1)
        let rowHeight: CGFloat = 50
        let verticalPadding: CGFloat = 16
        let rowSpacing: CGFloat = 5

        return verticalPadding
            + CGFloat(count) * rowHeight
            + CGFloat(max(count - 1, 0)) * rowSpacing
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(
                .vertical,
                showsIndicators: false
            ) {
                VStack(spacing: 5) {
                    ForEach(
                        displayedEffects,
                        id: \.self
                    ) { effect in
                        QuickEffectRowView(
                            effect: effect,
                            isSelected: effect == selectedEffect,
                            isHovered: effect == hoveredEffect,
                            onTap: {
                                selectEffect(effect)
                            }
                        )
                        .id(effect)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: QuickEffectRowFramePreferenceKey.self,
                                        value: [
                                            effect: proxy.frame(in: .global)
                                        ]
                                    )
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 220)
            .frame(height: menuHeight)
            .background(menuBackground)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: QuickEffectMenuFramePreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                }
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
            .onPreferenceChange(
                QuickEffectRowFramePreferenceKey.self
            ) { frames in
                rowFrames = frames

                DispatchQueue.main.async {
                    updateSelectionByDragLocation(dragLocation)
                }
            }
            .onPreferenceChange(
                QuickEffectMenuFramePreferenceKey.self
            ) { frame in
                menuFrame = frame
            }
            .onChange(of: dragLocation) { newLocation in
                updateSelectionByDragLocation(newLocation)
                updateAutoScrollDirection(newLocation)
            }
            .onReceive(quickEffectMenuAutoScrollTimer) { _ in
                guard let direction = autoScrollDirection,
                      dragLocation != nil else {
                    return
                }

                performAutoScrollStep(
                    direction,
                    proxy: scrollProxy
                )
            }
            .onChange(of: effectMenuIDsRaw) { _ in
                enforceMaximumEffectCount()
                removeInvalidSelectionIfNeeded()
            }
            .onChange(of: purchaseStore.purchasedProductIDs) { _ in
                removeInvalidSelectionIfNeeded()
            }
            .onAppear {
                initializeDefaultMenuIfNeeded()
                enforceMaximumEffectCount()
                removeInvalidSelectionIfNeeded()
            }
            .onDisappear {
                hoveredEffect = nil
                autoScrollDirection = nil
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
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(
                Color(white: 0.04)
                    .opacity(0.92)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        quickEffectAccentColor
                            .opacity(0.18),
                        lineWidth: 1
                    )
            )
    }

    private func selectEffect(_ effect: EffectType) {
        guard menuEffects.contains(effect) else {
            return
        }

        selectedEffect = effect

        withAnimation(
            .easeOut(duration: 0.2)
        ) {
            isVisible = false
        }
    }

    private func initializeDefaultMenuIfNeeded() {
        guard effectMenuIDsRaw.isEmpty else {
            return
        }

        effectMenuIDsRaw =
            EffectType.defaultMenuEffects
            .prefix(maximumVisibleEffects)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func enforceMaximumEffectCount() {
        let rawIDs = Set(
            effectMenuIDsRaw
                .split(separator: ",")
                .map(String.init)
        )

        guard !rawIDs.isEmpty else {
            return
        }

        let limitedEffects =
            EffectType.allCases
            .filter {
                rawIDs.contains($0.rawValue)
            }
            .prefix(maximumVisibleEffects)

        let normalizedRaw = limitedEffects
            .map(\.rawValue)
            .joined(separator: ",")

        guard normalizedRaw != effectMenuIDsRaw else {
            return
        }

        effectMenuIDsRaw = normalizedRaw
    }

    private func removeInvalidSelectionIfNeeded() {
        guard !menuEffects.isEmpty else {
            selectedEffect =
                EffectType.defaultMenuEffects.first ?? .lightning
            return
        }

        guard !menuEffects.contains(selectedEffect) else {
            return
        }

        selectedEffect =
            menuEffects.first
            ?? EffectType.defaultMenuEffects.first
            ?? .lightning
    }

    private func updateSelectionByDragLocation(
        _ location: CGPoint?
    ) {
        guard let location else {
            hoveredEffect = nil
            autoScrollDirection = nil
            return
        }

        guard !rowFrames.isEmpty else {
            return
        }

        let visibleMenuFrame =
            menuFrame.insetBy(
                dx: 0,
                dy: -4
            )

        let visibleRows = rowFrames.filter {
            $0.value.intersects(visibleMenuFrame)
        }

        let candidates =
            visibleRows.isEmpty
            ? rowFrames
            : visibleRows

        let targetY: CGFloat

        if menuFrame.isEmpty {
            targetY = location.y
        } else {
            targetY = min(
                max(
                    location.y,
                    menuFrame.minY + 1
                ),
                menuFrame.maxY - 1
            )
        }

        let nearestEffect =
            candidates.min {
                lhs,
                rhs in

                abs(lhs.value.midY - targetY)
                    <
                    abs(rhs.value.midY - targetY)
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

    private func updateAutoScrollDirection(
        _ location: CGPoint?
    ) {
        guard let location,
              !menuFrame.isEmpty,
              displayedEffects.count > 1 else {
            autoScrollDirection = nil
            return
        }

        if location.y <= menuFrame.minY + autoScrollEdgeSize {
            autoScrollDirection = .up
            return
        }

        if location.y >= menuFrame.maxY - autoScrollEdgeSize {
            autoScrollDirection = .down
            return
        }

        autoScrollDirection = nil
    }

    private func performAutoScrollStep(
        _ direction: AutoScrollDirection,
        proxy: ScrollViewProxy
    ) {
        guard !displayedEffects.isEmpty else {
            return
        }

        let currentEffect =
            hoveredEffect ?? selectedEffect

        let currentIndex =
            displayedEffects.firstIndex(of: currentEffect) ?? 0

        let targetIndex: Int

        switch direction {
        case .up:
            targetIndex = max(currentIndex - 1, 0)

        case .down:
            targetIndex = min(
                currentIndex + 1,
                displayedEffects.count - 1
            )
        }

        guard targetIndex != currentIndex else {
            return
        }

        let targetEffect =
            displayedEffects[targetIndex]

        hoveredEffect = targetEffect
        selectedEffect = targetEffect

        let anchor: UnitPoint =
            direction == .up ? .top : .bottom

        withAnimation(
            .linear(duration: 0.08)
        ) {
            proxy.scrollTo(
                targetEffect,
                anchor: anchor
            )
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

        return quickEffectAccentColor
            .opacity(
                isSelected ? 0.12 : 0.08
            )
    }

    private var rowBorderColor: Color {
        if isSelected {
            return quickEffectAccentColor
                .opacity(0.4)
        }

        if isHovered {
            return quickEffectAccentColor
                .opacity(0.25)
        }

        return Color.white.opacity(0.07)
    }
}
