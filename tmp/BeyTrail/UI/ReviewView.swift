import SwiftUI
import AVKit

/// 預覽頁（對應 Android ReviewActivity）：循環播放、儲存到相簿、分享、捨棄。
struct ReviewView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var savedToast = false
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear {
                            player.play()
                            NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: player.currentItem, queue: .main
                            ) { _ in
                                player.seek(to: .zero)
                                player.play()
                            }
                        }
                }

                HStack(spacing: 16) {
                    actionButton("🗑 捨棄", color: .red) {
                        try? FileManager.default.removeItem(at: url)
                        dismiss()
                    }
                    actionButton("📤 分享", color: .white) { showShare = true }
                    actionButton(saving ? "儲存中…" : "💾 儲存", color: .cyan) {
                        saving = true
                        RecordingManager.saveToPhotos(url: url) { success in
                            saving = false
                            if success { savedToast = true; dismiss() }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [url])
        }
    }

    private func actionButton(_ title: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
