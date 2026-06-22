import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Photos
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

/// 原生 PhotosPicker 載入的暫存影片。
///
/// 使用 FileRepresentation，而不是一次把整支影片讀進 Data，避免大影片造成記憶體尖峰。
private struct PickedVideoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let sourceURL = received.file
            let fileExtension = sourceURL.pathExtension.isEmpty
                ? "mov"
                : sourceURL.pathExtension

            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "beytail_input_\(UUID().uuidString).\(fileExtension)"
                )

            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destinationURL
            )

            return PickedVideoFile(url: destinationURL)
        }
    }
}

/// 直式影片特效頁。
///
/// 流程：原生 PhotosPicker 選片 → 選擇特效 → 完整離線渲染
/// → 預覽 → 重新選擇／下載／分享。
struct VideoRenderPage: View {

    let onClose: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var inputURL: URL?
    @State private var selectedEffect: EffectType
    @State private var videoInfo = "點擊選擇影片"

    @State private var processor: VideoRenderProcessor?
    @State private var isLoadingVideo = false
    @State private var isProcessing = false
    @State private var cancelRequested = false
    @State private var progress = 0.0

    @State private var resultURL: URL?
    @State private var player: AVPlayer?

    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var alertMessage: String?

    init(
        initialEffect: EffectType,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        _selectedEffect = State(
            initialValue: initialEffect.isLocked
                ? .lightning
                : initialEffect
        )
    }

    private var canStartProcessing: Bool {
        inputURL != nil &&
        !selectedEffect.isLocked &&
        !isLoadingVideo &&
        !isProcessing
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.065)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if resultURL == nil {
                        selectionContent
                    } else {
                        resultContent
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else {
                return
            }

            Task {
                await loadVideo(newItem)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime
            )
        ) { notification in
            guard let player,
                  let endedItem = notification.object as? AVPlayerItem,
                  endedItem === player.currentItem else {
                return
            }

            player.seek(to: .zero)
            player.play()
        }
        .onDisappear {
            processor?.cancel()
            player?.pause()
        }
        .sheet(isPresented: $showShareSheet) {
            if let resultURL {
                VideoRenderShareSheet(items: [resultURL])
            }
        }
        .alert(
            "影片特效",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { presented in
                    if !presented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                closePage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isProcessing)
            .opacity(isProcessing ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("影片特效")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("為相簿中的影片加上軌跡特效")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()
        }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            PhotosPicker(
                selection: $pickerItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 14) {
                    Image(systemName: "clapperboard.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isLoadingVideo ? "正在載入影片…" : videoInfo)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if inputURL != nil {
                            Text("點擊可重新選擇")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.38))
                        }
                    }

                    Spacer()

                    if isLoadingVideo {
                        ProgressView()
                            .tint(.cyan)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.035))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
            }
            .disabled(isLoadingVideo || isProcessing)

            effectSelector

            startButton

            if isProcessing {
                processingCard
            }
        }
    }

    private var effectSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("選擇特效")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.42))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(EffectType.allCases, id: \.self) { effect in
                        effectChip(effect)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func effectChip(_ effect: EffectType) -> some View {
        let selected = selectedEffect == effect
        let enabled = !effect.isLocked && !isProcessing

        return Button {
            selectedEffect = effect
        } label: {
            HStack(spacing: 6) {
                Text(effect.emoji)
                    .font(.system(size: 15))

                Text(effect.displayName)
                    .font(.system(size: 13, weight: .medium))

                if effect.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundColor(
                effect.isLocked
                    ? .white.opacity(0.28)
                    : .white
            )
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        selected
                            ? Color.cyan.opacity(0.16)
                            : Color.white.opacity(0.025)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        selected
                            ? Color.cyan.opacity(0.65)
                            : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var startButton: some View {
        Button {
            startProcessing()
        } label: {
            HStack(spacing: 8) {
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                }

                Text(isProcessing ? "處理中" : "開始處理")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                LinearGradient(
                    colors: [
                        Color(hex: 0x6B2BA6),
                        Color(hex: 0x007A9A),
                        Color(hex: 0x00A8A8)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(canStartProcessing ? 1 : 0.42)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canStartProcessing)
    }

    private var processingCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("正在完整渲染影片")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            ProgressView(value: progress)
                .tint(.cyan)

            Button("取消處理") {
                cancelRequested = true
                processor?.cancel()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.red)
        }
        .padding(16)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("處理完成")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("\(selectedEffect.emoji) \(selectedEffect.displayName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.cyan)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.green)
            }

            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .onAppear {
                        player.play()
                    }
            }

            HStack(spacing: 10) {
                resultButton(
                    title: "重新選擇",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .white
                ) {
                    resetForReselection()
                }

                resultButton(
                    title: isSaving ? "儲存中" : "下載",
                    systemImage: "square.and.arrow.down",
                    tint: .cyan,
                    enabled: !isSaving
                ) {
                    saveToPhotoLibrary()
                }

                resultButton(
                    title: "分享",
                    systemImage: "square.and.arrow.up",
                    tint: .purple
                ) {
                    showShareSheet = true
                }
            }
        }
    }

    private func resultButton(
        title: String,
        systemImage: String,
        tint: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(enabled ? tint : .gray)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.white.opacity(enabled ? 0.08 : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @MainActor
    private func loadVideo(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        alertMessage = nil

        defer {
            isLoadingVideo = false
        }

        do {
            guard let pickedVideo = try await item.loadTransferable(
                type: PickedVideoFile.self
            ) else {
                throw makeError("無法讀取選取的影片")
            }

            if let oldInputURL {
                try? FileManager.default.removeItem(at: oldInputURL)
            }

            let asset = AVURLAsset(url: pickedVideo.url)
            let duration = try await asset.load(.duration).seconds

            inputURL = pickedVideo.url
            videoInfo = String(
                format: "已選擇影片 ・ %d:%02d",
                Int(duration) / 60,
                Int(duration) % 60
            )
        } catch {
            pickerItem = nil
            inputURL = nil
            videoInfo = "點擊選擇影片"
            alertMessage = error.localizedDescription
        }
    }

    private var oldInputURL: URL? {
        inputURL
    }

    private func startProcessing() {
        guard let inputURL,
              canStartProcessing else {
            return
        }

        player?.pause()
        player = nil
        resultURL = nil
        progress = 0
        isProcessing = true
        cancelRequested = false
        alertMessage = nil

        let processor = VideoRenderProcessor()
        self.processor = processor

        processor.onProgress = { value in
            progress = value
        }

        processor.onCompleted = { outputURL in
            progress = 1
            isProcessing = false
            resultURL = outputURL
            player = AVPlayer(url: outputURL)
            player?.play()
            self.processor = nil
        }

        processor.onFailed = { message in
            isProcessing = false
            progress = 0
            self.processor = nil

            if cancelRequested {
                cancelRequested = false
            } else {
                alertMessage = message
            }
        }

        processor.process(
            inputURL: inputURL,
            effect: selectedEffect
        )
    }

    private func resetForReselection() {
        player?.pause()
        player = nil

        if let resultURL {
            try? FileManager.default.removeItem(at: resultURL)
        }

        if let inputURL {
            try? FileManager.default.removeItem(at: inputURL)
        }

        resultURL = nil
        inputURL = nil
        pickerItem = nil
        videoInfo = "點擊選擇影片"
        progress = 0
        alertMessage = nil
    }

    private func saveToPhotoLibrary() {
        guard let resultURL,
              !isSaving else {
            return
        }

        isSaving = true

        let save: () -> Void = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: resultURL
                )
            } completionHandler: { success, error in
                Task { @MainActor in
                    isSaving = false

                    if success {
                        alertMessage = "影片已儲存到相簿"
                    } else {
                        alertMessage = error?.localizedDescription
                            ?? "影片儲存失敗"
                    }
                }
            }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            save()

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    Task { @MainActor in
                        isSaving = false
                        alertMessage = "沒有相簿寫入權限"
                    }
                    return
                }

                save()
            }

        default:
            isSaving = false
            alertMessage = "沒有相簿寫入權限"
        }
    }

    private func closePage() {
        processor?.cancel()
        player?.pause()

        if let inputURL {
            try? FileManager.default.removeItem(at: inputURL)
        }

        if let resultURL {
            try? FileManager.default.removeItem(at: resultURL)
        }

        onClose()
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "BeyTail.VideoRenderPage",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct VideoRenderShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
