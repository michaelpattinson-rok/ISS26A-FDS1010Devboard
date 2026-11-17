import SwiftUI

struct LiveWaveformPane: View {
    private enum Window: String, CaseIterable, Identifiable {
        case latest = "Latest Samples", quarter = "Last 250 ms", one = "Last 1 second", five = "Last 5 seconds"
        case ten = "Last 10 seconds", thirty = "Last 30 seconds", all = "All", custom = "Custom"
        var id: Self { self }

        func span(rate: Double, end: Double, milliseconds: Int) -> Double {
            switch self {
            case .latest: 256 / rate
            case .quarter: 0.25
            case .one: 1
            case .five: 5
            case .ten: 10
            case .thirty: 30
            case .all: end
            case .custom: Double(milliseconds) / 1_000
            }
        }
    }

    @ObservedObject var bench: StreamingBench
    let addFlag: () -> Void
    let addNote: () -> Void
    @State private var window = Window.ten
    @State private var originalLiveDots = false
    @State private var customText = "250"
    @State private var customMilliseconds = 250
    @State private var zoomedSpan: Double?
    @State private var center: Double?
    @State private var height = WaveformHeight.standard
    @State private var paused: LiveWaveformCapture?
    @State private var pausing = false
    @State private var pauseTask: Task<Void, Never>?
    @State private var metalFailed = false
    @State private var metalPresented = false
    @State private var display: Display?
    @State private var previous: WaveformOverview?
    @State private var issue: String?
    @State private var flagTimes: [Double] = []
    @State private var pendingFlag: UInt64?
    @State private var markerTask: Task<Void, Never>?

    private struct Display {
        let range: StreamSelection
        let plot: StudioPlot
        let latestCode: UInt16?
    }

    private struct Request: Equatable {
        let run: UUID?
        let window: Window
        let custom: Int
        let zoom: Double?
        let center: Double?
        let pausedAt: Date?
        let pausing: Bool
        let density: Double?
        let originalLiveDots: Bool
        let dotLimit: Int
        let previousReady: Bool
        let fps: Int
    }

    private var configuredRate: Double { paused?.raw.rate ?? bench.preview.configuredRate ?? Double(bench.sampleRate) }
    private var canUseMetal: Bool { !metalFailed && WaveformMetal.shared != nil }
    private var currentEnd: Double { paused?.raw.bounds.upper ?? bench.preview.waveformBoundary ?? bench.preview.manualTimeUpper ?? 0 }
    private var bounds: StreamSelection { .init(lower: 0, upper: currentEnd) }
    private var validCustom: Bool { Int(customText).map { (1...7_200_000).contains($0) } == true }

    private func visibleRange(end: Double, rate: Double) -> StreamSelection {
        guard end > 0 else { return .init(lower: 0, upper: 0) }
        let wanted = zoomedSpan ?? window.span(rate: rate, end: end, milliseconds: customMilliseconds)
        let zoom = WaveformZoom(bounds: .init(lower: 0, upper: end), minimum: 2 / rate)
        return zoom.window(center: center ?? end, span: wanted)
    }

    private var request: Request {
        let density = bench.waveformStyle == .points ? bench.dotDensity : nil
        return .init(run: bench.current?.id, window: window, custom: customMilliseconds,
                     zoom: zoomedSpan, center: center, pausedAt: paused?.raw.click, pausing: pausing, density: density,
                     originalLiveDots: originalLiveDots,
                     dotLimit: density != nil && canUseMetal ? WaveformDots.liveLimit : WaveformDots.canvasLimit,
                     previousReady: previous != nil, fps: bench.liveFPS)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Live Waveform").font(.headline)
                if paused != nil { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }.fixedSize()
                    HStack(spacing: 8) { actions }.labelStyle(.iconOnly).fixedSize()
                }
            }
            HStack(spacing: 10) {
                windowPicker
                displayControls
            }
            if window == .custom { customField }
            WaveformZoomControl(bounds: bounds, selection: visibleRange(end: currentEnd, rate: configuredRate),
                                minimum: 2 / configuredRate, change: zoom,
                                home: { window = .all; zoomedSpan = nil; center = nil })
            if let display {
                readings(display)
                chart(display)
                WaveformPositionControl(bounds: bounds, selection: display.range) { target in
                    if paused == nil { pause(center: target) }
                    else { center = target }
                }
                if paused != nil {
                    let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))
                    Text("Visible range · \(display.range.lower.formatted(format)) to \(display.range.upper.formatted(format)) s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if bench.current?.settings.adcAveraging != nil {
                    Text("Waveform and rail counts use the original ADC samples.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                WaveformSignalQuality(stats: display.plot.stats, estimated: display.plot.indexed, board: bench.board)
            } else {
                Text("Waiting for waveform samples").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: height.points)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let paused {
                Text("View paused at \(WaveformTime.span(paused.raw.time(paused.raw.end - 1))). Recording continues.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: request) { await refresh(request) }
        .task(id: bench.current?.segments.last?.id) {
            previous = nil
            do {
                let saved = try await bench.previousWaveformOverview()
                if !Task.isCancelled { previous = saved }
            } catch {
                if !Task.isCancelled { issue = "The earlier saved waveform is unavailable. \(error.localizedDescription)" }
            }
        }
        .task(id: bench.timelineRevision) { await refreshFlags() }
        .onChange(of: bench.preview.committedBoundary) { _, boundary in
            guard let pendingFlag, pendingFlag < boundary else { return }
            self.pendingFlag = nil
            markerTask?.cancel()
            markerTask = Task { await refreshFlags() }
        }
        .onDisappear { pauseTask?.cancel(); markerTask?.cancel() }
    }

    @ViewBuilder private var actions: some View {
        Button("Add Flag…", systemImage: "flag", action: addFlag)
            .disabled(bench.preview.received == 0 || bench.timelineSaving).help("Add Flag")
        Button("Add Note…", systemImage: "note.text", action: addNote)
            .disabled(bench.timelineSaving).help("Add Note")
        Button(paused == nil ? "Pause View" : "Follow Live", systemImage: paused == nil ? "pause" : "play") {
            if paused != nil { paused = nil; center = nil }
            else { pause() }
        }
        .disabled(pausing || currentEnd <= 0)
        .help(paused == nil ? "Freeze the waveform while recording continues" : "Show the newest waveform")
    }

    private var windowPicker: some View {
        Picker("Live window", selection: $window) {
            ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
        .onChange(of: window) { _, _ in zoomedSpan = nil; center = nil }
    }

    @State private var showDisplay = false

    private var displayControls: some View {
        Button("Display", systemImage: "slider.horizontal.3") { showDisplay.toggle() }
            .popover(isPresented: $showDisplay, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
                    HStack {
                        Picker("Height", selection: $height) {
                            ForEach(WaveformHeight.allCases) { Text($0.rawValue).tag($0) }
                        }.fixedSize()
                        WaveformFPSControl(fps: $bench.liveFPS)
                    }
                    if bench.waveformStyle == .points {
                        Toggle("Original dots while following live", isOn: $originalLiveDots)
                            .help("Use original dots in wider live windows. Paused views can show original dots at close zoom.")
                        DotDensityControl(percent: $bench.dotDensity, plot: display?.plot,
                                          rendererLimited: !metalPresented || !canUseMetal)
                    }
                }.padding(14)
            }
    }

    private var customField: some View {
        HStack(spacing: 8) {
            TextField("Window in milliseconds", text: $customText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden().accessibilityLabel("Window in milliseconds").frame(width: 95)
                .onChange(of: customText) { _, value in
                    if let milliseconds = Int(value), (1...7_200_000).contains(milliseconds) {
                        customMilliseconds = milliseconds
                        zoomedSpan = nil
                        center = nil
                    }
                }
            Text("ms").font(.callout)
            Text(validCustom ? "= \((Double(customMilliseconds) / 1_000).formatted(.number.precision(.fractionLength(3)))) s" : "Enter 1 to 7,200,000 ms")
                .font(.caption.monospacedDigit()).foregroundStyle(validCustom ? Color.secondary : .orange)
        }
    }

    private func readings(_ display: Display) -> some View {
        let stats = display.plot.stats
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], alignment: .leading, spacing: 7) {
            metric(paused == nil ? "Latest raw code" : "Raw code at pause", display.latestCode?.formatted() ?? "Unavailable")
            if paused == nil, let preset = bench.current?.settings.adcAveraging {
                let group = bench.preview.latestAverage
                let status = group?.mean?.formatted(.number.precision(.fractionLength(0...6))) ??
                    (group == nil ? "Waiting for samples" : "Clipped or invalid")
                metric("Latest average (\(preset.count))", status)
            }
            metric("Visible min / max", stats.minimum.flatMap { low in stats.maximum.map { "\(low) / \($0)" } } ?? "Unavailable")
            metric("Visible peak to peak", stats.minimum.flatMap { low in stats.maximum.map { "\($0 - low) codes" } } ?? "Unavailable")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func chart(_ display: Display) -> StreamWaveform {
        let plot = display.plot
        var chart = StreamWaveform(columns: plot.columns, breaks: plot.breaks, selection: display.range,
                                   height: height.points, xAxis: true)
        chart.board = bench.board
        chart.baseline = plot.stats.baseline
        chart.baselineSpan = bench.waveformScale.baselineSpan ?? 0
        chart.fullScale = bench.waveformScale == .full
        chart.faults = plot.faults
        chart.rails = plot.rails
        chart.lowRails = plot.lowRails
        chart.highRails = plot.highRails
        chart.gaps = plot.gaps
        chart.samples = plot.samples
        chart.dots = plot.dots
        chart.means = plot.means
        chart.style = bench.waveformStyle
        chart.allowMetal = canUseMetal
        chart.metalFailed = $metalFailed
        chart.metalPresentation = $metalPresented
        chart.referenceTime = paused?.raw.bounds.upper
        chart.flagTimes = flagTimes
        chart.home = { window = .all; zoomedSpan = nil; center = nil }
        chart.navigate = navigate
        return chart
    }

    private func zoom(_ span: Double) {
        let range = visibleRange(end: currentEnd, rate: configuredRate)
        if paused != nil { center = (range.lower + range.upper) / 2 }
        zoomedSpan = span
    }

    private func navigate(_ anchor: Double?, _ amount: Double) {
        let range = display?.range ?? visibleRange(end: currentEnd, rate: configuredRate)
        guard range.valid else { return }
        let span = range.upper - range.lower
        if let anchor {
            let proposed = span * exp2(amount)
            let width = min(currentEnd, max(2 / configuredRate, proposed))
            if paused != nil { center = range.lower + anchor * span + (0.5 - anchor) * width }
            zoomedSpan = width
        } else {
            let target = (range.lower + range.upper) / 2 + amount * span
            if paused == nil { pause(center: target) }
            else { center = target }
        }
    }

    private func pause(center desiredCenter: Double? = nil) {
        guard !pausing, paused == nil else { return }
        let instant = DispatchTime.now().uptimeNanoseconds
        let date = Date()
        pausing = true
        pauseTask = Task {
            let capture = await bench.captureWaveform(at: instant, date: date, seconds: 30)
            guard !Task.isCancelled else { return }
            if let capture {
                paused = capture
                center = desiredCenter
                issue = nil
            } else {
                issue = "No samples were available to pause."
            }
            pausing = false
        }
    }

    private func refresh(_ request: Request) async {
        guard !request.pausing else { return }
        let frozen = paused
        var renderedRange: StreamSelection?
        var renderedSample: UInt64?
        repeat {
            guard !Task.isCancelled else { return }
            let live = bench.preview
            let rate = configuredRate
            var range = visibleRange(end: currentEnd, rate: rate)
            let requestedRange = range
            if range.valid, requestedRange != renderedRange || renderedSample != live.received {
                renderedRange = requestedRange
                renderedSample = live.received
                let width = range.upper - range.lower
                let possible = width * rate
                let wantsRaw = width <= 0.25 || (request.density != nil && (frozen != nil || request.originalLiveDots)
                                                && possible <= Double(WaveformDots.rawReadLimit))
                var capture = frozen
                if capture == nil, wantsRaw, width <= 30 {
                    let instant = DispatchTime.now().uptimeNanoseconds
                    capture = await bench.captureWaveform(at: instant, date: .now, seconds: min(30, width + 0.02))
                    if let capture { range = visibleRange(end: capture.raw.bounds.upper, rate: rate) }
                }
                guard !Task.isCancelled else { return }
                do {
                    if let frozen, range.lower < frozen.raw.bounds.lower - 1e-9,
                       wantsRaw, range.upper <= frozen.raw.bounds.lower + 1e-9,
                       let result = try await bench.readRecordingWaveform(range, density: request.density, limit: request.dotLimit) {
                        guard !Task.isCancelled else { return }
                        display = .init(range: range, plot: result, latestCode: lastCode(frozen))
                    } else {
                        let result = try await render(range: range, rate: rate, live: live, capture: capture,
                                                      prior: previous, request: request)
                        guard !Task.isCancelled else { return }
                        display = .init(range: range, plot: result, latestCode: frozen.map(lastCode) ?? live.latestCode)
                    }
                } catch {
                    if !Task.isCancelled { issue = error.localizedDescription }
                }
            }
            if frozen != nil { return }
            try? await Task.sleep(for: .nanoseconds(1_000_000_000 / max(1, request.fps)))
        } while !Task.isCancelled
    }

    private func refreshFlags() async {
        guard let run = bench.current else { return }
        guard let content = try? await bench.timelineLoad(for: .init(runID: run.id, tool: .review, frozen: nil)),
              !Task.isCancelled, bench.current?.id == run.id else { return }
        flagTimes = content.entries.compactMap { item in
            guard item.state == .placed, let position = item.position else { return nil }
            return RunTimeline.time(of: position, in: content.reader.run)
        }
        let segment = content.reader.run.segments.last?.id
        pendingFlag = content.entries.compactMap { item in
            item.state == .pending && item.position?.segment == segment ? item.position?.index : nil
        }.min()
    }

    private func lastCode(_ capture: LiveWaveformCapture) -> UInt16? {
        guard let sample = capture.raw.sample(at: capture.raw.time(capture.raw.end - 1)), !sample.invalid else { return nil }
        return sample.code
    }

    private func render(range: StreamSelection, rate: Double, live: LiveStreamPreview, capture: LiveWaveformCapture?,
                        prior: WaveformOverview?, request: Request) async throws -> StudioPlot {
        let worker = Task.detached(priority: .utility) {
            let start = capture?.raw.timelineStart ?? live.waveformSegmentStart
            if let prior, range.upper <= start {
                var plot = prior.plot(range)
                if let density = request.density { plot.dots = .averages(plot.means, percent: density) }
                return plot
            }
            let limit = request.dotLimit
            let density = request.density
            var current: StudioPlot
            if let capture {
                let dotPercent = (range.upper - range.lower) * rate <= Double(WaveformDots.rawReadLimit) ? density : nil
                current = try capture.plot(range, dotPercent: dotPercent, limit: limit)
            } else if let end = live.waveformBoundary ?? live.manualTimeUpper,
                      range.lower >= end - Double(live.waveformBins.count) * live.waveformBinSeconds {
                var accumulator = LivePlotBins(range: range, columns: 960)
                let binEnd = live.manualTimeUpper ?? end
                let origin = binEnd - Double(live.waveformBins.count) * live.waveformBinSeconds
                var gaps: [StreamSelection] = []
                for (index, bin) in live.waveformBins.enumerated() {
                    let lower = origin + Double(index) * live.waveformBinSeconds
                    let upper = min(end, lower + live.waveformBinSeconds)
                    accumulator.add(bin, lower: lower, upper: upper)
                    if bin.gap, upper > lower {
                        if let last = gaps.last, abs(last.upper - lower) < 1e-8 { gaps[gaps.count - 1].upper = upper }
                        else { gaps.append(.init(lower: lower, upper: upper)) }
                    }
                }
                current = accumulator.plot(gaps: gaps, rate: rate)
                current.stats.baseline = live.baseline
            } else {
                var empty = LivePlotBins(range: range, columns: 960)
                let gap = StreamSelection(lower: range.lower, upper: range.upper)
                if live.waveformOverview == nil, !live.waveformSamples.isEmpty {
                    for sample in live.waveformSamples {
                        var bin = LiveWaveformBin()
                        if let group = sample.group { bin.append([group][...]) }
                        else { bin.append([sample.word]) }
                        empty.add(bin, lower: sample.time, upper: sample.time + 1 / rate)
                    }
                }
                current = live.waveformOverview?.plot(range, start: start, rate: rate) ?? empty.plot(gaps: [gap], rate: rate)
                current.stats.baseline = live.baseline
            }
            if range.lower < start {
                current = Self.withPrevious(current, prior: prior, range: range, nextStart: start)
            }
            if let density, current.indexed || current.dots == nil {
                current.dots = .averages(current.means, percent: density)
            }
            return current
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    nonisolated private static func withPrevious(_ current: StudioPlot, prior: WaveformOverview?, range: StreamSelection,
                                                nextStart: Double) -> StudioPlot {
        var plot = current
        if let prior {
            let earlier = prior.plot(range, columns: current.columns.count)
            for index in plot.columns.indices {
                if let bin = earlier.columns[index] {
                    let other = plot.columns[index] ?? bin
                    plot.columns[index] = min(bin.lowerBound, other.lowerBound)...max(bin.upperBound, other.upperBound)
                }
                if plot.means[index] == nil { plot.means[index] = earlier.means[index] }
                plot.faults[index] = plot.faults[index] || earlier.faults[index]
                plot.lowRails[index] = plot.lowRails[index] || earlier.lowRails[index]
                plot.highRails[index] = plot.highRails[index] || earlier.highRails[index]
            }
            plot.breaks += earlier.breaks
            plot.gaps += earlier.gaps
            plot.stats.samples += earlier.stats.samples
            plot.stats.adcErrors += earlier.stats.adcErrors
            plot.stats.clipped += earlier.stats.clipped
            plot.stats.lowRail = plot.stats.lowRail.flatMap { count in earlier.stats.lowRail.map { $0 + count } }
            plot.stats.highRail = plot.stats.highRail.flatMap { count in earlier.stats.highRail.map { $0 + count } }
            plot.stats.minimum = [plot.stats.minimum, earlier.stats.minimum].compactMap { $0 }.min()
            plot.stats.maximum = [plot.stats.maximum, earlier.stats.maximum].compactMap { $0 }.max()
            plot.stats.nominalSampledSeconds += max(0, earlier.stats.nominalSampledSeconds - max(0, range.upper - prior.duration))
        }
        let earlierEnd = prior?.duration ?? range.lower
        if earlierEnd < nextStart { plot.gaps.append(.init(lower: earlierEnd, upper: nextStart)) }
        plot.breaks.append(nextStart)
        plot.indexed = true
        return plot
    }
}

#if STREAM_TESTING
extension LiveWaveformPane {
    static func pausedForLayout(bench: StreamingBench, capture: LiveWaveformCapture) -> Self {
        var pane = Self(bench: bench, addFlag: {}, addNote: {})
        pane._paused = State(initialValue: capture)
        pane._window = State(initialValue: .custom)
        return pane
    }
}
#endif
