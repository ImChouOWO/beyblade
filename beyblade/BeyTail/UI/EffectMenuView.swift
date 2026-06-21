import SwiftUI

struct EffectMenuView: View {

    @Binding var selectedEffect: EffectType
    @Binding var isVisible: Bool

    // 長按拖曳時，由 ContentView 傳入目前手指位置
    var dragLocation: CGPoint? = nil

    @AppStorage("effectMenuIDs") private var effectMenuIDsRaw: String = ""

    @State private var rowFrames: [EffectType: CGRect] = [:]
    @State private var hoveredEffect: EffectType?

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

        return effects.isEmpty ? EffectType.defaultMenuEffects : effects
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 5) {
                ForEach(menuEffects.reversed(), id: \.self) { effect in
                    EffectRowView(
                        effect: effect,
                        isSelected: effect == selectedEffect,
                        isHovered: effect == hoveredEffect,
                        onTap: {
                            selectedEffect = effect

                            withAnimation(.easeOut(duration: 0.2)) {
                                isVisible = false
                            }
                        }
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: EffectRowFramePreferenceKey.self,
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
        .frame(maxHeight: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.04).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: 0x00F5FF).opacity(0.18), lineWidth: 1)
                )
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 16)
        )
        .onPreferenceChange(EffectRowFramePreferenceKey.self) { frames in
            rowFrames = frames
        }
        .onChange(of: dragLocation) { _, newLocation in
            updateSelectionByDragLocation(newLocation)
        }
        .onChange(of: effectMenuIDsRaw) { _, _ in
            removeInvalidSelectionIfNeeded()
        }
        .onAppear {
            initializeDefaultMenuIfNeeded()
            removeInvalidSelectionIfNeeded()
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            )
        )
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

        selectedEffect = menuEffects.first ?? EffectType.defaultMenuEffects[0]
    }

    private func updateSelectionByDragLocation(_ location: CGPoint?) {
        guard let location else {
            hoveredEffect = nil
            return
        }

        let hitEffect = rowFrames.first { item in
            item.value
                .insetBy(dx: -16, dy: -6)
                .contains(location)
        }?.key

        guard let hitEffect else {
            return
        }

        hoveredEffect = hitEffect

        if selectedEffect != hitEffect {
            selectedEffect = hitEffect
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
                            ? Color(hex: 0x00F5FF).opacity(isSelected ? 0.12 : 0.08)
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