import SwiftUI

nonisolated struct AnalysisViewInputIdentity: Equatable {
    let recordID: String
    let capturedAt: Date
    let complete: Bool
    let metadata: [String: String]
    let events: [[String: String]]
    let samples: [UInt16]
    let polarity: String
    let filterWidth: Int

    init(record: CaptureRecord, polarity: String, filterWidth: Int) {
        recordID=record.id;capturedAt=record.capturedAt;complete=record.complete
        metadata=record.metadata;events=record.events;samples=record.samples
        self.polarity=polarity;self.filterWidth=filterWidth
    }
}

struct SignalAnalysisView: View {
    let record: CaptureRecord
    let onSave: (SignalAnalysisResult) -> Void
    let canSave: Bool
    @State private var polarity = ""
    @State private var filterWidth = 1
    @State private var result: SignalAnalysisResult?
    @State private var filtered: [Double?] = []
    @State private var issue: String?
    @State private var completedInput: AnalysisViewInputIdentity?

    init(record: CaptureRecord, initialFilterWidth: Int = 1, canSave: Bool = true, onSave: @escaping (SignalAnalysisResult) -> Void) {
        self.record = record
        self.onSave = onSave
        self.canSave = canSave
        _filterWidth = State(initialValue: SignalAnalysis.filterWidths.contains(initialFilterWidth) ? initialFilterWidth : 1)
    }

    private var selectedPolarity: String {
        polarity.isEmpty ? (record.metadata["profile"] ?? record.metadata["processing_profile"] ?? "POSITIVE") : polarity
    }
    private var taskIdentity: AnalysisViewInputIdentity {
        .init(record:record,polarity:selectedPolarity,filterWidth:filterWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Noise and processing").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { controls }
                VStack(alignment: .leading, spacing: 10) { controls }
            }
            Text("Raw samples and the original firmware result remain available. Saving adds this analysis to the session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue, completedInput == taskIdentity {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else if let result, completedInput == taskIdentity {
                metrics(result)
                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                AnalysisPlot(title: "ADC distribution", points: result.histogram, xUnit: "ADC codes", yUnit: "Samples", bars: true)
                AnalysisPlot(title: "Baseline over the window", points: result.baselineTrend,
                             xUnit: "Seconds, nominal", yUnit: "Median ADC codes",
                             maximumContinuousGap: 512.0 / result.sampleRateHz * 1.1)
                AnalysisPlot(title: "Frequency spectrum", points: result.spectrum.map {
                    AnalysisPoint(x: $0.x, y: 10 * log10(max($0.y, 1e-18)))
                }, xUnit: "Hz, nominal", yUnit: "dB relative to 1 code²/Hz")
                Text("Hann windows of \(result.spectrumWindowSamples) samples with 50% overlap, \(result.spectrumWindows) valid windows. Each window has its mean removed. Invalid sample gaps are excluded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if filterWidth > 1 {
                    FilterInspectionPlot(samples: record.samples, filtered: filtered, width: filterWidth)
                    Text("Centered moving average over \(filterWidth) samples. Endpoints use the available samples. Invalid samples break the filtered trace. Filtering changes only this inspection view; pulse checks use raw samples.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if result.qualityFlags != 0 {
                    let reasons = RecordDiagnostics.describe(String(result.qualityFlags), flags: RecordDiagnostics.quality) ?? []
                    Label("Window rejected", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(reasons, id: \.self) { Text($0).font(.caption) }
                }
                Button("Save Analysis") { onSave(result) }
                    .help(canSave ? "Save these processing settings, noise statistics and candidate results alongside the raw capture." : "Pause recording and stop live readings before saving an analysis.")
                    .disabled(!canSave || record.samples.isEmpty || !record.complete)
            } else {
                ProgressView("Analyzing saved samples…").controlSize(.small)
            }
        }
        .task(id: taskIdentity) {
            let input = record, selected = selectedPolarity, width = filterWidth
            let identity = taskIdentity
            result = nil; issue = nil; filtered = []; completedInput = nil
            do {
                let operation = Task.detached(priority: .utility) {
                    let result = try SignalAnalysis.compute(record: input, polarity: selected, filterWidth: width)
                    return (result, width > 1 ? SignalAnalysis.filteredSamples(input.samples, width: width) : [])
                }
                let computed = try await withTaskCancellationHandler {
                    try await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard !Task.isCancelled else { return }
                result = computed.0; filtered = computed.1; completedInput = identity
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription; completedInput = identity
            }
        }
        .onChange(of: record.id) { _, _ in polarity = ""; filterWidth = 1 }
    }

    @ViewBuilder private var controls: some View {
        Picker("Pulse direction", selection: Binding(get: { selectedPolarity }, set: { polarity = $0 })) {
            Text("Negative detector pulse").tag("NEGATIVE")
            Text("Positive electrical test").tag("POSITIVE")
        }.fixedSize()
        Picker("Inspect", selection: $filterWidth) {
            Text("Raw samples").tag(1)
            Text("5 sample average").tag(5)
            Text("11 sample average").tag(11)
            Text("21 sample average").tag(21)
        }.fixedSize()
    }

    private func metrics(_ result: SignalAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(result.candidates.count) candidates · \(result.qualifiedPulses) qualified pulses · \(result.adcErrors) ADC errors")
                .font(.callout.monospacedDigit())
            Text(String(format: "Baseline %.2f · noise σ %.2f · baseline RMS %.2f · threshold %.2f codes",
                        result.baselineCodes, result.robustNoiseCodes, result.baselineRMSCodes, result.thresholdCodes))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Processing version \(result.algorithmVersion) · \(result.validSamples) valid samples · \(result.qualificationAvailable ? "Calibration context matched" : "Diagnostic processing")")
                .font(.caption).foregroundStyle(.secondary)
        }.textSelection(.enabled)
    }
}

private struct AnalysisPlot: View {
    let title: String
    let points: [AnalysisPoint]
    let xUnit: String
    let yUnit: String
    var bars = false
    var maximumContinuousGap: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            if points.isEmpty {
                Text("No valid data for this plot.").font(.caption).foregroundStyle(.secondary).frame(height: 75)
            } else {
                let lowX = points.map(\.x).min() ?? 0, highX = points.map(\.x).max() ?? 1
                let minimum = points.map(\.y).min() ?? 0, maximum = points.map(\.y).max() ?? 1
                let lowY = bars ? 0 : (minimum == maximum ? minimum - 1 : minimum)
                let highY = maximum == lowY ? maximum + 1 : (minimum == maximum && !bars ? maximum + 1 : maximum)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing) {
                        Text(highY.formatted(.number.precision(.fractionLength(0...2))))
                        Spacer()
                        Text(lowY.formatted(.number.precision(.fractionLength(0...2))))
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, height: 110)
                    Canvas { context, size in
                        let xSpan = max(highX - lowX, 1e-12), ySpan = max(highY - lowY, 1e-12)
                        var path = Path()
                        for (index, point) in points.enumerated() {
                            let x = (point.x - lowX) / xSpan * max(0, size.width - 8) + 4
                            let y = size.height - 3 - (point.y - lowY) / ySpan * max(0, size.height - 6)
                            if bars {
                                let width = max(1, (size.width - 8) / Double(points.count) * 0.8)
                                path.addRect(CGRect(x: x - width / 2, y: y, width: width, height: size.height - y))
                            } else if index == 0 || maximumContinuousGap.map({ point.x - points[index - 1].x > $0 }) == true {
                                path.move(to: CGPoint(x: x, y: y))
                            }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        if bars { context.fill(path, with: .color(.accentColor.opacity(0.7))) }
                        else { context.stroke(path, with: .color(.accentColor), lineWidth: 1) }
                    }.frame(height: 110)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("\(title), \(points.count) points, \(yUnit)")
                }
                HStack {
                    Text(lowX.formatted(.number.precision(.significantDigits(3))))
                    Spacer()
                    Text(xUnit)
                    Spacer()
                    Text(highX.formatted(.number.precision(.significantDigits(3))))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(yUnit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FilterInspectionPlot: View {
    let samples: [UInt16]
    let filtered: [Double?]
    let width: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Raw and filtered inspection").font(.subheadline.weight(.semibold))
            Canvas { context, size in
                let valid = samples.filter { $0 & 0x8000 == 0 }.map { Double($0 & 0xfff) }
                let low = (valid.min() ?? 0) - 1, high = (valid.max() ?? 1) + 1
                let columns = min(samples.count, max(1, Int(size.width)))
                guard columns > 0 else { return }
                for isFiltered in [false, true] {
                    var trace = Path()
                    for column in 0..<columns {
                        let first = column * samples.count / columns, end = (column + 1) * samples.count / columns
                        var minimum = Double.infinity, maximum = -Double.infinity
                        for index in first..<end {
                            let value = isFiltered ? (index < filtered.count ? filtered[index] : nil) : (samples[index] & 0x8000 == 0 ? Double(samples[index] & 0xfff) : nil)
                            if let value { minimum = min(minimum, value); maximum = max(maximum, value) }
                        }
                        guard minimum.isFinite else { continue }
                        let x = Double(column) / Double(max(1, columns - 1)) * size.width
                        let y1 = size.height - (minimum - low) / (high - low) * size.height
                        let y2 = size.height - (maximum - low) / (high - low) * size.height
                        trace.move(to: CGPoint(x: max(0, x - 0.25), y: y1))
                        trace.addLine(to: CGPoint(x: min(size.width, x + 0.25), y: y2))
                    }
                    context.stroke(trace, with: .color(isFiltered ? .orange : .accentColor.opacity(0.65)), lineWidth: 1)
                }
            }.frame(height: 130)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Raw ADC codes in blue and \(width) sample moving average in orange")
            Text("Blue shows raw ADC codes. Orange shows the moving average. Horizontal position is the sample index across the full window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
