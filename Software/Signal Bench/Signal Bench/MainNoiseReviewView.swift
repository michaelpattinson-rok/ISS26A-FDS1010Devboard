import Charts
import SwiftUI

struct MainNoiseReviewRequest: Identifiable {
    let id = UUID()
    let context: MainNoiseReviewContext
    let runs: [RunArchive]
    let selectedCapture: CaptureRecord?
    let criteria: MainPulseCriteria

    init(context: MainNoiseReviewContext, runs: [RunArchive], selectedCapture: CaptureRecord? = nil, criteria: MainPulseCriteria) {
        self.context = context
        self.runs = runs
        self.selectedCapture = selectedCapture
        self.criteria = criteria
    }
}

nonisolated struct MainNoiseReviewResult: Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        case run(UUID)
        case capture(String)
    }

    let id: Source
    let label: String
    let statistics: MainNoiseSummary
    let matchesByWindow: [String: Int]
    let thresholdRange: ClosedRange<Double>?
    let skippedWindows: Int
    let cappedWindows: Int
    let firstReadError: String?
    let sampledSeconds: Double
    let recordedWindows: Int

    var matchCount: Int { matchesByWindow.values.reduce(0, +) }

    static func inspect(
        _ id: Source, label: String, summaries: [CaptureRecord], context: MainNoiseReviewContext,
        criteria: MainPulseCriteria, recordedWindows: Int
    ) throws -> Self {
        var matches: [String: Int] = [:]
        var minThreshold = Double.infinity
        var maxThreshold = 0.0
        var skipped = 0
        var capped = 0
        var sampled = 0.0
        var firstError: String?
        for summary in summaries {
            try Task.checkCancellation()
            do {
                let record = try context.loadRecord(summary)
                if let rate = record.metadata["sample_hz"].flatMap(Double.init), rate.isFinite, rate > 0 {
                    sampled += Double(record.samples.count) / rate
                }
                let analysis = try MainNoiseAnalysis.evaluate(record, criteria: criteria)
                guard analysis.eligibleForMatches else {
                    skipped += 1
                    continue
                }
                matches[summary.id] = analysis.matchCount
                minThreshold = min(minThreshold, analysis.thresholdCodes)
                maxThreshold = max(maxThreshold, analysis.thresholdCodes)
                if analysis.candidateDetailsTruncated { capped += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return Self(id: id, label: label, statistics: MainNoiseAnalysis.summarize(summaries),
                    matchesByWindow: matches, thresholdRange: minThreshold <= maxThreshold ? minThreshold...maxThreshold : nil,
                    skippedWindows: skipped, cappedWindows: capped, firstReadError: firstError, sampledSeconds: sampled,
                    recordedWindows: max(recordedWindows, summaries.count))
    }
}

struct MainNoiseReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let request: MainNoiseReviewRequest
    let openCapture: (String) -> Void

    @State private var primary: MainNoiseReviewResult.Source?
    @State private var comparison: UUID?
    @State private var criteria: MainPulseCriteria
    @State private var results: [MainNoiseReviewResult] = []
    @State private var analysisTask: Task<Void, Never>?
    @State private var issue: String?
    @State private var showCriteria = true
    @State private var revision = UUID()

    init(request: MainNoiseReviewRequest, openCapture: @escaping (String) -> Void) {
        self.request = request
        self.openCapture = openCapture
        let newest = request.runs.first
        _primary = State(initialValue: request.selectedCapture.map { .capture($0.id) } ?? newest.map { .run($0.id) })
        _criteria = State(initialValue: request.selectedCapture.flatMap { MainObservationOptions(metadata: $0.metadata)?.criteria }
                          ?? newest?.mainObservationOptions?.criteria ?? request.criteria)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Noise Runs").font(.title2.weight(.semibold))
                    Text("Compare saved noise over time and try pulse criteria on the same raw samples.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if primary == nil {
                        ContentUnavailableView("No saved Main runs", systemImage: "waveform.path",
                                               description: Text("Start a Background run in Main. Its saved windows will be available here even if quiet calibration fails."))
                    } else {
                        runPickers
                        DisclosureGroup("Pulse criteria for this review", isExpanded: $showCriteria) {
                            MainPulseCriteriaEditor(criteria: $criteria).padding(.top, 8)
                        }
                        HStack {
                            Button("Analyze Saved Data", action: analyze)
                                .buttonStyle(.borderedProminent)
                                .disabled(!criteria.isValid || analysisTask != nil)
                            if analysisTask != nil {
                                ProgressView().controlSize(.small).accessibilityLabel("Reading saved waveforms")
                                Button("Cancel Analysis", action: clearAnalysis)
                            }
                        }
                        if let issue {
                            Label(issue, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !results.isEmpty {
                            Divider()
                            MainNoiseReportView(results: results, warnings: comparisonWarnings) { recordID in
                                openCapture(recordID)
                                dismiss()
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 540, idealWidth: 690, minHeight: 470, idealHeight: 690)
        .onChange(of: primary) { _, value in
            if case .run(let id) = value, id == comparison { comparison = nil }
            if case .capture = value { comparison = nil }
            clearAnalysis()
        }
        .onChange(of: comparison) { _, _ in clearAnalysis() }
        .onChange(of: criteria) { _, _ in clearAnalysis() }
        .onDisappear(perform: clearAnalysis)
    }

    private var runPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Saved data", selection: $primary) {
                if let capture = request.selectedCapture {
                    Text("Selected capture · \(capture.capturedAt.formatted(date: .omitted, time: .standard))")
                        .tag(MainNoiseReviewResult.Source?.some(.capture(capture.id)))
                }
                ForEach(request.runs) { run in
                    Text(runLabel(run)).tag(MainNoiseReviewResult.Source?.some(.run(run.id)))
                }
            }
            if case .run(let id) = primary, request.runs.count > 1 {
                Picker("Compare with", selection: $comparison) {
                    Text("None").tag(UUID?.none)
                    ForEach(request.runs.filter { $0.id != id }) { run in
                        Text(runLabel(run)).tag(UUID?.some(run.id))
                    }
                }
            }
            if case .run(let id) = primary,
               let archived = request.runs.first(where: { $0.id == id })?.mainObservationOptions?.criteria,
               archived != criteria {
                Button("Use Criteria Saved with Run") { criteria = archived }
            }
        }
    }

    private func runLabel(_ run: RunArchive) -> String {
        let detector = run.mainObservationOptions?.condition.label ?? "Detector setup unrecorded"
        return "\(detector) · \(run.tag.capitalized) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var comparisonWarnings: [String] {
        guard case .run(let id) = primary,
              let first = request.runs.first(where: { $0.id == id }),
              let second = request.runs.first(where: { $0.id == comparison }) else { return [] }
        return MainNoiseAnalysis.comparisonWarnings(first, second)
    }

    private func clearAnalysis() {
        revision = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        results = []
        issue = nil
    }

    private func analyze() {
        guard let primary, criteria.isValid else { return }
        clearAnalysis()
        let token = revision
        let context = request.context
        let chosenCriteria = criteria
        let chosenRuns = request.runs
        let selected = request.selectedCapture
        let runIDs = [comparison].compactMap { $0 }
        let work: [(MainNoiseReviewResult.Source, String, RunArchive?, CaptureRecord?)] =
            ([primary] + runIDs.map(MainNoiseReviewResult.Source.run)).compactMap { source in
                switch source {
                case .run(let id):
                    guard let run = chosenRuns.first(where: { $0.id == id }) else { return nil }
                    return (source, runLabel(run), run, nil)
                case .capture(let id):
                    guard let selected, selected.id == id else { return nil }
                    return (source, "Selected capture", nil, selected)
                }
            }

        analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try work.map { source, label, run, selected in
                    try Task.checkCancellation()
                    if let run {
                        return try MainNoiseReviewResult.inspect(source, label: label, summaries: context.recordSummaries(for: run),
                                                               context: context, criteria: chosenCriteria, recordedWindows: run.completed)
                    }
                    guard let selected else { throw StorageError.noData }
                    return try MainNoiseReviewResult.inspect(source, label: label, summaries: [selected], context: context,
                                                           criteria: chosenCriteria, recordedWindows: 1)
                }
            }
            do {
                let report = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard token == revision else { return }
                results = report
            } catch {
                guard token == revision else { return }
                issue = error.localizedDescription
            }
            analysisTask = nil
        }
    }
}

struct MainNoiseReportView: View {
    enum Metric: String, CaseIterable {
        case noise = "Noise"
        case baseline = "Baseline"
        case drift = "Tail shift"
        case matches = "Pulse matches"

        var unit: String { self == .matches ? "Matches per window" : "ADC codes" }

        func value(_ point: MainNoisePoint, in result: MainNoiseReviewResult) -> Double? {
            switch self {
            case .noise: point.noiseSigmaCodes
            case .baseline: point.baselineCodes
            case .drift: point.tailShiftCodes
            case .matches: result.matchesByWindow[point.id].map(Double.init)
            }
        }
    }

    let results: [MainNoiseReviewResult]
    let warnings: [String]
    let openCapture: (String) -> Void
    @State private var metric: Metric = .noise

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Noise over time").font(.headline)
            Text("Each dot is one saved window. Time starts at the first window of each run and includes gaps. It is approximate across Pico restarts.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Trend", selection: $metric) {
                ForEach(Metric.allCases, id: \.self) { metric in Text(metric.rawValue).tag(metric) }
            }.pickerStyle(.segmented)
            if results.contains(where: { result in result.statistics.points.contains { metric.value($0, in: result) != nil } }) {
                Chart {
                    ForEach(results) { result in
                        ForEach(result.statistics.points) { point in
                            if let value = metric.value(point, in: result) {
                                PointMark(x: .value("Seconds since first window", point.elapsedSeconds), y: .value(metric.unit, value))
                                    .foregroundStyle(by: .value("Run", seriesLabel(result)))
                                    .symbol(by: .value("Run", seriesLabel(result)))
                                    .symbolSize(18)
                            }
                        }
                    }
                }
                .chartXScale(domain: 0...max(1, results.compactMap { $0.statistics.points.last?.elapsedSeconds }.max() ?? 0))
                .chartYScale(domain: .automatic(includesZero: metric == .matches))
                .chartXAxisLabel("Seconds since first window")
                .chartYAxisLabel(metric.unit)
                .frame(height: 205)
                .accessibilityLabel("\(metric.rawValue) by capture time")
            } else {
                Text("No saved windows with this trend.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 65)
            }
            ForEach(results) { result in summary(result) }
            Text("Pulse matches follow the saved polarity and the selected amplitude and duration. Noise and drift flags stay visible. Acquisition faults, ADC errors and clipped windows are excluded. Matches are provisional and cannot establish radiation or count rate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func seriesLabel(_ result: MainNoiseReviewResult) -> String {
        results.count == 1 ? "Saved data" : (result.id == results.first?.id ? "First run" : "Comparison")
    }

    private func summary(_ result: MainNoiseReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(results.count > 1 ? "\(seriesLabel(result)) · \(result.label)" : result.label).font(.headline)
            let stats = result.statistics
            if !result.matchesByWindow.isEmpty {
                LabeledContent("Pulse matches", value: result.cappedWindows > 0
                               ? "At least \(result.matchCount.formatted())" : result.matchCount.formatted())
            } else {
                LabeledContent("Pulse matches", value: "Unavailable")
            }
            LabeledContent("Noise median / 95th percentile",
                           value: "\(format(stats.medianNoiseCodes)) / \(format(stats.percentile95NoiseCodes)) codes")
            LabeledContent("Baseline range", value: range(stats.baselineRangeCodes))
            LabeledContent("Tail shift range", value: range(stats.tailShiftRangeCodes))
            LabeledContent("Applied threshold", value: range(result.thresholdRange))
            LabeledContent("Verified sampled time", value: "\(format(result.sampledSeconds)) s nominal")
            Text("\(stats.points.count.formatted()) windows available · \(stats.flaggedWindows.formatted()) flagged · \(result.skippedWindows.formatted()) excluded from matching")
                .font(.caption).foregroundStyle(.secondary)
            if stats.clippedWindows > 0 || stats.adcErrorWindows > 0 {
                Text("\(stats.clippedWindows.formatted()) clipped windows · \(stats.adcErrorWindows.formatted()) windows with ADC errors")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.recordedWindows > stats.points.count || stats.missingWindows > 0 {
                Text("Some records or recorded diagnostics are unavailable. The review covers the windows it could read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.cappedWindows > 0 {
                Text("\(result.cappedWindows.formatted()) windows exceeded the estimator’s candidate detail limit. Their matches are a lower bound.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = result.firstReadError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let point = stats.points.max(by: { ($0.noiseSigmaCodes ?? -1) < ($1.noiseSigmaCodes ?? -1) }) {
                Button("Inspect Noisiest Waveform") { openCapture(point.id) }
            }
        }
        .font(.callout).padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func format(_ number: Double?) -> String {
        number.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Unavailable"
    }

    private func range(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "Unavailable" }
        return range.lowerBound == range.upperBound ? "\(format(range.lowerBound)) codes"
            : "\(format(range.lowerBound)) to \(format(range.upperBound)) codes"
    }
}
