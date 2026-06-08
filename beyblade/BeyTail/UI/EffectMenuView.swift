import SwiftUI

// 對應 Android buildEffectMenu()
struct EffectMenuView: View {

    @Binding var selectedEffect: EffectType
    @Binding var isVisible: Bool

    var body: some View {
        VStack(spacing: 5) {
            ForEach(EffectType.allCases.reversed(), id: \.self) { effect in
                EffectRowView(
                    effect: effect,
                    isSelected: effect == selectedEffect,
                    onTap: {
                        guard !effect.isLocked else { return }
                        selectedEffect = effect
                        withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
                    }
                )
            }
        }
        .padding(.vertical, 8)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.04).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: 0x00F5FF).opacity(0.18), lineWidth: 1)
                )
        )
        .transition(.asymmetric(
            insertion:  .move(edge: .bottom).combined(with: .opacity),
            removal:    .move(edge: .bottom).combined(with: .opacity)
        ))
    }
}

private struct EffectRowView: View {

    let effect: EffectType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(effect.emoji).font(.system(size: 20))

                VStack(alignment: .leading, spacing: 1) {
                    Text(effect.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.92))
                    Text(effect.description)
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.55))
                }
                Spacer()

                Text(effect.isLocked ? "🔒" : (isSelected ? "✓" : ""))
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? Color(hex: 0x00F5FF) : Color(white: 0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected
                          ? Color(hex: 0x00F5FF).opacity(0.12)
                          : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected
                                    ? Color(hex: 0x00F5FF).opacity(0.4)
                                    : Color(white: 1, opacity: 0.07),
                                    lineWidth: 1)
                    )
            )
            .opacity(effect.isLocked ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255)
    }
}
