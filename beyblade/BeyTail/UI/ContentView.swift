import SwiftUI
@preconcurrency import AVFoundation
import UIKit
@preconcurrency import Photos

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var vm = MainViewModel()

    @State private var showVideoPicker = false
    @State private var isPreparingVideoPicker = false

    @State private var pickerSessionID = UUID()
    @State private var presentedPickerSessionID: UUID?
    @State private var selectionPreparedPickerSessionID: UUID?
    @State private var handledPickerSessionID: UUID?

    /*
     固定畫布模式：
     - AppDelegate 維持 .landscapeRight
     - CameraPreview / VideoPlayer / TrailOverlay 不跟隨裝置方向旋轉
     - 選單列固定在畫面右側
     - 不修改 controlBarLayer 的外層旋轉與位置邏輯
     - icon / 文字 / FPS / 效果按鈕跟隨 iconRotation
     - hintBar 外層跟選單列方向一致，內部跟 iconRotation 一致
     - BEY TAIL 額外補償 90 度
     - busyOverlay 只旋轉中間卡片，不旋轉遮罩
     - 影片庫改為自製 SwiftUI Grid
     - 影片庫實際角度 = iconRotation + videoLibraryExtraRotationDeg
     - layout 寬高交換也使用同一個實際角度，避免跑版
     - 影片縮圖固定直拍比例 9:16
     - 影片縮圖使用固定 cardWidth，避免寬度重疊
    */
    @State private var iconRotation: Angle = .degrees(0)
    @State private var effectDragLocation: CGPoint?

    @State private var showEffectLibraryPage = false
    @State private var effectPressStartDate: Date?
    @State private var effectLongPressTask: Task<Void, Never>?
    @State private var isEffectDragSelecting = false

    private let fixedIsLandscape = true
    private let fixedVideoGravity: AVLayerVideoGravity = .resizeAspect
    private let controlBarHeight: CGFloat = 110

    private let busyDeg: Double = 90
    private let videoLibraryExtraRotationDeg: Double = 90

    private var isBusy: Bool {
        vm.isVideoLoading || vm.isSwitchingInputSource
    }

    private var controlBarLayer: some View {
        GeometryReader { geometry in
            let size = geometry.size

            bottomBar
                .frame(
                    width: size.height,
                    height: controlBarHeight
                )
                .rotationEffect(.degrees(90))
                .position(
                    x: size.width - controlBarHeight / 2,
                    y: size.height / 2
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    private var hintLayer: some View {
        GeometryReader { geometry in
            let size = geometry.size

            hintBar
                .position(
                    x: size.width / 2,
                    y: size.height / 2
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    private func isEffectMenuQuarterTurn(_ degrees: Double) -> Bool {
        let value = normalizedEffectMenuDegrees(degrees)

        return abs(value - 90) < 0.5 ||
            abs(value - 270) < 0.5
    }

    private func normalizedEffectMenuDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)

        if value < 0 {
            value += 360
        }

        return value
    }
    private let effectMenuWidth: CGFloat = 220
    private let effectMenuHeight: CGFloat = 360

    private let effectMenuGapToControlBar: CGFloat = 10
    private let effectMenuBottomPadding: CGFloat = 24

    private var effectMenuLayer: some View {
        GeometryReader { geometry in
            let rotationDegrees = iconRotation.degrees + 90
            let isQuarterTurn = isEffectMenuQuarterTurn(rotationDegrees)

            let visualWidth = isQuarterTurn ? effectMenuHeight : effectMenuWidth
            let visualHeight = isQuarterTurn ? effectMenuWidth : effectMenuHeight

            ZStack(alignment: .bottomTrailing) {
                Color.clear

                if vm.effectMenuVisible {
                    ZStack {
                        EffectMenuView(
                            selectedEffect: $vm.selectedEffect,
                            isVisible: $vm.effectMenuVisible,
                            dragLocation: effectDragLocation
                        )
                        .frame(
                            width: effectMenuWidth,
                            height: effectMenuHeight
                        )
                        .rotationEffect(.degrees(rotationDegrees))
                    }
                    .frame(
                        width: visualWidth,
                        height: visualHeight
                    )
                    .padding(.trailing, controlBarHeight + effectMenuGapToControlBar)
                    .padding(.bottom, effectMenuBottomPadding)
                    .transition(.opacity)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(vm.effectMenuVisible)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let isLandscape = fixedIsLandscape
            let videoGravity = fixedVideoGravity

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
                            videoGravity: videoGravity,
                            isLandscape: isLandscape
                        )
                    }
                }
                .ignoresSafeArea()

                TrailOverlayRepresentable(
                    view: vm.trailOverlayView
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

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

                topBar
                    .frame(
                        width: 96,
                        height: size.height
                    )
                    .position(
                        x: 48,
                        y: size.height / 2
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                hintLayer
                controlBarLayer
                effectMenuLayer

                if isBusy {
                    busyOverlay
                        .transition(.opacity)
                }
            }
            .fullScreenCover(
                isPresented: $showVideoPicker,
                onDismiss: {
                    let sessionID = presentedPickerSessionID ?? pickerSessionID
                    handleVideoPickerDismiss(sessionID: sessionID)
                }
            ) {
                RotatedVideoLibraryPickerView(
                    isPresented: $showVideoPicker,
                    sessionID: pickerSessionID,
                    rotation: $iconRotation,
                    extraRotationDegrees: videoLibraryExtraRotationDeg,
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
            }
            .fullScreenCover(isPresented: $showEffectLibraryPage) {
                EffectLibraryPage(
                    selectedEffect: $vm.selectedEffect,
                    isPresented: $showEffectLibraryPage
                )
                .preferredColorScheme(.dark)
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                updateIconRotation()

                print(
                    "[CONTENT_LAYOUT_APPEAR]",
                    "size:", size,
                    "fixedCanvas:", true,
                    "isLandscape:", isLandscape,
                    "videoGravity:", videoGravity.rawValue,
                    "iconRotation:", iconRotation
                )

                vm.updatePreviewLayout(
                    overlaySize: size,
                    videoGravity: videoGravity
                )

                vm.cameraManager.updateVideoRotation()
                vm.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    print("[SCENE_PHASE] active")
                    vm.start()

                case .inactive:
                    print("[SCENE_PHASE] inactive")

                case .background:
                    print("[SCENE_PHASE] background")
                    vm.stop()

                @unknown default:
                    break
                }
            }
            .onChange(of: size) { _, newSize in
                print(
                    "[CONTENT_LAYOUT_CHANGE]",
                    "size:", newSize,
                    "fixedCanvas:", true,
                    "isLandscape:", fixedIsLandscape,
                    "videoGravity:", fixedVideoGravity.rawValue,
                    "iconRotation:", iconRotation
                )

                vm.updatePreviewLayout(
                    overlaySize: newSize,
                    videoGravity: fixedVideoGravity
                )

                vm.cameraManager.updateVideoRotation()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification
                )
            ) { _ in
                updateIconRotation()
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

    // MARK: - Icon Rotation

    private func updateIconRotation() {
        let orientation = UIDevice.current.orientation
        let addDeg: Double = 90

        switch orientation {
        case .landscapeRight:
            iconRotation = .degrees(0 + addDeg)

        case .portrait:
            iconRotation = .degrees(90 + addDeg)

        case .landscapeLeft:
            iconRotation = .degrees(180 + addDeg)

        case .portraitUpsideDown:
            iconRotation = .degrees(270 + addDeg)

        default:
            break
        }

        print(
            "[ICON_ROTATION]",
            "deviceOrientation:", orientation.rawValue,
            "iconRotation:", iconRotation
        )
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
        let txtDeg: Double = 90

        return VStack {
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
                    .rotationEffect(iconRotation)
            }
            .disabled(isBusy)
            .opacity(isBusy ? 0.45 : 1.0)
            .padding(.top, 8)

            Spacer()

            ZStack {
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
                    .fixedSize()
//                    .rotationEffect(iconRotation)
                    .rotationEffect(.degrees(txtDeg))
                    .rotationEffect(.degrees(180))
            }
            .frame(width: 96, height: 96)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .frame(width: 96)
        .padding(.leading, 0)
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
                .rotationEffect(iconRotation)
                .rotationEffect(.degrees(90))
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
                .rotationEffect(iconRotation)
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
                    if vm.isUsingVideoFile {
                        vm.backToCamera()
                    } else {
                        vm.toggleRecording()
                    }
                }  label: {
                    Image(systemName: centerButtonIconName)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 62, height: 62)
                        .background(
                            Circle()
                                .fill(centerButtonGradient)
                        )
                        .rotationEffect(iconRotation)
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
                    .rotationEffect(iconRotation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)

                    HStack {
                        Spacer()

                        effectButton
                            .padding(.trailing, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: controlBarHeight)
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
        if vm.isUsingVideoFile {
            return "arrow.uturn.backward"
        }

        return vm.isRecording ? "stop.fill" : "video.fill"
    }

    private var effectButton: some View {
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
            .rotationEffect(iconRotation)
            .contentShape(Circle())
            .gesture(effectButtonPressGesture)
            .opacity(isBusy ? 0.45 : 1.0)
    }

    private var effectButtonPressGesture: some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .global
        )
        .onChanged { value in
            guard !isBusy else {
                return
            }

            if effectPressStartDate == nil {
                beginEffectPress(at: value.location)
            }

            if isEffectDragSelecting {
                effectDragLocation = value.location
            }
        }
        .onEnded { _ in
            guard !isBusy else {
                resetEffectPressState()
                return
            }

            let elapsed = Date().timeIntervalSince(
                effectPressStartDate ?? Date()
            )

            let shouldOpenPage = elapsed < 1.0 && !isEffectDragSelecting

            if shouldOpenPage {
                resetEffectPressState()

                withAnimation(.easeOut(duration: 0.18)) {
                    vm.effectMenuVisible = false
                }

                showEffectLibraryPage = true
                return
            }

            resetEffectPressState()

            withAnimation(.easeOut(duration: 0.18)) {
                vm.effectMenuVisible = false
            }
        }
    }

    private func beginEffectPress(at location: CGPoint) {
        effectPressStartDate = Date()
        effectDragLocation = nil
        isEffectDragSelecting = false

        effectLongPressTask?.cancel()

        effectLongPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !Task.isCancelled else {
                return
            }

            guard effectPressStartDate != nil else {
                return
            }

            isEffectDragSelecting = true
            effectDragLocation = location

            withAnimation(.easeOut(duration: 0.18)) {
                vm.effectMenuVisible = true
            }
        }
    }

    private func resetEffectPressState() {
        effectLongPressTask?.cancel()
        effectLongPressTask = nil

        effectPressStartDate = nil
        effectDragLocation = nil
        isEffectDragSelecting = false
    }
    private var centerButtonGradient: LinearGradient {
        if vm.isUsingVideoFile {
            return LinearGradient(
                colors: [
                    Color(hex: 0x8E8E93),
                    Color(hex: 0x3A3A3C)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

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
            .rotationEffect(iconRotation)
            .rotationEffect(.degrees(busyDeg))
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
// MARK: - Effect Library Page

private struct EffectLibraryPage: View {

    @Binding var selectedEffect: EffectType
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                Divider()
                    .background(Color.white.opacity(0.12))

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(EffectType.allCases, id: \.self) { effect in
                            EffectLibraryPageRow(
                                effect: effect,
                                isSelected: effect == selectedEffect,
                                onTap: {
                                    guard !effect.isLocked else {
                                        return
                                    }

                                    selectedEffect = effect
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))

                    Text("返回主頁面")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                )
            }

            Spacer()

            Text("特效庫")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            Color.clear
                .frame(width: 104, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

private struct EffectLibraryPageRow: View {

    let effect: EffectType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(effect.emoji)
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(effect.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)

                    Text(effect.description)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                if effect.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(hex: 0x00F5FF))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        isSelected
                            ? Color(hex: 0x00F5FF).opacity(0.12)
                            : Color.white.opacity(0.07)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isSelected
                                    ? Color(hex: 0x00F5FF).opacity(0.45)
                                    : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            .opacity(effect.isLocked ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(effect.isLocked)
    }
}

// MARK: - Custom SwiftUI Video Library Picker

struct RotatedVideoLibraryPickerView: View {

    @Binding var isPresented: Bool

    let sessionID: UUID

    @Binding var rotation: Angle
    let extraRotationDegrees: Double

    let onSelectionPrepared: (UUID) -> Void
    let onPicked: (UUID, URL) -> Void
    let onCancel: (UUID) -> Void
    let onFailed: (UUID) -> Void

    @Environment(\.displayScale) private var displayScale

    @State private var imageManager = PHCachingImageManager()

    @State private var authorizationStatus: PHAuthorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)

    @State private var assets: [PHAsset] = []
    @State private var isLoadingAssets = true
    @State private var isPreparingVideo = false
    @State private var errorText: String?

    private let gridSpacing: CGFloat = 12
    private let headerDropY: CGFloat = 10

    private var effectiveRotation: Angle {
        .degrees(rotation.degrees + extraRotationDegrees)
    }

    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let angle = effectiveRotation
            let contentSize = Self.contentSize(
                screenSize: screenSize,
                rotation: angle
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                pickerContent
                    .frame(
                        width: contentSize.width,
                        height: contentSize.height
                    )
                    .clipped()
                    .contentShape(Rectangle())
                    .rotationEffect(angle)
                    .position(
                        x: screenSize.width / 2,
                        y: screenSize.height / 2
                    )
            }
        }
        .interactiveDismissDisabled(isPreparingVideo)
        .onAppear {
            requestPhotoLibraryAccessIfNeeded()
        }
        .onDisappear {
            imageManager.stopCachingImagesForAllAssets()
        }
    }

    private var pickerContent: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                Divider()
                    .background(Color.white.opacity(0.12))

                contentArea
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if isPreparingVideo {
                preparingOverlay
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                guard !isPreparingVideo else {
                    return
                }

                onCancel(sessionID)
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))

                    Text("取消")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                )
            }

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                Text("影片庫")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("\(assets.count) 支影片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(minWidth: 96)

            Spacer(minLength: 8)

            Button {
                guard !isPreparingVideo else {
                    return
                }

                loadVideoAssets()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.14))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12 + headerDropY)
        .padding(.bottom, 12)
        .frame(height: 66 + headerDropY)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch authorizationStatus {
        case .authorized, .limited:
            if isLoadingAssets {
                loadingView
            } else if assets.isEmpty {
                emptyView
            } else {
                assetGrid
            }

        case .notDetermined:
            loadingView

        case .denied, .restricted:
            permissionDeniedView

        @unknown default:
            permissionDeniedView
        }
    }

    private var assetGrid: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 12
            let availableWidth = max(
                1,
                proxy.size.width - horizontalPadding * 2
            )

            let minCardWidth: CGFloat = 82
            let maxCardWidth: CGFloat = 112

            let rawColumnCount = Int(
                (availableWidth + gridSpacing) / (minCardWidth + gridSpacing)
            )

            let columnCount = max(
                2,
                min(rawColumnCount, 4)
            )

            let computedCardWidth = (
                availableWidth - CGFloat(columnCount - 1) * gridSpacing
            ) / CGFloat(columnCount)

            let cardWidth = min(
                maxCardWidth,
                max(minCardWidth, computedCardWidth)
            )

            let columns = Array(
                repeating: GridItem(
                    .fixed(cardWidth),
                    spacing: gridSpacing,
                    alignment: .top
                ),
                count: columnCount
            )

            ScrollView {
                LazyVGrid(
                    columns: columns,
                    alignment: .center,
                    spacing: gridSpacing
                ) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        VideoLibraryAssetCell(
                            asset: asset,
                            imageManager: imageManager,
                            displayScale: displayScale,
                            cardWidth: cardWidth
                        ) {
                            selectVideoAsset(asset)
                        }
                        .disabled(isPreparingVideo)
                        .opacity(isPreparingVideo ? 0.55 : 1.0)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.visible)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text("讀取影片庫中...")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.45))

            Text("找不到影片")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text("請確認相簿中是否有可讀取的影片。")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.45))

            Text("無法讀取影片庫")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text("請到設定中允許 BeyTail 讀取照片與影片。")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                openAppSettings()
            } label: {
                Text("開啟設定")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.white)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)

                Text(errorText ?? "準備影片中...")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.82))
            )
        }
        .allowsHitTesting(true)
    }

    private func requestPhotoLibraryAccessIfNeeded() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus

        switch currentStatus {
        case .authorized, .limited:
            loadVideoAssets()

        case .notDetermined:
            isLoadingAssets = true

            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                Task { @MainActor in
                    authorizationStatus = newStatus

                    switch newStatus {
                    case .authorized, .limited:
                        loadVideoAssets()

                    default:
                        isLoadingAssets = false
                    }
                }
            }

        case .denied, .restricted:
            isLoadingAssets = false

        @unknown default:
            isLoadingAssets = false
        }
    }

    private func loadVideoAssets() {
        guard authorizationStatus == .authorized ||
              authorizationStatus == .limited else {
            isLoadingAssets = false
            return
        }

        isLoadingAssets = true
        errorText = nil

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(
                key: "creationDate",
                ascending: false
            )
        ]

        let result = PHAsset.fetchAssets(
            with: .video,
            options: options
        )

        var fetchedAssets: [PHAsset] = []
        fetchedAssets.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            fetchedAssets.append(asset)
        }

        assets = fetchedAssets
        isLoadingAssets = false

        imageManager.stopCachingImagesForAllAssets()
        imageManager.startCachingImages(
            for: fetchedAssets,
            targetSize: CGSize(width: 180, height: 320),
            contentMode: .aspectFill,
            options: nil
        )
    }

    private func selectVideoAsset(_ asset: PHAsset) {
        guard !isPreparingVideo else {
            return
        }

        isPreparingVideo = true
        errorText = nil

        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestAVAsset(
            forVideo: asset,
            options: options
        ) { avAsset, _, _ in
            guard let avAsset else {
                Task { @MainActor in
                    isPreparingVideo = false
                    errorText = "無法取得影片資源"
                    onFailed(sessionID)
                    isPresented = false
                }
                return
            }

            Task {
                do {
                    let url = try await Self.prepareTemporaryVideoURL(
                        from: avAsset
                    )

                    await MainActor.run {
                        onSelectionPrepared(sessionID)
                        isPresented = false

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onPicked(sessionID, url)
                        }
                    }

                } catch {
                    await MainActor.run {
                        isPreparingVideo = false
                        errorText = "影片準備失敗"
                        onFailed(sessionID)
                        isPresented = false
                    }
                }
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(url)
    }

    private static func prepareTemporaryVideoURL(
        from avAsset: AVAsset
    ) async throws -> URL {
        if let urlAsset = avAsset as? AVURLAsset {
            do {
                let ext = urlAsset.url.pathExtension.isEmpty
                    ? "mov"
                    : urlAsset.url.pathExtension

                let copyURL = makeTemporaryVideoURL(fileExtension: ext)

                if FileManager.default.fileExists(atPath: copyURL.path) {
                    try FileManager.default.removeItem(at: copyURL)
                }

                try FileManager.default.copyItem(
                    at: urlAsset.url,
                    to: copyURL
                )

                return copyURL

            } catch {
                return try await exportTemporaryVideoURL(from: avAsset)
            }
        }

        return try await exportTemporaryVideoURL(from: avAsset)
    }

    private static func exportTemporaryVideoURL(
        from avAsset: AVAsset
    ) async throws -> URL {
        guard let exportSession = AVAssetExportSession(
            asset: avAsset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoLibraryPickerError.exportSessionUnavailable
        }

        let outputFileType: AVFileType

        if exportSession.supportedFileTypes.contains(.mov) {
            outputFileType = .mov
        } else if exportSession.supportedFileTypes.contains(.mp4) {
            outputFileType = .mp4
        } else if let first = exportSession.supportedFileTypes.first {
            outputFileType = first
        } else {
            throw VideoLibraryPickerError.unsupportedOutputType
        }

        let fileExtension = outputFileType == .mp4 ? "mp4" : "mov"
        let outputURL = makeTemporaryVideoURL(fileExtension: fileExtension)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        exportSession.shouldOptimizeForNetworkUse = true

        try await exportSession.export(
            to: outputURL,
            as: outputFileType
        )

        return outputURL
    }

    private static func makeTemporaryVideoURL(
        fileExtension: String
    ) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    private static func contentSize(
        screenSize: CGSize,
        rotation: Angle
    ) -> CGSize {
        if isQuarterTurn(rotation) {
            return CGSize(
                width: screenSize.height,
                height: screenSize.width
            )
        }

        return screenSize
    }

    private static func isQuarterTurn(_ angle: Angle) -> Bool {
        let deg = normalizedDegrees(angle.degrees)

        return abs(deg - 90) < 0.5 ||
               abs(deg - 270) < 0.5
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)

        if value < 0 {
            value += 360
        }

        return value
    }
}

private enum VideoLibraryPickerError: LocalizedError {
    case exportSessionUnavailable
    case unsupportedOutputType
    case exportFailed
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable:
            return "無法建立影片匯出工作"

        case .unsupportedOutputType:
            return "不支援的影片輸出格式"

        case .exportFailed:
            return "影片匯出失敗"

        case .exportCancelled:
            return "影片匯出已取消"
        }
    }
}

private struct VideoLibraryAssetCell: View {

    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let displayScale: CGFloat
    let cardWidth: CGFloat
    let onTap: () -> Void

    private let portraitAspectRatio: CGFloat = 9.0 / 16.0

    private var cardHeight: CGFloat {
        cardWidth / portraitAspectRatio
    }

    var body: some View {
        Button {
            onTap()
        } label: {
            ZStack(alignment: .bottomLeading) {
                VideoLibraryThumbnailView(
                    asset: asset,
                    imageManager: imageManager,
                    displayScale: displayScale
                )
                .frame(
                    width: cardWidth,
                    height: cardHeight
                )
                .clipped()

                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.72)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(
                    width: cardWidth,
                    height: cardHeight
                )

                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))

                    Text(durationText(asset.duration))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                )
                .padding(6)
            }
            .frame(
                width: cardWidth,
                height: cardHeight
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: cardWidth,
            height: cardHeight
        )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct VideoLibraryThumbnailView: View {

    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let displayScale: CGFloat

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.08))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .clipped()
        .onAppear {
            requestThumbnail()
        }
        .onDisappear {
            cancelThumbnailRequest()
        }
    }

    private func requestThumbnail() {
        guard image == nil else {
            return
        }

        cancelThumbnailRequest()

        let scale = displayScale

        let targetSize = CGSize(
            width: 180 * scale,
            height: 320 * scale
        )

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { requestedImage, _ in
            guard let requestedImage else {
                return
            }

            Task { @MainActor in
                image = requestedImage
            }
        }
    }

    private func cancelThumbnailRequest() {
        guard requestID != PHInvalidImageRequestID else {
            return
        }

        imageManager.cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    let videoGravity: AVLayerVideoGravity
    let isLandscape: Bool

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.attachSession(session)
        view.setVideoGravity(videoGravity)
        view.setIsLandscape(isLandscape)
        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewUIView,
        context: Context
    ) {
        uiView.attachSession(session)
        uiView.setVideoGravity(videoGravity)
        uiView.setIsLandscape(isLandscape)
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

    private var isLandscape = true
    private var lastAppliedPreviewAngle: CGFloat = -1

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
        if previewLayer.videoGravity != videoGravity {
            previewLayer.videoGravity = videoGravity
        }
    }

    func setIsLandscape(_ isLandscape: Bool) {
        /*
         固定畫布模式：
         不接受外部動態方向，只維持橫向畫布。
        */
        self.isLandscape = true
        applyPreviewRotationIfNeeded(force: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPreviewRotationIfNeeded(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        previewLayer.frame = bounds
        applyPreviewRotationIfNeeded(force: false)

        print(
            "[PREVIEW_LAYOUT]",
            "bounds:", bounds.size,
            "fixedCanvas:", true,
            "isLandscape:", isLandscape,
            "videoGravity:", previewLayer.videoGravity.rawValue
        )
    }

    private func applyPreviewRotationIfNeeded(force: Bool) {
        guard let connection = previewLayer.connection else {
            return
        }

        let previewAngle = fixedPreviewRotationAngle()

        guard force || previewAngle != lastAppliedPreviewAngle else {
            return
        }

        guard connection.isVideoRotationAngleSupported(previewAngle) else {
            print(
                "[WARN] previewLayer videoRotationAngle not supported:",
                previewAngle
            )
            return
        }

        connection.videoRotationAngle = previewAngle
        lastAppliedPreviewAngle = previewAngle

        print(
            "[PREVIEW_ROTATION]",
            "previewAngle:", previewAngle,
            "fixedCanvas:", true,
            "bounds:", bounds.size,
            "isLandscape:", isLandscape,
            "automaticallyAdjustsVideoMirroring:", connection.automaticallyAdjustsVideoMirroring,
            "isVideoMirrored:", connection.isVideoMirrored
        )
    }

    private func fixedPreviewRotationAngle() -> CGFloat {
        /*
         固定順時針 90 度橫向基準。
         對應 CameraManager:
         videoRotationAngle = 0
         visionImageOrientation = .down
        */
        return 0
    }
}

// MARK: - Trail Overlay

struct TrailOverlayRepresentable: UIViewRepresentable {
    let view: TrailOverlayView

    func makeUIView(context: Context) -> TrailOverlayView {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.contentMode = .redraw
        return view
    }

    func updateUIView(
        _ uiView: TrailOverlayView,
        context: Context
    ) {
        uiView.backgroundColor = .clear
        uiView.isOpaque = false
        uiView.contentMode = .redraw
        uiView.setNeedsDisplay()
    }
}
