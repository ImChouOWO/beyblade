import Foundation
@preconcurrency import AVFoundation

/// 將設定頁的 30 / 60 FPS 選項套用到目前 CameraManager 的相機輸入。
///
/// 不需要修改既有 CameraManager.swift；此協調器會在相機 Session 啟動後，
/// 自動重新套用儲存在 UserDefaults 的 FPS 設定。
final class CameraFrameRateCoordinator: @unchecked Sendable {

    static let shared = CameraFrameRateCoordinator()

    private let preferenceKey = "is60FPSMode"
    private let configurationQueue = DispatchQueue(
        label: "com.beytail.camera.frame-rate",
        qos: .userInitiated
    )

    private weak var cameraManager: CameraManager?
    private var sessionStartedObserver: NSObjectProtocol?

    private init() {}

    deinit {
        if let sessionStartedObserver {
            NotificationCenter.default.removeObserver(sessionStartedObserver)
        }
    }

    /// 綁定目前 ContentView 使用的 CameraManager。
    /// 每次 AVCaptureSession 啟動時都會重新套用 30 / 60 FPS。
    func bind(to cameraManager: CameraManager) {
        if self.cameraManager === cameraManager,
           sessionStartedObserver != nil {
            applyStoredFrameRate()
            return
        }

        if let sessionStartedObserver {
            NotificationCenter.default.removeObserver(sessionStartedObserver)
        }

        self.cameraManager = cameraManager

        sessionStartedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: cameraManager.session,
            queue: .main
        ) { [weak self] _ in
            self?.applyStoredFrameRate()
        }

        applyStoredFrameRate()
    }

    /// 更新偏好並立即套用。`true` 為 60 FPS，`false` 為 30 FPS。
    func set60FPSMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        apply(frameRate: enabled ? 60 : 30)
    }

    private func applyStoredFrameRate() {
        let enabled = UserDefaults.standard.bool(forKey: preferenceKey)
        apply(frameRate: enabled ? 60 : 30)
    }

    private func apply(frameRate: Int32) {
        guard let cameraManager else {
            return
        }

        let boxedManager = FrameRateSendableBox(value: cameraManager)

        configurationQueue.async { [boxedManager] in
            Self.configure(
                cameraManager: boxedManager.value,
                frameRate: frameRate
            )
        }
    }

    private static func configure(
        cameraManager: CameraManager,
        frameRate: Int32
    ) {
        let session = cameraManager.session

        guard let deviceInput = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first else {
            // Session 尚未建立 input 時，會在 Session 啟動通知後再次套用。
            return
        }

        let device = deviceInput.device
        let requestedFPS = Double(frameRate)

        guard let selectedFormat = bestFormat(
            for: device,
            requestedFPS: requestedFPS
        ) else {
            print(
                "[FPS] Device does not support requested frame rate:",
                frameRate
            )
            return
        }

        do {
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
            }

            device.activeFormat = selectedFormat

            let duration = CMTime(
                value: 1,
                timescale: frameRate
            )

            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration

            let dimensions = CMVideoFormatDescriptionGetDimensions(
                selectedFormat.formatDescription
            )

            print(
                "[FPS] Applied:",
                "\(frameRate) FPS,",
                "format=\(dimensions.width)x\(dimensions.height)"
            )
        } catch {
            print(
                "[FPS] Cannot configure camera frame rate:",
                error.localizedDescription
            )
        }
    }

    private static func bestFormat(
        for device: AVCaptureDevice,
        requestedFPS: Double
    ) -> AVCaptureDevice.Format? {
        let currentFormat = device.activeFormat

        if supports(
            format: currentFormat,
            requestedFPS: requestedFPS
        ) {
            return currentFormat
        }

        let currentDimensions = CMVideoFormatDescriptionGetDimensions(
            currentFormat.formatDescription
        )

        let supportedFormats = device.formats.filter {
            supports(
                format: $0,
                requestedFPS: requestedFPS
            )
        }

        let matchingCurrentResolution = supportedFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )

            return dimensions.width == currentDimensions.width &&
                dimensions.height == currentDimensions.height
        }

        if let format = matchingCurrentResolution.first {
            return format
        }

        // CameraManager 使用 .hd1280x720；找不到同尺寸格式時，只退回 720p，
        // 避免切換到 4K 等格式造成記憶體與推論負載暴增。
        let hd720Formats = supportedFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )

            return dimensions.width == 1280 &&
                dimensions.height == 720
        }

        return hd720Formats.min { lhs, rhs in
            formatScore(
                lhs,
                targetDimensions: currentDimensions
            ) < formatScore(
                rhs,
                targetDimensions: currentDimensions
            )
        }
    }

    private static func supports(
        format: AVCaptureDevice.Format,
        requestedFPS: Double
    ) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= requestedFPS &&
                range.maxFrameRate >= requestedFPS
        }
    }

    private static func formatScore(
        _ format: AVCaptureDevice.Format,
        targetDimensions: CMVideoDimensions
    ) -> Int64 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            format.formatDescription
        )

        let widthDifference = abs(
            Int64(dimensions.width) - Int64(targetDimensions.width)
        )
        let heightDifference = abs(
            Int64(dimensions.height) - Int64(targetDimensions.height)
        )

        // 優先維持 CameraManager 原本的 1280×720 或當前解析度。
        return widthDifference + heightDifference
    }
}

private struct FrameRateSendableBox<T>: @unchecked Sendable {
    let value: T
}
