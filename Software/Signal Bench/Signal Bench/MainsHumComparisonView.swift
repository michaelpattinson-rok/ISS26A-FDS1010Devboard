import SwiftUI

struct MainsHumComparisonView: View {
    @ObservedObject var bench: StreamingBench
    #if STREAM_TESTING
    var initialRuns: [UUID] = []
    #else
    private var initialRuns: [UUID] { [] }
    #endif

    private enum Comparison: String, CaseIterable {
        case power = "Battery and Charger"
        case device = "Uno and Pico"
        case detector = "Empty Board and Dark Detector"

        var labels: [String] {
            switch self {
            case .power: ["On Battery", "Charger Connected"]
            case .device: ["UNO R4 Minima", "Pico W"]
            case .detector: ["Electronics Only", "Dark Detector"]
            }
        }
    }

    @State private var comparison = Comparison.power
    @State private var width: CGFloat = 0
    private var runs: [StreamRun] {
        bench.runs.compactMap(\.run).filter { !$0.isManualDraft && $0.curveSource == nil && $0.status != .recording }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare Saved Runs").font(.title2.weight(.semibold))
            Text("Choose two original recordings. Signal Bench fits 60 Hz over up to 20 seconds per side.")
                .foregroundStyle(.secondary)
            Picker("Compare", selection: $comparison) {
                ForEach(Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if runs.isEmpty {
                ContentUnavailableView("No saved recordings", systemImage: "waveform",
                                       description: Text("Record two runs to compare them here."))
            } else {
                let layout = width >= 590
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                layout {
                    MainsHumComparisonSlot(bench: bench, runs: runs, title: comparison.labels[0], preset: initialRuns.first)
                    MainsHumComparisonSlot(bench: bench, runs: runs, title: comparison.labels[1], preset: initialRuns.dropFirst().first)
                }.id(comparison)
                Text("The slot names describe your intended comparison. Check the saved setup on both sides. Changes in input, gain, wiring, averaging, or rate can affect the result. A repeated 60 Hz tone alone cannot locate the source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

private struct MainsHumComparisonSlot: View {
    let bench: StreamingBench
    let runs: [StreamRun]
    let title: String
    let preset: UUID?

    @State private var runID: UUID?
    @State private var segmentID: UUID?
    @State private var start = 0.0
    @State private var reference = ""
    @State private var reading: MainsHumCapture.Reading?
    @State private var issue: String?
    @State private var working = false
    @State private var worker: Task<Void, Never>?

    private var run: StreamRun? { runs.first { $0.id == runID } }
    private var segment: StreamRunSegment? { run?.segments.first { $0.id == segmentID } }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Run", selection: $runID) {
                    Text("Choose a run").tag(UUID?.none)
                    ForEach(runs) { run in Text(run.name).tag(Optional(run.id)) }
                }.help(run?.name ?? "Select a recording from this Project")
                if let run {
                    if run.segments.count > 1 {
                        Picker("Segment", selection: $segmentID) {
                            ForEach(Array(run.segments.enumerated()), id: \.element.id) { number, segment in
                                Text("Segment \(number + 1)").tag(Optional(segment.id))
                            }
                        }
                    }
                    if let segment {
                        settings(run, segment)
                        LabeledContent("Start in segment") {
                            TextField("Start in segment (seconds)", value: $start, format: .number.precision(.fractionLength(0...3)))
                                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }.disabled(working)
                        if working {
                            HStack { ProgressView().controlSize(.small); Button("Cancel") { reset() } }
                        } else {
                            Button("Measure 60 Hz") { measure(run, segment) }.buttonStyle(.borderedProminent)
                                .disabled(bench.busy || !start.isFinite || start < 0)
                        }
                        if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout) }
                        if let reading { result(reading, run: run, segment: segment) }
                    } else {
                        Text("No saved segment is available.").foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        #if STREAM_TESTING
        .task {
            guard let preset else { return }
            runID = preset
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled, let run, let segment { measure(run, segment) }
        }
        #endif
        .onChange(of: runID) {
            segmentID = run?.segments.first?.id
            reference = ""
            start = 0
            reset()
        }
        .onChange(of: segmentID) { start = 0; reference = ""; reset() }
        .onChange(of: start) { reset() }
        .onChange(of: bench.busy) { _, busy in if busy { reset() } }
        .onDisappear { reset() }
    }

    private func settings(_ run: StreamRun, _ segment: StreamRunSegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(segment.board.title) · \(segment.board.analogPin(run.settings.channel))").font(.headline)
            Text("\(number(segment.rawConfiguredRate(run.settings.nominalRate))) raw samples/s, \(segment.factor)× device average")
            if let macAverage = run.settings.adcAveraging { Text("Mac average \(macAverage.count)×") }
            Text("Gain \(run.settings.gain) · \(run.status == .interrupted ? "Interrupted" : "Complete")")
            Text(run.settings.wiring.isEmpty ? "Wiring declaration unavailable" : run.settings.wiring)
            Text(run.settings.mainsHum?.step.power ?? "Mac power state unrecorded by guided test")
            if !run.description.isEmpty { Text(run.description).lineLimit(3).help(run.description) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func result(_ reading: MainsHumCapture.Reading, run: StreamRun, segment: StreamRunSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LabeledContent("60 Hz level", value: reading.humRMS.map { "\(number($0)) codes RMS" } ?? "Unavailable")
            if let range = reading.selection {
                LabeledContent("Run range", value: "\(number(range.lower)) to \(number(range.upper)) s")
                LabeledContent("Sampled / usable", value: "\(number(reading.sampledSeconds)) / \(number(reading.usableSeconds)) s")
                LabeledContent("Range without saved samples", value: "\(number(max(0, range.upper - range.lower - Double(reading.samples) / segment.configuredRate(run.settings.nominalRate)))) s")
                Button("Open Waveform at Range", systemImage: "waveform") { bench.openDiagnosisSource(run, range: range) }
            }
            LabeledContent("Rail hits / ADC errors", value: "\(reading.railed.formatted()) / \(reading.errors.formatted())")
            if let note = reading.comparisonIssue { Text(note).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Known ADC reference") {
                TextField("Known ADC reference (volts)", text: $reference, prompt: Text("Optional")).labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("V").foregroundStyle(.secondary)
            }
            if let volts = try? FloatingPointFormatStyle<Double>.number.parseStrategy.parse(reference.trimmingCharacters(in: .whitespaces)),
               volts.isFinite, (0.01...10).contains(volts), let codes = reading.humRMS {
                LabeledContent("60 Hz level at entered reference", value: "\(number(codes * volts * 1000 / Double(segment.board.maxCode + 1))) mV RMS")
            } else {
                Text("Enter the measured or confirmed ADC reference to show mV RMS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Recording Health") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Full selected segment").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Peak device queue", value: segment.firmwareQueuePeak?.formatted() ?? "Unavailable")
                    LabeledContent("Longest USB write stall", value: segment.maximumUSBBackpressureUS.map { "\($0.formatted()) µs" } ?? "Unavailable")
                    LabeledContent("Peak Mac writer queue", value: segment.hostQueuePeak?.formatted() ?? "Unavailable")
                    LabeledContent("Longest Mac writer call", value: segment.maximumWriterUS.map { "\($0.formatted()) µs" } ?? "Unavailable")
                }.padding(.top, 6)
            }
        }.monospacedDigit()
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func reset() {
        worker?.cancel()
        worker = nil
        working = false
        reading = nil
        issue = nil
    }

    private func measure(_ run: StreamRun, _ segment: StreamRunSegment) {
        reset()
        working = true
        let start = start
        worker = Task {
            defer { if !Task.isCancelled { working = false; worker = nil } }
            do {
                let value = try await bench.compareMainsHum(in: run, segment: segment.id, start: start)
                if !Task.isCancelled { reading = value }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}
