import Foundation

/// Reusable CPU-side float buffer. The original Android effects use direct
/// NIO FloatBuffer writes; this class preserves the same append semantics.
final class MetalFloatBuffer {
    private(set) var values: [Float]
    private(set) var count: Int = 0

    init(capacity: Int) {
        values = Array(repeating: 0, count: max(capacity, 1))
    }

    var capacity: Int { values.count }
    var capacityBytes: Int { values.count * MemoryLayout<Float>.stride }
    var usedByteCount: Int { count * MemoryLayout<Float>.stride }

    func clear() {
        count = 0
    }

    @discardableResult
    func put(_ value: Float) -> MetalFloatBuffer {
        ensureCapacity(count + 1)
        values[count] = value
        count += 1
        return self
    }

    func append(contentsOf source: [Float]) {
        ensureCapacity(count + source.count)
        values.replaceSubrange(count..<(count + source.count), with: source)
        count += source.count
    }

    func replaceUsedValues(with source: [Float]) {
        ensureCapacity(source.count)
        values.replaceSubrange(0..<source.count, with: source)
        count = source.count
    }

    func usedValues() -> ArraySlice<Float> {
        values.prefix(count)
    }

    func withUnsafeRawPointer<R>(
        _ body: (UnsafeRawPointer, Int) throws -> R
    ) rethrows -> R? {
        guard count > 0 else { return nil }
        return try values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return try body(base, count)
        }
    }

    private func ensureCapacity(_ required: Int) {
        guard required > values.count else { return }
        let next = max(required, values.count * 2)
        values.append(contentsOf: repeatElement(0, count: next - values.count))
    }
}
