import MetalKit
import SwiftUI

struct LiveMetalWaveform: NSViewRepresentable {
    let renderer: WaveformMetal
    let dots: WaveformDots
    let range: ClosedRange<Double>
    let onPresented: (UUID, ClosedRange<Double>, Double) -> Void
    let onFailure: () -> Void

    func makeNSView(context: Context) -> DrawableView {
        let view = DrawableView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        return view
    }

    func updateNSView(_ view: DrawableView, context: Context) {
        view.renderer = renderer
        view.onPresented = onPresented
        view.onFailure = onFailure
        let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        view.submit(dots, range: range, tint: .init(Float(color.redComponent), Float(color.greenComponent),
                                                   Float(color.blueComponent), 0.75))
    }

    static func dismantleNSView(_ view: DrawableView, coordinator: ()) { view.detach() }

    final class DrawableView: MTKView {
        private struct Frame {
            let dots: WaveformDots
            let range: ClosedRange<Double>
            let tint: SIMD4<Float>
        }

        var renderer: WaveformMetal?
        var onPresented: ((UUID, ClosedRange<Double>, Double) -> Void)?
        var onFailure: (() -> Void)?
        private var latest: Frame?
        private var drawnID: UUID?
        private var drawnRange: ClosedRange<Double>?
        private var drawnTint: SIMD4<Float>?
        private var buffer: MTLBuffer?
        private var inFlight = false
        private var active = true

        func submit(_ dots: WaveformDots, range: ClosedRange<Double>, tint: SIMD4<Float>) {
            guard drawnID != dots.id || drawnRange != range || drawnTint != tint else { return }
            latest = .init(dots: dots, range: range, tint: tint)
            if !inFlight { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard active, !inFlight, let frame = latest, let renderer,
                  let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
            let length = frame.dots.values.count * MemoryLayout<SIMD2<Float>>.stride
            if buffer?.length ?? 0 < length {
                buffer = renderer.device.makeBuffer(length: length, options: .storageModeShared)
            }
            guard let buffer, let command = renderer.queue.makeCommandBuffer() else { fail(); return }
            frame.dots.values.withUnsafeBytes {
                if let base = $0.baseAddress { buffer.contents().copyMemory(from: base, byteCount: length) }
            }
            guard renderer.encode(command, pass: pass, buffer: buffer, count: frame.dots.values.count,
                                  range: frame.range, size: frame.dots.values.count < 4_000 ? 4 : 2,
                                  color: frame.tint) else { fail(); return }
            latest = nil
            drawnID = frame.dots.id
            drawnRange = frame.range
            drawnTint = frame.tint
            inFlight = true
            let id = frame.dots.id, range = frame.range
            drawable.addPresentedHandler { [weak self] result in
                let timestamp = result.presentedTime
                Task { @MainActor [weak self] in
                    guard let self, active, timestamp > 0 else { return }
                    onPresented?(id, range, timestamp)
                }
            }
            command.addCompletedHandler { [weak self] result in
                let success = result.status == .completed
                if success { WaveformGPUTiming.shared.record(start: result.gpuStartTime, end: result.gpuEndTime) }
                Task { @MainActor [weak self] in
                    guard let self, active else { return }
                    inFlight = false
                    if !success { fail() }
                    else if latest != nil { needsDisplay = true }
                }
            }
            command.present(drawable)
            command.commit()
        }

        private func fail() {
            let report = onFailure
            detach()
            Task { @MainActor in report?() }
        }

        func detach() {
            active = false
            latest = nil
            buffer = nil
            renderer = nil
            onPresented = nil
            onFailure = nil
        }
    }
}
