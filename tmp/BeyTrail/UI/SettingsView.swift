import SwiftUI
import StoreKit

/// 設定（對應 Android SettingsBottomSheetFragment）
struct SettingsView: View {
    var onFpsChanged: (Bool) -> Void
    @State private var is60 = SettingsStore.is60Fps
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    // TODO: 換成你的 Google 表單與隱私權政策網址
    private let supportFormURL = "https://forms.gle/REPLACE_WITH_YOUR_FORM"
    private let privacyPolicyURL = "https://REPLACE_WITH_YOUR_PRIVACY_POLICY"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $is60) {
                        VStack(alignment: .leading) {
                            Text("60 FPS 模式")
                            Text("預覽與錄影 60fps，更流暢但較耗電、發熱")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                    .onChange(of: is60) { newValue in
                        SettingsStore.is60Fps = newValue
                        onFpsChanged(newValue)
                    }
                }
                Section {
                    Link("📝  問題回報與客服", destination: URL(string: supportFormURL)!)
                    Button("⭐  為 App 評分") { requestReview() }
                    Button("🛒  恢復購買") {
                        Task { await StoreManager.shared.restore() }
                    }
                    Link("🔒  隱私權政策", destination: URL(string: privacyPolicyURL)!)
                }
                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                             as? String ?? "?")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
