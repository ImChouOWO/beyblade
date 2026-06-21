import Foundation
import AVFoundation
import Photos
import CoreVideo

/// 錄影（對應 Android GLRecordingManager + CameraGLThread 錄影 blit）：
///   - 固定標準尺寸：直拍 1080×1920、橫拍 1920×1080（旋轉由渲染端烘進畫面，metadata 不帶旋轉）
///   - H.264 8Mbps（60fps 12Mbps）、AAC 44.1kHz 128kbps 麥克風收音
///   - 寫到暫存檔，預覽頁確認後才存入相簿（= Android 的 IS_PENDING 流程）
final class RecordingManager {

    private(set) var isRecording = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private(set) var outputURL: URL?

    private(set) var outputWidth = 1080
    private(set) var outputHeight = 1920
    /// 烘焙進畫面的旋轉（0/90/180/270），由渲染端讀取
    private(set) var contentRotation = 0

    func start(orientationDegrees: Int, fps: Int) throws {
        let landscape = orientationDegrees == 90 || orientationDegrees == 270
        outputWidth = landscape ? 1920 : 1080
        outputHeight = landscape ? 1080 : 1920
        contentRotation = orientationDegrees

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("beyblade_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        outputURL = url

        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: fps > 30 ? 12_000_000 : 8_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        w.add(vIn)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128_000
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aIn.expectsMediaDataInRealTime = true
        w.add(aIn)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)

        guard w.startWriting() else { throw w.error ?? NSError(domain: "BeyTrail", code: -2) }

        writer = w
        videoInput = vIn
        audioInput = aIn
        adaptor = ad
        sessionStarted = false
        isRecording = true
    }

    /// 渲染端取得可寫入的 pixel buffer（Metal 相容，渲染完呼叫 append）
    func dequeuePixelBuffer() -> CVPixelBuffer? {
        guard isRecording, let pool = adaptor?.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    func append(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard isRecording, let vIn = videoInput, let ad = adaptor else { return }
        if !sessionStarted {
            writer?.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        if vIn.isReadyForMoreMediaData {
            ad.append(pixelBuffer, withPresentationTime: pts)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard isRecording, sessionStarted,
              let aIn = audioInput, aIn.isReadyForMoreMediaData else { return }
        aIn.append(sample)
    }

    /// 停止並回傳暫存檔 URL（進預覽頁）
    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording, let w = writer else { completion(nil); return }
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = outputURL
        w.finishWriting {
            DispatchQueue.main.async {
                completion(w.status == .completed ? url : nil)
            }
        }
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
    }

    // ── 存入相簿（BeyBlade 相簿，對應 Android DCIM/BeyBlade） ─────────────

    static func saveToPhotos(url: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }; return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                if let album = Self.findOrCreateAlbum(named: "BeyBlade"),
                   let placeholder = req?.placeholderForCreatedAsset,
                   let albumChange = PHAssetCollectionChangeRequest(for: album) {
                    albumChange.addAssets([placeholder] as NSArray)
                }
            }) { success, _ in
                DispatchQueue.main.async {
                    if success { try? FileManager.default.removeItem(at: url) }
                    completion(success)
                }
            }
        }
    }

    private static func findOrCreateAlbum(named name: String) -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any,
            options: {
                let o = PHFetchOptions()
                o.predicate = NSPredicate(format: "title = %@", name)
                return o
            }())
        if let existing = fetch.firstObject { return existing }
        // 同一個 performChanges 內不能查回，先建立（下次儲存就會加入）
        try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any,
            options: {
                let o = PHFetchOptions()
                o.predicate = NSPredicate(format: "title = %@", name)
                return o
            }()).firstObject
    }
}
