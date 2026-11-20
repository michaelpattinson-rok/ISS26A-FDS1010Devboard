import Metal
import SwiftUI

nonisolated final class WaveformMetal: @unchecked Sendable {
    static let shared: WaveformMetal? = try? WaveformMetal()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "waveform_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "waveform_fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func encode(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, buffer: MTLBuffer, count: Int,
                range: ClosedRange<Double>, size: Float, color: SIMD4<Float>) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var scale = SIMD4(Float(range.lowerBound), Float(range.upperBound), size, 0)
        var tint = color
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        encoder.endEncoding()
        return true
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct WaveformVertex {
        float4 position [[position]];
        float size [[point_size]];
    };
    vertex WaveformVertex waveform_vertex(uint index [[vertex_id]],
                                          const device float2 *points [[buffer(0)]],
                                          constant float4 &scale [[buffer(1)]]) {
        const float2 point = points[index];
        const float y = (point.y - scale.x) / (scale.y - scale.x);
        return {float4(point.x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0), scale.z};
    }
    fragment float4 waveform_fragment(constant float4 &color [[buffer(0)]]) { return color; }
    """
}

actor WaveformRasterWorker {
    private var buffer: MTLBuffer?
    private var texture: MTLTexture?
    private var busy = false

    func image(renderer: WaveformMetal, dots: WaveformDots, range: ClosedRange<Double>,
               width: Int, height: Int, color: SIMD4<Float>) async throws -> CGImage {
        while busy { try await Task.sleep(for: .milliseconds(8)) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        let length = dots.values.count * MemoryLayout<SIMD2<Float>>.stride
        if buffer?.length ?? 0 < length {
            buffer = renderer.device.makeBuffer(length: length, options: .storageModeShared)
        }
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                       height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            texture = renderer.device.makeTexture(descriptor: descriptor)
        }
        guard let buffer, let texture, let command = renderer.queue.makeCommandBuffer() else {
            throw CocoaError(.featureUnsupported)
        }
        dots.values.withUnsafeBytes {
            if let source = $0.baseAddress { buffer.contents().copyMemory(from: source, byteCount: length) }
        }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard renderer.encode(command, pass: pass, buffer: buffer, count: dots.values.count, range: range,
                              size: dots.values.count < 4_000 ? 4 : 2, color: color) else {
            throw CocoaError(.featureUnsupported)
        }
        let error: String? = await withCheckedContinuation { continuation in
            command.addCompletedHandler { result in
                if result.status == .completed {
                    WaveformGPUTiming.shared.record(start: result.gpuStartTime, end: result.gpuEndTime)
                }
                continuation.resume(returning: result.status == .completed ? nil : result.error?.localizedDescription ?? "Metal draw failed.")
            }
            command.commit()
        }
        if let error {
            throw NSError(domain: "SignalBench.WaveformMetal", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        try Task.checkCancellation()
        let row = width * 4
        var bytes = Data(count: row * height)
        bytes.withUnsafeMutableBytes {
            if let output = $0.baseAddress {
                texture.getBytes(output, bytesPerRow: row, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        let info = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }
}

struct MetalWaveformLayer: View {
    let renderer: WaveformMetal
    let dots: WaveformDots
    let range: ClosedRange<Double>
    let onPreparing: () -> Void
    let onPresented: (UUID, ClosedRange<Double>) -> Void
    let onFailure: () -> Void
    var customTint: SIMD4<Float>? = nil

    @Environment(\.displayScale) private var scale
    @State private var worker = WaveformRasterWorker()
    @State private var frame: Frame?
    @State private var pending: Input?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()

    private struct Input {
        let request: Request
        let dots: WaveformDots
    }

    private struct Request: Equatable {
        let data: UUID
        let range: ClosedRange<Double>
        let width: Int
        let height: Int
        let color: SIMD4<Float>
    }

    private struct Frame {
        let request: Request
        let image: CGImage
    }

    var body: some View {
        GeometryReader { geometry in
            let request = Request(data: dots.id, range: range,
                                  width: min(3_072, max(1, Int((geometry.size.width * scale).rounded()))),
                                  height: min(1_024, max(1, Int((geometry.size.height * scale).rounded()))),
                                  color: tint)
            Group {
                if let frame, frame.request == request {
                    Image(decorative: frame.image, scale: scale).resizable().interpolation(.none)
                } else { Color.clear }
            }
            .onChange(of: request, initial: true) { _, request in
                onPreparing()
                pending = Input(request: request, dots: dots)
                startDrawing()
            }
        }
        .onDisappear {
            generation = UUID()
            work?.cancel()
            work = nil
            pending = nil
        }
    }

    private var tint: SIMD4<Float> {
        if let customTint { return customTint }
        let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        return .init(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 0.72)
    }

    private func startDrawing() {
        guard work == nil else { return }
        let currentGeneration = generation
        work = Task {
            defer { if generation == currentGeneration { work = nil } }
            while let input = pending, !Task.isCancelled {
                pending = nil
                let request = input.request
                do {
                    let image = try await worker.image(renderer: renderer, dots: input.dots, range: request.range,
                                                       width: request.width, height: request.height, color: request.color)
                    guard !Task.isCancelled, generation == currentGeneration else { return }
                    if pending == nil {
                        frame = .init(request: request, image: image)
                        onPresented(request.data, request.range)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled && generation == currentGeneration { onFailure() }
                    return
                }
            }
        }
    }
}
