import SwiftUI
@preconcurrency import AVFoundation
import UIKit

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var vm = MainViewModel()

    @State private var showVideoPicker = false

    @State private var iconRotation: Angle = .zero
    @State private var effectDragLocation: CGPoint?

    @State private var showEffectLibraryPage = false
    @State private var effectPressStartDate: Date?
    @State private var effectLongPressTask: Task<Void, Never>?
    @State private var isEffectDragSelecting = false

    // 全螢幕拖曳選特效使用。
    @State private var effectButtonFrame: CGRect = .zero
    @State private var latestEffectDragLocation: CGPoint?

    private let fixedIsLandscape = false
    private let fixedVideoGravity: AVLayerVideoGravity = .resizeAspectFill
    private let controlBarHeight: CGFloat = 110

    private let topBarHeight: CGFloat = 40
    private let topBarTopPadding: CGFloat = 10

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
    private let effectMenuHeight: CGFloat = 360
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

                topBarLayer
                hintLayer
                controlBarLayer
                effectMenuLayer

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
                EffectLibraryPage(
                    selectedEffect: $vm.selectedEffect,
                    isPresented: $showEffectLibraryPage,
                    rotation: iconRotation
                )
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
            }
            .onAppear {
                UIDevice.current
                    .beginGeneratingDeviceOrientationNotifications()

                updateIconRotation()

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
            .onChange(of: size) { _, newSize in
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
            .preferredColorScheme(.dark)
        }
        .statusBarHidden(true)
    }

    // MARK: - Icon Rotation

    private func updateIconRotation() {
        let orientation = UIDevice.current.orientation

        switch orientation {
        case .portrait:
            iconRotation = .degrees(0)

        case .landscapeLeft:
            iconRotation = .degrees(90)

        case .portraitUpsideDown:
            iconRotation = .degrees(180)

        case .landscapeRight:
            iconRotation = .degrees(-90)

        default:
            break
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
                // settings
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

            VStack(spacing: 4) {
                ZStack {
                    VStack {
                        Text("\(vm.fps) FPS")
                            .font(
                                .system(
                                    size: 11,
                                    design: .monospaced
                                )
                            )
                            .foregroundColor(.white)

                        Text("[\(vm.hardwareLabel)]")
                            .font(
                                .system(
                                    size: 11,
                                    weight: .bold,
                                    design: .monospaced
                                )
                            )
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

        return vm.isRecording
            ? "stop.fill"
            : "video.fill"
    }

    // MARK: - Effect Button / Full-screen Drag

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

private struct EffectLibraryPage: View {

    @Binding var selectedEffect: EffectType
    @Binding var isPresented: Bool

    let rotation: Angle

    @AppStorage("ownedEffectIDs")
    private var ownedEffectIDsRaw: String = ""

    @AppStorage("effectMenuIDs")
    private var effectMenuIDsRaw: String = ""

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var ownedEffects: [EffectType] {
        EffectType.allCases.filter { isOwned($0) }
    }

    private var shopEffects: [EffectType] {
        EffectType.shopEffects.filter { !isOwned($0) }
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
        .onAppear {
            initializeDefaultStorageIfNeeded()
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
                                    onTap: {
                                        buyEffect(effect)
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
                                onTap: {
                                    toggleMenuEffect(effect)
                                }
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
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                )
            }

            Spacer()

            Text("特效商店")
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

                    HStack(spacing: 8) {
                        Text("原價 NT$120")
                            .font(.system(size: 12))
                            .strikethrough()
                            .foregroundColor(.white.opacity(0.38))

                        Text("NT$100")
                            .font(.system(size: 20, weight: .black))
                            .foregroundColor(Color(hex: 0x00F5FF))
                    }
                }

                Spacer()
            }

            Button {
                buyLimitedPack()
            } label: {
                Text("立即購買  省 NT$20")
                    .font(.system(size: 15, weight: .bold))
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
                EffectType.shopEffects
                    .allSatisfy { isOwned($0) }
            )
            .opacity(
                EffectType.shopEffects
                    .allSatisfy { isOwned($0) }
                    ? 0.45
                    : 1.0
            )
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

    private func initializeDefaultStorageIfNeeded() {
        if ownedEffectIDsRaw.isEmpty {
            ownedEffectIDsRaw = EffectType.defaultOwnedEffects
                .map(\.rawValue)
                .joined(separator: ",")
        }

        if effectMenuIDsRaw.isEmpty {
            effectMenuIDsRaw = EffectType.defaultMenuEffects
                .map(\.rawValue)
                .joined(separator: ",")
        }
    }

    private func ids(from raw: String) -> Set<String> {
        Set(
            raw
                .split(separator: ",")
                .map(String.init)
        )
    }

    private func raw(from ids: Set<String>) -> String {
        EffectType.allCases
            .map(\.rawValue)
            .filter { ids.contains($0) }
            .joined(separator: ",")
    }

    private func isOwned(_ effect: EffectType) -> Bool {
        if effect.isDefaultOwned {
            return true
        }

        return ids(from: ownedEffectIDsRaw)
            .contains(effect.rawValue)
    }

    private func isInMenu(_ effect: EffectType) -> Bool {
        ids(from: effectMenuIDsRaw)
            .contains(effect.rawValue)
    }

    private func buyEffect(_ effect: EffectType) {
        var ownedIDs = ids(from: ownedEffectIDsRaw)
        ownedIDs.insert(effect.rawValue)
        ownedEffectIDsRaw = raw(from: ownedIDs)
    }

    private func buyLimitedPack() {
        var ownedIDs = ids(from: ownedEffectIDsRaw)

        for effect in EffectType.shopEffects {
            ownedIDs.insert(effect.rawValue)
        }

        ownedEffectIDsRaw = raw(from: ownedIDs)
    }

    private func toggleMenuEffect(_ effect: EffectType) {
        guard isOwned(effect) else {
            return
        }

        var menuIDs = ids(from: effectMenuIDsRaw)

        if menuIDs.contains(effect.rawValue) {
            menuIDs.remove(effect.rawValue)

            if selectedEffect == effect {
                selectedEffect = EffectType.defaultMenuEffects.first
                    ?? .lightning
            }
        } else {
            menuIDs.insert(effect.rawValue)
            selectedEffect = effect
        }

        effectMenuIDsRaw = raw(from: menuIDs)
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

        return abs(degrees - 90) < 0.5 ||
            abs(degrees - 270) < 0.5
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)

        if value < 0 {
            value += 360
        }

        return value
    }
}

private struct EffectShopCard: View {

    let effect: EffectType
    let isOwned: Bool
    let isInMenu: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(effect.emoji)
                .font(.system(size: 34))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 4)

            Text(effect.displayName)
                .font(.system(size: 17, weight: .black))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(effect.description)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Button(action: onTap) {
                Text(buttonTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(14)
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.065))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    private var buttonTitle: String {
        if !isOwned {
            return "NT$\(effect.price)"
        }

        return isInMenu
            ? "從選單移除"
            : "加入選單"
    }

    private var buttonBackground: LinearGradient {
        if !isOwned {
            return LinearGradient(
                colors: [
                    Color(hex: 0xBF5FFF),
                    Color(hex: 0x00F5FF)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        if isInMenu {
            return LinearGradient(
                colors: [
                    Color.red.opacity(0.55),
                    Color.red.opacity(0.35)
                ],
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

    private var isLandscape = false
    private var lastAppliedPreviewAngle: CGFloat = -1

    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError(
                "CameraPreviewUIView layer is not AVCaptureVideoPreviewLayer"
            )
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
        self.isLandscape = isLandscape
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
            return
        }

        connection.videoRotationAngle = previewAngle
        lastAppliedPreviewAngle = previewAngle
    }

    private func fixedPreviewRotationAngle() -> CGFloat {
        isLandscape ? 0 : 90
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
