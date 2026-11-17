import AppKit
import SwiftUI

enum WaveformStyle: String, CaseIterable, Identifiable {
    case envelope = "Envelope", trace = "Trace", points = "Dots"
    var id: Self { self }
}

enum WaveformScale: String, CaseIterable, Identifiable {
    case fit = "Fit", full = "Full ADC", narrow = "Baseline ±16", medium = "Baseline ±64", wide = "Baseline ±256"
    var id: Self { self }
    var baselineSpan: Double? {
        switch self {
        case .fit, .full: nil
        case .narrow: 16
        case .medium: 64
        case .wide: 256
        }
    }
}

enum WaveformHeight: String, CaseIterable, Identifiable {
    case compact = "Compact", standard = "Standard", expanded = "Expanded"
    var id: Self { self }
    var points: CGFloat {
        switch self {
        case .compact: 135
        case .standard: 205
        case .expanded: 370
        }
    }
}

struct WaveformDisplayControls: View {
    @Binding var style: WaveformStyle
    @Binding var scale: WaveformScale

    var body: some View {
        HStack(spacing: 10) {
            Picker("Display", selection: $style) {
                ForEach(WaveformStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Vertical Scale", selection: $scale) {
                ForEach(WaveformScale.allCases) { Text($0.rawValue).tag($0) }
            }
        }.fixedSize()
    }
}

struct StreamWaveform: View {
    static let left = 52.0
    static let right = 14.0

    let columns: [ClosedRange<UInt16>?]
    let breaks: [Double]
    let selection: StreamSelection
    let height: CGFloat
    let xAxis: Bool
    var flagTimes: [Double] = []
    var maskedTimes: [StreamSelection] = []
    var baseline: Double? = nil
    var baselineSpan: Double = 0
    var faults: [Bool] = []
    var rails: [Bool] = []
    var referenceTime: Double? = nil
    var home: (() -> Void)? = nil
    var gaps: [StreamSelection] = []
    var samples: [WaveformSample] = []
    var style: WaveformStyle = .envelope
    var board: AcquisitionBoard = .picoW
    var fullScale = false
    var cursorTimes: [Double] = []
    var picked: ((Double, Double) -> Void)? = nil
    var navigate: ((Double?, Double) -> Void)? = nil
    var cursor: ((Double) -> Void)? = nil
    var viewport: StreamSelection? = nil
    var pendingViewport: StreamSelection? = nil
    var moveViewport: ((Double) -> Void)? = nil
    var lowRails: [Bool] = []
    var highRails: [Bool] = []
    var dots: WaveformDots? = nil
    var means: [Double?] = []
    var allowMetal = true
    var metalFailed: Binding<Bool>? = nil
    var metalPresentation: Binding<Bool>? = nil
    var analogTrace: [(time: Double, value: Double?)]? = nil
    var comparisonTrace: [(time: Double, value: Double?)]? = nil
    var analogRange: ClosedRange<Double>? = nil
    var waveformLabel = "Raw ADC waveform"
    @State private var localMetalPresented = false
    @State private var localMetalFailed = false
    @FocusState private var focused: Bool
    @GestureState private var drag: (Double, Double)? = nil

    private var yRange: ClosedRange<Double> {
        if let analogRange { return analogRange }
        if fullScale { return 0...Double(board.maxCode) }
        if let baseline, baselineSpan > 0 { return (baseline - baselineSpan)...(baseline + baselineSpan) }
        var low = UInt16.max, high: UInt16 = 0
        for bin in columns.compactMap({ $0 }) { low = min(low, bin.lowerBound); high = max(high, bin.upperBound) }
        for sample in samples where !sample.invalid { low = min(low, sample.code); high = max(high, sample.code) }
        guard low <= high else { return 0...Double(board.maxCode) }
        let pad = max(3, Double(high - low) * 0.08)
        return max(0, Double(low) - pad)...min(Double(board.maxCode), Double(high) + pad)
    }

    private func fraction(_ x: Double, width: Double) -> Double {
        max(0, min(1, (x - Self.left) / max(1, width - Self.left - Self.right)))
    }

    private func time(_ part: Double) -> Double { selection.lower + part * (selection.upper - selection.lower) }

    private var metal: WaveformMetal? {
        guard style == .points, let dots, !dots.values.isEmpty,
              allowMetal, !localMetalFailed, metalFailed?.wrappedValue != true else { return nil }
        return WaveformMetal.shared
    }

    private var metalPresented: Bool { metalPresentation?.wrappedValue ?? localMetalPresented }

    private func setMetalPresented(_ value: Bool) {
        guard metalPresented != value else { return }
        if let metalPresentation { metalPresentation.wrappedValue = value }
        else { localMetalPresented = value }
    }

    private var plotTop: Double { height < 80 ? 4 : 12 }

    var body: some View {
        ZStack {
            if let metal, let dots {
                GeometryReader { geometry in
                    MetalWaveformLayer(renderer: metal, dots: dots, range: yRange,
                                       onPreparing: { setMetalPresented(false) },
                                       onPresented: { setMetalPresented(true) },
                                       onFailure: {
                                           setMetalPresented(false)
                                           localMetalFailed = true
                                           metalFailed?.wrappedValue = true
                                       })
                    .frame(width: max(1, geometry.size.width - Self.left - Self.right),
                           height: max(1, geometry.size.height - (xAxis ? 26 : 10) - plotTop))
                    .offset(x: Self.left, y: plotTop)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            Canvas { context, size in draw(context, size: size) }
            if moveViewport == nil && analogTrace?.contains(where: { $0.value != nil }) != true
                && columns.allSatisfy({ $0 == nil }) && samples.allSatisfy(\.invalid) {
                Text(columns.isEmpty && samples.isEmpty ? "Waiting for samples" : "No valid ADC samples")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .onChange(of: metal != nil) { _, enabled in if !enabled { setMetalPresented(false) } }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if navigate != nil || picked != nil || moveViewport != nil {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($drag) { value, state, _ in
                                state = (fraction(value.startLocation.x, width: geometry.size.width),
                                         fraction(value.location.x, width: geometry.size.width))
                            }
                            .onEnded { value in
                                focused = true
                                let start = fraction(value.startLocation.x, width: geometry.size.width)
                                let end = fraction(value.location.x, width: geometry.size.width)
                                if let moveViewport { moveViewport(time(end)) }
                                else if abs(value.translation.width) < 4 && abs(value.translation.height) < 4 {
                                    cursor?(time(end))
                                } else if let picked { picked(time(min(start, end)), time(max(start, end))) }
                                else { navigate?(nil, start - end) }
                            })
                        .simultaneousGesture(MagnifyGesture().onEnded { value in
                            navigate?(fraction(value.startAnchor.x * geometry.size.width, width: geometry.size.width),
                                      -log2(Double(value.magnification)))
                        })
                }.accessibilityHidden(true)
            }
        }
        .background {
            if let navigate {
                WaveformScrollInput { x, width, zoom, pan in
                    if let zoom { navigate(fraction(x, width: width), zoom) }
                    if let pan { navigate(nil, pan / max(1, width - Self.left - Self.right)) }
                }.accessibilityHidden(true)
            }
        }
        .focusable(navigate != nil || moveViewport != nil)
        .focused($focused)
        .onKeyPress(.return) {
            guard let cursor else { return .ignored }
            cursor(time(0.5))
            return .handled
        }
        .onKeyPress(.home) {
            guard let home else { return .ignored }
            home()
            return .handled
        }
        .onKeyPress(.leftArrow) { keyboardPan(-0.25) }
        .onKeyPress(.rightArrow) { keyboardPan(0.25) }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { press in
            guard let navigate else { return .ignored }
            navigate(0.5, press.characters == "-" ? 1 : -1)
            return .handled
        }
        .accessibilityLabel(moveViewport == nil ? waveformLabel : "Waveform overview")
        .accessibilityValue(viewport.map {
            "Displayed from \($0.lower.formatted(.number.precision(.fractionLength(0...6)))) to \($0.upper.formatted(.number.precision(.fractionLength(0...6)))) seconds"
        } ?? "")
        .accessibilityHint(navigate == nil ? "" : "Use arrow keys to pan, plus or minus to zoom. Option scroll or pinch zooms around the pointer.")
    }

    private func keyboardPan(_ amount: Double) -> KeyPress.Result {
        if let navigate { navigate(nil, amount); return .handled }
        if let moveViewport, let viewport {
            moveViewport((viewport.lower + viewport.upper) / 2 + (viewport.upper - viewport.lower) * amount)
            return .handled
        }
        return .ignored
    }

    private func draw(_ context: GraphicsContext, size: CGSize) {
        let codes = yRange
        let left = Self.left
        let width = max(1, size.width - left - Self.right)
        let bottom = max(15, size.height - (xAxis ? 26 : 10))
        let top = plotTop
        let span = bottom - top
        let seconds = max(Double.leastNonzeroMagnitude, selection.upper - selection.lower)
        func x(_ time: Double) -> Double { left + (time - selection.lower) / seconds * width }
        func y(_ value: Double) -> Double { top + (codes.upperBound - value) / (codes.upperBound - codes.lowerBound) * span }
        func box(_ a: Double, _ b: Double, color: Color, in drawing: GraphicsContext, minimumWidth: Double = 0) {
            let a = max(left, x(a)), b = min(left + width, x(b))
            guard b > a else { return }
            drawing.fill(Path(CGRect(x: a, y: top, width: max(minimumWidth, b - a), height: span)), with: .color(color))
        }
        var drawing = context
        drawing.clip(to: Path(CGRect(x: left - 1, y: top - 2, width: width + 2, height: span + 4)))
        for item in maskedTimes { box(item.lower, item.upper, color: .orange.opacity(0.18), in: drawing) }
        for item in gaps { box(item.lower, item.upper, color: .secondary.opacity(0.24), in: drawing, minimumWidth: 1) }
        if height >= 80 {
            for i in 0...4 {
                let lineY = top + Double(i) * span / 4
                let value = codes.upperBound - Double(i) * (codes.upperBound - codes.lowerBound) / 4
                context.stroke(line(left, lineY, left + width, lineY), with: .color(.secondary.opacity(0.24)), lineWidth: 1)
                let origin = baselineSpan > 0 ? baseline ?? 0 : 0
                let label = analogRange == nil ? Int((value - origin).rounded()).formatted() :
                    (value - origin).formatted(.number.precision(.fractionLength(0...2)))
                context.draw(Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                             at: .init(x: left - 6, y: lineY), anchor: .trailing)
            }
        }

        var signal = drawing
        if !gaps.isEmpty {
            var coverage = Path(CGRect(x: left - 1, y: top - 2, width: width + 2, height: span + 4))
            for gap in gaps {
                let a = max(left, x(gap.lower)), b = min(left + width, x(gap.upper))
                if b > a { coverage.addRect(CGRect(x: a, y: top - 2, width: b - a, height: span + 4)) }
            }
            signal.clip(to: coverage, style: FillStyle(eoFill: true))
        }

        var paths = Path(), envelope = Path(), points = Path()
        var faultMarks = Path(), railMarks = Path()
        func mark(_ x: Double, error: Bool, low: Bool = false) {
            if error { faultMarks.addPath(line(x, top + 6, x, top + 12)) }
            else if low { railMarks.addPath(line(x, bottom - 5, x, bottom)) }
            else { railMarks.addPath(line(x, top, x, top + 5)) }
        }
        func markColumn(_ index: Int, at x: Double) {
            if lowRails.indices.contains(index), lowRails[index] { mark(x, error: false, low: true) }
            if highRails.indices.contains(index), highRails[index] { mark(x, error: false) }
            else if highRails.isEmpty, rails.indices.contains(index), rails[index] { mark(x, error: false) }
            if faults.indices.contains(index), faults[index] { mark(x, error: true) }
        }
        func markSample(_ sample: WaveformSample) {
            let px = x(sample.time)
            if sample.low { mark(px, error: false, low: true) }
            if sample.high { mark(px, error: false, low: false) }
            if sample.error { mark(px, error: true) }
        }
        if style == .points, let dots {
            let shown = min(dots.values.count, WaveformDots.canvasLimit)
            if !metalPresented, shown > 0 {
                let radius = shown > 4_000 ? 0.65 : 1.35
                for offset in 0..<shown {
                    let point = dots.values[offset * dots.values.count / shown]
                    let px = left + Double(point.x) * width, py = y(Double(point.y))
                    points.addEllipse(in: CGRect(x: px - radius, y: py - radius, width: 2 * radius, height: 2 * radius))
                }
            }
            if samples.isEmpty {
                let n = Double(max(1, columns.count))
                for i in columns.indices { markColumn(i, at: left + (Double(i) + 0.5) / n * width) }
            } else {
                for sample in samples where sample.invalid || sample.clipped { markSample(sample) }
            }
        } else if !samples.isEmpty && (style != .envelope || columns.isEmpty) {
            var previous: WaveformSample?
            for sample in samples {
                let px = x(sample.time), py = y(sample.value)
                if sample.invalid || sample.clipped { markSample(sample) }
                guard !sample.invalid else { previous = nil; continue }
                let connected = previous.map { $0.segment == sample.segment && $0.index + 1 == sample.index } ?? false
                if style != .trace || !connected {
                    points.addEllipse(in: CGRect(x: px - 1.5, y: py - 1.5, width: 3, height: 3))
                }
                if style == .trace, connected, let previous {
                    paths.addPath(line(x(previous.time), y(previous.value), px, py))
                }
                previous = sample
            }
        } else {
            let n = Double(max(1, columns.count))
            let boundaries = Set(breaks.filter { $0 >= selection.lower && $0 < selection.upper }.map {
                Int((($0 - selection.lower) / seconds * n).rounded(.down))
            })
            var previous: CGPoint?
            for (i, bin) in columns.enumerated() {
                let px = left + (Double(i) + 0.5) / n * width
                markColumn(i, at: px)
                if boundaries.contains(i) { previous = nil }
                guard let bin else { previous = nil; continue }
                let high = y(Double(bin.upperBound)), low = y(Double(bin.lowerBound))
                let middle = CGPoint(x: px, y: means.indices.contains(i) ? means[i].map(y) ?? (high + low) / 2 : (high + low) / 2)
                switch style {
                case .points:
                    continue
                case .envelope, .trace:
                    envelope.addRect(CGRect(x: px - width / n / 2, y: high - 0.4,
                                            width: width / n + 0.25, height: max(0.8, low - high + 0.8)))
                    if style == .trace, let previous { paths.addPath(line(previous.x, previous.y, middle.x, middle.y)) }
                }
                previous = middle
            }
        }
        if let analogTrace {
            func drawTrace(_ values: [(time: Double, value: Double?)], color: Color, lineWidth: Double) {
                var path = Path(), dots = Path()
                var previous: Double?
                for item in values {
                    guard let value = item.value else { previous = nil; continue }
                    let point = CGPoint(x: x(item.time), y: y(value))
                    if let previous, !breaks.contains(where: { previous < $0 && $0 <= item.time }) {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        dots.addEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
                    }
                    previous = item.time
                }
                signal.stroke(path, with: .color(color), lineWidth: lineWidth)
                signal.fill(dots, with: .color(color))
            }
            paths = Path()
            if let comparisonTrace { drawTrace(comparisonTrace, color: .secondary, lineWidth: 1.7) }
            drawTrace(analogTrace, color: .accentColor, lineWidth: 1.25)
        }
        signal.fill(envelope, with: .color(.accentColor.opacity(analogTrace == nil ? (style == .trace ? 0.21 : 0.72) : 0.12)))
        signal.stroke(paths, with: .color(.accentColor), lineWidth: 1.25)
        signal.fill(points, with: .color(.accentColor))
        drawing.stroke(railMarks, with: .color(.orange), lineWidth: 1.5)
        drawing.stroke(faultMarks, with: .color(.red), lineWidth: 1.5)
        if let referenceTime, referenceTime >= selection.lower && referenceTime <= selection.upper {
            let position = x(referenceTime)
            drawing.stroke(line(position, top, position, bottom), with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for value in breaks where value >= selection.lower && value <= selection.upper {
            drawing.stroke(line(x(value), top, x(value), bottom), with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for value in flagTimes where value >= selection.lower && value <= selection.upper {
            var flag = Path()
            flag.move(to: .init(x: x(value), y: top + 6))
            flag.addLine(to: .init(x: x(value) + 8, y: top + 10))
            flag.addLine(to: .init(x: x(value), y: top + 14))
            flag.closeSubpath()
            drawing.fill(flag, with: .color(.accentColor))
        }
        for value in cursorTimes where value >= selection.lower && value <= selection.upper {
            drawing.stroke(line(x(value), top, x(value), bottom), with: .color(.primary.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        if let viewport, let band = bandFrame(viewport, left: left, width: width, top: top, height: span) {
            // De-emphasize the recording outside the displayed range.
            let dim = Path { path in
                path.addRect(CGRect(x: left, y: top, width: band.minX - left, height: span))
                path.addRect(CGRect(x: band.maxX, y: top, width: max(0, left + width - band.maxX), height: span))
            }
            drawing.fill(dim, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.66)))
            drawing.fill(Path(band), with: .color(.accentColor.opacity(0.16)))
            drawing.stroke(Path(band), with: .color(.accentColor), lineWidth: 1.5)
        }
        if let pendingViewport, let band = bandFrame(pendingViewport, left: left, width: width, top: top, height: span) {
            drawing.stroke(Path(band), with: .color(.primary.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        if let drag, picked != nil { box(time(min(drag.0, drag.1)), time(max(drag.0, drag.1)), color: .accentColor.opacity(0.2), in: drawing) }
        if xAxis {
            let ticks = size.width < 430 ? 2 : 4
            for i in 0...ticks {
                let tick = Double(i) / Double(ticks)
                let label = time(tick).formatted(.number.precision(.fractionLength(0...6)))
                context.draw(Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                             at: .init(x: left + tick * width, y: bottom + 8),
                             anchor: i == ticks ? .topTrailing : i == 0 ? .topLeading : .top)
            }
        }
    }

    private func bandFrame(_ range: StreamSelection, left: Double, width: Double, top: Double, height: Double) -> CGRect? {
        guard selection.valid, range.valid else { return nil }
        let start = max(range.lower, selection.lower), end = min(range.upper, selection.upper)
        guard end > start else { return nil }
        let span = selection.upper - selection.lower
        let exactWidth = (end - start) / span * width
        let visibleWidth = min(width, max(3, exactWidth))
        let center = left + ((start - selection.lower) + (end - start) / 2) / span * width
        let x = min(left + width - visibleWidth, max(left, center - visibleWidth / 2))
        return CGRect(x: x, y: top, width: visibleWidth, height: height)
    }

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
        var line = Path()
        line.move(to: .init(x: x1, y: y1))
        line.addLine(to: .init(x: x2, y: y2))
        return line
    }
}

private struct WaveformScrollInput: NSViewRepresentable {
    let onScroll: (Double, Double, Double?, Double?) -> Void

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ nsView: Surface, context: Context) { nsView.onScroll = onScroll }

    final class Surface: NSView {
        private var monitor: Any?
        var onScroll: ((Double, Double, Double?, Double?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
                let pointer = convert(event.locationInWindow, from: nil)
                guard visibleRect.contains(pointer) else { return event }
                let y = event.scrollingDeltaY, x = event.scrollingDeltaX
                if event.modifierFlags.contains(.option), y != 0 {
                    onScroll?(pointer.x, bounds.width, min(0.6, max(-0.6, -y * (event.hasPreciseScrollingDeltas ? 0.012 : 0.1))), nil)
                    return nil
                }
                if abs(x) > abs(y), x != 0 {
                    onScroll?(pointer.x, bounds.width, nil, -x)
                    return nil
                }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
