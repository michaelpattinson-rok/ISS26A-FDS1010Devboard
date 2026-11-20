import SwiftUI

nonisolated struct LiveWaveformPosition {
    // A live position is a delay from the advancing edge. A frozen position is absolute.
    var delay: Double = 0

    func range(end: Double, span: Double, minimum: Double, frozenCenter: Double?) -> StreamSelection {
        guard end > 0 else { return .init(lower: 0, upper: 0) }
        let zoom = WaveformZoom(bounds: .init(lower: 0, upper: end), minimum: minimum)
        let width = min(end, max(zoom.smallest, span))
        return zoom.window(center: frozenCenter ?? end - delay - width / 2, span: width)
    }

    mutating func move(to center: Double, end: Double, span: Double, minimum: Double) {
        let selected = range(end: end, span: span, minimum: minimum, frozenCenter: center)
        delay = max(0, end - selected.upper)
    }
}

nonisolated struct LivePresentationMeter {
    private var first: Double?
    private var last: Double?
    private var frames = 0

    mutating func record(_ timestamp: Double) -> Double? {
        guard timestamp.isFinite, timestamp > (last ?? 0) else { return nil }
        last = timestamp
        guard let first else { self.first = timestamp; return nil }
        frames += 1
        let span = timestamp - first
        guard span >= 1 else { return nil }
        let value = Double(frames) / span
        self.first = timestamp
        frames = 0
        return value
    }
}

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
    let addNote: () -> Void
    @State private var window = Window.ten
    @State private var originalLiveDots = false
    @State private var customText = "250"
    @State private var customMilliseconds = 250
    @State private var zoomedSpan: Double?
    @State private var center: Double?
    @State private var position = LiveWaveformPosition()
    @State private var height = WaveformHeight.standard
    @State private var paused: LiveWaveformCapture?
    @State private var pausing = false
    @State private var pauseTask: Task<Void, Never>?
    @State private var metalFailed = false
    @State private var metalPresented = false
    @State private var presentedDotFrame: UUID?
    @State private var fps = LivePresentationMeter()
    @State private var actualFPS: Double?
    @State private var displayBehind = false
    @State private var skippedPreviewUpdates: UInt64 = 0
    @State private var display: Display?
    @State private var previous: WaveformOverview?
    @State private var issue: String?
    @State private var flagTimes: [Double] = []
    @State private var pendingFlagTimes: [Double] = []
    @State private var pendingFlag: UInt64?
    @State private var markerTask: Task<Void, Never>?

    private struct Display {
        var id = UUID()
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
        let delay: Double
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

    private func visibleRange(end: Double, rate: Double, request: Request? = nil) -> StreamSelection {
        let request = request ?? self.request
        let wanted = request.zoom ?? request.window.span(rate: rate, end: end, milliseconds: request.custom)
        return LiveWaveformPosition(delay: request.delay).range(end: end, span: wanted, minimum: 2 / rate,
                                                               frozenCenter: request.pausedAt != nil ? request.center ?? end : nil)
    }

    private var request: Request {
        let density = bench.waveformStyle == .points ? bench.dotDensity : nil
        return .init(run: bench.current?.id, window: window, custom: customMilliseconds,
                     zoom: zoomedSpan, center: center, pausedAt: paused?.raw.click, delay: position.delay, density: density,
                     originalLiveDots: originalLiveDots,
                     dotLimit: density != nil && canUseMetal ? WaveformDots.liveLimit : WaveformDots.canvasLimit,
                     previousReady: previous != nil, fps: bench.liveFPS)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Live Waveform").font(.headline)
                if displayBehind && paused == nil {
                    Text("Preview behind").font(.caption).foregroundStyle(.orange).lineLimit(1)
                        .help("The viewer is taking longer than the FPS goal. Saved samples are tracked separately.")
                }
                if paused != nil { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                else if position.delay > 0 {
                    Text("\(WaveformTime.span(position.delay)) behind live").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { flagActions; viewingActions }.fixedSize()
                    HStack(spacing: 8) {
                        HStack(spacing: 8) { flagActions }.labelStyle(.iconOnly)
                        viewingActions
                    }.fixedSize()
                    HStack(spacing: 8) { flagActions; viewingActions }.labelStyle(.iconOnly).fixedSize()
                }
            }
            HStack(spacing: 10) {
                windowPicker
                displayControls
            }
            if window == .custom { customField }
            WaveformZoomControl(bounds: bounds, selection: visibleRange(end: currentEnd, rate: configuredRate),
                                minimum: 2 / configuredRate, change: zoom,
                                home: showAll)
            if let display {
                readings(display)
                chart(display)
                    .onChange(of: display.id, initial: true) { _, _ in
                        if display.plot.dots?.values.isEmpty != false || !canUseMetal || paused != nil {
                            notePresentation(ProcessInfo.processInfo.systemUptime)
                        }
                    }
                WaveformPositionControl(bounds: bounds, selection: display.range) { target in
                    move(to: target, span: display.range.upper - display.range.lower)
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
                Text(bench.preview.settlingRemaining == nil ? "Waiting for waveform samples" : "Settling before waveform display")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: height.points)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let paused {
                Text("View paused at \(WaveformTime.span(paused.raw.time(paused.raw.end - 1))). Recording continues.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: bench.current?.id) { await refresh() }
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

    @ViewBuilder private var flagActions: some View {
        Button("Add Note…", systemImage: "note.text", action: addNote)
            .disabled(bench.timelineSaving).help("Add Note")
    }

    @ViewBuilder private var viewingActions: some View {
        if paused != nil {
            Button("Refresh Once", systemImage: "arrow.clockwise") { pause(replacing: true) }
                .disabled(pausing || bench.stopping)
                .help("Show the latest samples once and keep the waveform paused")
        }
        if paused == nil, position.delay > 0 {
            Button("Jump to Live", systemImage: "forward.end") { position.delay = 0 }
                .help("Show the newest samples at the current zoom")
        }
        Button(paused == nil ? "Pause View" : "Follow Live", systemImage: paused == nil ? "pause" : "play") {
            if paused != nil { paused = nil; center = nil; position.delay = 0; fps = .init(); actualFPS = nil }
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
        .onChange(of: window) { _, _ in zoomedSpan = nil; center = nil; position.delay = 0 }
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
                        LabeledContent("Actual FPS", value: actualFPS.map {
                            $0.formatted(.number.precision(.fractionLength(1)))
                        } ?? "…").fixedSize()
                            .help("Recent Metal presentations or Canvas plot updates. This is separate from the sample rate.")
                    }
                    if skippedPreviewUpdates > 0 {
                        Text("Preview updates skipped: \(skippedPreviewUpdates.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Only the viewer skipped these updates. See saved sample and gap counters for recording coverage.")
                    }
                    if bench.waveformStyle == .points {
                        Toggle("Original Dots", isOn: $originalLiveDots)
                            .help("Use original dots in wider live windows. Paused views can show original dots at close zoom.")
                        DotDensityControl(percent: $bench.dotDensity, plot: display?.plot,
                                          rendererLimited: !canUseMetal || (paused == nil
                                            ? presentedDotFrame != display?.plot.dots?.id : !metalPresented))
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
        chart.directLiveMetal = paused == nil
        chart.onLivePresentation = { id, timestamp in
            presentedDotFrame = id
            notePresentation(timestamp)
        }
        chart.metalFailed = $metalFailed
        chart.metalPresentation = $metalPresented
        chart.referenceTime = paused?.raw.bounds.upper
        chart.flagTimes = flagTimes
        chart.pendingFlagTimes = pendingFlagTimes
        chart.home = showAll
        chart.navigate = navigate
        return chart
    }

    private func notePresentation(_ timestamp: Double) {
        guard paused == nil else { return }
        if let result = fps.record(timestamp) { actualFPS = result }
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
            if paused != nil || position.delay > 0 {
                move(to: range.lower + anchor * span + (0.5 - anchor) * width, span: width)
            }
            zoomedSpan = width
        } else {
            let target = (range.lower + range.upper) / 2 + amount * span
            move(to: target, span: span)
        }
    }

    private func showAll() {
        window = .all
        zoomedSpan = nil
        center = nil
        position.delay = 0
    }

    private func move(to target: Double, span: Double) {
        if paused != nil { center = target }
        else { position.move(to: target, end: currentEnd, span: span, minimum: 2 / configuredRate) }
    }

    private func pause(replacing: Bool = false) {
        guard !pausing, replacing == (paused != nil) else { return }
        let instant = DispatchTime.now().uptimeNanoseconds
        let date = Date()
        let displayed = display?.range
        let keepPosition = !replacing && position.delay > 0
        pausing = true
        pauseTask = Task {
            let capture = await bench.captureWaveform(at: instant, date: date, seconds: 30)
            guard !Task.isCancelled else { return }
            if let capture {
                paused = capture
                actualFPS = nil
                fps = .init()
                center = keepPosition ? displayed.map { ($0.lower + $0.upper) / 2 } : nil
                issue = nil
            } else {
                issue = replacing ? "The paused waveform could not be refreshed." : "No samples were available to pause."
            }
            pausing = false
        }
    }

    private func refresh() async {
        var lastRequest: Request?
        var renderedRange: StreamSelection?
        var renderedBoundary: Double?
        var renderedRevision: UInt64?
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let started = clock.now
            let request = self.request
            let frozen = paused
            let live = bench.preview
            let rate = configuredRate
            var range = visibleRange(end: currentEnd, rate: rate, request: request)
            let requestedRange = range
            let boundary = frozen == nil ? live.waveformBoundary : nil
            if range.valid, request != lastRequest || requestedRange != renderedRange || boundary != renderedBoundary {
                let width = range.upper - range.lower
                let possible = width * rate
                let wantsRaw = width <= 0.25 || (request.density != nil && (frozen != nil || request.originalLiveDots)
                                                && possible <= Double(WaveformDots.rawReadLimit))
                var capture = frozen
                if capture == nil, wantsRaw, request.delay + width <= LiveFlagHistory.seconds {
                    let instant = DispatchTime.now().uptimeNanoseconds
                    capture = await bench.captureWaveform(at: instant, date: .now,
                                                          seconds: min(LiveFlagHistory.seconds, request.delay + width + 0.02))
                    if let candidate = capture {
                        let recent = candidate.raw.bounds
                        let selected = visibleRange(end: recent.upper, rate: rate, request: request)
                        if selected.lower >= recent.lower - 1 / rate { range = selected }
                        else { capture = nil }
                    }
                }
                guard !Task.isCancelled else { return }
                do {
                    let result: StudioPlot
                    if let frozen, range.lower < frozen.raw.bounds.lower - 1e-9,
                       wantsRaw, range.upper <= frozen.raw.bounds.lower + 1e-9,
                       let saved = try await bench.readRecordingWaveform(range, density: request.density, limit: request.dotLimit) {
                        result = saved
                    } else {
                        result = try await render(range: range, rate: rate, live: live, capture: capture,
                                                      prior: previous, request: request)
                    }
                    guard !Task.isCancelled else { return }
                    if frozen?.raw.click == paused?.raw.click {
                        display = .init(range: range, plot: result, latestCode: frozen.map(lastCode) ?? live.latestCode)
                        lastRequest = request
                        renderedRange = requestedRange
                        renderedBoundary = boundary
                        if frozen == nil {
                            if let renderedRevision, live.waveformRevision > renderedRevision + 1 {
                                skippedPreviewUpdates += live.waveformRevision - renderedRevision - 1
                            }
                            renderedRevision = live.waveformRevision
                        } else { renderedRevision = nil }
                        if issue != nil { issue = nil }
                    }
                } catch {
                    if !Task.isCancelled { issue = error.localizedDescription }
                }
            }
            let fps = frozen == nil ? request.fps : min(10, request.fps)
            let interval = Duration.nanoseconds(1_000_000_000 / max(1, fps))
            let spent = clock.now - started
            let behind = frozen == nil && spent > interval
            if displayBehind != behind { displayBehind = behind }
            do { try await clock.sleep(until: max(started + interval, clock.now + .milliseconds(1))) }
            catch { return }
        }
    }

    private func refreshFlags() async {
        guard let run = bench.current else { return }
        guard let content = try? await bench.timelineLoad(for: .init(runID: run.id, tool: .review, frozen: nil), waveform: false),
              !Task.isCancelled, bench.current?.id == run.id else { return }
        flagTimes = content.entries.compactMap { item in
            guard item.state == .placed, let position = item.position else { return nil }
            return RunTimeline.time(of: position, in: content.reader.run)
        }
        pendingFlagTimes = content.entries.filter { $0.state == .pending }.compactMap {
            $0.position.flatMap { RunTimeline.time(of: $0, in: content.reader.run) }
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
                let step = live.waveformBinSeconds
                let startIndex = max(0, min(live.waveformBins.count, Int(floor((range.lower - origin) / step))))
                let endIndex = max(startIndex, min(live.waveformBins.count, Int(ceil((range.upper - origin) / step))))
                for index in startIndex..<endIndex {
                    let bin = live.waveformBins[index]
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
        var pane = Self(bench: bench, addNote: {})
        pane._paused = State(initialValue: capture)
        pane._window = State(initialValue: .custom)
        return pane
    }
}
#endif
