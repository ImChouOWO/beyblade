import SwiftUI
@preconcurrency import AVFoundation
import UIKit

private struct RecognitionStatusSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(
        value: inout CGSize,
        nextValue: () -> CGSize
    ) {
        value = nextValue()
    }
}

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var vm = MainViewModel()

    @State private var showVideoPicker = false

    // BEYTAIL_FEEDBACK_PATCH 2026.06.28-1
    @AppStorage("hasShownEffectLongPressTip")
    private var hasShownEffectLongPressTip = false

    @AppStorage("effectMenuIDs")
    private var effectMenuIDsRaw: String = ""

    @State private var showEffectLongPressTip = false

    @AppStorage("is60FPSMode")
    private var is60FPSMode = false

    @State private var showSettingsSheet = false

    @State private var iconRotation: Angle = .zero
    @State private var deviceOrientation: UIDeviceOrientation = .portrait

    // MARK: - Recognition status orientation transition
    @State private var recognitionStatusRotation: Angle = .zero
    @State private var recognitionStatusTargetRotation: Angle = .zero
    @State private var recognitionStatusOpacity: Double = 1.0
    @State private var recognitionStatusSize: CGSize = .zero
    @State private var hasInitializedRecognitionStatusOrientation = false
    @State private var recognitionStatusTransitionTask: Task<Void, Never>?
    @State private var effectDragLocation: CGPoint?

    @State private var showEffectLibraryPage = false
    @State private var effectPressStartDate: Date?
    @State private var effectLongPressTask: Task<Void, Never>?
    @State private var isEffectDragSelecting = false

    // 全螢幕拖曳選特效使用。
    @State private var effectButtonFrame: CGRect = .zero
    @State private var latestEffectDragLocation: CGPoint?

    private let fixedVideoGravity: AVLayerVideoGravity = .resizeAspectFill
    private let controlBarHeight: CGFloat = 110

    private let topBarHeight: CGFloat = 40
    private let topBarTopPadding: CGFloat = 10
    private let uiAnimationDuration: Double = 0.25

    private var isBusy: Bool {
        vm.isVideoLoading || vm.isSwitchingInputSource
    }

    private var controlBarLayer: some View {
        GeometryReader { geometry in
            bottomBar
                .frame(
                    width: geometry.size.width,
                    height: controlBarHeight
                )
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height - controlBarHeight / 2
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    // MARK: - Recognition / Recording Status

    private var recognitionStatusLayer: some View {
        GeometryReader { geometry in
            let statusHeight: CGFloat = 30
            let edgeSpacing: CGFloat = 10

            let isLandscapeStatus = isEffectMenuQuarterTurn(
                recognitionStatusRotation.degrees
            )

            /*
             rotationEffect 不會改變 SwiftUI 的排版尺寸。

             橫置時，提示膠囊旋轉 90 度，因此畫面上的寬度會等於
             旋轉前的高度。使用量測結果可以讓提示框的視覺邊緣
             與直立座標系的右側邊界維持 10 pt 距離。
             */
            let measuredWidth = max(
                recognitionStatusSize.width,
                statusHeight
            )
            let measuredHeight = max(
                recognitionStatusSize.height,
                statusHeight
            )

            let visualWidth = isLandscapeStatus
                ? measuredHeight
                : measuredWidth

            // 直立時維持原本位於 Control Bar 上方的位置。
            let portraitX = geometry.size.width / 2
            let portraitY = geometry.size.height
                - controlBarHeight
                - edgeSpacing
                - statusHeight / 2

            // 橫置時的「上方」使用直立座標系的右側邊界。
            let landscapeX = geometry.size.width
                - edgeSpacing
                - visualWidth / 2
            let landscapeY = geometry.size.height / 2

            recognitionStatusBar
                .frame(height: statusHeight)
                .opacity(recognitionStatusOpacity)
                .position(
                    x: isLandscapeStatus
                        ? landscapeX
                        : portraitX,
                    y: isLandscapeStatus
                        ? landscapeY
                        : portraitY
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var recognitionStatusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(
                    systemName: vm.hasCompletedFirstInference
                        ? "viewfinder.circle.fill"
                        : "hourglass"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    vm.hasCompletedFirstInference
                        ? Color(hex: 0x00F5FF)
                        : .yellow
                )

                Text(recognitionStatusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            if vm.isRecording {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 14)

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)

                    Text(formatRecordingElapsed(vm.recordingElapsedSeconds))
                        .font(
                            .system(
                                size: 11,
                                weight: .bold,
                                design: .monospaced
                            )
                        )
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: RecognitionStatusSizePreferenceKey.self,
                        value: proxy.size
                    )
            }
        }
        .onPreferenceChange(
            RecognitionStatusSizePreferenceKey.self
        ) { newSize in
            recognitionStatusSize = newSize
        }
        .rotationEffect(recognitionStatusRotation)
    }

    private var recognitionStatusText: String {
        guard vm.hasCompletedFirstInference else {
            return "辨識準備中"
        }

        return "辨識到 \(vm.detectedBeybladeCount) 顆陀螺"
    }

    private func formatRecordingElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var topBarLayer: some View {
        GeometryReader { geometry in
            topBar
                .frame(
                    width: geometry.size.width,
                    height: topBarHeight
                )
                .position(
                    x: geometry.size.width / 2,
                    y: topBarTopPadding + topBarHeight / 2
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
    private let maximumQuickEffectCount = 6

    private var configuredQuickEffectCount: Int {
        let storedCount = EffectQuickMenuStore
            .decode(effectMenuIDsRaw)
            .count

        let hasStoredConfiguration =
            UserDefaults.standard.object(
                forKey: EffectQuickMenuStore.storageKey
            ) != nil

        let count = hasStoredConfiguration
            ? storedCount
            : EffectType.defaultMenuEffects.count

        return min(
            max(count, 1),
            maximumQuickEffectCount
        )
    }

    private var effectMenuHeight: CGFloat {
        let count = configuredQuickEffectCount
        let rowsHeight = CGFloat(count) * 50
        let spacingHeight = CGFloat(max(count - 1, 0)) * 5
        return 16 + rowsHeight + spacingHeight
    }

    private let effectMenuGapToControlBar: CGFloat = 10
    private let effectMenuBottomPadding: CGFloat = 24

    private var effectMenuLayer: some View {
        GeometryReader { geometry in
            let rotationDegrees = iconRotation.degrees
            let isQuarterTurn = isEffectMenuQuarterTurn(rotationDegrees)

            let visualWidth = isQuarterTurn
                ? effectMenuHeight
                : effectMenuWidth

            let visualHeight = isQuarterTurn
                ? effectMenuWidth
                : effectMenuHeight

            ZStack(alignment: .bottomTrailing) {
                Color.clear

                if vm.effectMenuVisible {
                    ZStack {
                        QuickEffectMenuView(
                            selectedEffect: $vm.selectedEffect,
                            isVisible: $vm.effectMenuVisible,
                            dragLocation: effectDragLocation,
                            rotation: Angle.degrees(rotationDegrees)
                        )
                        .frame(
                            width: effectMenuWidth,
                            height: effectMenuHeight
                        )
                        .rotationEffect(Angle.degrees(rotationDegrees))
                    }
                    .frame(
                        width: visualWidth,
                        height: visualHeight
                    )
                    .padding(.trailing, 16)
                    .padding(
                        .bottom,
                        controlBarHeight + effectMenuGapToControlBar
                    )
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

    // MARK: - Settings Sheet Addition

    private var settingsSheetLayer: some View {
        GeometryReader { _ in
            ZStack(alignment: .bottom) {
                if showSettingsSheet {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeSettingsSheet()
                        }

                    SettingsSheetView(
                        isPresented: $showSettingsSheet,
                        is60FPSMode: $is60FPSMode,
                        iconRotation: iconRotation,
                        animationDuration: uiAnimationDuration
                    )
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(showSettingsSheet)
        .zIndex(100)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
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
                            deviceOrientation: deviceOrientation,
                            onFocus: { devicePoint in
                                vm.focusCamera(at: devicePoint)
                            }
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

                topBarLayer
                recognitionStatusLayer
                controlBarLayer
                effectMenuLayer
                settingsSheetLayer

                if isBusy {
                    busyOverlay
                        .transition(.opacity)
                }
            }
            // 手勢掛在整個畫面；只有從特效按鈕開始時才啟動選擇。
            .contentShape(Rectangle())
            .simultaneousGesture(
                effectScreenPressGesture,
                including: .all
            )
            .onPreferenceChange(
                EffectButtonFramePreferenceKey.self
            ) { frame in
                effectButtonFrame = frame
            }
            .fullScreenCover(
                isPresented: $showVideoPicker,
                onDismiss: {
                    vm.start()
                }
            ) {
                VideoRenderPage(
                    initialEffect: vm.selectedEffect,
                    onClose: {
                        showVideoPicker = false
                    }
                )
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
            }
            .fullScreenCover(isPresented: $showEffectLibraryPage) {
                EditableEffectLibraryPage(
                    selectedEffect: $vm.selectedEffect,
                    isPresented: $showEffectLibraryPage,
                    rotation: iconRotation
                )
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
            }
            .sheet(
                isPresented: Binding(
                    get: {
                        vm.isRecordingResultPresented
                    },
                    set: { isPresented in
                        if !isPresented {
                            vm.dismissRecordingResult()
                        }
                    }
                )
            ) {
                if let videoURL = vm.completedRecordingURL {
                    RecordingCompletionSheet(
                        vm: vm,
                        videoURL: videoURL
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(vm.recordingSaveState == .saving)
                }
            }
            .alert(
                "操作提示",
                isPresented: $showEffectLongPressTip
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("長按可切換特效")
            }
            .onAppear {
                UIDevice.current
                    .beginGeneratingDeviceOrientationNotifications()

                updateIconRotation()

                if !hasShownEffectLongPressTip {
                    hasShownEffectLongPressTip = true
                    showEffectLongPressTip = true
                }

                CameraFrameRateCoordinator.shared.bind(
                    to: vm.cameraManager
                )
                CameraFrameRateCoordinator.shared.set60FPSMode(
                    is60FPSMode
                )

                vm.updatePreviewLayout(
                    overlaySize: size,
                    videoGravity: videoGravity
                )

                vm.cameraManager.updateVideoRotation()
                vm.start()
            }
            .onDisappear {
                recognitionStatusTransitionTask?.cancel()
                recognitionStatusTransitionTask = nil
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    if !showVideoPicker {
                        vm.start()
                    }

                case .inactive:
                    break

                case .background:
                    vm.stop()

                @unknown default:
                    break
                }
            }
            .onChange(of: size) { newSize in
                vm.updatePreviewLayout(
                    overlaySize: newSize,
                    videoGravity: fixedVideoGravity
                )

                vm.cameraManager.updateVideoRotation()
            }
            .onChange(of: is60FPSMode) { enabled in
                CameraFrameRateCoordinator.shared.set60FPSMode(
                    enabled
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification
                )
            ) { _ in
                updateIconRotation()
            }
            .preferredColorScheme(.dark)
        }
        .statusBarHidden(true)
    }

    // MARK: - Icon Rotation

    private func updateIconRotation() {
        let orientation = UIDevice.current.orientation
        let targetRotation: Angle

        switch orientation {
        case .portrait:
            targetRotation = .degrees(0)

        case .landscapeLeft:
            targetRotation = .degrees(90)

        case .portraitUpsideDown:
            targetRotation = .degrees(180)

        case .landscapeRight:
            targetRotation = .degrees(-90)

        default:
            return
        }

        deviceOrientation = orientation
        vm.updateDeviceOrientation(orientation)

        // 其他控制項維持原本的旋轉動畫。
        if !isSameRotation(iconRotation, targetRotation) {
            withAnimation(
                .easeInOut(duration: uiAnimationDuration)
            ) {
                iconRotation = targetRotation
            }
        }

        // 辨識提示使用「淡出 -> 換位與旋轉 -> 淡入」。
        transitionRecognitionStatus(to: targetRotation)
    }

    private func transitionRecognitionStatus(
        to targetRotation: Angle
    ) {
        if !hasInitializedRecognitionStatusOrientation {
            recognitionStatusRotation = targetRotation
            recognitionStatusTargetRotation = targetRotation
            recognitionStatusOpacity = 1.0
            hasInitializedRecognitionStatusOrientation = true
            return
        }

        guard !isSameRotation(
            recognitionStatusTargetRotation,
            targetRotation
        ) else {
            return
        }

        recognitionStatusTargetRotation = targetRotation
        recognitionStatusTransitionTask?.cancel()

        let fadeDuration = uiAnimationDuration

        recognitionStatusTransitionTask = Task { @MainActor in
            // 先在舊位置淡出。
            withAnimation(
                .easeOut(duration: fadeDuration)
            ) {
                recognitionStatusOpacity = 0
            }

            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        fadeDuration * 1_000_000_000
                    )
                )
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            // 完全透明後，切換位置及文字方向。
            recognitionStatusRotation = targetRotation

            // 在新位置淡入。
            withAnimation(
                .easeIn(duration: fadeDuration)
            ) {
                recognitionStatusOpacity = 1
            }
        }
    }

    private func isSameRotation(
        _ lhs: Angle,
        _ rhs: Angle
    ) -> Bool {
        let lhsValue = normalizedEffectMenuDegrees(lhs.degrees)
        let rhsValue = normalizedEffectMenuDegrees(rhs.degrees)
        let difference = abs(lhsValue - rhsValue)

        return difference < 0.5 || abs(difference - 360) < 0.5
    }

    private func closeSettingsSheet() {
        withAnimation(
            .easeInOut(duration: uiAnimationDuration)
        ) {
            showSettingsSheet = false
        }
    }

    // MARK: - Video Picker

    private func openVideoPicker() {
        guard vm.canOpenVideoLibrary,
              !isBusy,
              !showVideoPicker else {
            return
        }

        vm.stop()
        showVideoPicker = true
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
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
                guard !isBusy else {
                    return
                }

                withAnimation(
                    .easeInOut(duration: uiAnimationDuration)
                ) {
                    showSettingsSheet = true
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Color.white.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .rotationEffect(iconRotation)
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
                        .foregroundColor(
                            Color(white: 0.9, opacity: 0.8)
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color(white: 0.04).opacity(0.88))
                )
                .rotationEffect(iconRotation)
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
                            Color(
                                white: 1,
                                opacity: vm.canOpenVideoLibrary
                                    ? 0.12
                                    : 0.05
                            )
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
            .disabled(
                !vm.canOpenVideoLibrary ||
                showVideoPicker ||
                isBusy
            )
            .opacity(
                (
                    vm.canOpenVideoLibrary &&
                    !showVideoPicker &&
                    !isBusy
                ) ? 1.0 : 0.45
            )

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
                } label: {
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

            effectButton
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

        return vm.isRecording
            ? "stop.fill"
            : "video.fill"
    }

    // MARK: - Effect Button / Full-screen Drag

    private var effectButton: some View {
        VStack(spacing: 4) {
            Text(vm.selectedEffect.emoji)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .background(
                    Color(white: 1, opacity: 0.12)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    Color(hex: 0x00F5FF).opacity(0.42),
                                    lineWidth: 1
                                )
                        )
                )

            Text("特效庫")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.5))
        }
        .rotationEffect(iconRotation)
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: EffectButtonFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        )
        .opacity(isBusy ? 0.45 : 1.0)
    }

    private var effectScreenPressGesture: some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .global
        )
        .onChanged { value in
            guard !isBusy else {
                return
            }

            // 只接受從特效按鈕開始的手勢。
            if effectPressStartDate == nil {
                let expandedButtonFrame = effectButtonFrame.insetBy(
                    dx: -14,
                    dy: -14
                )

                guard expandedButtonFrame.contains(value.startLocation) else {
                    return
                }

                beginEffectPress(at: value.location)
            }

            guard effectPressStartDate != nil else {
                return
            }

            latestEffectDragLocation = value.location

            if isEffectDragSelecting {
                effectDragLocation = value.location
            }
        }
        .onEnded { _ in
            // 不是從特效按鈕開始的手勢，不做處理。
            guard effectPressStartDate != nil else {
                return
            }

            guard !isBusy else {
                resetEffectPressState()
                return
            }

            let elapsed = Date().timeIntervalSince(
                effectPressStartDate ?? Date()
            )

            let shouldOpenPage =
                elapsed < 1.0 &&
                !isEffectDragSelecting

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
        latestEffectDragLocation = location
        isEffectDragSelecting = false

        effectLongPressTask?.cancel()

        effectLongPressTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: 250_000_000
            )

            guard !Task.isCancelled,
                  effectPressStartDate != nil else {
                return
            }

            isEffectDragSelecting = true
            effectDragLocation = latestEffectDragLocation ?? location

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
        latestEffectDragLocation = nil
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

private struct EffectButtonFramePreferenceKey: PreferenceKey {
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

// MARK: - Effect Library Page

// BEYTAIL_STOREKIT_PATCH 2026.06.23-2
private struct EffectLibraryPage: View {

    @Binding var selectedEffect: EffectType
    @Binding var isPresented: Bool

    let rotation: Angle

    @ObservedObject private var purchaseStore = EffectPurchaseStore.shared

    @AppStorage("effectMenuIDs")
    private var effectMenuIDsRaw: String = ""

    @State private var trialEffect: EffectType?
    @State private var alertMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private let maximumMenuEffectCount = 6

    private var ownedEffects: [EffectType] {
        EffectType.allCases.filter { purchaseStore.isPurchased($0) }
    }

    private var shopEffects: [EffectType] {
        EffectType.shopEffects.filter { !purchaseStore.isPurchased($0) }
    }

    private var ownsAllPaidEffects: Bool {
        EffectType.shopEffects.allSatisfy { purchaseStore.isPurchased($0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let contentSize = Self.contentSize(
                screenSize: screenSize,
                rotation: rotation
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                pageContent
                    .frame(
                        width: contentSize.width,
                        height: contentSize.height
                    )
                    .clipped()
                    .contentShape(Rectangle())
                    .rotationEffect(rotation)
                    .position(
                        x: screenSize.width / 2,
                        y: screenSize.height / 2
                    )
            }
        }
        .task {
            initializeDefaultMenuIfNeeded()
            await purchaseStore.loadProductsAndEntitlements()
            removeUnownedEffectsFromMenu()
        }
        .onChange(
                of: purchaseStore.purchasedProductIDs
            ) { _ in
            removeUnownedEffectsFromMenu()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { trialEffect != nil },
                set: { presented in
                    if !presented {
                        trialEffect = nil
                    }
                }
            )
        ) {
            if let trialEffect {
                VideoRenderPage(
                    initialEffect: trialEffect,
                    trialEffect: trialEffect,
                    onClose: {
                        self.trialEffect = nil
                    }
                )
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
            }
        }
        .alert(
            "特效商店",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { presented in
                    if !presented { alertMessage = nil }
                }
            )
        ) {
            Button("確定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(Color.white.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    limitedPackCard

                    if !shopEffects.isEmpty {
                        sectionTitle("單件特效")

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(shopEffects, id: \.self) { effect in
                                EffectShopCard(
                                    effect: effect,
                                    isOwned: false,
                                    isInMenu: false,
                                    displayPrice: purchaseStore.displayPrice(for: effect),
                                    isBusy: purchaseStore.purchasingProductID == effect.productID,
                                    onPrimary: {
                                        purchase(effect)
                                    },
                                    onTrial: {
                                        trialEffect = effect
                                    }
                                )
                            }
                        }
                    }

                    sectionTitle("已擁有")

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ownedEffects, id: \.self) { effect in
                            EffectShopCard(
                                effect: effect,
                                isOwned: true,
                                isInMenu: isInMenu(effect),
                                displayPrice: effect.isDefaultOwned ? "免費" : "已購買",
                                isBusy: false,
                                onPrimary: {
                                    toggleMenuEffect(effect)
                                },
                                onTrial: nil
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .background(Color.black)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))

                    Text("返回")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
            }

            Spacer()

            Text("特效商店")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            Button {
                restorePurchases()
            } label: {
                HStack(spacing: 5) {
                    if purchaseStore.isRestoring {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }

                    Text("恢復")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: 82, height: 36)
                .background(
                    Capsule().fill(Color.white.opacity(0.14))
                )
            }
            .disabled(purchaseStore.isRestoring)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var limitedPackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("🎁")
                    .font(.system(size: 42))

                VStack(alignment: .leading, spacing: 5) {
                    Text("限定特效包")
                        .font(.system(size: 22, weight: .black))
                        .foregroundColor(.white)

                    Text("滔天浪潮 + 不滅鋼盾 + 爆刃亂舞 + 狂暴冰裂")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)

                    Text(
                        ownsAllPaidEffects
                            ? "已擁有全部特效"
                            : purchaseStore.premiumPackDisplayPrice
                    )
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(Color(hex: 0x00F5FF))
                }

                Spacer()
            }

            Button {
                purchaseLimitedPack()
            } label: {
                HStack(spacing: 8) {
                    if purchaseStore.purchasingProductID == EffectType.premiumPackProductID {
                        ProgressView().tint(.white)
                    }

                    Text(ownsAllPaidEffects ? "已擁有" : "購買限定特效包")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xBF5FFF),
                            Color(hex: 0x00F5FF)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(
                ownsAllPaidEffects ||
                purchaseStore.purchasingProductID != nil
            )
            .opacity(ownsAllPaidEffects ? 0.45 : 1.0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0x07111F).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            Color(hex: 0x00F5FF).opacity(0.32),
                            lineWidth: 1.4
                        )
                )
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white.opacity(0.55))
    }

    private func initializeDefaultMenuIfNeeded() {
        guard effectMenuIDsRaw.isEmpty else { return }

        effectMenuIDsRaw = EffectType.defaultMenuEffects
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func ids(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    private func raw(from ids: Set<String>) -> String {
        EffectType.allCases
            .map(\.rawValue)
            .filter { ids.contains($0) }
            .joined(separator: ",")
    }

    private func isInMenu(_ effect: EffectType) -> Bool {
        ids(from: effectMenuIDsRaw).contains(effect.rawValue)
    }

    private func toggleMenuEffect(_ effect: EffectType) {
        guard purchaseStore.isPurchased(effect) else { return }

        var menuIDs = ids(from: effectMenuIDsRaw)

        if menuIDs.contains(effect.rawValue) {
            menuIDs.remove(effect.rawValue)

            if selectedEffect == effect {
                selectedEffect = EffectType.defaultMenuEffects.first ?? .lightning
            }
        } else {
            guard menuIDs.count < maximumMenuEffectCount else {
                alertMessage = "長按快捷特效最多只能加入 6 個"
                return
            }

            menuIDs.insert(effect.rawValue)
            selectedEffect = effect
        }

        effectMenuIDsRaw = raw(from: menuIDs)
    }

    private func removeUnownedEffectsFromMenu() {
        let currentIDs = ids(from: effectMenuIDsRaw)
        let filtered = EffectType.allCases
            .filter { effect in
                currentIDs.contains(effect.rawValue) &&
                    purchaseStore.isPurchased(effect)
            }
            .prefix(maximumMenuEffectCount)

        effectMenuIDsRaw = filtered
            .map(\.rawValue)
            .joined(separator: ",")

        if !purchaseStore.isPurchased(selectedEffect) {
            selectedEffect = .lightning
        }
    }

    private func purchase(_ effect: EffectType) {
        Task {
            _ = await purchaseStore.purchase(effect)
            if let message = purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
    }

    private func purchaseLimitedPack() {
        Task {
            _ = await purchaseStore.purchasePremiumPack()
            if let message = purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
    }

    private func restorePurchases() {
        Task {
            let restored = await purchaseStore.restorePurchases()
            if restored {
                alertMessage = "購買紀錄已恢復"
            } else if let message = purchaseStore.lastErrorMessage {
                alertMessage = message
            }
        }
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
        let degrees = normalizedDegrees(angle.degrees)
        return abs(degrees - 90) < 0.5 || abs(degrees - 270) < 0.5
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }
}

private struct EffectShopCard: View {

    let effect: EffectType
    let isOwned: Bool
    let isInMenu: Bool
    let displayPrice: String
    let isBusy: Bool
    let onPrimary: () -> Void
    let onTrial: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(effect.emoji)
                    .font(.system(size: 34))

                Spacer()

                Text(isOwned ? displayPrice : "付費")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.62))
            }

            Text(effect.displayName)
                .font(.system(size: 17, weight: .black))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(effect.description)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(minHeight: 38)

            Spacer(minLength: 2)

            Button(action: onPrimary) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    }

                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .disabled(isBusy)

            if let onTrial, !isOwned {
                Button(action: onTrial) {
                    Text("試用 10 秒")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: 0x00F5FF))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.065))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Color(hex: 0x00F5FF).opacity(0.35), lineWidth: 1)
                        )
                }
            }
        }
        .padding(14)
        .frame(height: isOwned ? 226 : 262)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.065))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var primaryTitle: String {
        if !isOwned {
            return displayPrice
        }

        return isInMenu ? "從選單移除" : "加入選單"
    }

    private var primaryBackground: LinearGradient {
        if !isOwned {
            return LinearGradient(
                colors: [Color(hex: 0xBF5FFF), Color(hex: 0x00F5FF)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        if isInMenu {
            return LinearGradient(
                colors: [Color.red.opacity(0.55), Color.red.opacity(0.35)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        return LinearGradient(
            colors: [
                Color(hex: 0x00F5FF).opacity(0.55),
                Color(hex: 0x0088FF).opacity(0.55)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    let videoGravity: AVLayerVideoGravity
    let deviceOrientation: UIDeviceOrientation
    let onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.attachSession(session)
        view.setVideoGravity(videoGravity)
        view.setDeviceOrientation(deviceOrientation)
        view.setFocusHandler(onFocus)
        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewUIView,
        context: Context
    ) {
        uiView.attachSession(session)
        uiView.setVideoGravity(videoGravity)
        uiView.setDeviceOrientation(deviceOrientation)
        uiView.setFocusHandler(onFocus)
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(
        _ uiView: CameraPreviewUIView,
        coordinator: ()
    ) {
        uiView.setFocusHandler(nil)
        uiView.detachSession()
    }
}

final class CameraPreviewUIView: UIView {

    /*
     AppDelegate 將介面鎖定為 portrait，因此橫置手機時，
     SwiftUI / UIView 的邏輯 bounds 仍維持直向尺寸。

     不能只修改 AVCaptureVideoPreviewLayer.videoRotationAngle：
     橫向影像會被塞進直向 bounds，resizeAspectFill 因而產生
     大幅裁切，看起來像 zoom in。

     此處使用獨立的 AVCaptureVideoPreviewLayer：
     1. 橫置時交換 layer 的寬高。
     2. 將 layer 旋轉回使用者目前觀看的方向。
     3. 保留原本的 videoRotationAngle，使畫面方向與相機輸出一致。
    */
    private let capturePreviewLayer = AVCaptureVideoPreviewLayer()

    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var onFocus: ((CGPoint) -> Void)?

    private let focusIndicatorView = UIView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: 72,
            height: 72
        )
    )

    var previewLayer: AVCaptureVideoPreviewLayer {
        capturePreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePreviewLayer()
        configureFocusInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreviewLayer()
        configureFocusInteraction()
    }

    private func configurePreviewLayer() {
        clipsToBounds = true

        capturePreviewLayer.backgroundColor =
            UIColor.black.cgColor
        capturePreviewLayer.videoGravity =
            .resizeAspectFill
        capturePreviewLayer.anchorPoint =
            CGPoint(x: 0.5, y: 0.5)

        layer.insertSublayer(
            capturePreviewLayer,
            at: 0
        )
    }

    private func configureFocusInteraction() {
        isUserInteractionEnabled = true

        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleFocusTap(_:))
        )

        tapGesture.numberOfTapsRequired = 1
        addGestureRecognizer(tapGesture)

        focusIndicatorView.isUserInteractionEnabled = false
        focusIndicatorView.backgroundColor = .clear
        focusIndicatorView.layer.borderWidth = 1.5
        focusIndicatorView.layer.borderColor =
            UIColor.systemYellow.cgColor
        focusIndicatorView.layer.cornerRadius = 5
        focusIndicatorView.alpha = 0

        addSubview(focusIndicatorView)
    }

    func setFocusHandler(
        _ handler: ((CGPoint) -> Void)?
    ) {
        onFocus = handler
    }

    @objc
    private func handleFocusTap(
        _ recognizer: UITapGestureRecognizer
    ) {
        guard recognizer.state == .ended else {
            return
        }

        let viewPoint = recognizer.location(in: self)

        guard bounds.contains(viewPoint) else {
            return
        }

        /*
         previewLayer 在橫向時具有旋轉 transform，
         因此先將 UIView 座標轉為 previewLayer 座標，
         再交給 AVFoundation 計算相機對焦點。
        */
        let previewPoint = previewLayer.convert(
            viewPoint,
            from: layer
        )

        guard previewLayer.bounds.contains(previewPoint) else {
            return
        }

        let devicePoint =
            previewLayer.captureDevicePointConverted(
                fromLayerPoint: previewPoint
            )

        showFocusIndicator(at: viewPoint)
        onFocus?(devicePoint)
    }

    private func showFocusIndicator(
        at point: CGPoint
    ) {
        focusIndicatorView.layer.removeAllAnimations()

        focusIndicatorView.center = point
        focusIndicatorView.alpha = 1
        focusIndicatorView.transform = CGAffineTransform(
            scaleX: 1.3,
            y: 1.3
        )

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [
                .curveEaseOut,
                .beginFromCurrentState
            ]
        ) {
            self.focusIndicatorView.transform = .identity
        } completion: { _ in
            UIView.animate(
                withDuration: 0.25,
                delay: 0.65,
                options: [
                    .curveEaseOut,
                    .beginFromCurrentState
                ]
            ) {
                self.focusIndicatorView.alpha = 0
            }
        }
    }

    func attachSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }

        applyPreviewGeometry()
    }

    func detachSession() {
        previewLayer.session = nil
    }

    func setVideoGravity(
        _ videoGravity: AVLayerVideoGravity
    ) {
        if previewLayer.videoGravity != videoGravity {
            previewLayer.videoGravity = videoGravity
        }
    }

    func setDeviceOrientation(
        _ orientation: UIDeviceOrientation
    ) {
        switch orientation {
        case .portrait,
             .portraitUpsideDown,
             .landscapeLeft,
             .landscapeRight:
            guard deviceOrientation != orientation else {
                return
            }

            deviceOrientation = orientation
            setNeedsLayout()
            applyPreviewGeometry()

        default:
            break
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPreviewGeometry()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPreviewGeometry()
    }

    private struct PreviewGeometry {
        let videoRotationAngle: CGFloat
        let layerRotationAngle: CGFloat
        let layerSize: CGSize
    }

    private func previewGeometry() -> PreviewGeometry {
        let portraitSize = bounds.size
        let landscapeSize = CGSize(
            width: bounds.height,
            height: bounds.width
        )

        switch deviceOrientation {
        case .portrait:
            return PreviewGeometry(
                videoRotationAngle: 90,
                layerRotationAngle: 0,
                layerSize: portraitSize
            )

        case .portraitUpsideDown:
            return PreviewGeometry(
                videoRotationAngle: 270,
                layerRotationAngle: .pi,
                layerSize: portraitSize
            )

        case .landscapeLeft:
            return PreviewGeometry(
                videoRotationAngle: 180,
                layerRotationAngle: -.pi / 2,
                layerSize: landscapeSize
            )

        case .landscapeRight:
            return PreviewGeometry(
                videoRotationAngle: 0,
                layerRotationAngle: .pi / 2,
                layerSize: landscapeSize
            )

        default:
            return PreviewGeometry(
                videoRotationAngle: 90,
                layerRotationAngle: 0,
                layerSize: portraitSize
            )
        }
    }

    private func applyPreviewGeometry() {
        guard bounds.width > 1,
              bounds.height > 1 else {
            return
        }

        let geometry = previewGeometry()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        /*
         橫置時先交換 layer 寬高，再旋轉 layer。
         這樣 resizeAspectFill 會以真正的橫向比例排版，
         不會再將 16:9 影像塞進直向框而產生額外放大。
        */
        previewLayer.bounds = CGRect(
            origin: .zero,
            size: geometry.layerSize
        )
        previewLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        previewLayer.setAffineTransform(
            CGAffineTransform(
                rotationAngle:
                    geometry.layerRotationAngle
            )
        )

        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(
            geometry.videoRotationAngle
           ) {
            connection.videoRotationAngle =
                geometry.videoRotationAngle
        }

        CATransaction.commit()
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
