import Foundation
import Metal

/// Triple-buffered transient vertex storage. It avoids allocating a new
/// MTLBuffer for every particle/ribbon draw call.
final class MetalFrameAllocator {
    struct Slice {
        let buffer: MTLBuffer
        let offset: Int
        let length: Int
    }

    private let device: MTLDevice
    private let capacity: Int
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer] = []
    private var frameIndex = -1
    private var cursor = 0

    init(device: MTLDevice, capacity: Int = 4 * 1024 * 1024) {
        self.device = device
        self.capacity = capacity

        for index in 0..<3 {
            guard let buffer = device.makeBuffer(
                length: capacity,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]
            ) else {
                fatalError("Unable to allocate Metal transient buffer")
            }
            buffer.label = "BeyTail transient vertices \(index)"
            buffers.append(buffer)
        }
    }

    func beginFrame(commandBuffer: MTLCommandBuffer) {
        inFlightSemaphore.wait()
        frameIndex = (frameIndex + 1) % buffers.count
        cursor = 0

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
    }

    func copyFloats(_ values: [Float], count: Int) -> Slice? {
        guard count > 0 else { return nil }
        let byteCount = count * MemoryLayout<Float>.stride
        let alignedOffset = (cursor + 255) & ~255
        guard alignedOffset + byteCount <= capacity else {
            assertionFailure("MetalFrameAllocator capacity exceeded")
            return nil
        }

        let buffer = buffers[frameIndex]
        values.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            memcpy(buffer.contents().advanced(by: alignedOffset), source, byteCount)
        }

        cursor = alignedOffset + byteCount
        return Slice(buffer: buffer, offset: alignedOffset, length: byteCount)
    }
}
