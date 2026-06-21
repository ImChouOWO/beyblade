import SwiftUI
import MetalKit
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════
// ViewModel — 持有相機/渲染/錄影，主畫面所有狀態
// ═══════════════════════════════════════════════════════════════════════

@MainActor
final class CameraViewModel: ObservableObject {
    let camera = CameraManager()
    let renderer: CameraRenderer

    @Published var selectedEffect: EffectType = SettingsStore.quickMenu.first ?? .lightning
    @Published var quickMenu: [EffectType] = SettingsStore.quickMenu
    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var hudFps: Float = 0
    @Published var hudHardware: InferenceHardware = .mock
    @Published var hudThermal: ProcessInfo.ThermalState = .nominal
    @Published var torchOn = SettingsStore.torchOn
    @Published var showEffectMenu = false
    @Published var showTimerMenu = false
    @Published var countdown: Int? = nil
    @Published var previewEffect: EffectType? = nil     // 20 秒試用
    @Published var previewRemaining = 0
    @Published var reviewURL: URL? = nil
    @Published var orientationDegrees = 0               // 實體方向

    private var recordTimer: Timer?
    private var previewTimer: Timer?
    private var thermalTimer: Timer?

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        renderer = try! CameraRenderer(device: device)
        renderer.effectType = selectedEffect

        camera.onVideoFrame = { [weak self] pb, pts in
            self?.renderer.onCameraFrame(pb, pts: pts)
        }
        camera.onAudioSample = { [weak self] sample in
            self?.renderer.recording.appendAudio(sample)
        }
        renderer.onHudUpdate = { [weak self] fps, hw, _ in
            self?.hudFps = fps
            self?.hudHardware = hw
        }

        camera.setTorch(torchOn)
        camera.setFrameRate(is60: SettingsStore.is60Fps)
        camera.start()

        // 溫度狀態（iOS 無電池溫度 API，用系統 thermalState）
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hudThermal = ProcessInfo.processInfo.thermalState }
        }

        // 實體方向監聽（app 鎖直向，錄影方向用感應器）
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRecording else { return }
            switch UIDevice.current.orientation {
            case .landscapeLeft:      self.orientationDegrees = 90
            case .landscapeRight:     self.orientationDegrees = 270
            case .portraitUpsideDown: self.orientationDegrees = 180
            case .portrait:           self.orientationDegrees = 0
            default: break
            }
            self.renderer.deviceOrientationDegrees = self.orientationDegrees
        }

        // 相機 session 中斷（來電 / 被其他 app 搶相機）→ 錄影中自動存檔
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: camera.session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRecordingAndSave() }
        }
    }

    // ── 特效 ─────────────────────────────────────────────────────────────

    func select(_ effect: EffectType) {
        guard !effect.locked else { return }
        selectedEffect = effect
        renderer.effectType = effect
        showEffectMenu = false
    }

    func startPreview(_ effect: EffectType) {
        previewEffect = effect
        previewRemaining = 20
        renderer.effectType = effect
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.previewRemaining -= 1
                if self.previewRemaining <= 0 { self.stopPreview() }
            }
        }
    }

    func stopPreview() {
        previewTimer?.invalidate()
        previewEffect = nil
        renderer.effectType = selectedEffect
    }

    // ── 錄影 ─────────────────────────────────────────────────────────────

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        do {
            try renderer.recording.start(
                orientationDegrees: orientationDegrees,
                fps: SettingsStore.is60Fps ? 60 : 30)
            isRecording = true
            recordSeconds = 0
            UIApplication.shared.isIdleTimerDisabled = true
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.recordSeconds += 1 }
            }
        } catch {
            print("[Record] start failed: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        renderer.recording.stop { [weak self] url in
            self?.reviewURL = url
        }
    }

    /// 退背景 / 來電中斷時：停止錄影並**直接存入相簿**（不進預覽頁，對應 Android onPause 自動存檔）
    func stopRecordingAndSave() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        renderer.recording.stop { url in
            guard let url else { return }
            RecordingManager.saveToPhotos(url: url) { _ in }
        }
    }

    // ── 生命週期（背景/前景切換，對應 Android onPause/onResume） ──────────

    func handleBackground() {
        stopRecordingAndSave()      // 錄影中退背景 → 自動存檔
        camera.stop()               // 暫停相機與推論，省電防發熱
    }

    func handleForeground() {
        camera.start()
        // 回前景重查購買狀態（付款視窗關閉後）
        Task { await StoreManager.shared.refreshEntitlements() }
    }

    func startCountdown(seconds: Int) {
        SettingsStore.timerSeconds = seconds
        countdown = seconds
        tickCountdown()
    }

    private func tickCountdown() {
        guard let c = countdown else { return }
        if c <= 0 {
            countdown = nil
            startRecording()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.countdown != nil else { return }
            self.countdown = (self.countdown ?? 1) - 1
            self.tickCountdown()
        }
    }

    func cancelCountdown() { countdown = nil }

    // ── 手電筒 / 快捷選單 ───────────────────────────────────────────────

    func toggleTorch() {
        torchOn.toggle()
        SettingsStore.torchOn = torchOn
        camera.setTorch(torchOn)
    }

    func reloadQuickMenu() {
        quickMenu = SettingsStore.quickMenu
        if !quickMenu.contains(selectedEffect), let first = quickMenu.first {
            select(first)
        }
    }

    func applyFpsMode(is60: Bool) {
        camera.setFrameRate(is60: is60)
        renderer.inference.inferenceFrameInterval = is60 ? 4 : 2
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MTKView 包裝
// ═══════════════════════════════════════════════════════════════════════

struct MetalCameraView: UIViewRepresentable {
    let renderer: CameraRenderer
    let preferredFps: Int

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.preferredFramesPerSecond = preferredFps
        view.framebufferOnly = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = preferredFps
    }
}

// ═══════════════════════════════════════════════════════════════════════
// 主畫面
// ═══════════════════════════════════════════════════════════════════════

struct MainView: View {
    @StateObject private var vm = CameraViewModel()
    @StateObject private var store = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showShop = false
    @State private var showSettings = false
    @State private var showVideoFx = false

    // 長按拖曳選單互動狀態（特效快選 + 倒數選單共用）
    @State private var menuFrames: [String: CGRect] = [:]   // 項目命中框（root 座標）
    @State private var hoveredKey: String?                  // 拖曳中高亮項
    @State private var pressRing: CGFloat = 0               // 長按進度環 0→1
    @State private var pressTarget: PressTarget?            // 目前按住的按鈕
    @State private var pressActivated = false               // 長按是否已達門檻
    @State private var pressActivation: DispatchWorkItem?   // 0.55s 後彈選單
    private let longPressDuration: TimeInterval = 0.55

    enum PressTarget { case effect, record }

    var body: some View {
        ZStack {
            MetalCameraView(renderer: vm.renderer,
                            preferredFps: SettingsStore.is60Fps ? 60 : 30)
                .ignoresSafeArea()

            VStack {
                topBar
                hudBar
                Spacer()
                if vm.showEffectMenu { effectMenu }
                if vm.showTimerMenu { timerMenu }
                bottomBar
            }
            .padding()

            if let c = vm.countdown { countdownOverlay(c) }
            if let effect = vm.previewEffect { previewHud(effect) }
        }
        .coordinateSpace(name: "root")
        .onPreferenceChange(MenuItemFrameKey.self) { menuFrames = $0 }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: vm.handleBackground()
            case .active:     vm.handleForeground()
            default:          break
            }
        }
        .sheet(isPresented: $showShop, onDismiss: { vm.reloadQuickMenu() }) {
            ShopView(onPreview: { effect in
                showShop = false
                vm.startPreview(effect)
            })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onFpsChanged: { vm.applyFpsMode(is60: $0) })
        }
        .fullScreenCover(isPresented: $showVideoFx) { VideoFxView() }
        .fullScreenCover(item: Binding(
            get: { vm.reviewURL.map(ReviewItem.init) },
            set: { if $0 == nil { vm.reviewURL = nil } })
        ) { item in
            ReviewView(url: item.url)
        }
    }

    // ── 子元件 ───────────────────────────────────────────────────────────

    private var topBar: some View {
        HStack {
            Text("BEYTRAIL")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0, green: 0.96, blue: 1),
                             Color(red: 0.75, green: 0.37, blue: 1)],
                    startPoint: .leading, endPoint: .trailing))
            Spacer()
            iconButton("🎬") { showVideoFx = true }
            iconButton("⚙️") { showSettings = true }
        }
    }

    private var hudBar: some View {
        HStack(spacing: 8) {
            Text("\(Int(vm.hudFps)) FPS").font(.system(size: 11, design: .monospaced))
            Text(vm.hudHardware.rawValue)
                .font(.system(size: 11, design: .monospaced)).bold()
                .foregroundColor(hwColor)
            Text(thermalText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(thermalColor)
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.black.opacity(0.4)).cornerRadius(8)
    }

    private var hwColor: Color {
        switch vm.hudHardware {
        case .ane: return .green
        case .gpu: return .blue
        case .cpu: return .orange
        case .mock: return .gray
        }
    }

    private var thermalText: String {
        switch vm.hudThermal {
        case .nominal: return "溫度正常"
        case .fair: return "微熱"
        case .serious: return "偏熱"
        case .critical: return "過熱"
        @unknown default: return "—"
        }
    }

    private var thermalColor: Color {
        switch vm.hudThermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var effectMenu: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("選擇特效").font(.system(size: 9)).foregroundColor(.gray)
            ForEach(vm.quickMenu.reversed()) { effect in
                let key = "fx:\(effect.rawValue)"
                let hovered = hoveredKey == key
                // 也保留點擊選取（長按拖曳放開為主互動，點選為備援）
                Button { vm.select(effect) } label: {
                    HStack {
                        Text(effect.emoji)
                        VStack(alignment: .leading) {
                            Text(effect.displayName).font(.system(size: 12))
                                .foregroundColor(.white)
                            Text(effect.blurb).font(.system(size: 9))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        if effect.locked { Text("🔒") }
                        else if effect == vm.selectedEffect {
                            Text("✓").foregroundColor(.cyan)
                        }
                    }
                    .padding(8)
                    .background(menuRowBackground(selected: effect == vm.selectedEffect,
                                                  hovered: hovered))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cyan, lineWidth: hovered ? 2 : 0))
                    .opacity(effect.locked ? 0.5 : 1)
                }
                .disabled(effect.locked)
                .background(reportFrame(key))
            }
        }
        .frame(maxWidth: 240)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var timerMenu: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("倒數拍攝").font(.system(size: 9)).foregroundColor(.gray)
            ForEach([10, 5, 3], id: \.self) { sec in
                let key = "t:\(sec)"
                let hovered = hoveredKey == key
                Button {
                    vm.showTimerMenu = false
                    vm.startCountdown(seconds: sec)
                } label: {
                    HStack { Text("⏱"); Text("\(sec)s").foregroundColor(.white); Spacer() }
                        .padding(8)
                        .background(menuRowBackground(selected: false, hovered: hovered))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan, lineWidth: hovered ? 2 : 0))
                }
                .background(reportFrame(key))
            }
        }
        .frame(maxWidth: 180)
    }

    private func menuRowBackground(selected: Bool, hovered: Bool) -> Color {
        if hovered { return Color.cyan.opacity(0.35) }
        if selected { return Color.cyan.opacity(0.2) }
        return Color.black.opacity(0.5)
    }

    /// 回報項目在 root 座標的命中框，供長按拖曳時 hit-test
    private func reportFrame(_ key: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: MenuItemFrameKey.self,
                                   value: [key: geo.frame(in: .named("root"))])
        }
    }

    private var bottomBar: some View {
        HStack {
            // 手電筒
            iconButton(vm.torchOn ? "🔦" : "💡") { vm.toggleTorch() }
            Spacer()
            // 特效快選（短按開選單；長按 0.55s 彈選單→按住拖到項目放開選取）
            Text(vm.selectedEffect.emoji)
                .font(.system(size: 26))
                .iconRotation(vm.orientationDegrees)
                .frame(width: 56, height: 56)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
                .overlay(ringOverlay(for: .effect))
                .gesture(menuDragGesture(.effect))
            Spacer()
            // 錄影鈕（短按開始/停止；長按彈倒數選單→拖選 3/5/10 秒）
            recordButton
            Spacer()
            // 商店
            Button { showShop = true } label: {
                Text("🛒").font(.system(size: 26))
                    .iconRotation(vm.orientationDegrees)
                    .frame(width: 56, height: 56)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            Spacer()
            // 錄影計時
            Text(vm.isRecording
                 ? String(format: "%02d:%02d", vm.recordSeconds / 60, vm.recordSeconds % 60)
                 : "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.red)
                .frame(width: 44)
        }
    }

    private var recordButton: some View {
        Circle()
            .fill(vm.isRecording
                  ? AnyShapeStyle(Color.red)
                  : AnyShapeStyle(LinearGradient(
                        colors: [Color(red: 0, green: 0.96, blue: 1),
                                 Color(red: 0.75, green: 0.37, blue: 1)],
                        startPoint: .top, endPoint: .bottom)))
            .frame(width: 74, height: 74)
            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 3))
            .overlay(ringOverlay(for: .record))
            .gesture(menuDragGesture(.record))
    }

    /// 長按進度環（按住期間沿按鈕外圈填滿，0.55s 滿 → 彈選單）
    @ViewBuilder
    private func ringOverlay(for target: PressTarget) -> some View {
        if pressTarget == target {
            Circle()
                .trim(from: 0, to: pressRing)
                .stroke(Color.cyan,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    // ── 長按拖曳選單手勢（特效快選 / 錄影鈕共用） ─────────────────────────

    private func menuDragGesture(_ target: PressTarget) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
            .onChanged { value in
                if pressTarget == nil { beginPress(target) }
                if pressTarget == target && pressActivated {
                    hoveredKey = hitTest(value.location, target: target)
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 12
                endPress(target, moved: moved)
            }
    }

    private func beginPress(_ target: PressTarget) {
        if target == .record && vm.isRecording { return }   // 錄影中不開倒數選單
        pressTarget = target
        pressActivated = false
        hoveredKey = nil
        pressRing = 0
        withAnimation(.linear(duration: longPressDuration)) { pressRing = 1 }

        let work = DispatchWorkItem {
            pressActivated = true
            withAnimation {
                if target == .effect { vm.showEffectMenu = true; vm.showTimerMenu = false }
                else                 { vm.showTimerMenu = true; vm.showEffectMenu = false }
            }
        }
        pressActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    private func endPress(_ target: PressTarget, moved: Bool) {
        pressActivation?.cancel(); pressActivation = nil
        withAnimation(.easeOut(duration: 0.12)) { pressRing = 0 }
        defer { pressTarget = nil; pressActivated = false; hoveredKey = nil }

        if pressActivated {
            // 長按已成立：拖到項目放開 → 選取；放開在按鈕上 → 選單留著可點選
            if let key = hoveredKey { commitSelection(key) }
        } else if !moved {
            // 快速點按 = 直接執行主動作
            switch target {
            case .effect:
                withAnimation { vm.showEffectMenu.toggle(); vm.showTimerMenu = false }
            case .record:
                vm.showTimerMenu = false
                vm.toggleRecording()
            }
        }
    }

    private func hitTest(_ point: CGPoint, target: PressTarget) -> String? {
        let prefix = target == .effect ? "fx:" : "t:"
        return menuFrames.first { $0.key.hasPrefix(prefix) && $0.value.contains(point) }?.key
    }

    private func commitSelection(_ key: String) {
        if key.hasPrefix("fx:"),
           let fx = EffectType(rawValue: String(key.dropFirst(3))) {
            vm.select(fx)                       // 內含 locked 防護 + 關閉選單
        } else if key.hasPrefix("t:"), let sec = Int(key.dropFirst(2)) {
            vm.showTimerMenu = false
            vm.startCountdown(seconds: sec)
        }
    }

    private func countdownOverlay(_ c: Int) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            Text(c > 0 ? "\(c)" : "GO")
                .font(.system(size: 96, weight: .black))
                .foregroundColor(.cyan)
        }
        .onTapGesture { vm.cancelCountdown() }
    }

    private func previewHud(_ effect: EffectType) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                Text("\(effect.emoji)  \(effect.displayName)  預覽中")
                    .foregroundColor(.white)
                Text("\(vm.previewRemaining)")
                    .font(.system(size: 56, weight: .bold)).foregroundColor(.cyan)
                Button("停止預覽") { vm.stopPreview() }
                    .foregroundColor(.red)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.black.opacity(0.6)).cornerRadius(10)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.85))
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func iconButton(_ emoji: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 17))
                .iconRotation(vm.orientationDegrees)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ReviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 蒐集選單各項目在 root 座標的命中框，供長按拖曳 hit-test
struct MenuItemFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// icon 跟實體方向旋轉（250ms，對齊 Android 規格）。
    /// App 鎖直向，故反向旋轉 glyph 讓圖示對使用者保持正立；選單面板維持直向以確保
    /// 拖曳命中判定不需做旋轉座標換算。（旋轉方向若與實機相反，把負號拿掉即可。）
    func iconRotation(_ degrees: Int) -> some View {
        rotationEffect(.degrees(Double(-degrees)))
            .animation(.easeInOut(duration: 0.25), value: degrees)
    }
}
