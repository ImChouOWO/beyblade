import SwiftUI
import Combine

private let effectMenuAutoScrollTimer = Timer
    .publish(
        every: 0.12,
        on: .main,
        in: .common
    )
    .autoconnect()

struct EffectMenuView: View {

    @Binding var selectedEffect: EffectType
    @Binding var isVisible: Bool

    /// ContentView 傳入的全螢幕 global 手指位置。
    var dragLocation: CGPoint? = nil

    @AppStorage("effectMenuIDs")
    private var effectMenuIDsRaw: String = ""

    @State private var rowFrames: [EffectType: CGRect] = [:]
    @State private var menuFrame: CGRect = .zero
    @State private var hoveredEffect: EffectType?
    @State private var autoScrollDirection: AutoScrollDirection?

    private let autoScrollEdgeSize: CGFloat = 54

    private enum AutoScrollDirection {
        case up
        case down
    }

    private var menuEffects: [EffectType] {
        let ids = effectMenuIDsRaw
            .split(separator: ",")
            .map(String.init)

        if ids.isEmpty {
            return EffectType.defaultMenuEffects
        }

        let effects = EffectType.allCases.filter {
            ids.contains($0.rawValue)
        }

        return effects.isEmpty
            ? EffectType.defaultMenuEffects
            : effects
    }

    /// 實際由上到下顯示的特效順序。
    private var displayedEffects: [EffectType] {
        Array(menuEffects.reversed())
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(
                .vertical,
                showsIndicators: true
            ) {
                VStack(spacing: 5) {
                    ForEach(
                        displayedEffects,
                        id: \.self
                    ) { effect in
                        EffectRowView(
                            effect: effect,
                            isSelected: effect == selectedEffect,
                            isHovered: effect == hoveredEffect,
                            onTap: {
                                selectedEffect = effect

                                withAnimation(
                                    .easeOut(duration: 0.2)
                                ) {
                                    isVisible = false
                                }
                            }
                        )
                        .id(effect)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: EffectRowFramePreferenceKey.self,
                                        value: [
                                            effect: proxy.frame(
                                                in: .global
                                            )
                                        ]
                                    )
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 220)
            .frame(maxHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        Color(white: 0.04)
                            .opacity(0.92)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                Color(hex: 0x00F5FF)
                                    .opacity(0.18),
                                lineWidth: 1
                            )
                    )
            )
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: EffectMenuFramePreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                }
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
            .onPreferenceChange(
                EffectRowFramePreferenceKey.self
            ) { frames in
                rowFrames = frames

                // 捲動後列位置會改變；使用目前手指位置重新判斷。
                DispatchQueue.main.async {
                    updateSelectionByDragLocation(dragLocation)
                }
            }
            .onPreferenceChange(
                EffectMenuFramePreferenceKey.self
            ) { frame in
                menuFrame = frame
            }
            .onChange(of: dragLocation) { _, newLocation in
                updateSelectionByDragLocation(newLocation)
                updateAutoScrollDirection(newLocation)
            }
            .onReceive(effectMenuAutoScrollTimer) { _ in
                guard let direction = autoScrollDirection,
                      dragLocation != nil else {
                    return
                }

                performAutoScrollStep(
                    direction,
                    proxy: scrollProxy
                )
            }
            .onChange(of: effectMenuIDsRaw) { _, _ in
                removeInvalidSelectionIfNeeded()
            }
            .onAppear {
                initializeDefaultMenuIfNeeded()
                removeInvalidSelectionIfNeeded()
            }
            .onDisappear {
                autoScrollDirection = nil
            }
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom)
                        .combined(with: .opacity),
                    removal: .move(edge: .bottom)
                        .combined(with: .opacity)
                )
            )
        }
    }

    private func initializeDefaultMenuIfNeeded() {
        guard effectMenuIDsRaw.isEmpty else {
            return
        }

        effectMenuIDsRaw = EffectType.defaultMenuEffects
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func removeInvalidSelectionIfNeeded() {
        guard !menuEffects.contains(selectedEffect) else {
            return
        }

        selectedEffect = menuEffects.first
            ?? EffectType.defaultMenuEffects[0]
    }

    /// 依照手指的垂直位置選擇最接近的特效。
    /// 不判斷 x 座標，因此可在整個螢幕寬度內操作。
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

        let visibleMenuFrame = menuFrame.insetBy(
            dx: 0,
            dy: -4
        )

        let visibleRows = rowFrames.filter {
            $0.value.intersects(visibleMenuFrame)
        }

        let candidates = visibleRows.isEmpty
            ? rowFrames
            : visibleRows

        // 手指超出選單上下方時，仍映射到最接近的可見列。
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

        let nearestEffect = candidates.min { lhs, rhs in
            abs(lhs.value.midY - targetY)
                < abs(rhs.value.midY - targetY)
        }?.key

        guard let nearestEffect else {
            return
        }

        hoveredEffect = nearestEffect

        if selectedEffect != nearestEffect {
            selectedEffect = nearestEffect
        }
    }

    /// 判斷手指是否進入選單的上、下自動捲動區域。
    private func updateAutoScrollDirection(
        _ location: CGPoint?
    ) {
        guard let location,
              !menuFrame.isEmpty else {
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

    /// 每次計時移動一個特效項目，讓未顯示項目逐步進入畫面。
    private func performAutoScrollStep(
        _ direction: AutoScrollDirection,
        proxy: ScrollViewProxy
    ) {
        guard !displayedEffects.isEmpty else {
            return
        }

        let currentEffect = hoveredEffect ?? selectedEffect

        let currentIndex = displayedEffects
            .firstIndex(of: currentEffect)
            ?? 0

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

        let targetEffect = displayedEffects[targetIndex]

        hoveredEffect = targetEffect
        selectedEffect = targetEffect

        let anchor: UnitPoint = direction == .up
            ? .top
            : .bottom

        withAnimation(.linear(duration: 0.08)) {
            proxy.scrollTo(
                targetEffect,
                anchor: anchor
            )
        }
    }
}

private struct EffectMenuFramePreferenceKey: PreferenceKey {
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

private struct EffectRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [EffectType: CGRect] = [:]

    static func reduce(
        value: inout [EffectType: CGRect],
        nextValue: () -> [EffectType: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct EffectRowView: View {

    let effect: EffectType
    let isSelected: Bool
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        let isActive = isSelected || isHovered

        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(effect.emoji)
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 1) {
                    Text(effect.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.92))

                    Text(effect.description)
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.55))
                }

                Spacer()

                Text(isSelected ? "✓" : "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: 0x00F5FF))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isActive
                            ? Color(hex: 0x00F5FF)
                                .opacity(isSelected ? 0.12 : 0.08)
                            : Color.clear
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected
                                    ? Color(hex: 0x00F5FF).opacity(0.4)
                                    : (
                                        isHovered
                                            ? Color(hex: 0x00F5FF).opacity(0.25)
                                            : Color(white: 1, opacity: 0.07)
                                    ),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
