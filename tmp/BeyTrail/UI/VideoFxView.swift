import SwiftUI
import PhotosUI
import AVFoundation

/// 影片特效（對應 Android VideoFxActivity）：
/// 選相簿影片 → 預選已購特效 → 離線處理（進度條/取消）→ 預覽儲存。
struct VideoFxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var videoInfo = "點擊選擇影片"
    @State private var selectedEffect: EffectType?
    @State private var processing = false
    @State private var progress: Float = 0
    @State private var resultURL: URL?
    @State private var errorMessage: String?
    @State private var processor: VideoEffectProcessor?

    private var ownedEffects: [EffectType] {
        EffectType.allCases.filter { !$0.locked }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // 選片
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    HStack {
                        Text("🎬").font(.largeTitle)
                        Text(videoInfo).foregroundColor(.white)
                        Spacer()
                    }
                    .padding()
                    .background(Color.white.opacity(0.06)).cornerRadius(14)
                }
                .disabled(processing)

                // 特效選擇
                Text("選擇特效").font(.caption).foregroundColor(.gray)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ownedEffects) { effect in
                            Button {
                                selectedEffect = effect
                            } label: {
                                Text("\(effect.emoji) \(effect.displayName)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(selectedEffect == effect
                                                ? Color.cyan.opacity(0.3)
                                                : Color.white.opacity(0.08))
                                    .cornerRadius(10)
                            }
                            .disabled(processing)
                        }
                    }
                }

                // 開始
                Button {
                    startProcessing()
                } label: {
                    Text("開始處理")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(LinearGradient(colors: [.cyan, .purple],
                                                   startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(12)
                }
                .opacity(videoURL != nil && selectedEffect != nil && !processing ? 1 : 0.4)
                .disabled(videoURL == nil || selectedEffect == nil || processing)

                Spacer()

                // 進度
                if processing {
                    VStack(spacing: 10) {
                        Text("處理中… \(Int(progress * 100))%")
                            .foregroundColor(.white)
                        ProgressView(value: progress)
                        Button("取消") { processor?.cancel() }
                            .foregroundColor(.red)
                    }
                    .padding()
                    .background(Color.white.opacity(0.06)).cornerRadius(14)
                }

                if let msg = errorMessage {
                    Text(msg).foregroundColor(.red).font(.caption)
                }
            }
            .padding()
            .background(Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea())
            .navigationTitle("影片特效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("‹ 返回") { dismiss() }.disabled(processing)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: pickerItem) { item in
            Task { await loadVideo(item) }
        }
        .fullScreenCover(item: Binding(
            get: { resultURL.map(ReviewItem.init) },
            set: { if $0 == nil { resultURL = nil } })
        ) { item in
            ReviewView(url: item.url)
        }
    }

    private func loadVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // 複製到暫存檔以便 AVAsset 讀取
        if let data = try? await item.loadTransferable(type: Data.self) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("videofx_input.mov")
            try? FileManager.default.removeItem(at: url)
            try? data.write(to: url)
            videoURL = url
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            videoInfo = String(format: "已選擇影片 ・ %d:%02d", Int(dur) / 60, Int(dur) % 60)
        }
    }

    private func startProcessing() {
        guard let url = videoURL, let effect = selectedEffect else { return }
        guard let proc = try? VideoEffectProcessor() else { return }
        processor = proc
        processing = true
        progress = 0
        errorMessage = nil
        proc.onProgress = { progress = $0 }
        proc.onDone = { out in
            processing = false
            resultURL = out
        }
        proc.onError = { msg in
            processing = false
            errorMessage = msg
        }
        proc.process(asset: url, effect: effect)
    }
}
