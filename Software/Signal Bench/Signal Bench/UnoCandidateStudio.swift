import SwiftUI

struct UnoCandidateStudio: View {
    let bench: StreamingBench
    let reader: StreamRangeReader
    let selection: StreamSelection
    let openSample: (StreamMatchLocation) -> Void
    let didSave: (StreamAnalysisManifest) -> Void

    @State private var result: UnoCandidateAnalysis.Comparison?
    @State private var plot: StudioPlot?
    @State private var training: UUID?
    @State private var empty: UUID?
    @State private var replay: UnoAveragingReplay.Report?
    @State private var revision: StreamAnalysisManifest?
    @State private var saved: [StreamAnalysisManifest] = []

    #if CANDIDATE_SCREENS
    init(bench: StreamingBench, reader: StreamRangeReader, selection: StreamSelection,
         openSample: @escaping (StreamMatchLocation) -> Void, didSave: @escaping (StreamAnalysisManifest) -> Void,
         example: (UnoCandidateAnalysis.Comparison, StudioPlot)? = nil,
         replayExample: UnoAveragingReplay.Report? = nil) {
        self.bench = bench
        self.reader = reader
        self.selection = selection
        self.openSample = openSample
        self.didSave = didSave
        _result = State(initialValue: example?.0)
        _plot = State(initialValue: example?.1)
        _replay = State(initialValue: replayExample)
    }
    #endif

    private var fixtures: [StreamRun] { availableRuns.filter { $0.settings.bench?.step == .fixture && $0.id != reader.run.id } }
    private var controls: [StreamRun] {
        availableRuns.filter { [.empty, .repeatEmpty].contains($0.settings.bench?.step) }
    }
    private var availableRuns: [StreamRun] {
        bench.runs.compactMap(\.run).filter {
            $0.settings.board == .unoR4 && $0.settings.factor == 1 && $0.segments.count == 1 &&
                $0.settings.adcAveraging == nil && $0.settings.channel == 0 && $0.status != .recording &&
                $0.curveSource == nil
        }
    }
    private var segment: StreamRunSegment? { reader.run.segments.last { $0.timelineStart <= selection.lower } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if reader.run.settings.unoCandidates != nil { candidates }
            if reader.run.settings.bench?.step == .fixture { averaging }
            if !saved.isEmpty {
                DisclosureGroup("Saved Candidate and Averaging Reviews") {
                    ForEach(saved) { item in
                        Button("\(item.analyzer == "signalbench.uno-averaging-replay" ? "Averaging replay" : "Candidate comparison") · \(item.created.formatted(date: .abbreviated, time: .shortened))") {
                            openSaved(item)
                        }.buttonStyle(.link).disabled(bench.busy)
                    }
                }
            }
        }
        .task(id: reader.run.id) {
            let source = reader
            let operation = Task.detached(priority: .utility) { try Self.savedManifest(source) }
            do { saved = try await operation.value }
            catch { if !Task.isCancelled { bench.notice = error.localizedDescription } }
        }
        .onChange(of: selection) { _, _ in result = nil; plot = nil }
        .onChange(of: training) { _, _ in replay = nil }
        .onChange(of: empty) { _, _ in replay = nil }
    }

    private var candidates: some View {
        GroupBox("Device Candidates and Mac Pulse Matches") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Compare up to three seconds starting at the selected range. Missing device coverage is shown separately from detector disagreement.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Compare Selected Range", systemImage: "waveform") { compare() }
                        .disabled(bench.busy || segment == nil || !selection.valid)
                    if let result {
                        Button("Save Comparison") { saveComparison(result) }.disabled(bench.busy)
                    }
                }
                if let result, let plot, let source = reader.run.segments.first(where: { $0.id == result.segment }) {
                    HStack(spacing: 14) {
                        Label("Device", systemImage: "circle.fill").foregroundStyle(.teal)
                        Label("Mac", systemImage: "triangle.fill").foregroundStyle(.orange)
                        Text("Shading shows shared coverage").foregroundStyle(.secondary)
                    }.font(.caption)
                    CandidateOverlay(plot: plot, comparison: result, epoch: source.timelineStart,
                                     rate: source.configuredRate(reader.run.settings.nominalRate))
                        .frame(height: 150)
                        .accessibilityLabel("Original waveform with device and Mac pulse markers")
                    Text("\(result.sharedReadings.formatted()) readings in shared coverage")
                        .font(.callout.weight(.medium))
                    if source.unknown { Text("The stream ended without a verified tail.").font(.caption).foregroundStyle(.secondary) }
                    if let work = source.candidatePeakUS {
                        LabeledContent("Longest device processing block", value: "\(work.formatted()) µs").font(.caption)
                    }
                    ForEach(result.coverage.sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                        if count > 0 { LabeledContent(reason, value: count.formatted()).font(.caption) }
                    }
                    if result.events.isEmpty {
                        Text("No candidates or matches in this view.").foregroundStyle(.secondary)
                    } else {
                        ForEach(result.events.prefix(50)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Button("\(event.label) · sample \((event.device?.peak ?? event.mac?.peakIndex ?? event.range.first).formatted())") {
                                    openSample(.init(segment: event.range.segment, sample: event.device?.peak ?? event.mac?.peakIndex ?? event.range.first))
                                }.buttonStyle(.link)
                                if let item = event.device {
                                    Text("Device · \(item.decision.title), \(item.height) codes, \(decimal(Double(item.end - item.first) / source.configuredRate(reader.run.settings.nominalRate) * 1e6)) µs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let item = event.mac {
                                    Text("Mac · \(item.decision == "match" ? "Pulse Match" : item.decision), \(decimal(item.height)) codes, \(decimal(Double(item.width) / source.configuredRate(reader.run.settings.nominalRate) * 1e6)) µs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let d = event.device, let m = event.mac {
                                    Text("Device minus Mac · \(decimal(Double(d.height) - m.height)) codes, \(decimal((Double(d.end - d.first) - Double(m.width)) / source.configuredRate(reader.run.settings.nominalRate) * 1e6)) µs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if result.events.count > 50 { Text("Showing the first 50 findings. The saved comparison includes all findings.").font(.caption) }
                    }
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var averaging: some View {
        GroupBox("Uno Averaging Replay") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This run is the held-out recording. Choose a different timed training run and, optionally, a matching empty-board control.")
                    .foregroundStyle(.secondary)
                Picker("Training run", selection: $training) {
                    Text("Choose training").tag(UUID?.none)
                    ForEach(fixtures) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Empty control", selection: $empty) {
                    Text("None").tag(UUID?.none)
                    ForEach(controls) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Replay All Six Rates", systemImage: "repeat") { analyzeReplay() }
                    .disabled(bench.busy || training == nil)
                if let replay {
                    Text("Training alignment \(decimal(replay.trainingBiasUS)) µs")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(replay.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(row.factor)× · \(decimal(row.recordedRate)) readings/s").font(.headline)
                            Text("\(row.matched) matched · \(row.missed) missed in coverage · \(row.ambiguous) ambiguous")
                            Text("\(row.outsideCoverage) outside coverage · \(row.unassociated) unassociated · \(decimal(row.usableSeconds)) usable s")
                            Text("Height loss \(optional(row.averageHeightLoss, "codes")) · width change \(optional(row.averageWidthChangeUS, "µs"))")
                            Text("Timing RMS \(optional(row.rmsTimingErrorUS, "µs")) · empty false matches \(optional(row.falseMatchesPerUsableMinute, "/ usable minute"))")
                        }.font(.callout).padding(.vertical, 3)
                    }
                }
                if revision != nil {
                    Label("Saved as a new analysis revision", systemImage: "checkmark.circle").font(.caption)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compare() {
        guard let segment else { return }
        let input = reader, range = selection
        bench.perform("Comparing Device Candidates") {
            try UnoCandidateAnalysis.compare(input, segment: segment,
                                             start: range.lower - segment.timelineStart,
                                             length: min(3, max(0.1, range.upper - range.lower)))
        } completion: { value in
            guard range == selection else { return }
            result = value.0
            plot = value.1
        }
    }

    private func saveComparison(_ value: UnoCandidateAnalysis.Comparison) {
        let input = reader
        bench.perform("Saving candidate comparison") {
            try UnoCandidateAnalysis.save(value, reader: input, selection: value.selection,
                                          analyzer: "signalbench.uno-candidate-comparison", name: "candidate-comparison.jsonl")
        } completion: { saved.insert($0, at: 0); didSave($0) }
    }

    private func analyzeReplay() {
        guard let trainingRun = fixtures.first(where: { $0.id == training }) else { return }
        let emptyRun = controls.first { $0.id == empty }
        let source = reader
        bench.perform("Replaying Uno averaging") {
            let train = StreamRangeReader(store: source.store, run: trainingRun)
            let control = emptyRun.map { StreamRangeReader(store: source.store, run: $0) }
            let report = try UnoAveragingReplay.run(training: train, heldOut: source, empty: control)
            let manifest = try UnoCandidateAnalysis.save(report, reader: source,
                selection: FixtureTemplateStudy.fullRange(source),
                analyzer: "signalbench.uno-averaging-replay", name: "averaging-replay.jsonl")
            return (report, manifest)
        } completion: { value in replay = value.0; revision = value.1; saved.insert(value.1, at: 0); didSave(value.1) }
    }

    nonisolated private static func savedManifest(_ reader: StreamRangeReader) throws -> [StreamAnalysisManifest] {
        try StreamStudio.analyses(reader).filter {
            ["signalbench.uno-candidate-comparison", "signalbench.uno-averaging-replay"].contains($0.analyzer)
        }
    }

    private func openSaved(_ manifest: StreamAnalysisManifest) {
        let source = reader
        if manifest.analyzer == "signalbench.uno-averaging-replay" {
            bench.perform("Opening averaging replay") {
                try UnoCandidateAnalysis.load(UnoAveragingReplay.Report.self, reader: source,
                                              manifest: manifest, name: "averaging-replay.jsonl")
            } completion: { report in replay = report; revision = manifest }
        } else {
            bench.perform("Opening candidate comparison") {
                let report = try UnoCandidateAnalysis.load(UnoCandidateAnalysis.Comparison.self, reader: source,
                    manifest: manifest, name: "candidate-comparison.jsonl")
                let pinned = try source.prepared()
                let index = Dictionary(uniqueKeysWithValues: (pinned.index ?? []).map { ($0.id, $0.sha256) })
                guard report.ranges.allSatisfy({ index[$0.chunk] == $0.sha256 }) else { throw ReviewWorkerError.stale }
                return (report, try StreamStudio.plot(pinned, selection: report.selection))
            } completion: { value in result = value.0; plot = value.1 }
        }
    }

    private func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    private func optional(_ value: Double?, _ unit: String) -> String { value.map { "\(decimal($0)) \(unit)" } ?? "unavailable" }
}

private struct CandidateOverlay: View {
    let plot: StudioPlot
    let comparison: UnoCandidateAnalysis.Comparison
    let epoch: Double
    let rate: Double

    var body: some View {
        Canvas { context, size in
            let range = comparison.selection
            let minimum = Double(plot.stats.minimum ?? 0), maximum = Double(plot.stats.maximum ?? 16383)
            let span = max(8, maximum - minimum)
            let inset: CGFloat = 45
            let chart = CGRect(x: inset, y: 10, width: max(1, size.width - inset - 12), height: max(1, size.height - 35))
            let width = chart.width / CGFloat(max(1, plot.columns.count))
            func y(_ value: Double) -> CGFloat {
                chart.maxY - chart.height * (value - minimum) / span
            }
            func x(_ sample: UInt64) -> CGFloat {
                chart.minX + chart.width * (epoch + Double(sample) / rate - range.lower) / (range.upper - range.lower)
            }
            for band in comparison.sharedRanges {
                let left = max(chart.minX, x(band.first)), right = min(chart.maxX, x(band.end))
                if right > left {
                    context.fill(Path(CGRect(x: left, y: chart.minY, width: right - left, height: chart.height)),
                                 with: .color(.teal.opacity(0.09)))
                }
            }
            for value in [minimum, minimum + span / 2, minimum + span] {
                var grid = Path()
                grid.move(to: CGPoint(x: chart.minX, y: y(value)))
                grid.addLine(to: CGPoint(x: chart.maxX, y: y(value)))
                context.stroke(grid, with: .color(.secondary.opacity(0.25)))
                let label = Text(Int(value.rounded()).formatted()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: chart.minX - 5, y: y(value)), anchor: .trailing)
            }
            var signal = Path()
            for (i, values) in plot.columns.enumerated() {
                guard let values else { continue }
                let px = chart.minX + (CGFloat(i) + 0.5) * width
                signal.move(to: CGPoint(x: px, y: y(Double(values.upperBound)) - 0.5))
                signal.addLine(to: CGPoint(x: px, y: y(Double(values.lowerBound)) + 0.5))
            }
            context.stroke(signal, with: .color(.primary.opacity(0.72)), lineWidth: max(0.6, width))
            for event in comparison.events {
                if let peak = event.device?.peak, (chart.minX...chart.maxX).contains(x(peak)) {
                    context.fill(Path(ellipseIn: CGRect(x: x(peak) - 3, y: chart.minY - 3, width: 6, height: 6)), with: .color(.teal))
                }
                if let peak = event.mac?.peakIndex, (chart.minX...chart.maxX).contains(x(peak)) {
                    var triangle = Path()
                    triangle.move(to: CGPoint(x: x(peak), y: chart.maxY - 4))
                    triangle.addLine(to: CGPoint(x: x(peak) + 4, y: chart.maxY + 3))
                    triangle.addLine(to: CGPoint(x: x(peak) - 4, y: chart.maxY + 3))
                    triangle.closeSubpath()
                    context.fill(triangle, with: .color(.orange))
                }
            }
            let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2...4))
            for i in 0...2 {
                let fraction = Double(i) / 2
                let time = range.lower + fraction * (range.upper - range.lower)
                let label = Text("\(time.formatted(precision)) s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: chart.minX + chart.width * fraction, y: chart.maxY + 14),
                             anchor: i == 0 ? .leading : (i == 2 ? .trailing : .center))
            }
        }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}
