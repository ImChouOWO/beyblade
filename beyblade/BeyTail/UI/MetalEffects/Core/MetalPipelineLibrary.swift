import Metal

final class MetalPipelineLibrary {
    private struct PipelineKey: Hashable {
        let blendMode: MetalBlendMode
        let pointShader: Bool
    }

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let library: MTLLibrary
    private var cache: [PipelineKey: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        self.pixelFormat = pixelFormat

        guard let library = device.makeDefaultLibrary() else {
            fatalError(
                "Metal default library not found. Ensure BeyTailEffects.metal " +
                "is included in the beyblade target."
            )
        }
        self.library = library
    }

    func pipeline(
        blendMode: MetalBlendMode,
        pointShader: Bool
    ) -> MTLRenderPipelineState {
        let key = PipelineKey(
            blendMode: blendMode,
            pointShader: pointShader
        )
        if let pipeline = cache[key] {
            return pipeline
        }

        guard let vertex = library.makeFunction(name: "beytailEffectVertex") else {
            fatalError("Missing Metal function: beytailEffectVertex")
        }

        let fragmentName = pointShader
            ? "beytailPointFragment"
            : "beytailEffectFragment"

        guard let fragment = library.makeFunction(name: fragmentName) else {
            fatalError("Missing Metal function: \(fragmentName)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "BeyTail \(fragmentName) \(blendMode)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        configureBlend(
            descriptor.colorAttachments[0],
            mode: blendMode
        )

        do {
            let pipeline = try device.makeRenderPipelineState(
                descriptor: descriptor
            )
            cache[key] = pipeline
            return pipeline
        } catch {
            fatalError("Unable to create BeyTail Metal pipeline: \(error)")
        }
    }

    private func configureBlend(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor?,
        mode: MetalBlendMode
    ) {
        guard let attachment else { return }
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add

        switch mode {
        case .alpha:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        case .additive:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
    }
}
