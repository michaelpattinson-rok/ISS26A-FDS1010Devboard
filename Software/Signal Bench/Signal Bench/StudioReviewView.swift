import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioProposalList: View {
    let items: [ReviewProposal.ListItem]
    let issue: String?
    let busy: Bool
    let open: (UUID) -> Void
    let refresh: () -> Void
    let close: (() -> Void)?
    @State private var expanded: Bool
    @State private var limit = 12

    init(items: [ReviewProposal.ListItem], issue: String?, busy: Bool, expanded: Bool = false,
         open: @escaping (UUID) -> Void, refresh: @escaping () -> Void, close: (() -> Void)?) {
        self.items = items
        self.issue = issue
        self.busy = busy
        self.open = open
        self.refresh = refresh
        self.close = close
        _expanded = State(initialValue: expanded)
    }

    private func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...7)))) s"
    }

    var body: some View {
        DisclosureGroup("Proposed Reviews", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                if items.isEmpty {
                    Text("Stage a review from Ask Local AI to find it here.").foregroundStyle(.secondary)
                } else {
                    ForEach(items.prefix(limit)) { item in
                        Button {
                            open(item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Label(item.selection == nil ? "Unavailable review" : item.isComparison ? "Filter comparison" : "Filter preview",
                                          systemImage: "doc.text.magnifyingglass")
                                    if let created = item.created {
                                        Spacer()
                                        Text(created.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let range = item.selection, let filters = item.filters {
                                    Text("\(seconds(range.lower)) to \(seconds(range.upper)) · \(filters)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered).disabled(busy)
                    }
                    if items.count > limit {
                        Button("Show Older Reviews") { limit += 12 }
                            .disabled(busy)
                    }
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Refresh Proposals", action: refresh)
                    if let close { Button("Close Proposed Review", action: close) }
                }.disabled(busy)
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }
}

struct StudioReviewView: View {
    enum Tool: String, CaseIterable { case range = "Range Review", filters = "Filters", exclusions = "Exclusions", labels = "Labels", fixture = "Fixture Fit" }
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let initial: StreamSelection
    var saved: SavedReview?
    var fixtureReport: StreamAnalysisManifest?
    let savedRange: StudioRangeResult?
    let duration: Double
    let exclusionJob: ProjectJob?
    let exclusionProposal: JobExclusionProposal?
    let openSample: (StreamMatchLocation) -> Void
    let openTime: (Double) -> Void
    let didSave: (StreamAnalysisManifest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tool = Tool.filters
    @State private var low: Double = 0
    @State private var high: Double = 1
    @State private var settings = ReviewSettings()
    @State private var manual: [ReviewInterval] = []
    @State private var preview: ReviewResult?
    @State private var reference: StreamFixtureReference?
    @State private var comparison: (FixtureComparison, FixtureComparison)?
    @State private var templates: [FixtureTemplate] = []
    @State private var error: String?
    @State private var category = RegionLabel.unknown
    @State private var labelReason = ""
    @State private var contextSamples = 500
    @State private var labels: [TrainingLabel] = []
    @State private var partition = DatasetGroup.review
    @State private var maskNote = ""
    @State private var outputName = ""
    @State private var templateChoice: UUID?
    @State private var showExport: Export?
    @State private var loaded = false
    @State private var proposedReviews: [ReviewProposal.ListItem] = []
    @State private var sampleInspection: StreamMatchLocation?
    @State private var proposalIssue: String?
    @State private var proposal: ReviewProposal?
    @State private var proposedResult: StudioRangeResult?
    @State private var proposedReference: StudioRangeResult?
    @State private var proposedChanges: [ReviewDecisionChange] = []
    @State private var proposedChangeCount = 0
    @State private var rangePanelID = UUID()

    init(bench: StreamingBench, reader: StreamRangeReader, initial: StreamSelection, saved: SavedReview?,
         initialTool: Tool = .filters, fixtureReport: StreamAnalysisManifest? = nil,
         savedRange: StudioRangeResult? = nil, duration: Double = 0,
         exclusionJob: ProjectJob? = nil, exclusionProposal: JobExclusionProposal? = nil,
         openSample: @escaping (StreamMatchLocation) -> Void = { _ in },
         openTime: @escaping (Double) -> Void = { _ in }, didSave: @escaping (StreamAnalysisManifest) -> Void) {
        self.bench = bench
        self.reader = reader
        self.initial = initial
        self.saved = saved
        self.fixtureReport = fixtureReport
        self.savedRange = savedRange
        self.duration = duration
        self.exclusionJob = exclusionJob
        self.exclusionProposal = exclusionProposal
        self.openSample = openSample
        self.openTime = openTime
        self.didSave = didSave
        _tool = State(initialValue: initialTool)
    }

    private enum Export: String, Identifiable {
        case clean = "Export Cleaned Samples", training = "Export Training Data"
        var id: Self { self }
    }
    private var selection: StreamSelection { .init(lower: low, upper: high) }
    private var selectionOK: Bool { selection.valid && high - low <= ReviewInput.maximumSeconds }
    private var group: UUID { reader.run.settings.bench?.sequence ?? reader.run.id }
    private var current: ReviewResult? {
        guard let preview, preview.selection == selection, preview.settings == settings, preview.manual == manual else { return nil }
        return preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Post Processing Studio").font(.title2.weight(.semibold))
                    Text(reader.run.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(bench.busy)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if let exclusionJob, let exclusionProposal {
                        JobExclusionsReview(bench: bench, reader: reader, job: exclusionJob, proposal: exclusionProposal,
                                            openSample: { sampleInspection = $0 })
                    }
                    rangeControls
                    if isDetailTool, let preview { plot(preview) }
                    else if isDetailTool {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path")
                            Text(bench.busy ? "Reading waveform…" : "Choose up to three seconds and select Preview.")
                        }.font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Picker("Review tools", selection: $tool) {
                        ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    switch tool {
                    case .range:
                        StudioRangePanel(bench: bench, reader: reader, selection: selection, saved: savedRange?.config,
                                         openSample: { sampleInspection = $0 }, openTime: openTime, didSave: didSave,
                                         initialPreview: proposedResult ?? savedRange, proposal: proposal,
                                         initialReference: proposedReference, decisionChanges: proposedChanges,
                                         decisionChangeCount: proposedChangeCount, duration: duration,
                                         moveRange: { center in
                                             let width = high - low
                                             low = max(0, center - width / 2)
                                             high = min(duration, low + width)
                                         })
                            .id(rangePanelID)
                        StudioLocalAI(settings: bench.localAI, bench: bench, reader: reader, selection: selection,
                                      openSample: { sampleInspection = $0 }, didStage: refreshProposals)
                        if reader.run.settings.unoCandidates != nil {
                            UnoCandidateStudio(bench: bench, reader: reader, selection: selection,
                                               openSample: { sampleInspection = $0 }, didSave: didSave)
                        }
                        proposals
                    case .filters: filters
                    case .exclusions: exclusions
                    case .labels: labelTools
                    case .fixture:
                        FixtureStudyPanel(bench: bench, reader: reader, selection: selection, baseline: settings,
                                          saved: fixtureReport, openSample: openSample, didSave: didSave)
                        if reader.run.settings.board == .unoR4, reader.run.settings.bench?.step == .fixture {
                            UnoCandidateStudio(bench: bench, reader: reader, selection: selection,
                                               openSample: { sampleInspection = $0 }, didSave: didSave)
                        }
                    }
                }.padding(16)
            }
            if isDetailTool || bench.operation != nil || error != nil || bench.notice != nil {
                Divider()
                HStack(spacing: 10) {
                    if let work = bench.operation { ProgressView().controlSize(.small); Text(work).font(.callout) }
                    else if let message = error ?? bench.notice {
                        Label(message, systemImage: "info.circle").font(.callout).textSelection(.enabled)
                    }
                    Spacer()
                    if bench.busy { Button("Cancel Work") { bench.cancelWork() } }
                    if isDetailTool {
                        Button("Save Review", action: save).disabled(bench.busy || current == nil)
                    }
                }.padding(12)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 760, minHeight: 400, idealHeight: 650, maxHeight: 760)
        .onAppear { initialize() }
        .onChange(of: tool) { _, currentTool in
            if currentTool != .range && currentTool != .fixture, preview == nil { refresh() }
        }
        .sheet(item: $sampleInspection) { location in
            StudioSampleInspector(reader: reader, location: location)
        }
        .sheet(item: $showExport) { export in
            StreamMetadataSheet(title: export.rawValue, name: outputName, description: nil, actionTitle: "Choose Location…",
                                dismissAfterAction: false) { name, _ in
                exportFiles(export, name: name)
            }
        }
    }

    private var proposals: some View {
        let closeAction: (() -> Void)? = proposal == nil ? nil : { closeProposal() }
        return StudioProposalList(items: proposedReviews, issue: proposalIssue, busy: bench.busy,
                                  open: openProposal, refresh: refreshProposals, close: closeAction)
            .task { await loadProposals() }
    }

    private func loadProposals() async {
        let input = reader
        let scan = Task.detached(priority: .utility) { try ReviewProposal.summaries(input) }
        do { proposedReviews = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() } }
        catch { if !Task.isCancelled { proposalIssue = error.localizedDescription } }
    }

    private func refreshProposals() {
        let input = reader
        proposalIssue = nil
        bench.perform("Looking for proposed reviews") { try ReviewProposal.summaries(input) } completion: {
            proposedReviews = $0
        }
    }

    private func openProposal(_ id: UUID) {
        let input = reader
        proposalIssue = nil
        bench.perform("Verifying proposed review") {
            do {
                let proposal = try ReviewProposal.load(id, reader: input)
                var changes: [ReviewDecisionChange] = []
                var count = 0
                let result = try proposal.review(input) { item in
                    if changes.count < 50 { changes.append(item) }
                    count += 1
                }
                return ProposalLoad.ready(proposal, result.primary, result.reference, changes, count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return ProposalLoad.unavailable(error.localizedDescription)
            }
        } completion: { result in
            switch result {
            case .ready(let item, let primary, let reference, let changes, let count):
                proposal = item
                proposedResult = primary
                proposedReference = reference
                proposedChanges = changes
                proposedChangeCount = count
                low = item.config.selection.lower
                high = item.config.selection.upper
                rangePanelID = UUID()
            case .unavailable(let message):
                closeProposal()
                proposalIssue = message
            }
        }
    }

    private enum ProposalLoad: Sendable {
        case ready(ReviewProposal, StudioRangeResult, StudioRangeResult?, [ReviewDecisionChange], Int)
        case unavailable(String)
    }

    private func closeProposal() {
        proposal = nil
        proposedResult = nil
        proposedReference = nil
        proposedChanges = []
        proposedChangeCount = 0
        rangePanelID = UUID()
    }

    private var isDetailTool: Bool { tool != .range && tool != .fixture }

    private var rangeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { rangeFields; WaveformFPSControl(fps: $bench.reviewFPS); Spacer(); rangeActions }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading) {
                HStack { rangeFields; rangeActions }
                WaveformFPSControl(fps: $bench.reviewFPS)
            }
        }
    }

    private var rangeFields: some View {
        HStack {
            Text("From")
            TextField("From seconds", value: $low, format: .number.precision(.fractionLength(0...6))).frame(width: 92)
            Text("to")
            TextField("To seconds", value: $high, format: .number.precision(.fractionLength(0...6))).frame(width: 92)
            Text("s").foregroundStyle(.secondary)
        }.fixedSize()
    }

    @ViewBuilder private var rangeActions: some View {
            if tool == .range, duration > 0 {
                Button("Full Run") { low = 0; high = duration }.disabled(bench.busy)
            }
            if tool != .range, high - low > ReviewInput.maximumSeconds {
                Button("First 3 Seconds") { high = min(high, low + ReviewInput.maximumSeconds) }.disabled(bench.busy)
            }
            if isDetailTool {
                Button("Preview", action: refresh).buttonStyle(.borderedProminent)
                    .disabled(!selectionOK || !settings.valid || bench.busy)
            }
    }

    private func plot(_ result: ReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if current == nil {
                Text("Showing \(seconds(result.selection.lower)) to \(seconds(result.selection.upper)). \(bench.busy ? "Updating preview…" : "Select Preview to apply changes.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
            if bench.waveformStyle == .points {
                DotDensityControl(percent: $bench.dotDensity)
                Text("Averaged dots · One mean per displayed bin").font(.caption).foregroundStyle(.secondary)
            }
            ReviewTrace(result: result, board: reader.run.settings.board, fps: bench.reviewFPS, style: bench.waveformStyle,
                        density: bench.dotDensity, scale: bench.waveformScale)
            WaveformPositionControl(bounds: .init(lower: 0, upper: duration), selection: selection) { center in
                let width = high - low
                low = max(0, center - width / 2)
                high = min(duration, low + width)
            }
            HStack(spacing: 14) {
                Label("Raw", systemImage: "line.diagonal").foregroundStyle(.secondary)
                Label("Processed", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("Excluded", systemImage: "rectangle.fill").foregroundStyle(.orange)
                Spacer()
                Text("ADC codes").foregroundStyle(.secondary)
            }.font(.caption)
            Text("\(seconds(result.sampledSeconds)) sampled · \(seconds(result.excludedSeconds)) excluded · \(seconds(result.processedUsableSeconds)) usable after processing")
                .font(.callout)
            if result.filterSettling > 0 {
                Text("Filter settling · \(seconds(result.settlingSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.hasProcessedSamples {
                Label("No eligible samples for processed Pulse Matches.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.intervals.filter({ $0.action == .missing }).isEmpty {
                Text("Missing samples remain a gap. Time between disconnected segments is unknown.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...5))) + " s"
    }

    private func seconds(_ samples: UInt64, _ rate: Int) -> String {
        seconds(Double(samples) / Double(rate))
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Correct local baseline and drift", isOn: $settings.drift)
                StudioHelp(title: "Baseline and drift", detail: "Tracks the median of nearby ADC samples and interpolates between blocks. Review the overlay for pulse shape changes.", assets: ["ReviewDrift"], illustration: true)
            }
            HStack(spacing: 10) {
                Toggle("Suppress 60 Hz", isOn: $settings.notch60)
                StudioHelp(title: "60 Hz suppression", detail: "Reduces energy near 60 Hz. Filtering starts again at each acquisition gap and after invalid data.", assets: ["ReviewNotch"], illustration: true)
                Spacer().frame(width: 22)
                Toggle("Suppress 120 Hz", isOn: $settings.notch120)
                StudioHelp(title: "120 Hz suppression", detail: "Reduces the second harmonic near 120 Hz. Settling samples are skipped in the processed trace.", assets: ["ReviewNotch"], illustration: true)
            }
            HStack {
                Picker("Pulse template", selection: $templateChoice) {
                    Text("None").tag(UUID?.none)
                    ForEach(templates) { item in Text("\(item.gain) · \(item.polarity.rawValue) · \(item.id.uuidString.prefix(6))").tag(Optional(item.id)) }
                }
                StudioHelp(title: "Measured pulse template", detail: "Compares pulse shape against a selected fixture waveform with an independent timing reference. Gain, polarity and filtering must match.", assets: ["ReviewTemplate"], illustration: true)
            }.onChange(of: templateChoice) { _, id in settings.template = templates.first { $0.id == id } }
            if settings.template != nil {
                HStack {
                    ProfileNumberField("Minimum correlation", value: $settings.correlation, unit: "0 to 1")
                    StudioHelp(title: "Template correlation", detail: "Higher values require a closer shape match. Check missed reference pulses and compare the same range with the template off.", assets: ["ReviewTemplate"], illustration: true)
                }
            }
            if reader.run.settings.bench?.step == .fixture {
                HStack {
                    Button("Import Fixture Timing…", action: importTiming).disabled(bench.busy || reference != nil)
                    Button("Make Template from Range", action: createTemplate).disabled(bench.busy || reference == nil || !selectionOK || !settings.valid)
                    StudioHelp(title: "Fixture timing", detail: "Import the versioned scope timing reference for this stream. It records the independent clock alignment and its uncertainty. Power off before fixture wiring changes.", assets: ["ReviewFixture", "SetupDetectorBoard"], illustration: false)
                }
                if let reference {
                    Text("Timing source: \(reference.source)").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Pulse criteria") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Polarity", selection: $settings.polarity) {
                            ForEach(ProfilePulseRules.Polarity.allCases) { Text($0.rawValue).tag($0) }
                        }
                        StudioHelp(title: "Pulse criteria", detail: "Compare the same polarity, height, width and separation on both traces. Edge crossings and overlapping candidates require review.", assets: ["ReviewTemplate"], illustration: true)
                    }
                    ProfileNumberField("Minimum height", value: $settings.height, unit: "ADC codes")
                    ProfileSampleField("Minimum width", samples: $settings.minWidth, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
                    ProfileSampleField("Maximum width", samples: $settings.maxWidth, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
                    ProfileSampleField("Separation", samples: $settings.separation, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
                }.padding(.top, 8)
            }
            if settings.ruleVersion < ReviewSettings.version {
                HStack {
                    Text("Using saved review rules version \(settings.ruleVersion)").font(.caption).foregroundStyle(.secondary)
                    Button("Use Current Rules") { settings.algorithmVersion = nil }.disabled(bench.busy)
                }
            }
            if let current { pulseResults(current) }
        }
    }

    private func pulseResults(_ result: ReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(result.hasProcessedSamples
                 ? "\(result.rawCount.formatted()) raw · \(result.processedCount.formatted()) processed Pulse Matches"
                 : "\(result.rawCount.formatted()) raw Pulse Matches")
                .font(.headline)
            Text(result.overflow ? "Candidate limit reached. Results are incomplete." : "Pulse Matches are diagnostic until verified against an independent fixture.")
                .font(.caption).foregroundStyle(.secondary)
            if let (raw, processed) = comparison {
                Text("Fixture references").font(.subheadline.weight(.semibold))
                Text("Raw \(raw.matched) hits, \(raw.missed) in-coverage misses, \(raw.extraMatches) extras. Processed \(processed.matched) hits, \(processed.missed) misses, \(processed.extraMatches) extras.")
                Text("Processed \(processed.missingCoverage) outside coverage and \(processed.ambiguous) timing or matching ambiguities.")
                    .foregroundStyle(.secondary)
                if result.settings.template?.run == reader.run.id {
                    Text("This run supplied the template. Use a different fixture run to test it.").foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                pulseList("Raw peaks", items: result.raw)
                if result.hasProcessedSamples { pulseList("Processed peaks", items: result.processed) }
            }
        }
    }

    private func pulseList(_ title: String, items: [ReviewPulse]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            if items.isEmpty { Text("No candidates").foregroundStyle(.secondary) }
            ForEach(Array(items.prefix(10).enumerated()), id: \.offset) { _, pulse in
                Button { sampleInspection = .init(segment: pulse.range.segment, sample: pulse.peakIndex) } label: {
                    Text("\(pulse.peakTime.formatted(.number.precision(.fractionLength(6)))) s · \(Int(pulse.height.rounded())) codes · \((Double(pulse.width) * 1_000_000 / (reader.run.segments.first { $0.id == pulse.range.segment }?.configuredRate(reader.run.settings.nominalRate) ?? reader.run.settings.recordedRate)).formatted(.number.precision(.fractionLength(0...2)))) µs · \(pulse.decision)")
                    }.buttonStyle(.link)
            }
            if items.count > 10 { Text("Showing first 10. Save Review to retain all decisions.").foregroundStyle(.secondary) }
        }.font(.caption.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ADC errors, rail clipping and dropped samples").font(.subheadline.weight(.medium))
                StudioHelp(title: "ADC errors and missing samples", detail: "Invalid samples and clipping recovery stay excluded. Dropped samples leave a gap. Orange shading shows excluded samples.", assets: ["ReviewMask"], illustration: true)
            }
            HStack {
                Toggle("Exclude short, steep glitches", isOn: $settings.maskGlitches)
                StudioHelp(title: "Short glitches", detail: "Requires a fast rise and return within the width limit. A large amplitude by itself is a review flag.", assets: ["ReviewGlitch"], illustration: true)
            }
            ProfileSampleField("Maximum glitch width", samples: $settings.spikeWidth, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
            ProfileNumberField("Minimum glitch slope", value: $settings.spikeSlope, unit: "codes/sample")
            HStack {
                Toggle("Exclude abnormal noise bursts", isOn: $settings.maskNoise)
                StudioHelp(title: "Noise bursts", detail: "Checks robust noise over a short block. Leave this off to review detected bursts before masking them.", assets: ["ReviewNoise"], illustration: true)
            }
            ProfileNumberField("Noise limit", value: $settings.noiseLimit, unit: "ADC codes")
            HStack {
                ProfileNumberField("Review peaks above", value: $settings.reviewHeight, unit: "ADC codes")
                StudioHelp(title: "High peak review", detail: "Flags a tall peak of either polarity for inspection. Amplitude alone does not mask a region.", assets: ["ReviewGlitch"], illustration: true)
            }
            HStack {
                Text("Recovery padding")
                StudioHelp(title: "Recovery padding", detail: "Adds time around detected intervals within the same contiguous span. The exclusions file retains each reason and sample range.", assets: ["ReviewMask"], illustration: true)
            }
            ProfileSampleField("Before", samples: $settings.padBefore, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
            ProfileSampleField("After", samples: $settings.padAfter, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
            TextField("Reason for excluding the current range", text: $maskNote)
            HStack {
                Button("Exclude Range", action: excludeRange).disabled(current == nil || maskNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bench.busy)
                StudioHelp(title: "Manual exclusion", detail: "Set the From and To fields to the interval you want to exclude, preview it, and add a reason. Undo removes the most recent edit.", assets: ["ReviewMask"], illustration: true)
                Button("Undo Last Edit", action: undo).disabled(manual.isEmpty || bench.busy)
                Spacer()
                Button("Export Cleaned…") { outputName = "Cleaned " + reader.run.name; showExport = .clean }
                    .disabled(current == nil || bench.busy)
            }
            if let current {
                ForEach(Array(current.intervals.prefix(16).enumerated()), id: \.offset) { _, interval in
                    let range = interval.range
                    Text("\(interval.reason.rawValue) · \(range.first) to \(range.end) · \(interval.action.rawValue)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if current.intervals.count > 16 {
                    Text("Showing first 16 of \(current.intervals.count) intervals. Save or export to review all intervals.").font(.caption)
                }
            }
        }
    }

    private var labelTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Label selected range", selection: $category) {
                    ForEach(RegionLabel.allCases) { Text($0.rawValue).tag($0) }
                }
                StudioHelp(title: "Waveform labels", detail: "Use Unknown when you cannot identify a region. A known fixture pulse requires an independent timing reference that falls inside the range.", assets: ["ReviewLabel"], illustration: true)
            }
            TextField("Reason for label", text: $labelReason)
            HStack {
                Text("Context on each side")
                StudioHelp(title: "Context samples", detail: "Keeps nearby original samples before and after the labeled range. Context stops at an acquisition gap.", assets: ["ReviewLabel"], illustration: true)
                Spacer()
                TextField("Context samples", value: $contextSamples, format: .number.grouping(.never)).frame(width: 80)
                Text("samples").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker(reader.run.settings.bench == nil ? "Whole run group" : "Bench sequence group", selection: $partition) {
                    ForEach(DatasetGroup.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                StudioHelp(title: "Dataset grouping", detail: "All labels in the same run or linked bench sequence share a group. Unknown regions go to review. Keep the test group independent.", assets: ["ReviewGroups"], illustration: true)
                Button("Save Group", action: saveGroup).disabled(bench.busy)
            }
            HStack {
                Button("Save Label", action: label).disabled(!selectionOK || labelReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bench.busy)
                Spacer()
                Button("Export Training Data…") { outputName = "Training dataset"; showExport = .training }.disabled(bench.busy)
                StudioHelp(title: "Training exports", detail: "Exports per-group feature CSVs and original binary waveform windows with a manifest. Labels and model suggestions are kept separately.", assets: ["ReviewGroups"], illustration: true)
            }
            if !labels.isEmpty {
                Text("Labels in this run").font(.subheadline.weight(.semibold))
                ForEach(labels.prefix(20)) { item in
                    HStack {
                        Text(item.category.rawValue).fontWeight(.medium)
                        Text("· \(item.reason)").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Show Range") {
                            low = item.timelineStart + Double(item.event.first) / Double(item.nominalRate)
                            high = item.timelineStart + Double(item.event.end) / Double(item.nominalRate)
                            refresh()
                        }.disabled(bench.busy)
                    }.font(.caption)
                }
            }
            Text("Unknown labels stay in the review group. Local classifier evaluation needs labeled, independent training and test groups.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func initialize() {
        guard !loaded else { return }
        loaded = true
        let range = savedRange?.config.selection ?? saved?.selection ?? (fixtureReport?.analyzer == FixtureSelection.analyzer ? fixtureReport?.selection : nil) ?? initial
        low = range.lower
        high = tool == .range ? range.upper : min(range.upper, range.lower + ReviewInput.maximumSeconds)
        settings = saved?.settings ?? .init(profile: reader.run.settings.profile, sampleRate: Int(reader.run.settings.recordedRate.rounded()))
        manual = saved?.manual ?? []
        templateChoice = settings.template?.id
        do {
            templates = try FixtureEvidence.templates(reader.store)
            if let template = settings.template, !templates.contains(where: { $0.id == template.id }) { templates.append(template) }
            labels = try TrainingLabels.list(reader.store).filter { $0.run == reader.run.id }
            partition = try TrainingLabels.partition(reader.store, group: group)
            reference = try? FixtureEvidence.reference(reader).0
        } catch { self.error = error.localizedDescription }
        if error == nil, isDetailTool { refresh() }
    }

    private func refresh() {
        let range = selection, config = settings, edits = manual, reader = reader, reference = reference
        guard selectionOK, config.valid, !bench.busy else { return }
        error = nil
        bench.notice = nil
        comparison = nil
        bench.perform("Reviewing waveform") {
            let input = try ReviewInput.load(reader, selection: range)
            let output = try StudioReview.analyze(input, settings: config, manual: edits)
            let check = reference.map {
                (FixtureEvidence.compare($0, input: input, result: output, processed: false),
                 FixtureEvidence.compare($0, input: input, result: output, processed: true))
            }
            return (output, check)
        } completion: {
            preview = $0.0
            comparison = $0.1
        }
    }

    private func excludeRange() {
        let note = maskNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, current.sampled > 0, note.utf8.count <= 512, !note.isEmpty else { return }
        let items = reader.run.segments.compactMap { segment -> ReviewInterval? in
            let range = ReviewInput.indices(selection, segment: segment, rate: reader.run.settings.nominalRate)
            let end = min(segment.accountedSamples, range.upperBound)
            guard range.lowerBound < end else { return nil }
            return .init(range: .init(segment: segment.id, first: range.lowerBound, end: end), reason: .manual, action: .excluded, note: note)
        }
        guard items.count == 1, let item = items.first, manual.count < 256 else {
            error = "Choose one timing segment for a manual exclusion."
            return
        }
        manual.append(item)
        maskNote = ""
        refresh()
    }

    private func undo() {
        _ = manual.popLast()
        refresh()
    }

    private func save() {
        guard current != nil else { return }
        let reader = reader, selection = selection, settings = settings, edits = manual
        bench.perform("Saving waveform review") {
            try ReviewStorage.save(reader, selection: selection, settings: settings, manual: edits)
        } completion: { result in didSave(result); error = "Review saved." }
    }

    private func importTiming() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let acquired = file.startAccessingSecurityScopedResource()
        defer { if acquired { file.stopAccessingSecurityScopedResource() } }
        do {
            try FixtureEvidence.importReference(file, reader: reader)
            reference = try FixtureEvidence.reference(reader).0
            preview = nil
            comparison = nil
            error = "Independent timing reference saved."
        } catch { self.error = error.localizedDescription }
    }

    private func createTemplate() {
        let reader = reader, range = selection, config = settings
        bench.perform("Saving measured template") {
            try FixtureEvidence.createTemplate(reader, selection: range, settings: config)
        } completion: { template in
            templates.append(template)
            templateChoice = template.id
            error = "Template saved from the fixture waveform."
        }
    }

    private func label() {
        let reader = reader, range = selection, category = category, reason = labelReason, context = contextSamples
        bench.perform("Saving waveform label") {
            try TrainingLabels.add(reader, selection: range, category: category, reason: reason, context: context)
        } completion: { item in
            if !labels.contains(where: { $0.id == item.id }) { labels.insert(item, at: 0) }
            labelReason = ""
            error = "Label saved."
        }
    }

    private func saveGroup() {
        do { try TrainingLabels.assign(partition, project: reader.store, group: group); error = "Group saved." }
        catch { self.error = error.localizedDescription }
    }

    private func exportFiles(_ kind: Export, name: String) {
        if kind == .clean, current == nil { error = "Preview the current selection and exclusions before exporting."; return }
        let reader = reader, range = selection, config = settings, edits = manual
        bench.export(toFolderFor: reader.store, title: kind.rawValue, progress: "Writing export",
                     onSelection: { showExport = nil; error = nil }) { folder in
            switch kind {
            case .clean: try ReviewStorage.cleaned(reader, name: name, selection: range, settings: config, manual: edits, destination: folder)
            case .training: try TrainingLabels.export(reader.store, name: name, destination: folder)
            }
        }
    }
}

struct ReviewTrace: View {
    var result: ReviewResult
    var board: AcquisitionBoard = .picoW
    var fps = 30
    var style = WaveformStyle.envelope
    var density = 100.0
    var scale = WaveformScale.fit
    @State private var displayed: ReviewResult?
    @State private var rawMetal = false
    @State private var filteredMetal = false
    @State private var metalFailed = false
    @State private var rawDots: WaveformDots?
    @State private var filteredDots: WaveformDots?
    private struct RenderState: Equatable {
        let selection: StreamSelection
        let settings: ReviewSettings
        let manual: [ReviewInterval]
        let intervals: [ReviewInterval]
        let fps: Int
        let density: Double
        let style: WaveformStyle
    }

    private func limits(_ result: ReviewResult) -> ClosedRange<Double> {
        if scale == .full { return 0...Double(board.maxCode) }
        if let half = scale.baselineSpan {
            let codes = result.bins.reduce(into: (sum: 0.0, count: 0)) {
                $0.sum += $1.rawSum
                $0.count += $1.rawCount
            }
            let baseline = codes.count > 0 ? codes.sum / Double(codes.count) : 2048
            return (baseline - half)...(baseline + half)
        }
        let values = result.bins.flatMap { [$0.raw, $0.processed].compactMap { $0 } }
        return ((values.map(\.lowerBound).min() ?? 0) - 3)...((values.map(\.upperBound).max() ?? Double(board.maxCode)) + 3)
    }

    var body: some View {
        let result = displayed ?? result
        let axis = limits(result)
        ZStack {
            chart(result, axis: axis)
            if style == .points, !metalFailed, let renderer = WaveformMetal.shared {
                GeometryReader { geometry in
                    ZStack {
                        if let rawDots, !rawDots.values.isEmpty {
                            MetalWaveformLayer(renderer: renderer, dots: rawDots, range: axis,
                                onPreparing: { rawMetal = false }, onPresented: { _, _ in rawMetal = true },
                                onFailure: { metalFailed = true }, customTint: .init(0.5, 0.5, 0.5, 0.8))
                        }
                        if let filteredDots, !filteredDots.values.isEmpty {
                            MetalWaveformLayer(renderer: renderer, dots: filteredDots, range: axis,
                                onPreparing: { filteredMetal = false }, onPresented: { _, _ in filteredMetal = true },
                                onFailure: { metalFailed = true })
                        }
                    }
                    .frame(width: max(1, geometry.size.width - 50), height: max(1, geometry.size.height - 34))
                    .offset(x: 44, y: 10)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(height: 154)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Raw and processed waveform overlay with excluded intervals")
        .task(id: RenderState(selection: self.result.selection, settings: self.result.settings,
                              manual: self.result.manual, intervals: self.result.intervals, fps: fps,
                              density: density, style: style)) {
            try? await Task.sleep(for: .nanoseconds(1_000_000_000 / max(1, fps)))
            guard !Task.isCancelled else { return }
            displayed = self.result
            if style == .points {
                rawMetal = false
                filteredMetal = false
                rawDots = .averages(self.result.bins.map { $0.rawCount > 0 ? $0.rawSum / Double($0.rawCount) : nil }, percent: density)
                filteredDots = .averages(self.result.bins.map { $0.processedCount > 0 ? $0.processedSum / Double($0.processedCount) : nil }, percent: density)
            }
        }
    }

    private func chart(_ result: ReviewResult, axis: ClosedRange<Double>) -> some View {
        Canvas { context, size in
            let low = axis.lowerBound
            let high = axis.upperBound
            let width = size.width - 50
            let bottom = size.height - 24
            let top = 10.0
            func y(_ value: Double) -> Double { top + (high - value) / (high - low) * (bottom - top) }
            for row in 0...3 {
                let value = low + (high - low) * Double(row) / 3
                let position = y(value)
                context.draw(Text(Int(value.rounded()).formatted()).font(.caption2).foregroundStyle(.secondary),
                             at: .init(x: 39, y: position), anchor: .trailing)
                var line = Path()
                line.move(to: .init(x: 44, y: position)); line.addLine(to: .init(x: width + 44, y: position))
                context.stroke(line, with: .color(.secondary.opacity(0.2)))
            }
            let step = width / Double(result.bins.count)
            for (index, bin) in result.bins.enumerated() where bin.mask {
                context.fill(Path(CGRect(x: 44 + Double(index) * step, y: top, width: step + 0.4, height: bottom - top)),
                             with: .color(.orange.opacity(0.24)))
            }
            for index in result.breakBins where index > 0 {
                let x = 44 + Double(index) * step
                var gap = Path()
                gap.move(to: .init(x: x, y: top))
                gap.addLine(to: .init(x: x, y: bottom))
                context.stroke(gap, with: .color(.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            for (key, color, processed) in [(\ReviewTraceBin.raw, Color.secondary, false), (\ReviewTraceBin.processed, Color.blue, true)] {
                var trace = Path(), previous: CGPoint?
                let dots = WaveformDotSelection(percent: density, limit: result.bins.count, possible: result.bins.count)
                for (index, bin) in result.bins.enumerated() {
                    if result.breakBins.contains(index) { previous = nil }
                    guard let range = bin[keyPath: key] else { previous = nil; continue }
                    let x = 44 + Double(index) * step
                    let count = processed ? bin.processedCount : bin.rawCount
                    let sum = processed ? bin.processedSum : bin.rawSum
                    let center = count > 0 ? sum / Double(count) : (range.lowerBound + range.upperBound) / 2
                    let midpoint = CGPoint(x: x, y: y(center))
                    if style == .points {
                        if (metalFailed || !(processed ? filteredMetal : rawMetal)), dots.includes(UInt64(index)) {
                            context.fill(Path(ellipseIn: CGRect(x: x - 1, y: midpoint.y - 1, width: 2, height: 2)), with: .color(color))
                        }
                        continue
                    }
                    if style == .envelope {
                    trace.move(to: .init(x: x, y: y(range.upperBound) - 0.25))
                    trace.addLine(to: .init(x: x, y: y(range.lowerBound) + 0.25))
                    }
                    if let previous { trace.move(to: previous); trace.addLine(to: midpoint) }
                    previous = midpoint
                }
                context.stroke(trace, with: .color(color), lineWidth: 0.85)
            }
            for index in 0...3 {
                let fraction = Double(index) / 3
                let time = result.selection.lower + (result.selection.upper - result.selection.lower) * fraction
                context.draw(Text(time.formatted(.number.precision(.fractionLength(0...6))) + " s").font(.caption2).foregroundStyle(.secondary),
                             at: .init(x: 44 + width * fraction, y: bottom + 12), anchor: index == 3 ? .trailing : .leading)
            }
        }
    }
}
