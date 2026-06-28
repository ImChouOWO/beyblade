import SwiftUI
import StoreKit

struct SettingsSheetView: View {

    @Binding var isPresented: Bool
    @Binding var is60FPSMode: Bool

    let iconRotation: Angle
    let animationDuration: Double

    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview

    @State private var dragOffset: CGFloat = 0
    @State private var isRestoringPurchases = false
    @State private var presentedAlert: SettingsAlert?

    private let supportURL = URL(
        string: "https://forms.gle/KdWvoQipyodQwb8HA"
    )!

    private let privacyPolicyURL = URL(
        string: "https://lunayee.github.io/byetail/privacy-policy.html"
    )!

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dragHandle
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    fpsRow

                    settingButton(
                        systemName: "bubble.left.and.text.bubble.right.fill",
                        title: "問題回報與客服"
                    ) {
                        openURL(supportURL)
                    }

                    settingButton(
                        systemName: "star.fill",
                        title: "為 App 評分"
                    ) {
                        requestReview()
                    }

                    settingButton(
                        systemName: "arrow.clockwise.circle.fill",
                        title: isRestoringPurchases
                            ? "恢復購買中…"
                            : "恢復購買",
                        disabled: isRestoringPurchases
                    ) {
                        restorePurchases()
                    }

                    settingButton(
                        systemName: "lock.fill",
                        title: "隱私權政策"
                    ) {
                        openURL(privacyPolicyURL)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 470)

            footer
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    Color(
                        red: 0.055,
                        green: 0.058,
                        blue: 0.085
                    )
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: max(0, dragOffset))
        .contentShape(Rectangle())
        .gesture(dismissGesture)
        .animation(
            .easeInOut(duration: animationDuration),
            value: iconRotation
        )
        .alert(item: $presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("設定")
                .font(.system(size: 27, weight: .black))
                .foregroundColor(.white)

            Text("SETTINGS")
                .font(.system(size: 13, weight: .bold))
                .tracking(6)
                .foregroundColor(.white.opacity(0.38))
        }
        .padding(.horizontal, 24)
    }

    private var fpsRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("60 FPS 模式")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)

                Text("關閉時使用 30 FPS；開啟後使用 60 FPS")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $is60FPSMode)
                .labelsHidden()
                .tint(
                    Color(
                        red: 0.0,
                        green: 229.0 / 255.0,
                        blue: 1.0
                    )
                )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .background(cardBackground)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                presentedAlert = SettingsAlert(
                    title: "BEY TAIL",
                    message: "版本 \(appVersion)"
                )
            } label: {
                Image(systemName: "info")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(
                                Color.white.opacity(0.9),
                                lineWidth: 2
                            )
                    )
                    .rotationEffect(iconRotation)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關於此 App")

            Spacer()

            Text("版本 \(appVersion)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))

            Spacer()

            Color.clear
                .frame(width: 42, height: 42)
        }
        .padding(.horizontal, 32)
        .padding(.top, 2)
    }

    private func settingButton(
        systemName: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(
                                red: 0.0,
                                green: 229.0 / 255.0,
                                blue: 1.0
                            )
                        )
                    )
                    .rotationEffect(iconRotation)

                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.88))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.22))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                Color(
                    red: 0.025,
                    green: 0.035,
                    blue: 0.06
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.08),
                        lineWidth: 1.2
                    )
            )
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.translation.height > 0 else {
                    return
                }

                dragOffset = value.translation.height
            }
            .onEnded { value in
                let shouldDismiss =
                    value.translation.height > 100 ||
                    value.predictedEndTranslation.height > 180

                if shouldDismiss {
                    closeSheet()
                } else {
                    withAnimation(
                        .easeInOut(duration: animationDuration)
                    ) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func closeSheet() {
        withAnimation(.easeInOut(duration: animationDuration)) {
            dragOffset = 0
            isPresented = false
        }
    }

    private func restorePurchases() {
        guard !isRestoringPurchases else {
            return
        }

        isRestoringPurchases = true

        Task { @MainActor in
            defer {
                isRestoringPurchases = false
            }

            do {
                try await AppStore.sync()

                presentedAlert = SettingsAlert(
                    title: "恢復完成",
                    message: "已向 App Store 同步購買紀錄。"
                )
            } catch {
                presentedAlert = SettingsAlert(
                    title: "恢復失敗",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
