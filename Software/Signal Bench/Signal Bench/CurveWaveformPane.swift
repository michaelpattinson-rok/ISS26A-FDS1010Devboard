import SwiftUI

struct CurveWaveformPane: View {
    let reader: CurveReader
    let original: StreamRangeReader?
    @Binding var selection: StreamSelection
    let masks: [StreamSelection]
    @ObservedObject var bench: StreamingBench
    var keep: ((StreamSelection) -> Void)?
    @State private var trace: CurveInspection.Trace = .curve
    @State private var plot: CurveInspection?
    @State private var overview: StudioPlot?
    @State private var gaps: [StreamSelection] = []
    @State private var cursors: [CurveInspection.Point] = []
    @State private var issue: String?
    @State private var loading = false
    @State private var cursorTask: Task<Void, Never>?
    @State private var draftLower = 0.0
    @State private var draftUpper = 0.0
    @State private var height = WaveformHeight.standard
    @State private var playback = RunPlayback()

    private var bounds: StreamSelection { reader.manifest.selection }
    private var rate: Double { reader.run.settings.recordedRate }
    private var zoom: WaveformZoom { .init(bounds: bounds, minimum: 2 / rate) }
    private var source: StreamRangeReader? { trace == .curve ? nil : original }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            RunWaveformViewfinder(bounds: bounds, plot: overview, displayed: plot?.selection,
                requested: loading && plot?.selection != selection ? selection : nil, move: move, navigate: navigate)
            WaveformZoomControl(bounds: bounds, selection: selection, minimum: 2 / rate,
                change: { resize($0, center: center) }, home: home)
            if let plot {
                chart(plot)
                    .overlay { RunPlaybackMarker(playback: playback, range: plot.selection) }
                RunPlaybackControls(playback: playback, range: plot.selection,
                                    ready: !loading && plot.selection == selection && plot.count > 0 && !bench.busy)
            } else {
                ContentUnavailableView(loading ? "Opening Curve" : "No Waveform in View", systemImage: "waveform")
                    .frame(height: 180)
            }
            WaveformPositionControl(bounds: bounds, selection: selection, change: move)
            if loading { ProgressView("Reading waveform").controlSize(.small) }
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            if plot?.verifiedDetail == false {
                Text("Indexed overview. Zoom in for individual readings.").font(.caption).foregroundStyle(.secondary)
            }
            if !reader.manifest.unknownBoundaries.isEmpty {
                Text("Dashed boundaries mark interruptions with unknown duration.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = plot?.selectedError {
                Text("Selected range · Maximum \(error.maximum.formatted(.number.precision(.fractionLength(0...6)))) codes · RMS \((error.rms ?? 0).formatted(.number.precision(.fractionLength(0...6)))) codes")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            cursorReadout
            ViewThatFits(in: .horizontal) {
                HStack { tools }
                VStack(alignment: .leading, spacing: 6) { tools }
            }
            DisclosureGroup("Go to Time Range") {
                HStack {
                    TextField("Start (s)", value: $draftLower, format: .number)
                    TextField("End (s)", value: $draftUpper, format: .number)
                    Button("Go") {
                        selection = .init(lower: draftLower, upper: draftUpper)
                        cursors = []
                    }.disabled(!draftLower.isFinite || !draftUpper.isFinite ||
                                draftLower < bounds.lower || draftUpper > bounds.upper || draftUpper <= draftLower)
                }.textFieldStyle(.roundedBorder).padding(.top, 4)
            }
        }
        .onAppear { draftLower = selection.lower; draftUpper = selection.upper }
        .onDisappear { cursorTask?.cancel() }
        .onChange(of: original?.run.id) { _, id in
            if id == nil { trace = .curve; cursors = []; cursorTask?.cancel() }
        }
        .task(id: PlotRequest(selection: selection, trace: trace, original: source?.run.id)) { await refresh() }
        .task(id: reader.manifest.id) {
            let reader = reader
            let task = Task.detached(priority: .utility) {
                (try CurveInspection.load(reader, source: nil, selection: reader.manifest.selection),
                 try reader.gaps())
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                overview = overviewPlot(result.0)
                gaps = result.1
            } catch is CancellationError {
            } catch { issue = error.localizedDescription }
        }
    }

    @ViewBuilder private var controls: some View {
        Picker("View", selection: Binding(get: { trace }, set: { new in
            if new != .curve && (selection.upper - selection.lower) * rate > 2_000_000 {
                resize(1_950_000 / rate, center: center)
            }
            cursors = []
            trace = new
        })) {
            Text("Curve").tag(CurveInspection.Trace.curve)
            if original != nil {
                Text("Overlay").tag(CurveInspection.Trace.overlay)
                Text("Error").tag(CurveInspection.Trace.error)
            }
        }.pickerStyle(.segmented).frame(maxWidth: 280)
        Picker("Height", selection: $height) {
            ForEach(WaveformHeight.allCases) { Text($0.rawValue).tag($0) }
        }.fixedSize()
        if trace == .overlay { Text("Original in gray").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var tools: some View {
        Button("Worst Error", systemImage: "scope") {
            if let worst = reader.manifest.stats.worst, let time = reader.seconds(worst) {
                resize(min(0.02, max(2 / rate, selection.upper - selection.lower)), center: time)
                pick(time)
            }
        }.disabled(reader.manifest.stats.worst == nil)
        Button("Next Gap", systemImage: "waveform.path") {
            let next = gaps.first { $0.lower > center + 0.5 / rate } ?? gaps.first
            let boundary = next?.lower ?? reader.manifest.unknownBoundaries.first { $0 > center } ?? reader.manifest.unknownBoundaries.first
            if let boundary { resize(min(1, selection.upper - selection.lower), center: boundary) }
        }.disabled(gaps.isEmpty && reader.manifest.unknownBoundaries.isEmpty)
        if let keep {
            Button("Keep Range Exact", systemImage: "pin") { keep(selection) }.disabled(bench.busy)
        }
    }

    private var center: Double { (selection.lower + selection.upper) / 2 }
    private func home() { trace = .curve; selection = bounds; cursors = [] }
    private func resize(_ span: Double, center: Double) { selection = zoom.window(center: center, span: span) }
    private func move(_ center: Double) { resize(selection.upper - selection.lower, center: center) }
    private func navigate(_ anchor: Double?, _ amount: Double) {
        let width = selection.upper - selection.lower
        if let anchor {
            let newWidth = min(zoom.maximum, max(zoom.smallest, width * exp2(amount)))
            let time = selection.lower + width * anchor
            resize(newWidth, center: time + newWidth * (0.5 - anchor))
        } else { move(center + width * amount) }
    }

    private func chart(_ plot: CurveInspection) -> some View {
        let visible = plot.selection
        let w = visible.upper - visible.lower
        let bins = plot.columns
        let allBins = bins + (trace == .overlay ? plot.original : [])
        let low = allBins.compactMap(\.range).map(\.lowerBound).min() ?? 0
        let high = allBins.compactMap(\.range).map(\.upperBound).max() ?? Double(reader.run.settings.board.maxCode)
        let pad = max(trace == .error ? 0.03 : 0.1, (high - low) * 0.08)
        let axis = (low - pad)...(high + pad)
        let hasPoints = !plot.points.isEmpty
        let signal = hasPoints ? plot.points.map { point in
            let value = trace == .error ? point.original.flatMap { original in point.reading.value.map { $0 - original } } : point.reading.value
            return (time: point.time, value: value)
        } : traceBins(plot.columns, visible: visible)
        let comparison = hasPoints ? plot.points.map { (time: $0.time, value: $0.original) } : traceBins(plot.original, visible: visible)
        return StreamWaveform(columns: bins.map { bin in
            guard !hasPoints, let values = bin.range, trace != .error else { return nil }
            return UInt16(max(0, floor(values.lowerBound)))...UInt16(min(Double(reader.run.settings.board.maxCode), ceil(values.upperBound)))
        }, breaks: plot.breaks + reader.manifest.unknownBoundaries, selection: visible, height: height.points, xAxis: true,
           maskedTimes: masks, faults: bins.map(\.invalid), rails: bins.map(\.clipped),
           home: home, gaps: gaps.filter { $0.lower < visible.upper && $0.upper > visible.lower },
           style: .trace, cursorTimes: cursors.map(\.time), navigate: navigate,
           cursor: { pick(min(visible.upper - min(w, 1 / rate) / 10, $0)) },
           lowRails: bins.map(\.lowRail), highRails: bins.map(\.highRail),
           analogTrace: signal, comparisonTrace: trace == .overlay ? comparison : nil,
           analogRange: axis, waveformLabel: trace.rawValue + " waveform")
    }

    private func traceBins(_ bins: [CurveInspection.Bin], visible: StreamSelection) -> [(time: Double, value: Double?)] {
        bins.enumerated().map { i, bin in
            (visible.lower + (Double(i) + 0.5) / Double(bins.count) * (visible.upper - visible.lower),
             bin.count > 0 ? bin.sum / Double(bin.count) : nil)
        }
    }

    private func overviewPlot(_ inspection: CurveInspection) -> StudioPlot {
        .init(columns: inspection.columns.map { bin in
            bin.range.map { UInt16(max(0, floor($0.lowerBound)))...UInt16(min(Double(reader.run.settings.board.maxCode), ceil($0.upperBound))) }
        }, breaks: inspection.breaks,
        stats: .init(baseline: nil, robustNoise: nil, minimum: nil, maximum: nil, samples: inspection.count,
                     adcErrors: 0, clipped: 0, nominalSampledSeconds: 0, selectionSeconds: bounds.upper - bounds.lower),
        faults: inspection.columns.map(\.invalid), rails: inspection.columns.map(\.clipped),
        lowRails: inspection.columns.map(\.lowRail), highRails: inspection.columns.map(\.highRail))
    }

    @ViewBuilder private var cursorReadout: some View {
        if !cursors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(cursors.enumerated()), id: \.element.id) { index, point in
                    let code = point.reading.value.map { $0.formatted(.number.precision(.fractionLength(0...6))) + " ADC codes" } ?? "Flagged reading"
                    Text("\(index == 0 ? "A" : "B") · \(point.time.formatted(.number.precision(.fractionLength(0...9)))) s · Reading \(point.index.formatted()) · \(code) · \(point.reading.exact ? "Exact" : "Modeled")")
                    if point.reading.value == nil {
                        Text("\(point.reading.adcErrors) ADC errors · \(point.reading.low) low rail · \(point.reading.high) high rail").foregroundStyle(.secondary)
                    }
                    if let input = point.original, let output = point.reading.value {
                        Text("Original \(input.formatted()) · Error \((output - input).formatted(.number.precision(.fractionLength(0...6)))) codes").foregroundStyle(.secondary)
                    }
                }
                if cursors.count == 2 {
                    let a = cursors[0], b = cursors[1]
                    let amplitude = a.reading.value.flatMap { av in b.reading.value.map { $0 - av } }
                    Text("B − A · \(((b.time - a.time) * 1e6).formatted(.number.precision(.fractionLength(0...6)))) µs"
                         + (amplitude.map { " · \($0.formatted(.number.precision(.fractionLength(0...6)))) codes" } ?? ""))
                }
                Button("Clear Cursors") { cursors = [] }.buttonStyle(.link)
            }.font(.caption.monospacedDigit()).textSelection(.enabled)
        } else {
            Text("Click the waveform to place up to two cursors.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pick(_ time: Double) {
        let reader = reader, source = source
        cursorTask?.cancel()
        cursorTask = Task {
            let task = Task.detached(priority: .userInitiated) { try CurveInspection.sample(reader, source: source, at: time) }
            do {
                let point = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }
                if let point {
                    if cursors.count == 2 { cursors = [] }
                    if !cursors.contains(where: { $0.id == point.id }) { cursors.append(point) }
                    issue = nil
                } else { issue = "This position falls in a gap." }
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }

    @State private var loadToken = UUID()

    private struct PlotRequest: Equatable {
        let selection: StreamSelection
        let trace: CurveInspection.Trace
        let original: UUID?
    }

    private func refresh() async {
        guard selection.valid else { return }
        let reader = reader, range = selection, trace = trace, source = source
        let token = UUID()
        loadToken = token
        loading = true
        issue = nil
        defer { if loadToken == token { loading = false } }
        let task = Task.detached(priority: .userInitiated) {
            try CurveInspection.load(reader, source: source, selection: range, trace: trace)
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if !Task.isCancelled, loadToken == token { plot = value }
        } catch {
            if !Task.isCancelled, loadToken == token {
                issue = error.localizedDescription
                plot = nil
            }
        }
    }
}

struct CurveDiagnosticsPane: View {
    let reader: CurveReader
    let selection: StreamSelection
    let source: StreamRangeReader
    @State private var result: CurveInspection?
    @State private var issue: String?
    @State private var working: Task<Void, Never>?
    @State private var inProgress = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Curve Diagnostics").font(.headline)
            Text("Range statistics and spectra use saved curve values and skip approved exclusions. Choose up to two million readings.")
                .font(.callout).foregroundStyle(.secondary)
            Text(selection.lower.formatted() + " to " + selection.upper.formatted() + " s").font(.caption.monospacedDigit())
            HStack {
                Button("Analyze Range") { analyze() }.disabled(!selection.valid || inProgress)
                if inProgress {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { working?.cancel() }
                }
            }
            if let issue { Text(issue).foregroundStyle(.secondary) }
            if let result, result.selection == selection {
                Text("\(result.valid.formatted()) valid readings · \(result.modeled.formatted()) modeled · \((result.knownGap ?? 0).formatted(.number.precision(.fractionLength(0...6)))) s missing")
                if result.excluded > 0 { Text("\(result.excluded.formatted()) readings in approved exclusions").foregroundStyle(.secondary) }
                Text("Mean \(number(result.mean)) · RMS variation \(number(result.rmsVariation))")
                if result.spectra.isEmpty { Text("A spectrum needs at least 1,024 consecutive valid readings.").foregroundStyle(.secondary) }
                ForEach(result.spectra, id: \.rate) { spectrum in
                    NoiseSpectrumView(spectrum: .init(ranges: [], sampleRate: spectrum.rate, transformSize: 1024,
                        windows: spectrum.windows, points: spectrum.points.map { .init(hz: $0.x, density: $0.y) }),
                        accessibilityTitle: "Curve power spectral density")
                }
            }
            DisclosureGroup("Verified Error by Minute") {
                ForEach(reader.manifest.minutes) { minute in
                    Text("Minute \(minute.id + 1) · Maximum \(number(minute.stats.maximum)) · RMS \(number(minute.stats.rms))")
                        .font(.caption.monospacedDigit())
                }
            }
        }.onDisappear { working?.cancel() }.onChange(of: selection) { _, _ in working?.cancel(); result = nil }
    }

    private func analyze() {
        working?.cancel()
        let reader = reader, range = selection, source = source
        inProgress = true
        issue = nil
        working = Task {
            let worker = Task.detached(priority: .utility) {
                let exclusions = RunAnnotations.merged(try RunAnnotations.read(source)?.masks ?? [])
                return try CurveInspection.load(reader, source: nil, selection: range, diagnostics: true, exclusions: exclusions)
            }
            defer { inProgress = false }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled { result = value }
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }

    private func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...6))) + " codes" } ?? "Unavailable"
    }
}
