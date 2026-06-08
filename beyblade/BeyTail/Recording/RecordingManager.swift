import ReplayKit
import UIKit
import Photos

@MainActor
final class RecordingManager {

    enum RecordingState: String {
        case idle
        case starting
        case recording
        case stopping
    }

    private let recorder = RPScreenRecorder.shared()

    private(set) var state: RecordingState = .idle
    private(set) var isRecording = false

    private var pendingStopAfterStart = false

    var onStarted: ((Bool) -> Void)?
    var onStopped: ((URL?) -> Void)?

    // MARK: - Start

    func startRecording() {
        switch state {
        case .idle:
            break

        case .starting:
            print("[Recording] start ignored: already starting")
            return

        case .recording:
            print("[Recording] start ignored: already recording")
            onStarted?(true)
            return

        case .stopping:
            print("[Recording] start ignored: still stopping")
            onStarted?(false)
            return
        }

        guard recorder.isAvailable else {
            print("[Recording] recorder is not available")
            state = .idle
            isRecording = false
            onStarted?(false)
            return
        }

        print("[Recording] startRecording requested")

        state = .starting
        isRecording = false
        pendingStopAfterStart = false

        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        recorder.startRecording { [weak self] error in
            let errorMessage = error?.localizedDescription

            Task { @MainActor [weak self, errorMessage] in
                guard let self else {
                    return
                }

                self.handleStartFinished(errorMessage: errorMessage)
            }
        }
    }

    private func handleStartFinished(errorMessage: String?) {
        guard state == .starting else {
            print("[Recording] start callback ignored, current state:", state.rawValue)
            return
        }

        if let errorMessage {
            print("[Recording] start error:", errorMessage)

            state = .idle
            isRecording = false
            pendingStopAfterStart = false

            onStarted?(false)
            return
        }

        print("[Recording] start success")

        state = .recording
        isRecording = true

        onStarted?(true)

        if pendingStopAfterStart {
            print("[Recording] pending stop detected after start")
            pendingStopAfterStart = false
            stopRecording()
        }
    }

    // MARK: - Stop

    func stopRecording() {
        switch state {
        case .idle:
            print("[Recording] stop requested while idle")
            isRecording = false
            onStopped?(nil)
            return

        case .starting:
            print("[Recording] stop requested while starting, defer stop")
            pendingStopAfterStart = true
            return

        case .recording:
            break

        case .stopping:
            print("[Recording] stop ignored: already stopping")
            return
        }

        print("[Recording] stopRecording requested")

        state = .stopping
        isRecording = false

        let outputURL = makeOutputURL()

        recorder.stopRecording(withOutput: outputURL) { [weak self] error in
            let errorMessage = error?.localizedDescription

            Task { @MainActor [weak self, outputURL, errorMessage] in
                guard let self else {
                    return
                }

                self.handleStopFinished(
                    outputURL: outputURL,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func handleStopFinished(
        outputURL: URL,
        errorMessage: String?
    ) {
        guard state == .stopping else {
            print("[Recording] stop callback ignored, current state:", state.rawValue)
            return
        }

        state = .idle
        isRecording = false
        pendingStopAfterStart = false

        if let errorMessage {
            print("[Recording] stop error:", errorMessage)
            onStopped?(nil)
            return
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            print("[Recording] output file does not exist")
            onStopped?(nil)
            return
        }

        print("[Recording] stop success:", outputURL.path)
        onStopped?(outputURL)
    }

    // MARK: - Force Reset

    func forceReset() {
        print("[Recording] forceReset, state:", state.rawValue)

        pendingStopAfterStart = false
        isRecording = false
        state = .idle
    }

    // MARK: - Save

    func saveToPhotoLibrary(
        url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            performSaveToPhotoLibrary(
                url: url,
                completion: completion
            )

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self, url] newStatus in
                Task { @MainActor [weak self, url, newStatus] in
                    guard let self else {
                        completion(false)
                        return
                    }

                    switch newStatus {
                    case .authorized, .limited:
                        self.performSaveToPhotoLibrary(
                            url: url,
                            completion: completion
                        )

                    default:
                        print("[Recording] photo library permission denied")
                        completion(false)
                    }
                }
            }

        default:
            print("[Recording] photo library permission unavailable:", status.rawValue)
            completion(false)
        }
    }

    private func performSaveToPhotoLibrary(
        url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            let errorMessage = error?.localizedDescription

            Task { @MainActor [success, errorMessage] in
                if let errorMessage {
                    print("[Recording] save error:", errorMessage)
                }

                completion(success)
            }
        }
    }

    // MARK: - Helpers

    private func makeOutputURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "beytail_\(timestamp)_\(UUID().uuidString.prefix(8)).mp4"

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
    }
}
