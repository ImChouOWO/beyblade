import SwiftUI
import AVFoundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var vm = MainViewModel()

    @State private var showVideoPicker = false
    @State private var isPreparingVideoPicker = false

    @State private var pickerSessionID = UUID()
    @State private var presentedPickerSessionID: UUID?
    @State private var selectionPreparedPickerSessionID: UUID?
    @State private var handledPickerSessionID: UUID?

    private var isBusy: Bool {
        vm.isVideoLoading || vm.isSwitchingInputSource
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let isLandscape = size.width > size.height
            let videoGravity: AVLayerVideoGravity = isLandscape
                ? .resizeAspect
                : .resizeAspectFill

            ZStack {
                Group {
                    if vm.isUsingVideoFile {
                        VideoPlayerView(
                            player: vm.videoFrameSource.player,
                            videoGravity: videoGravity
                        )
                    } else {
                        CameraPreviewView(
                            session: vm.cameraManager.session,
                            videoGravity: videoGravity
                        )
                    }
                }
                .ignoresSafeArea()

                TrailOverlayRepresentable(view: vm.trailOverlayView)
                    .ignoresSafeArea()

                VStack {
                    LinearGradient(
                        colors: [
                            .black.opacity(0.55),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)

                    Spacer()
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    hintBar
                    bottomBar
                }
                .ignoresSafeArea(edges: .bottom)

                if vm.effectMenuVisible {
                    VStack {
                        Spacer()

                        HStack {
                            Spacer()

                            EffectMenuView(
                                selectedEffect: $vm.selectedEffect,
                                isVisible: $vm.effectMenuVisible
                            )
                            .padding(.trailing, 8)
                            .padding(.bottom, 130)
                        }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }

                if isBusy {
                    busyOverlay
                        .transition(.opacity)
                }
            }
            .sheet(
                isPresented: $showVideoPicker,
                onDismiss: {
                    let sessionID = presentedPickerSessionID ?? pickerSessionID
                    handleVideoPickerDismiss(sessionID: sessionID)
                }
            ) {
                VideoPickerController(
                    isPresented: $showVideoPicker,
                    sessionID: pickerSessionID,
                    onSelectionPrepared: { sessionID in
                        handleSelectionPrepared(sessionID: sessionID)
                    },
                    onPicked: { sessionID, url in
                        guard markPickerSessionHandled(sessionID) else {
                            return
                        }

                        handleSelectedVideo(url)
                    },
                    onCancel: { sessionID in
                        guard markPickerSessionHandled(sessionID) else {
                            resetPickerUIState()
                            return
                        }

                        resetPickerUIState()
                        vm.cancelVideoPickerAndRecover()
                    },
                    onFailed: { sessionID in
                        guard markPickerSessionHandled(sessionID) else {
                            resetPickerUIState()
                            return
                        }

                        resetPickerUIState()
                        vm.videoSelectionFailed()
                    }
                )
                .ignoresSafeArea()
                .interactiveDismissDisabled(false)
            }
            .onAppear {
                vm.updatePreviewLayout(
                    overlaySize: size,
                    videoGravity: videoGravity
                )

                vm.cameraManager.updateVideoRotation()
                vm.start()
            }
            .onDisappear {
                vm.stop()
            }
            .onChange(of: size) { _, newSize in
                let newIsLandscape = newSize.width > newSize.height
                let newVideoGravity: AVLayerVideoGravity = newIsLandscape
                    ? .resizeAspect
                    : .resizeAspectFill

                vm.updatePreviewLayout(
                    overlaySize: newSize,
                    videoGravity: newVideoGravity
                )

                vm.cameraManager.updateVideoRotation()
            }
            .onChange(of: vm.isSwitchingInputSource) { _, newValue in
                if !newValue {
                    isPreparingVideoPicker = false
                }
            }
            .onChange(of: vm.isVideoLoading) { _, newValue in
                if !newValue {
                    isPreparingVideoPicker = false
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Video Picker Handler

    private func openVideoPicker() {
        guard vm.canOpenVideoLibrary else {
            return
        }

        guard !isBusy else {
            return
        }

        guard !isPreparingVideoPicker else {
            return
        }

        guard !showVideoPicker else {
            return
        }

        let newSessionID = UUID()

        pickerSessionID = newSessionID
        presentedPickerSessionID = nil
        selectionPreparedPickerSessionID = nil
        handledPickerSessionID = nil

        isPreparingVideoPicker = true

        Task { @MainActor in
            let canOpen = await vm.prepareForVideoPickerAsync()

            guard canOpen else {
                resetPickerUIState()
                return
            }

            guard pickerSessionID == newSessionID else {
                resetPickerUIState()
                vm.cancelVideoPickerAndRecover()
                return
            }

            isPreparingVideoPicker = false
            presentedPickerSessionID = newSessionID
            showVideoPicker = true
        }
    }

    private func isValidPickerSession(_ sessionID: UUID) -> Bool {
        pickerSessionID == sessionID ||
        presentedPickerSessionID == sessionID ||
        selectionPreparedPickerSessionID == sessionID
    }

    private func handleSelectionPrepared(sessionID: UUID) {
        guard isValidPickerSession(sessionID) else {
            return
        }

        selectionPreparedPickerSessionID = sessionID
        isPreparingVideoPicker = false
    }

    @discardableResult
    private func markPickerSessionHandled(_ sessionID: UUID) -> Bool {
        guard isValidPickerSession(sessionID) else {
            return false
        }

        if handledPickerSessionID == sessionID {
            return false
        }

        handledPickerSessionID = sessionID
        return true
    }

    private func handleSelectedVideo(_ url: URL) {
        resetPickerUIState()

        vm.beginResolvingPickedVideo()
        vm.loadVideo(url: url)
    }

    private func handleVideoPickerDismiss(sessionID: UUID) {
        if selectionPreparedPickerSessionID == sessionID,
           handledPickerSessionID == nil {
            resetPickerUIState()
            return
        }

        guard markPickerSessionHandled(sessionID) else {
            resetPickerUIState()
            return
        }

        resetPickerUIState()
        vm.cancelVideoPickerAndRecover()
    }

    private func resetPickerUIState() {
        showVideoPicker = false
        isPreparingVideoPicker = false
        presentedPickerSessionID = nil
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Text("BEY TAIL")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x00F5FF),
                            Color(hex: 0xBF5FFF)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Spacer()

            Button {
                // settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Color(white: 1, opacity: 0.15)
                            .cornerRadius(8)
                    )
            }
            .disabled(isBusy)
            .opacity(isBusy ? 0.45 : 1.0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        Group {
            if vm.hintVisible {
                HStack(spacing: 7) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)

                    Text("請將陀螺放置於鏡頭可視範圍內")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.9, opacity: 0.8))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color(white: 0.04).opacity(0.88))
                )
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {

            Button {
                openVideoPicker()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Color(white: 1, opacity: vm.canOpenVideoLibrary ? 0.12 : 0.05)
                                .cornerRadius(10)
                        )

                    Text("影片庫")
                        .font(.system(size: 10))
                        .foregroundColor(
                            vm.canOpenVideoLibrary
                                ? Color(white: 0.5)
                                : Color(white: 0.28)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!vm.canOpenVideoLibrary || isPreparingVideoPicker || showVideoPicker || isBusy)
            .opacity((vm.canOpenVideoLibrary && !isPreparingVideoPicker && !showVideoPicker && !isBusy) ? 1.0 : 0.45)

            ZStack {
                Circle()
                    .fill(
                        Color(hex: 0x00F5FF)
                            .opacity(vm.isRecording ? 0 : 0.15)
                    )
                    .frame(width: 82, height: 82)
                    .scaleEffect(vm.pulseScale)
                    .animation(
                        .easeInOut(duration: 2)
                            .repeatForever(autoreverses: true),
                        value: vm.pulseScale
                    )

                Button {
                    vm.toggleRecording()
                } label: {
                    Image(systemName: centerButtonIconName)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 62, height: 62)
                        .background(
                            Circle()
                                .fill(centerButtonGradient)
                        )
                }
                .disabled(centerButtonDisabled)
                .opacity(centerButtonDisabled ? 0.45 : 1.0)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                ZStack {
                    VStack {
                        Text("\(vm.fps) FPS")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)

                        Text("[\(vm.hardwareLabel)]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(vm.hardwareColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)

                    HStack {
                        Spacer()

                        Button {
                            withAnimation(.easeOut(duration: 0.22)) {
                                vm.effectMenuVisible.toggle()
                            }
                        } label: {
                            Text(vm.selectedEffect.emoji)
                                .font(.system(size: 24))
                                .frame(width: 52, height: 52)
                                .background(
                                    Circle()
                                        .fill(Color(white: 0.08))
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    Color(hex: 0x00F5FF)
                                                        .opacity(0.5),
                                                    lineWidth: 1.5
                                                )
                                        )
                                )
                        }
                        .padding(.trailing, 8)
                        .disabled(isBusy)
                        .opacity(isBusy ? 0.45 : 1.0)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 110)
        .background(Color(white: 0.05).opacity(0.95))
    }

    private var centerButtonDisabled: Bool {
        if isBusy {
            return true
        }

        if vm.isUsingVideoFile {
            return false
        }

        return !vm.canToggleRecording
    }

    private var centerButtonIconName: String {
        vm.isRecording ? "stop.fill" : "video.fill"
    }

    private var centerButtonGradient: LinearGradient {
        if vm.isRecording {
            return LinearGradient(
                colors: [
                    Color(hex: 0xFF3B30),
                    Color(hex: 0xFF9500)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(hex: 0x00F5FF),
                Color(hex: 0x0088FF)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Busy Overlay

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)

                Text(busyOverlayText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.75))
            )
        }
        .allowsHitTesting(true)
    }

    private var busyOverlayText: String {
        if !vm.loadingText.isEmpty {
            return vm.loadingText
        }

        if vm.isVideoLoading {
            return "載入影片中..."
        }

        if vm.isSwitchingInputSource {
            return "處理影像資源中..."
        }

        return "處理中..."
    }
}

// MARK: - UIKit PHPicker Wrapper

struct VideoPickerController: UIViewControllerRepresentable {

    @Binding var isPresented: Bool

    let sessionID: UUID
    let onSelectionPrepared: (UUID) -> Void
    let onPicked: (UUID, URL) -> Void
    let onCancel: (UUID) -> Void
    let onFailed: (UUID) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator

        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let parent: VideoPickerController
        private var didFinish = false

        init(parent: VideoPickerController) {
            self.parent = parent
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            guard !didFinish else {
                return
            }

            didFinish = true

            guard let result = results.first else {
                DispatchQueue.main.async {
                    self.parent.onCancel(self.parent.sessionID)
                    self.parent.isPresented = false
                }
                return
            }

            let provider = result.itemProvider

            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
                guard let type = UTType(identifier) else {
                    return false
                }

                return type.conforms(to: .movie)
                    || type.conforms(to: .video)
                    || type.conforms(to: .audiovisualContent)
            }) else {
                DispatchQueue.main.async {
                    self.parent.onFailed(self.parent.sessionID)
                    self.parent.isPresented = false
                }
                return
            }

            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, error in
                if error != nil {
                    DispatchQueue.main.async {
                        self.parent.onFailed(self.parent.sessionID)
                        self.parent.isPresented = false
                    }
                    return
                }

                guard let url else {
                    DispatchQueue.main.async {
                        self.parent.onFailed(self.parent.sessionID)
                        self.parent.isPresented = false
                    }
                    return
                }

                do {
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension

                    let copyURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)

                    if FileManager.default.fileExists(atPath: copyURL.path) {
                        try FileManager.default.removeItem(at: copyURL)
                    }

                    try FileManager.default.copyItem(
                        at: url,
                        to: copyURL
                    )

                    DispatchQueue.main.async {
                        self.parent.onSelectionPrepared(self.parent.sessionID)
                        self.parent.isPresented = false

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.parent.onPicked(self.parent.sessionID, copyURL)
                        }
                    }

                } catch {
                    DispatchQueue.main.async {
                        self.parent.onFailed(self.parent.sessionID)
                        self.parent.isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.attachSession(session)
        view.setVideoGravity(videoGravity)
        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewUIView,
        context: Context
    ) {
        uiView.attachSession(session)
        uiView.setVideoGravity(videoGravity)
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(
        _ uiView: CameraPreviewUIView,
        coordinator: ()
    ) {
        uiView.detachSession()
    }
}

final class CameraPreviewUIView: UIView {

    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("CameraPreviewUIView layer is not AVCaptureVideoPreviewLayer")
        }

        return layer
    }

    func attachSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
    }

    func detachSession() {
        previewLayer.session = nil
    }

    func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        previewLayer.videoGravity = videoGravity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

// MARK: - Trail Overlay

struct TrailOverlayRepresentable: UIViewRepresentable {
    let view: TrailOverlayView

    func makeUIView(context: Context) -> TrailOverlayView {
        view
    }

    func updateUIView(_ uiView: TrailOverlayView, context: Context) {}
}
