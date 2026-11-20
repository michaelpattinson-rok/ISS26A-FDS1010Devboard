import AppKit
import SwiftUI

struct StreamLibrary: View {
    @ObservedObject var bench: StreamingBench
    @State private var search = ""
    @State private var filter: RecordingMode?
    @State private var filterBoard: AcquisitionBoard?
    @State private var filterRate: Double?
    @State private var filterStatus: StreamRun.Status?
    @State private var showRename = false
    @State private var showResume = false
    @State private var showingList = true
    @State private var showProjectReview = false
    @State private var showBatchExport = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var archiveRequest: RunBatchExportRequest?
    @State private var pendingArchive: (RunBatchExportRequest, String)?
    @State private var reviewRuns: [StreamRun] = []
    @State private var sampleJump: LibrarySampleJump?

    private var entries: [StreamRunItem] {
        bench.runs.filter { item in
            item.run?.isManualDraft != true
            && (filter == nil || item.run?.settings.mode == filter)
            && (filterBoard == nil || item.run?.settings.board == filterBoard)
            && (filterRate == nil || item.run?.settings.libraryRecordedRate == filterRate)
            && (filterStatus == nil || item.run?.status == filterStatus)
            && (search.isEmpty || (item.run.map {
                ($0.name + " " + $0.description).localizedCaseInsensitiveContains(search)
            } ?? item.id.uuidString.localizedCaseInsensitiveContains(search)))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 860 {
                HSplitView {
                    list(narrow: false).frame(minWidth: 250, idealWidth: 285, maxWidth: 340)
                        .frame(height: geometry.size.height, alignment: .topLeading)
                    detail.frame(minWidth: 450)
                        .frame(height: geometry.size.height, alignment: .topLeading)
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
            } else if bench.selection == nil || showingList {
                list(narrow: true)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button("Run Library", systemImage: "chevron.left") { showingList = true }
                        Spacer()
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                    Divider()
                    detail
                }
            }
        }
        .onAppear {
            showingList = bench.selection == nil
            selectedIDs = Set(entries.filter { $0.id == bench.selection }.map(\.id))
        }
        .onChange(of: bench.selection) { _, id in
            if bench.diagnosisSource?.run != id { bench.diagnosisSource = nil }
            if let id, selectedIDs.contains(id) { return }
            selectedIDs = Set(entries.filter { $0.id == id }.map(\.id))
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            let visible = selectedIDs.intersection(ids)
            if visible != selectedIDs { select(visible) }
        }
        .onChange(of: bench.exclusionJob?.id) { _, id in
            if id != nil { showingList = false }
        }
        .onChange(of: bench.requestedCurve, initial: true) { _, id in
            if id != nil { showingList = false }
        }

        .onChange(of: bench.renamePrompt, initial: true) { _, requested in
            if requested && bench.selectedRun != nil { showRename = true; bench.renamePrompt = false }
        }
        .sheet(item: $bench.picoCardRequest) { request in
            PicoCardImportSheet(request: request) { entries, wiring, date in
                bench.importPicoCard(request, entries: entries, wiring: wiring, date: date)
            }
        }
        .sheet(isPresented: $showRename) {
            if let run = bench.selectedRun {
                StreamMetadataSheet(title: "Edit Run Details", name: run.name, description: run.description, actionTitle: "Save",
                                    reviewTimeline: { bench.openRunTimeline(run.id) }) {
                    bench.rename($0, description: $1)
                }
            }
        }
        .sheet(isPresented: $showProjectReview, onDismiss: { reviewRuns.removeAll() }) {
            if let store = bench.project {
                ProjectReviewView(bench: bench, settings: bench.localAI, store: store, runs: reviewRuns) { location in
                    bench.selection = location.run
                    sampleJump = location
                    showingList = false
                    showProjectReview = false
                }
            }
        }
        .sheet(item: $archiveRequest, onDismiss: {
            guard let (request, name) = pendingArchive else { return }
            pendingArchive = nil
            bench.exportSelectedRuns(request.runs.map(\.id), projectID: request.projectID, name: name)
        }) { request in
            RunBatchExportSheet(request: request) { pendingArchive = (request, $0) }
        }
        .confirmationDialog("Export matching runs?", isPresented: $showBatchExport) {
            Button("Full Run ZIPs…") { bench.queueLibraryExports(exportableRuns, format: .zip) }
            Button("Original Binary ZIPs…") { bench.queueLibraryExports(exportableRuns, format: .binaryZIP) }
        } message: {
            Text("Choose a destination for \(exportableRuns.count) runs. Signal Bench queues a separate archive for each run.")
        }
        .confirmationDialog("Continue this run?", isPresented: $showResume) {
            Button("Start New Segment") { if let run = bench.selectedRun { bench.resume(run) } }
        } message: {
            Text("Confirm the original channel, wiring and gain. The gap before the new segment remains unknown.")
        }
    }

    private func list(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run Library").font(.title2.weight(.semibold))
                Spacer()
                Button("Import Pico Card…", systemImage: "sdcard") { bench.choosePicoCard() }
                    .labelStyle(.iconOnly).help("Import Pico Card…").disabled(bench.busy || bench.needsProjectAccess)
                Menu {
                    Button("Export Selected Runs as ZIP…", action: requestBatchExport).disabled(!canExportSelection)
                    Button("Export Matching Runs Separately…") { showBatchExport = true }
                        .disabled(bench.busy || exportableRuns.isEmpty)
                } label: {
                    Label("Run Export Options", systemImage: "square.and.arrow.up.on.square")
                }
                .labelStyle(.iconOnly).menuIndicator(.hidden).help("Run export options")
                Button("Show Exports in Finder", systemImage: "folder") { bench.showExports() }
                    .labelStyle(.iconOnly).help("Show Exports in Finder").disabled(bench.busy)
            }
            TextField("Search runs", text: $search, prompt: Text("Search runs")).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search runs")
            HStack {
                Picker("Mode", selection: $filter) {
                    Text("All modes").tag(RecordingMode?.none)
                    ForEach(RecordingMode.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden()
                Picker("Status", selection: $filterStatus) {
                    Text("All statuses").tag(StreamRun.Status?.none)
                    Text("Complete").tag(Optional(StreamRun.Status.complete))
                    Text("Interrupted").tag(Optional(StreamRun.Status.interrupted))
                }.labelsHidden()
            }
            Picker("Recording board", selection: $filterBoard) {
                Text("All boards").tag(AcquisitionBoard?.none)
                ForEach(AcquisitionBoard.allCases) { Text($0.title).tag(Optional($0)) }
            }.labelsHidden().accessibilityLabel("Filter by recording board")
            Picker("Recorded rate", selection: $filterRate) {
                Text("All recorded rates").tag(Double?.none)
                ForEach(Set(bench.runs.compactMap { $0.run?.settings.libraryRecordedRate }).sorted(), id: \.self) {
                    Text("\($0.formatted(.number.precision(.fractionLength(0...2)))) readings/s").tag(Optional($0))
                }
            }.labelsHidden().accessibilityLabel("Filter by recorded rate")
            Button("Review with Local AI…", systemImage: "sparkle.magnifyingglass") {
                openProjectReview(entries.compactMap(\.run))
            }.disabled(bench.busy || !entries.contains { $0.run.map(eligibleForReview) ?? false })
            .help("Review the runs in the current Library filters")
            if entries.isEmpty {
                let unfiltered = search.isEmpty && filter == nil && filterStatus == nil && filterRate == nil && filterBoard == nil
                ContentUnavailableView(unfiltered ? "No recordings yet" : "No matching runs",
                                       systemImage: "waveform.path",
                                       description: Text(unfiltered ? "Start a recording to add it to this Project." : "Change the search or filters."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, selection: Binding(get: { selectedIDs }, set: select)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.run?.name ?? "Unreadable run").font(.body.weight(.medium)).lineLimit(1)
                        if let run = item.run {
                            Text(run.curveSource == nil ? "\(run.settings.prerunPlan == nil ? run.settings.mode.rawValue : "Dark Prerun") · \(run.status.rawValue.capitalized)" : "Standalone Curve").font(.caption).foregroundStyle(.secondary)
                            Text(run.boardLabel + " · " + run.settings.libraryRateLabel)
                                .font(.caption).foregroundStyle(.secondary)
                            if let phase = run.settings.calibrationPhase {
                                Text(phase.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(run.created, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(item.id.uuidString).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                    .tag(item.id)
                    .onTapGesture(count: 2) { select([item.id]); showingList = false }
                    .contextMenu {
                        Button("Open in Studio") { select([item.id]); showingList = false }
                        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
                            Button("Export Selected Runs as ZIP…", action: requestBatchExport).disabled(!canExportSelection)
                        }
                        if let run = item.run, eligibleForReview(run) {
                            Button("Review with Local AI…") { openProjectReview([run]) }.disabled(bench.busy)
                        }
                        Button("View in Finder", systemImage: "folder") { bench.revealRun(item.id) }
                    }
                }.listStyle(.inset)
                HStack {
                    Text(selectedIDs.isEmpty ? "⌘ click to select runs" : "\(selectedIDs.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(selectedIDs.isEmpty ? "Hold Command and click to select multiple runs" : "\(selectedIDs.count) runs selected")
                    Spacer()
                    Button("Export ZIP…", action: requestBatchExport)
                        .disabled(!canExportSelection)
                        .accessibilityLabel("Export selected runs as ZIP")
                        .help(selectionHelp)
                }
                if narrow {
                    Button("Open Selected Run") { showingList = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!entries.contains(where: { $0.id == bench.selection }))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }.padding(16)
    }

    private var selectedItems: [StreamRunItem] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    private var canExportSelection: Bool {
        !bench.busy && bench.project != nil && !selectedItems.isEmpty &&
            selectedItems.allSatisfy { $0.run.map(RunBatchArchive.canExport) == true }
    }

    private var selectionHelp: String {
        if bench.busy { return "Finish the current activity to export runs." }
        if selectedIDs.isEmpty { return "Hold Command and click to select multiple runs." }
        if !canExportSelection { return "Select saved runs with readable data." }
        return "Save the selected runs together in one ZIP."
    }

    private func select(_ ids: Set<UUID>) {
        selectedIDs = ids
        if let id = bench.selection, ids.contains(id) { return }
        bench.selection = entries.first { ids.contains($0.id) }?.id
    }

    private func requestBatchExport() {
        guard canExportSelection, let project = bench.project else { return }
        archiveRequest = .init(projectID: project.identity.id, runs: selectedItems.compactMap(\.run))
    }

    private var exportableRuns: [StreamRun] {
        entries.compactMap(\.run).filter { !$0.isManualDraft && $0.curveSource == nil && !$0.segments.isEmpty }
    }

    private func eligibleForReview(_ run: StreamRun) -> Bool {
        !run.isManualDraft && run.curveSource == nil && !run.segments.isEmpty
    }

    private func openProjectReview(_ runs: [StreamRun]) {
        reviewRuns = runs.filter(eligibleForReview)
        showProjectReview = true
    }

    @ViewBuilder private var detail: some View {
        if let project = bench.project, let run = bench.selectedRun {
            RunWorkspaceView(bench: bench, reader: .init(store: project, run: run),
                             rename: { showRename = true }, resume: { showResume = true }, sampleJump: sampleJump,
                             initialRange: bench.diagnosisSource.flatMap { $0.run == run.id ? $0.range : nil })
                .id(run.id)
        } else if let id = bench.selection, let item = bench.runs.first(where: { $0.id == id }) {
            ContentUnavailableView("Could not open this run", systemImage: "exclamationmark.triangle",
                                   description: Text(item.issue ?? "The run metadata could not be read."))
        } else {
            ContentUnavailableView("Select a run", systemImage: "waveform.path", description: Text("Inspect the waveform or export a recording."))
        }
    }
}

struct StreamStudioView: View {
    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let rename: () -> Void
    let resume: () -> Void
    var sampleJump: LibrarySampleJump? = nil
    var workspaceRange: ((StreamSelection) -> Void)? = nil
    var openAnalysisOnLoad = false
    var requestedRangeOnLoad: StreamSelection? = nil
    var didOpenAnalysis: (() -> Void)? = nil
    var keepExactRange: ((StreamSelection) -> Void)? = nil
    @State private var duration = 0.0
    @State private var lower = 0.0
    @State private var upper = 1.0
    @State private var plottedRange = StreamSelection(lower: 0, upper: 1)
    @State private var plot: StudioPlot?
    @State private var metalFailed = false
    @State private var metalPresented = false
    @State private var overview: WaveformOverview?
    @State private var overviewPlot: StudioPlot?
    @State private var rangeReader: StreamRangeReader?
    @State private var selectRange = false
    @State private var cursors: [WaveformSample] = []
    @State private var selectedFlagID: UUID?
    @State private var cursorWork: Task<Void, Never>?
    @State private var cursorIssue: String?
    @State private var qualityMinute = 0
    @State private var qualityOpen = false
    @State private var analyses: [StreamAnalysisManifest] = []
    @State private var showExport = false
    @State private var format = StreamExporter.Format.zip
    @State private var fullRun = true
    @State private var includeAnalyses = false
    @State private var exportName = ""
    @State private var showStorage = false
    @State private var storage: RunCompression.Inventory?
    @State private var storageIssue: String?
    @State private var lastSampleJump: UUID?
    @State private var pulseAnalysis = false
    @State private var studioError: String?
    @State private var plotWork: Task<Void, Never>?
    @State private var plotLoading = false
    @State private var requestedRange: StreamSelection?
    @State private var selectedAnalysis: StreamAnalysisManifest?
    @State private var reviewSheet = false
    @State private var reviewRange: StreamSelection?
    @State private var reviewJob: ProjectJob?
    @State private var reviewJobMasks: JobExclusionProposal?
    @State private var noiseReview: PostRunAnalysis.Review?
    @State private var spectrumIndex = 0
    @State private var showNoiseReview = false
    @State private var previewNoiseMasks = false
    @State private var approveNoiseMasks = false
    @State private var savedReview: SavedReview?
    @State private var savedRangeReview: StudioRangeResult?
    @State private var savedFixture: StreamAnalysisManifest?
    @State private var moments: [BenchMoment] = []
    @State private var knownMissing: UInt64 = 0
    @State private var recoveredSampleCount: UInt64 = 0
    @State private var annotations: RunAnnotationRevision?
    @State private var annotationRange: StreamSelection?
    @State private var compareRuns = false
    @State private var confirmDiscard = false
    @State private var indexLoaded = false
    @State private var timelineEntries: [RunTimelineEntry] = []
    @State private var showSaveDraft = false
    @State private var waveformHeight = WaveformHeight.standard
    @State private var playback = RunPlayback()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(reader.run.isManualDraft ? "Review \(reader.run.settings.mode.rawValue) recording" : reader.run.name)
                                .font(.title2.weight(.semibold)).textSelection(.enabled)
                            if reader.run.isManualDraft {
                                Text("The raw samples are in a recoverable Project draft.").foregroundStyle(.secondary)
                            } else {
                                Text(reader.run.description).foregroundStyle(.secondary).textSelection(.enabled)
                                if let card = reader.run.picoCardOrigin {
                                    Text("Pico Card · " + card.input.rawValue)
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text(card.approximateStart.map {
                                        "Approximate start " + $0.formatted(date: .abbreviated, time: .shortened)
                                    } ?? "Recording date unknown")
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        if !reader.run.isManualDraft {
                            Menu("Actions") {
                                Button("Edit Run Details…", action: rename)
                                Button("Export…") { exportName = reader.run.name; showExport = true }
                                    .disabled(duration <= 0)
                                if reader.run.status == .interrupted, reader.run.settings.mainsHum == nil, reader.run.picoCardOrigin == nil {
                                    Button("Continue Recording…", action: resume)
                                        .disabled(!bench.canStart || !canResume)
                                }
                                Button("Storage…", systemImage: "externaldrive") { showStorage = true }
                                    .disabled(recoveredSampleCount == 0)
                                Button("Flag Manager…", systemImage: "flag") { bench.openRunTimeline(reader.run.id) }
                                Button("View in Finder", systemImage: "folder") { bench.revealRun(reader.run.id) }
                            }.fixedSize().disabled(bench.busy)
                        }
                    }
                    runSummary
                    if let studioError { Text(studioError).foregroundStyle(.orange).textSelection(.enabled) }
                    Divider()
                    if !reader.run.isManualDraft {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { primaryActions }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) { primaryActions }
                        }
                    }
                    rangeControls
                    waveformSection
                    if !reader.run.isManualDraft, duration > 0 { waveformJumps }
                    DisclosureGroup("Go to Time Range") { rangeFields.padding(.top, 6) }
                        .disabled(duration <= 0)
                    prerunDetails
                    if !reader.run.segments.isEmpty { recordingDetails }
                    if !reader.run.isManualDraft {
                        Divider()
                        qualitySection
                        HStack {
                            Button("Annotate…", systemImage: "flag") { annotationRange = plottedRange }
                                .disabled(bench.busy || !displayedSelectionReady)
                            Button("Compare Runs…") { compareRuns = true }.disabled(bench.busy)
                            StudioHelp(title: "Waveform review", detail: "Post Process opens the selected range. Use Full Run in Studio to review all saved samples.", assets: ["ReviewDrift", "ReviewMask"], illustration: true)
                        }
                        if let keepExactRange {
                            Button("Keep Range Exact", systemImage: "pin") { keepExactRange(plottedRange) }
                                .disabled(bench.busy || !displayedSelectionReady)
                        }
                        if let annotations {
                            DisclosureGroup("Annotations  ·  \(annotations.flags.count) flags  ·  \(annotations.masks.count) exclusions") {
                                ForEach(annotations.flags.prefix(50)) { item in
                                    if let time = flagTime(item) {
                                        Button(time.formatted(.number.precision(.fractionLength(3))) + " s · " + item.description) {
                                            lower = max(0, time - 0.025); upper = min(duration, time + 0.025); requestPlot()
                                        }.buttonStyle(.link)
                                    }
                                }
                            }
                        }
                    }
                    if !timelineEntries.isEmpty { timelineSection }
                    if !moments.isEmpty {
                        DisclosureGroup("Moment marks (\(moments.count))") {
                            ForEach(moments) { mark in
                                HStack {
                                    Text(mark.note.isEmpty ? "Disturbance" : mark.note).lineLimit(1)
                                    Spacer()
                                    Text("Near sample \(mark.receivedBoundary.formatted())").foregroundStyle(.secondary)
                                    Button("Show Range") { showMoment(mark) }
                                }.font(.callout)
                            }
                        }
                    }
                    if !reader.run.isManualDraft { analysisSection }
                }.padding(20).frame(maxWidth: 950, alignment: .leading).frame(maxWidth: .infinity)
            }
            .clipped()
            if reader.run.isManualDraft { manualSummary }
        }
        .sheet(isPresented: $showSaveDraft) {
            let run = reader.run
            StreamMetadataSheet(title: "Save to Library", name: run.name, description: run.description, actionTitle: "Save",
                                reviewTimeline: { bench.openRunTimeline(run.id) }) {
                bench.resolveDraft(keep: true, name: $0, description: $1)
            }
        }
        .task(id: bench.timelineRevision) {
            let reader = reader
            let work = Task.detached(priority: .utility) { try RunTimeline.entries(reader, finished: true) }
            do {
                let entries = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if !Task.isCancelled { timelineEntries = entries }
            } catch {
                if !Task.isCancelled { studioError = "Could not read flags and notes. " + error.localizedDescription }
            }
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Draft", role: .destructive) { bench.resolveDraft(keep: false) }
        } message: {
            Text("The unsaved samples and GPIO snapshots in this draft will be deleted from the Project.")
        }
        .task(id: reader.run.segments) {
            noiseReview = nil
            previewNoiseMasks = false
            cursors = []
            await load()
            guard !reader.run.isManualDraft else { return }
            do { annotations = try RunAnnotations.read(reader) }
            catch { studioError = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { annotationRange != nil }, set: { if !$0 { annotationRange = nil } })) {
            if let range = annotationRange {
                RunAnnotationPane(bench: bench, reader: reader, initial: range, revision: annotations) { annotations = $0 }
            }
        }
        .sheet(isPresented: $compareRuns) { RunComparisonPane(bench: bench, reader: reader) { minute in
            lower = Double(minute - 1) * 60
            upper = min(duration, lower + 60)
            requestPlot()
        } }
        .onDisappear { plotWork?.cancel(); cursorWork?.cancel() }
        .onChange(of: bench.dotDensity) { _, _ in if bench.waveformStyle == .points { requestPlot() } }
        .onChange(of: bench.waveformStyle) { _, _ in requestPlot() }
        .task(id: bench.qualityRevisions[reader.run.id]) { await refreshOverview() }
        .sheet(isPresented: $showExport) { exportSheet }
        .sheet(isPresented: $showStorage) { storageSheet }
        .onChange(of: sampleJump?.id) { _, _ in openRequestedSample() }

        .task(id: bench.exclusionJob?.id) {
            guard let job = bench.exclusionJob, job.input.run == reader.run.id else { return }
            let input = reader
            let work = Task.detached(priority: .utility) { try ProjectJobFiles.exclusionProposal(job, reader: input) }
            do {
                let proposal = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                let end = try await Task.detached { try input.duration() }.value
                duration = max(duration, end)
                reviewJob = job
                reviewJobMasks = proposal
                reviewRange = proposal.input.selection
                savedReview = nil
                savedRangeReview = nil
                savedFixture = nil
                bench.exclusionJob = nil
                reviewSheet = true
            } catch {
                guard !Task.isCancelled else { return }
                bench.notice = error.localizedDescription
                bench.exclusionJob = nil
            }
        }
        .sheet(isPresented: $reviewSheet, onDismiss: {
            reviewJob = nil
            reviewJobMasks = nil
            do { annotations = try RunAnnotations.read(reader) }
            catch { studioError = error.localizedDescription }
        }) {
            StudioReviewView(bench: bench, reader: reader, initial: reviewRange ?? plottedRange, saved: savedReview,
                             initialTool: savedFixture != nil ? .fixture : savedReview != nil ? .filters : .range,
                             fixtureReport: savedFixture, savedRange: savedRangeReview, duration: duration,
                             exclusionJob: reviewJob, exclusionProposal: reviewJobMasks,
                             openSample: { location in
                guard let time = sampleTime(location.segment, location.sample) else { return }
                reviewSheet = false
                jump(time, width: 0.02)
                pinCursor(time)
            }, openTime: { time in
                reviewSheet = false
                jump(time, width: min(2, duration))
            }) {
                analyses.insert($0, at: 0)
            }
        }
        .sheet(isPresented: $showNoiseReview) { noiseReviewSheet }
        .confirmationDialog("Apply the proposed exclusions?", isPresented: $approveNoiseMasks) {
            Button("Apply Exclusions") { applyNoiseReview() }
        } message: {
            Text("This creates a new annotation revision. The original samples and previous analyses are kept.")
        }
        .sheet(item: $selectedAnalysis) { analysis in
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved Analysis").font(.title2.weight(.semibold))
                Text("\(analysisTitle(analysis)) · version \(analysis.analyzerVersion)")
                Text("\(analysis.selection.lower.formatted()) to \(analysis.selection.upper.formatted()) nominal seconds")
                if let summary = analysis.pulseSummary {
                    Text("\(summary.candidates ?? 0) candidates · \(summary.operatorExcludedSamples ?? 0) operator-excluded samples")
                    if let usable = summary.usableSamples {
                        Text("\((Double(usable) / reader.run.settings.recordedRate).formatted(.number.precision(.fractionLength(3)))) s usable for pulse review")
                    }
                    Text("\(summary.matches.formatted()) pulse matches · \(summary.incompleteWindows.formatted()) incomplete analysis windows")
                    Text("\(summary.outsideEnvelope.formatted()) windows outside the profile limits")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let matches = analysis.matchLocations, !matches.isEmpty {
                    DisclosureGroup("Jump to a Pulse Match") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(matches.prefix(128)) { match in
                                    if let time = sampleTime(match.segment, match.sample) {
                                        Button("\(time.formatted(.number.precision(.fractionLength(6)))) s") {
                                            selectedAnalysis = nil
                                            jump(time, width: 0.02)
                                        }.buttonStyle(.link)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 118)
                    }
                }
                if let statistics = analysis.statistics { stats(statistics) }
                if let revision = analysis.profileRevision { Text("Calibration revision \(revision.uuidString)").textSelection(.enabled) }
                ForEach(analysis.outputs, id: \.file) { output in
                    Text("\(output.file) · \(output.type) · version \(output.version)").font(.caption)
                }
                HStack {
                    Spacer()
                    Button("Show Files in Finder") {
                        if let folder = try? reader.store.runDirectory(reader.run.id) {
                            NSWorkspace.shared.open(folder.appendingPathComponent("analyses").appendingPathComponent(analysis.id.uuidString))
                        }
                    }
                    if analysis.analyzer == PostRunAnalysis.noiseAnalyzer {
                        Button("Review Results") { openNoiseReview(analysis) }
                    }
                    if analysis.analyzer == StudioRangeReview.analyzer {
                        Button("Open Range Review") { reopenRange(analysis) }
                    }
                    if analysis.analyzer == "signalbench.waveform-review" {
                        Button("Open Review") { reopen(analysis) }
                    }
                    if analysis.analyzer == FixtureReplay.analyzer || analysis.analyzer == FixtureSelection.analyzer {
                        Button("Open Fixture Analysis") {
                            savedReview = nil
                            savedRangeReview = nil
                            reviewRange = nil
                            savedFixture = analysis
                            selectedAnalysis = nil
                            reviewSheet = true
                        }
                    }
                    Button("Done") { selectedAnalysis = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 480)
        }
    }

    private var runSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { runSummaryItems }.fixedSize()
            VStack(alignment: .leading, spacing: 4) { runSummaryItems }
        }.font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var runSummaryItems: some View {
        if !reader.run.isManualDraft {
            Label(reader.run.status.rawValue.capitalized,
                  systemImage: reader.run.status == .interrupted ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(reader.run.status == .interrupted ? .orange : .secondary)
        }
        Text("\(reader.run.settings.board.analogPin(reader.run.settings.channel)) · " + reader.run.boardLabel + " · " + reader.run.settings.libraryRateLabel)
    }

    @ViewBuilder private var prerunDetails: some View {
        if reader.run.settings.prerunPlan != nil || !reader.run.linkedPreruns.isEmpty {
            DisclosureGroup(reader.run.settings.prerunPlan != nil ? "Dark Prerun Result" : "Calibration Evidence") {
                VStack(alignment: .leading, spacing: 8) {
                    if let report = reader.run.prerunReport {
                        PrerunReportPanel(report: report, approved: false, historical: true)
                    } else if reader.run.settings.prerunPlan != nil {
                        Text("The prerun’s raw readings are available. No check report was saved.").foregroundStyle(.secondary)
                    }
                    ForEach(reader.run.linkedPreruns, id: \.run) { link in
                        if let linked = bench.runs.first(where: { $0.id == link.run })?.run {
                            Button(linked.name, systemImage: "waveform") { bench.showLinkedPrerun(link.run) }
                            if let report = linked.prerunReport {
                                Text(report.passed ? "Passed at recording time" : "Recorded for raw review")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Label("A linked prerun is unavailable.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }.padding(.top, 6)
            }
        }
    }

    private var recordingDetails: some View {
        DisclosureGroup("Recording Details") {
            VStack(alignment: .leading, spacing: 10) {
                if let factor = reader.run.settings.picoAveraging {
                    Text("Pico averaging · \(factor.count)× · exact group sums")
                    Text("Individual ADC conversions inside a group are unavailable. Flagged groups have no usable mean.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preset = reader.run.settings.adcAveraging {
                    Text("Recommended averaging · \(preset.title)")
                    Text("CSV and ZIP include the averaged series and original samples.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if reader.run.hasCadenceMismatch {
                    Label("Measured cadence differs from the configured rate. Waveform and export times use the configured rate.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let changes = reader.run.durationChanges {
                    DisclosureGroup("Duration Changes") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Original target: \(reader.run.initialDuration.formatted()) s")
                            Text("Final target: \(reader.run.settings.duration.formatted()) s")
                            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                                Text("At \(change.elapsed.formatted(.number.precision(.fractionLength(1)))) s · \(change.previous.formatted()) s to \(change.target.formatted()) s")
                            }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                if !reader.run.segments.isEmpty {
                    DisclosureGroup("Sample timing and coverage") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(reader.run.segments.enumerated()), id: \.element.id) { number, segment in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Segment \(number + 1)").fontWeight(.medium)
                                    if let version = segment.firmware { Text("\(segment.board.title) firmware \(version)") }
                                    if let cadence = segment.measuredByPicoTimer {
                                        Text("Measured cadence \(cadence.formatted(.number.precision(.fractionLength(0...2)))) samples/s")
                                    }
                                    let configured = segment.configuredRate(reader.run.settings.nominalRate)
                                    if let startup = segment.startup {
                                        let seconds = Double(startup.originalReadingOffset) / configured
                                        Text("Startup excluded · \(seconds.formatted(.number.precision(.fractionLength(0...3)))) s · \(startup.discardedReadings.formatted()) received readings skipped")
                                    }
                                    let nominalSeconds = Double(segment.savedSamples) / configured
                                    let raw = segment.rawConfiguredRate(reader.run.settings.nominalRate)
                                    Text("ADC configured \(raw.formatted(.number.precision(.fractionLength(0...2)))) samples/s")
                                    if segment.factor > 1 {
                                        Text("Recorded \(configured.formatted(.number.precision(.fractionLength(0...2)))) readings/s")
                                        Text("\((segment.savedSamples * segment.factor).formatted()) ADC conversions represented")
                                    }
                                    if let reason = segment.displayEndReason { Text(reason) }
                                    if let pico = segment.firmwareQueuePeak, let mac = segment.hostQueuePeak {
                                        Text("Queue peak · Device \(pico) · Mac \(mac)")
                                    }
                                    if let packing = segment.maximumPackingUS, let wait = segment.maximumUSBBackpressureUS {
                                        Text("Longest device preparation \(packing) µs · USB wait \(wait) µs")
                                    }
                                    if let writer = segment.maximumWriterUS { Text("Longest Mac write \(writer) µs") }
                                    Text("\(segment.savedSamples.formatted()) saved samples · \(nominalSeconds.formatted(.number.precision(.fractionLength(3)))) nominal sampled seconds")
                                    if segment.knownLoss > 0 { Text("\(segment.knownLoss.formatted()) known missing samples") }
                                    if segment.unknown { Text("Unconfirmed coverage").foregroundStyle(.orange) }
                                }
                            }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                if let message = reader.run.displayMessage, reader.run.status == .interrupted {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                }
                if reader.run.hasUnknownCoverage {
                    Text("Part of this run has unknown coverage. Unobserved time between segments has no width on the axis.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if knownMissing > 0 {
                    Text("\(knownMissing.formatted()) known missing samples").font(.callout).foregroundStyle(.secondary)
                }
                if reader.run.status == .interrupted, !reader.run.isManualDraft {
                    HStack(alignment: .top) {
                        Text(recoveredSampleCount > 0 ? "\(recoveredSampleCount.formatted()) saved samples in this run." : "No raw samples have been recovered yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        if canResume, reader.run.settings.mainsHum == nil, reader.run.picoCardOrigin == nil {
                            Button("Continue in New Segment…", action: resume).disabled(!bench.canStart)
                        }
                    }
                    if duration >= reader.run.settings.duration {
                        Text("This run reached its recording duration. Start a new run for more data.").font(.caption).foregroundStyle(.secondary)
                    } else if reader.run.hasCadenceMismatch {
                        Text("Start a new run to record at the correct cadence.").font(.caption).foregroundStyle(.secondary)
                    } else if !canResume && !bench.rateAvailable(reader.run.settings.nominalRate, channel: reader.run.settings.channel, averaging: reader.run.settings.picoAveraging) {
                        Text("Connect the run’s original device type, channel and rate.").font(.caption).foregroundStyle(.secondary)
                    } else if canResume && reader.run.settings.mode == .calibrated {
                        Text("Continuing starts with a fresh dark prerun.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func flagTime(_ flag: RunEventFlag) -> Double? {
        reader.run.segments.first { $0.id == flag.segment }.map {
            $0.timelineStart + Double(flag.sample) / $0.configuredRate(reader.run.settings.nominalRate)
        }
    }

    private struct WaveformFlag: Identifiable {
        let id: UUID
        let label: String
        let seconds: Double
    }

    private var waveformFlags: [WaveformFlag] {
        let legacy = annotations?.flags.compactMap { flag in
            flagTime(flag).map { WaveformFlag(id: flag.id, label: flag.description, seconds: $0) }
        } ?? []
        let placed = timelineEntries.filter { $0.state == .placed }.compactMap { entry in
            entry.position.flatMap { RunTimeline.time(of: $0, in: reader.run) }.map {
                WaveformFlag(id: entry.id, label: entry.label, seconds: $0)
            }
        }
        return (legacy + placed).sorted { ($0.seconds, $0.id.uuidString) < ($1.seconds, $1.id.uuidString) }
    }

    private var flagTimes: [Double] { waveformFlags.map(\.seconds) }

    private func jumpToFlag(_ flag: WaveformFlag) {
        selectedFlagID = flag.id
        jump(flag.seconds, width: min(duration, 0.1))
    }

    private var timelineSection: some View {
        DisclosureGroup("Flags & Notes (\(timelineEntries.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(timelineEntries.prefix(50)) { entry in
                    if entry.state == .placed, let position = entry.position, let time = RunTimeline.time(of: position, in: reader.run) {
                        Button(entry.label + " · " + time.formatted(.number.precision(.fractionLength(0...6))) + " s") {
                            jumpToFlag(.init(id: entry.id, label: entry.label, seconds: time))
                        }.buttonStyle(.link)
                    } else {
                        Text(entry.label.isEmpty ? entry.note : entry.label).lineLimit(2)
                    }
                }
                Button("Flag Manager…") { bench.openRunTimeline(reader.run.id) }
            }.padding(.top, 6)
        }
    }
    private var maskedTimes: [StreamSelection] {
        let segments = Dictionary(uniqueKeysWithValues: reader.run.segments.map { ($0.id, $0) })
        let proposed = previewNoiseMasks ? noiseReview?.proposals ?? [] : []
        return ((annotations?.masks ?? []) + proposed).compactMap {
            guard let segment = segments[$0.range.segment] else { return nil }
            let rate = segment.configuredRate(reader.run.settings.nominalRate)
            return .init(lower: segment.timelineStart + Double($0.range.first) / rate,
                         upper: segment.timelineStart + Double($0.range.end) / rate)
        }
    }

    private var canResume: Bool {
        let settings = reader.run.settings
        return !reader.run.isManualDraft && duration < settings.duration && !reader.run.hasCadenceMismatch && bench.rateAvailable(settings.nominalRate, channel: settings.channel, averaging: settings.picoAveraging) &&
            reader.run.settings.board == bench.board &&
            (settings.mode != .calibrated || (settings.purpose == nil && settings.profile?.measurementReady == true))
    }

    private var manualSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Recording summary").font(.headline)
                Spacer()
                Text(reader.run.status == .complete ? "Complete" : "Interrupted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(reader.run.status == .complete ? Color.secondary : Color.orange)
            }
            if indexLoaded {
                let seconds = Double(recoveredSampleCount) / reader.run.settings.recordedRate
                let quality = reader.run.segments.compactMap(\.manualQuality)
                let hasQuality = recoveredSampleCount > 0 && quality.reduce(0) { $0 + $1.samples } == recoveredSampleCount
                Text("\(seconds.formatted(.number.precision(.fractionLength(2)))) s sampled · \(recoveredSampleCount.formatted()) samples · \(knownMissing.formatted()) known missing")
                    .font(.callout).monospacedDigit()
                if hasQuality {
                    Text("\(quality.reduce(0) { $0 + $1.railSamples }.formatted()) rail samples · \(quality.reduce(0) { $0 + $1.adcErrors }.formatted()) ADC errors")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(studioError == nil ? "Checking saved samples…" : "The saved sample index could not be read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if reader.run.settings.mode == .manual {
                let released = reader.run.segments.last?.manualOutputsReleased == true
                Label(released ? "GPIO outputs released" : "GPIO release unconfirmed",
                      systemImage: released ? "lock.open" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(released ? Color.secondary : Color.orange)
            }
            HStack {
                Button("Discard Draft…", role: .destructive) { confirmDiscard = true }
                    .disabled(bench.busy || bench.needsProjectAccess)
                Spacer()
                Button("Flag Manager…", systemImage: "flag") { bench.openRunTimeline(reader.run.id) }
                    .disabled(bench.timelineSaving)
                Button("Save to Library…") { showSaveDraft = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(bench.busy || bench.timelineSaving || bench.needsProjectAccess || recoveredSampleCount == 0)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: 950, alignment: .leading).frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
    }

    private var selectedRange: StreamSelection { .init(lower: lower, upper: upper) }
    private var rangeValid: Bool { selectedRange.valid && upper <= duration + 0.000001 }
    private var displayedSelectionReady: Bool { !plotLoading && plot != nil && rangeValid && selectedRange == plottedRange }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Waveform").font(.headline)
                Spacer()
                if duration > 0 { Text("\(duration.formatted(.number.precision(.fractionLength(2)))) s on axis").font(.caption).foregroundStyle(.secondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { zoomControls; navigationMode }.fixedSize()
                VStack(alignment: .leading, spacing: 8) { zoomControls; navigationMode }
            }.disabled(duration <= 0)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale); heightPicker }.fixedSize()
                VStack(alignment: .leading, spacing: 7) {
                    WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
                    heightPicker
                }
            }
            if !plotLoading && plot != nil && selectedRange != plottedRange {
                Text("Select Show Range to apply these times.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var heightPicker: some View {
        Picker("Height", selection: $waveformHeight) {
            ForEach(WaveformHeight.allCases) { Text($0.rawValue).tag($0) }
        }.fixedSize()
    }

    private var rangeFields: some View {
        HStack {
            Text("From")
            TextField("From seconds", value: $lower, format: .number.precision(.fractionLength(0...6))).frame(width: 82)
            Text("to")
            TextField("To seconds", value: $upper, format: .number.precision(.fractionLength(0...6))).frame(width: 82)
            Text("s").foregroundStyle(.secondary)
            Button("Show Range") { requestPlot() }.disabled(!rangeValid)
        }.fixedSize()
    }
    private var zoomControls: some View {
        WaveformZoomControl(bounds: .init(lower: 0, upper: duration), selection: selectedRange,
                            minimum: 2 / reader.run.settings.recordedRate,
                            change: { jump((lower + upper) / 2, width: $0) },
                            home: { lower = 0; upper = duration; requestPlot() })
    }

    private func stats(_ stats: StreamStats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 6) {
            GridRow { Text("Baseline"); Text(number(stats.baseline)); Text("Sampled"); Text("\(number(stats.nominalSampledSeconds)) s") }
            GridRow { Text("Robust noise"); Text(number(stats.robustNoise)); Text("Missing on axis"); Text("\(number(max(0, stats.selectionSeconds - stats.nominalSampledSeconds))) s") }
            GridRow { Text("Range"); Text([stats.minimum, stats.maximum].compactMap { $0 }.map(String.init).joined(separator: " to ")); Text("ADC errors"); Text(stats.adcErrors.formatted()) }
            GridRow { Text("Clipped"); Text(stats.clipped.formatted()); Text("Raw samples"); Text(stats.samples.formatted()) }
        }.font(.callout).monospacedDigit().textSelection(.enabled)
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...4))) ?? "Unavailable"
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Analyses").font(.headline)
                Spacer()
                Button("Save Analysis") {
                    let reader = reader
                    let range = plottedRange
                    let rules = pulseAnalysis ? reader.run.settings.profile?.rules : nil
                    bench.perform("Saving analysis") {
                        try StreamStudio.save(reader, selection: range, rules: rules)
                    } completion: { analyses.insert($0, at: 0) }
                }.disabled(bench.busy || !displayedSelectionReady || (plot?.stats.samples ?? 0) == 0)
            }
            if reader.run.settings.channel == 0, reader.run.settings.profile?.ready == true {
                Toggle("Include pulse matches using the run’s saved profile", isOn: $pulseAnalysis)
                Text("Pulse matches describe waveform criteria. Count rate and radiation response are unverified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if analyses.isEmpty { Text("No saved analyses for this run.").foregroundStyle(.secondary) }
            ForEach(analyses) { result in
                Button { selectedAnalysis = result } label: {
                    Label(result.created.formatted(date: .abbreviated, time: .shortened) + " · " + analysisTitle(result),
                          systemImage: "doc.text")
                }.buttonStyle(.link)
            }
        }
    }

    private func analysisTitle(_ result: StreamAnalysisManifest) -> String {
        switch result.analyzer {
        case StudioRangeReview.analyzer: "Range review"
        case "signalbench.waveform-review": "Waveform review"
        case PostRunAnalysis.noiseAnalyzer: "Noise review"
        case FixtureSelection.analyzer: "Fixture waveform fit"
        case FixtureReplay.analyzer: "Fixture detector replay"
        default: result.rules == nil ? "Signal statistics" : "Signal statistics and pulse matches"
        }
    }

    #if STREAM_TESTING
    func exportSheetForLayout(format: StreamExporter.Format = .zip, samples: UInt64 = 0) -> some View {
        var view = self
        view._exportName = State(initialValue: reader.run.name)
        view._recoveredSampleCount = State(initialValue: samples)
        view._format = State(initialValue: format)
        return view.exportSheet
    }
    #endif

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Run").font(.title2.weight(.semibold))
            TextField("Export name", text: $exportName).textFieldStyle(.roundedBorder)
            Picker("Format", selection: $format) {
                ForEach(StreamExporter.Format.allCases.filter { $0 != .averaged || reader.run.settings.adcAveraging != nil || reader.run.settings.picoAveraging != nil }) {
                    Text($0.rawValue).tag($0)
                }
            }
            Picker("Range", selection: $fullRun) {
                Text("Full run").tag(true)
                Text("Visible range").tag(false).disabled(!displayedSelectionReady)
            }.pickerStyle(.segmented)
            if !format.includesRunInfo {
                Toggle("Include saved analyses", isOn: $includeAnalyses)
            }
            Text(format.detail).font(.caption).foregroundStyle(.secondary)
            let sampleEstimate = fullRun ? recoveredSampleCount : plot?.stats.samples ?? 0
            if sampleEstimate > 0 {
                let bytes = Int64(format.estimatedBytes(samples: sampleEstimate, averaging: reader.run.settings.adcAveraging,
                                                            pico: reader.run.settings.picoAveraging, hasExclusions: !(annotations?.masks.isEmpty ?? true), board: reader.run.settings.board))
                Text("Before compression: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { showExport = false }.keyboardShortcut(.cancelAction)
                Button("Choose Location…", action: export).keyboardShortcut(.defaultAction)
                    .disabled((try? SessionStore.projectName(exportName)) == nil || (!fullRun && !displayedSelectionReady))
            }
        }.padding(22).frame(width: 410)
    }

    private func export() {
        let reader = reader
        let range = fullRun ? StreamSelection(lower: 0, upper: duration) : plottedRange
        let name = exportName
        let format = format
        let include = includeAnalyses
        bench.queueExport(reader, name: name, selection: range, format: format, includeAnalyses: include) {
            showExport = false
        }
    }

    #if STREAM_TESTING
    func storageSheetForLayout(_ inventory: RunCompression.Inventory) -> some View {
        var view = self
        view._storage = State(initialValue: inventory)
        return view.storageSheet
    }
    #endif

    private var storageSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Storage").font(.title2.weight(.semibold))
            Text(reader.run.name).foregroundStyle(.secondary)
            if let storage {
                LabeledContent("Original sample bytes", value: ByteCountFormatter.string(fromByteCount: Int64(storage.original), countStyle: .file))
                LabeledContent("Stored sample bytes", value: ByteCountFormatter.string(fromByteCount: Int64(storage.stored), countStyle: .file))
                Text("\(storage.compressed.formatted()) of \(storage.chunks.formatted()) chunks compressed")
                    .font(.caption).foregroundStyle(.secondary)
            } else if storageIssue == nil {
                ProgressView("Checking sample storage…").controlSize(.small)
            }
            Text("Lossless compression preserves every ADC word, timing anchor and original hash. The run stays available for inspection, analysis and export. Use this version of Signal Bench to open compressed runs.")
                .font(.callout).foregroundStyle(.secondary)
            if let storageIssue { Text(storageIssue).foregroundStyle(.orange) }
            if let progress = bench.operationProgress, bench.busy {
                ProgressView(value: progress)
            }
            HStack {
                if bench.busy {
                    Button("Cancel Operation") { bench.cancelWork() }
                } else {
                    Button("Done") { showStorage = false }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Restore Uncompressed") { changeStorage(compress: false) }
                    .disabled(bench.busy || (storage?.compressed ?? 0) == 0)
                Button("Compress Losslessly") { changeStorage(compress: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(bench.busy || storage == nil || storage?.chunks == storage?.compressed)
            }
        }.padding(24).frame(width: 480)
            .task(id: bench.operation) {
                guard !bench.busy else { return }
                let input = reader
                let worker = Task.detached(priority: .utility) { try RunCompression.inventory(input) }
                let outcome = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                switch outcome {
                case .success(let value): storage = value; storageIssue = nil
                case .failure(let error): storage = nil; storageIssue = error.localizedDescription
                }
            }
    }

    private func changeStorage(compress: Bool) {
        let input = reader
        bench.performWithProgress(compress ? "Compressing verified samples" : "Restoring original sample files") { progress in
            try RunCompression.rewrite(input, compress: compress) { count, total in
                if count.isMultiple(of: max(1, total / 100)) || count == total { progress(Double(count) / Double(total)) }
            }
        } completion: { value in
            storage = value
            bench.notice = compress ? "Lossless archive checked. Every original ADC word is available." : "Uncompressed sample files restored."
        }
    }

    private func openRequestedSample() {
        guard let sampleJump, sampleJump.id != lastSampleJump, sampleJump.run == reader.run.id, duration > 0,
              let input = rangeReader,
              let segment = reader.run.segments.first(where: { $0.id == sampleJump.location.segment }) else { return }
        lastSampleJump = sampleJump.id
        let time = segment.timelineStart + Double(sampleJump.location.sample) / segment.configuredRate(reader.run.settings.nominalRate)
        guard time < duration else { return }
        if let endSample = sampleJump.endSample, endSample > sampleJump.location.sample {
            let end = segment.timelineStart + Double(endSample) / segment.configuredRate(reader.run.settings.nominalRate)
            let width = min(duration - time, end - time)
            jump(time + width / 2, width: width)
        } else {
            jump(time, width: min(duration, 0.025))
        }
        cursorWork?.cancel()
        let location = sampleJump.location
        cursorWork = Task {
            let task = Task.detached(priority: .utility) { try input.sample(at: location) }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }
                cursors = result.map { [$0] } ?? []
                cursorIssue = result == nil ? "This original sample is unavailable." : nil
            } catch {
                if !Task.isCancelled { cursorIssue = error.localizedDescription }
            }
        }
    }

    private func load() async {
        let reader = reader
        plotWork?.cancel()
        plot = nil
        plotLoading = false
        indexLoaded = false
        recoveredSampleCount = 0
        do {
            let worker = Task.detached {
                let reader = try reader.prepared()
                let duration = try reader.duration()
                let chunks = reader.index ?? []
                let count = chunks.reduce(UInt64(0)) { $0 + UInt64($1.readingCount) }
                let boundaries = reader.run.segments.reduce(into: [UUID: UInt64]()) { $0[$1.id] = $1.accountedSamples }
                let last = chunks.reduce(into: boundaries) { ends, chunk in
                    ends[chunk.segment] = max(ends[chunk.segment, default: 0], chunk.end)
                }
                let known = last.values.reduce(0, +)
                return (duration, try? StreamStudio.analyses(reader), try? BenchStudy.moments(reader), count, known >= count ? known - count : 0, reader, try? WaveformOverview.read(reader))
            }
            let content = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            duration = content.0
            analyses = content.1 ?? []
            moments = content.2 ?? []
            recoveredSampleCount = content.3
            knownMissing = content.4
            rangeReader = content.5
            overview = content.6
            overviewPlot = content.6.map { $0.plot(.init(lower: 0, upper: $0.duration), columns: 480) }
            indexLoaded = true
            if content.1 == nil { studioError = "A saved analysis could not be read. Its files remain in the run folder." }
            lower = 0
            upper = overview == nil ? min(duration, 2) : duration
            if let requestedRangeOnLoad, requestedRangeOnLoad.valid, requestedRangeOnLoad.upper <= duration + 1e-7 {
                lower = requestedRangeOnLoad.lower
                upper = min(duration, requestedRangeOnLoad.upper)
            }
            if sampleJump?.id != lastSampleJump, sampleJump?.run == reader.run.id { openRequestedSample() }
            else { requestPlot() }
        } catch {
            if !Task.isCancelled { studioError = error.localizedDescription }
        }
    }

    private func showMoment(_ mark: BenchMoment) {
        guard let segment = reader.run.segments.first(where: { $0.id == mark.segment }) else { return }
        let center = segment.timelineStart + Double(mark.receivedBoundary) / segment.configuredRate(reader.run.settings.nominalRate)
        lower = max(0, center - 1)
        upper = min(duration, center + 1)
        requestPlot()
    }

    private func reopenRange(_ analysis: StreamAnalysisManifest) {
        let reader = reader
        selectedAnalysis = nil
        bench.perform("Opening range review") {
            let config = try StudioRangeReview.load(reader, manifest: analysis)
            return try StudioRangeReview.analyze(reader, config: config, expectedSourceHash: analysis.sourceHash)
        } completion: { result in
            savedFixture = nil
            savedReview = nil
            savedRangeReview = result
            reviewRange = result.config.selection
            reviewSheet = true
        }
    }

    private func reopen(_ analysis: StreamAnalysisManifest) {
        savedRangeReview = nil
        savedFixture = nil
        reviewRange = nil
        let reader = reader
        selectedAnalysis = nil
        bench.perform("Opening saved waveform review") {
            try ReviewStorage.load(reader, manifest: analysis)
        } completion: { config in
            savedReview = config
            reviewSheet = true
        }
    }

    private func shift(_ direction: Double) { navigate(nil, direction) }
    private func zoom() { navigate(0.5, -1) }

    private func navigate(_ anchor: Double?, _ amount: Double) {
        guard duration > 0 else { return }
        let range = rangeValid ? selectedRange : plottedRange
        let span = range.upper - range.lower
        if let anchor {
            let width = min(duration, max(2 / reader.run.settings.recordedRate, span * exp2(amount)))
            let center = range.lower + anchor * span
            jump(center + (0.5 - anchor) * width, width: width)
        } else {
            jump((range.lower + range.upper) / 2 + amount * span, width: span)
        }
    }

    private func navigateOverview(_ anchor: Double?, _ amount: Double) {
        guard duration > 0 else { return }
        let range = (plotLoading ? requestedRange : nil) ?? (plot == nil ? selectedRange : plottedRange)
        guard range.valid else { return }
        let span = range.upper - range.lower
        if let anchor {
            let time = anchor * duration
            let width = span * exp2(amount)
            if (range.lower...range.upper).contains(time) {
                let fraction = (time - range.lower) / span
                jump(time + (0.5 - fraction) * width, width: width)
            } else {
                jump(time, width: width)
            }
        } else {
            jump((range.lower + range.upper) / 2 + amount * span, width: span)
        }
    }

    private func jump(_ center: Double, width: Double) {
        guard duration > 0 else { return }
        let width = min(duration, max(2 / reader.run.settings.recordedRate, width))
        lower = max(0, min(duration - width, center - width / 2))
        upper = min(duration, lower + width)
        requestPlot()
    }

    private func pinCursor(_ time: Double) {
        guard let reader = rangeReader, !plotLoading, plot?.gaps.contains(where: { $0.lower <= time && time < $0.upper }) != true else {
            cursorIssue = "No saved sample at this position."
            return
        }
        let tolerance = max(1 / reader.run.settings.recordedRate, (plottedRange.upper - plottedRange.lower) / 2000)
        cursorWork?.cancel()
        let stored = plot?.samples ?? []
        cursorWork = Task {
            let work = Task.detached { () throws -> WaveformSample? in
                if let exact = stored.min(by: { abs($0.time - time) < abs($1.time - time) }),
                   abs(exact.time - time) <= tolerance { return exact }
                var nearest: WaveformSample?
                let neighborhood = StreamSelection(lower: max(0, time - 2 / reader.run.settings.recordedRate),
                                                   upper: time + 2 / reader.run.settings.recordedRate)
                try reader.visit(neighborhood) { part in
                    for offset in 0..<part.reference.count {
                        let sample = part.sample(at: offset)
                        if abs(sample.time - time) < (nearest.map { abs($0.time - time) } ?? .infinity) { nearest = sample }
                    }
                }
                return nearest
            }
            do {
                let selected = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                cursorIssue = selected == nil ? "No saved sample at this position." : nil
                if let selected {
                    if cursors.count == 2 { cursors.removeFirst() }
                    cursors.append(selected)
                }
            } catch { if !Task.isCancelled { cursorIssue = error.localizedDescription } }
        }
    }

    private func selectSamples(_ first: Double, _ end: Double) {
        guard !bench.busy, !reader.run.isManualDraft, !plotLoading,
              let segment = reader.run.segments.last(where: { $0.timelineStart <= first }),
              let range = try? RunAnnotations.range(.init(lower: first, upper: end), segment: segment, reader: reader) else {
            cursorIssue = "Choose a range within one saved segment."
            return
        }
        guard let prepared = rangeReader else { return }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let lower = segment.timelineStart + Double(range.first) / rate
        let upper = segment.timelineStart + Double(range.end) / rate
        let requested = StreamSelection(lower: lower, upper: upper)
        cursorWork?.cancel()
        cursorWork = Task {
            let worker = Task.detached {
                for index in [range.first, range.end - 1] {
                    let time = segment.timelineStart + Double(index) / rate
                    var found = false
                    try prepared.visit(.init(lower: time, upper: time + 0.5 / rate)) { part in
                        found = found || (part.segment.id == segment.id && part.reference.first == index)
                    }
                    if !found { return false }
                }
                return true
            }
            do {
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if found { cursorIssue = nil; annotationRange = requested }
                else { cursorIssue = "Start and end the selection on saved samples." }
            } catch { if !Task.isCancelled { cursorIssue = error.localizedDescription } }
        }
    }

    private func refreshOverview() async {
        guard let reader = rangeReader else { return }
        let worker = Task.detached(priority: .utility) {
            let index = try WaveformOverview.read(reader)
            let preview = index.map { $0.plot(.init(lower: 0, upper: $0.duration), columns: 480) }
            return (index, preview, try StreamStudio.analyses(reader))
        }
        guard let result = try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }),
              !Task.isCancelled else { return }
        overview = result.0
        overviewPlot = result.1
        analyses = result.2
        if rangeValid && upper - lower > 12 { requestPlot() }
    }

    @ViewBuilder private var waveformSection: some View {
        if duration > 0 {
            let bounds = StreamSelection(lower: 0, upper: duration)
            let fullPlot = overviewPlot ?? (plottedRange == bounds ? plot : nil)
            let requested = plotLoading && (plot == nil || requestedRange != plottedRange) ? requestedRange : nil
            RunWaveformViewfinder(bounds: bounds, plot: fullPlot, displayed: plot == nil ? nil : plottedRange,
                                  requested: requested, move: { time in
                let range = requested ?? (plot == nil ? selectedRange : plottedRange)
                jump(time, width: range.upper - range.lower)
            }, navigate: navigateOverview)
        }
        if let plot {
            WaveformFPSControl(fps: $bench.reviewFPS)
            if bench.waveformStyle == .points {
                DotDensityControl(percent: $bench.dotDensity, plot: plot, rendererLimited: !metalPresented || metalFailed)
            }
            savedWaveform(plot)
                .overlay { RunPlaybackMarker(playback: playback, range: plottedRange) }
            if !reader.run.isManualDraft, reader.run.status == .complete || reader.run.status == .interrupted {
                RunPlaybackControls(playback: playback, range: plottedRange,
                                    ready: displayedSelectionReady && plot.stats.samples > 0 && !bench.busy)
            }
            WaveformPositionControl(bounds: .init(lower: 0, upper: duration), selection: selectedRange) {
                jump($0, width: upper - lower)
            }
            if plotLoading { ProgressView("Reading range").controlSize(.small) }
            let scale = bench.waveformScale.baselineSpan != nil && plot.stats.baseline != nil ? "Codes from baseline" : "ADC codes"
            let samples = plot.dots?.averaged == true ? "Averaged dots" : plot.samples.isEmpty && plot.dots == nil ? "Min and max bins" : "Original sample positions"
            Text("\(scale) · Seconds · \(samples) · Orange clipping · Red ADC errors · Shaded gaps")
                .font(.caption).foregroundStyle(.secondary)
            Text(selectRange ? "Drag to select a range. Click to pin a cursor." :
                    "Drag or use the arrow keys to pan. Pinch or Option scroll to zoom. Click to pin a cursor.")
                .font(.caption).foregroundStyle(.secondary)
            cursorReadout
            if previewNoiseMasks, let noiseReview {
                ViewThatFits(in: .horizontal) {
                    HStack { proposalActions(noiseReview.proposals.count) }.fixedSize()
                    VStack(alignment: .leading) { proposalActions(noiseReview.proposals.count) }
                }.font(.callout)
            }
            if plot.indexed {
                Text("Overview estimates use 0.1 s bins. Zoom in for exact range statistics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            stats(plot.stats)
        } else if plotLoading {
            ProgressView("Reading the selected range").frame(maxWidth: .infinity, minHeight: 165)
        } else {
            Text("No verified waveform to show.").frame(maxWidth: .infinity, minHeight: 165).foregroundStyle(.secondary)
        }
    }

    private func savedWaveform(_ plot: StudioPlot) -> StreamWaveform {
        var chart = StreamWaveform(columns: plot.columns, breaks: plot.breaks, selection: plottedRange,
                                   height: waveformHeight.points, xAxis: true)
        chart.board = reader.run.settings.board
        chart.flagTimes = flagTimes
        chart.maskedTimes = maskedTimes
        chart.baseline = plot.stats.baseline
        chart.baselineSpan = bench.waveformScale.baselineSpan ?? 0
        chart.faults = plot.faults
        chart.rails = plot.rails
        chart.lowRails = plot.lowRails
        chart.highRails = plot.highRails
        chart.dots = plot.dots
        chart.means = plot.means
        chart.metalFailed = $metalFailed
        chart.metalPresentation = $metalPresented
        chart.home = { lower = 0; upper = duration; requestPlot() }
        chart.gaps = plot.gaps
        chart.samples = plot.samples
        chart.style = bench.waveformStyle
        chart.fullScale = bench.waveformScale == .full
        chart.cursorTimes = cursors.map(\.time) + waveformFlags.filter { $0.id == selectedFlagID }.map(\.seconds)
        if selectRange { chart.picked = { first, end in selectSamples(first, end) } }
        chart.navigate = { anchor, amount in navigate(anchor, amount) }
        chart.cursor = { time in pinCursor(time) }
        return chart
    }

    private var waveformJumps: some View {
        let visibleEnd = plottedRange.lower <= 0 && plottedRange.upper >= duration ? 0 : plottedRange.upper
        let flags = waveformFlags
        let selected = flags.firstIndex { $0.id == selectedFlagID }
        let next = selected.flatMap { flags.indices.contains($0 + 1) ? flags[$0 + 1] : nil }
            ?? (selected == nil ? flags.first { $0.seconds >= visibleEnd } : nil)
        let prior = selected.flatMap { $0 > 0 ? flags[$0 - 1] : nil }
            ?? (selected == nil ? flags.last { $0.seconds < plottedRange.lower } : nil)
        let gaps = overview?.gaps ?? plot?.gaps ?? []
        let gap = gaps.first { $0.lower >= visibleEnd }
        let clipped = overview?.tiles.first {
            $0.clipped > 0 && Double($0.bucket) * WaveformOverview.tileSeconds >= visibleEnd
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let selected {
                Text("\(flags[selected].label) · \(flags[selected].seconds.formatted(.number.precision(.fractionLength(0...6)))) s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Previous Flag") { if let prior { jumpToFlag(prior) } }.disabled(prior == nil)
                Button("Next Flag") { if let next { jumpToFlag(next) } }.disabled(next == nil)
                Button("Next Gap") {
                    if let gap { jump(gap.lower, width: min(duration, 0.25)) }
                }.disabled(gap == nil)
                Button("Next Clipping") {
                    if let clipped {
                        let step = WaveformOverview.tileSeconds
                        jump((Double(clipped.bucket) + 0.5) * step, width: min(duration, step * 2))
                    }
                }.disabled(clipped == nil)
                    .help(overview == nil ? "Render Waveform to index clipping across this run." : "Jump to the next overview interval containing rail hits.")
            }
        }.font(.callout)
    }

    @ViewBuilder private var primaryActions: some View {
        Button("Render Waveform", systemImage: "waveform") {
            let input = rangeReader ?? reader
            bench.perform("Rendering verified waveform") { try WaveformOverview.build(input) } completion: { result in
                guard let result else { return }
                overview = result
                overviewPlot = result.plot(.init(lower: 0, upper: duration), columns: 480)
                bench.waveformStyle = .trace
                lower = 0
                upper = duration
                requestPlot()
            }
        }.disabled(bench.busy || duration <= 0)
        Button("Inspect Waveform", systemImage: "scope") {
            jump(duration > 2 ? min(duration, lower + 1) : duration / 2, width: min(2, duration))
        }.disabled(duration <= 0)
        Button("Post Process…", systemImage: "waveform.path") {
            savedReview = nil
            savedRangeReview = nil
            savedFixture = nil
            reviewRange = plottedRange
            reviewSheet = true
        }.disabled(bench.busy || !displayedSelectionReady)
        Button("Flag Manager…", systemImage: "flag") { bench.openRunTimeline(reader.run.id) }
            .disabled(bench.busy || bench.timelineSaving)
        Button("Export…", systemImage: "square.and.arrow.up") {
            exportName = reader.run.name
            showExport = true
        }.disabled(bench.busy || duration <= 0)
    }

    @ViewBuilder private func proposalActions(_ count: Int) -> some View {
        Text("\(count.formatted()) proposed exclusions").foregroundStyle(.secondary)
        Button("Hide Preview") { previewNoiseMasks = false }
        Button("Apply…") { approveNoiseMasks = true }.disabled(bench.busy || count == 0)
    }

    private func sampleTime(_ segment: UUID, _ sample: UInt64) -> Double? {
        reader.run.segments.first(where: { $0.id == segment }).map {
            $0.timelineStart + Double(sample) / $0.configuredRate(reader.run.settings.nominalRate)
        }
    }

    private func openNoiseReview(_ manifest: StreamAnalysisManifest) {
        let reader = rangeReader ?? reader
        selectedAnalysis = nil
        bench.perform("Reading noise review") {
            try PostRunAnalysis.load(manifest, reader: reader)
        } completion: { result in
            noiseReview = result
            spectrumIndex = 0
            showNoiseReview = true
        }
    }

    private var noiseReviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Noise Review").font(.title2.weight(.semibold))
            if let noiseReview {
                Text("\(noiseReview.proposals.count.formatted()) proposed exclusions. Review them on the waveform before applying.")
                    .fixedSize(horizontal: false, vertical: true)
                if let first = noiseReview.proposals.first, let time = sampleTime(first.range.segment, first.range.first) {
                    Button("Preview on Waveform") {
                        previewNoiseMasks = true
                        showNoiseReview = false
                        jump(time, width: 0.1)
                    }
                }
                if noiseReview.spectra.indices.contains(spectrumIndex) {
                    let item = noiseReview.spectra[spectrumIndex]
                    Stepper("Spectrum snapshot \(spectrumIndex + 1) of \(noiseReview.spectra.count)",
                            value: $spectrumIndex, in: 0...(noiseReview.spectra.count - 1))
                    NoiseSpectrumView(spectrum: item)
                    if let first = item.ranges.first, let time = sampleTime(first.segment, first.first) {
                        Button("Show Source Samples") { showNoiseReview = false; jump(time, width: 0.1) }.buttonStyle(.link)
                    }
                } else {
                    Text("No contiguous, unclipped samples were available for a spectrum.").foregroundStyle(.secondary)
                }
            }
            Button("Done") { showNoiseReview = false }.keyboardShortcut(.defaultAction)
        }.padding(22).frame(width: 450)
    }

    private func applyNoiseReview() {
        guard let noiseReview else { return }
        var revision = annotations ?? .init()
        revision.policy = .conservative
        revision.autoSettings = noiseReview.settings
        let ids = Set(revision.masks.map(\.id))
        revision.masks.append(contentsOf: noiseReview.proposals.filter { !ids.contains($0.id) })
        let reader = reader, expected = annotations?.id, next = revision
        bench.perform("Saving approved exclusions") {
            try RunAnnotations.save(next, reader: reader, replacing: expected)
        } completion: { result in
            annotations = result
            previewNoiseMasks = false
        }
    }

    private var navigationMode: some View {
        Picker("Tool", selection: $selectRange) {
            Text("Navigate").tag(false)
            Text("Select Range").tag(true)
        }.pickerStyle(.segmented).fixedSize().disabled(reader.run.isManualDraft)
    }

    @ViewBuilder private var cursorReadout: some View {
        if let cursorIssue { Text(cursorIssue).font(.caption).foregroundStyle(.secondary) }
        if !cursors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(cursors.enumerated()), id: \.offset) { position, cursor in
                    let value = cursor.readingLabel
                    Text("\(position == 0 ? "A" : "B")  \(cursor.time.formatted(.number.precision(.fractionLength(6)))) s  ·  \(value)  ·  \(cursor.indexLabel)")
                }
                if cursors.count == 2 {
                    let a = cursors[0], b = cursors[1]
                    if a.segment == b.segment, !a.invalid, !b.invalid {
                        Text("B − A  \((b.time - a.time).formatted(.number.precision(.fractionLength(6)))) s  ·  \((b.value - a.value).formatted(.number.precision(.fractionLength(0...6)))) codes")
                    } else {
                        Text("The cursors span different timing segments or include an ADC error.")
                    }
                }
                Button("Clear Cursors") { cursors = []; cursorIssue = nil }.buttonStyle(.link)
            }.font(.caption.monospacedDigit()).textSelection(.enabled)
        }
    }

    @ViewBuilder private var qualitySection: some View {
        if let overview, !overview.minutes.isEmpty {
            DisclosureGroup("Quality Summary", isExpanded: $qualityOpen) {
                let index = min(qualityMinute, overview.minutes.count - 1)
                let minute = overview.minutes[index]
                let start = Double(minute.id) * 60
                VStack(alignment: .leading, spacing: 8) {
                    if overview.hasUnboundedUnknownTime {
                        Text("This run includes an interruption. Some missing time cannot be measured.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Stepper("Minute \(minute.id + 1) of \(overview.minutes.count)", value: $qualityMinute, in: 0...(overview.minutes.count - 1))
                            .fixedSize()
                        Spacer()
                        Button("Show Minute") { jump(start + minute.seconds / 2, width: minute.seconds) }
                    }
                    Text("Sampled \(number(minute.sampled)) s · Missing on axis \(number(minute.unknown)) s · \(minute.gaps) gaps")
                    Text("Baseline \(number(minute.baseline)) · Noise \(number(minute.noise)) codes")
                    Text("ADC errors \(minute.errors.formatted()) · Clipped \(minute.clipped.formatted())")
                    if let first = overview.gaps.first(where: { $0.lower < start + minute.seconds && $0.upper > start }) {
                        Button("Show First Gap") { jump((first.lower + first.upper) / 2, width: max(0.02, (first.upper - first.lower) * 2)) }
                            .buttonStyle(.link)
                    }
                }.font(.callout).monospacedDigit().padding(.top, 6)
            }
        }
        if let issue = bench.qualityIssues[reader.run.id] {
            Text("Post processing could not finish. \(issue)").font(.caption).foregroundStyle(.secondary)
            Button("Retry Post Processing") { bench.retryPostRun(reader.run.id) }
        } else if let progress = bench.qualityProgress[reader.run.id] {
            HStack {
                ProgressView(progress.fraction < 1 ? "Preparing quality summary" : "Finishing post processing", value: progress.fraction)
                Button("Pause Processing") { bench.pausePostRun(reader.run.id) }
            }.controlSize(.small)
        } else if bench.qualityPaused.contains(reader.run.id) || (overview == nil && recoveredSampleCount > 0) {
            HStack {
                Text(bench.qualityPaused.contains(reader.run.id) ? "Post processing paused" : "Quality summary pending")
                    .foregroundStyle(.secondary)
                Button("Process Now") { bench.retryPostRun(reader.run.id) }
            }.font(.callout)
        }
    }

    private func requestPlot() {
        guard rangeValid else { return }
        let range = selectedRange
        let reader = rangeReader ?? reader
        let overview = overview
        let density = bench.waveformStyle == .points ? bench.dotDensity : nil
        let cadence = 1_000_000_000 / max(1, bench.reviewFPS)
        plotWork?.cancel()
        studioError = nil
        requestedRange = range
        plotLoading = true
        plotWork = Task {
            if plot != nil { try? await Task.sleep(for: .nanoseconds(cadence)) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let span = range.upper - range.lower
                let wide = span * reader.run.settings.recordedRate > Double(WaveformDots.rawReadLimit)
                if span > 12 && (density == nil || wide), let overview {
                    var plot = overview.plot(range)
                    if let density { plot.dots = .averages(plot.means, percent: density) }
                    return plot
                }
                var plot = try StreamStudio.plot(reader, selection: range, dotPercent: wide ? nil : density)
                if wide, let density { plot.dots = .averages(plot.means, percent: density) }
                return plot
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                plot = result
                plottedRange = range
                workspaceRange?(range)
                if openAnalysisOnLoad, !reviewSheet {
                    reviewRange = range
                    reviewSheet = true
                    didOpenAnalysis?()
                }
                plotLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                studioError = error.localizedDescription
                plotLoading = false
            }
        }
    }
}


struct RunWaveformViewfinder: View {
    let bounds: StreamSelection
    let plot: StudioPlot?
    let displayed: StreamSelection?
    let requested: StreamSelection?
    let move: (Double) -> Void
    var navigate: ((Double?, Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Run Overview").fontWeight(.medium)
                    Spacer(minLength: 12)
                    rangeStatus.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Overview").fontWeight(.medium)
                    rangeStatus
                }
            }
            .font(.caption)
            StreamWaveform(columns: plot?.columns ?? [], breaks: plot?.breaks ?? [], selection: bounds,
                           height: 44, xAxis: false, faults: plot?.faults ?? [], rails: plot?.rails ?? [],
                           gaps: plot?.gaps ?? [], navigate: navigate, viewport: displayed,
                           pendingViewport: requested, moveViewport: move)
                .help("Click or drag to move the visible range. Pinch or Option scroll to zoom.")
        }
    }

    private var rangeStatus: some View {
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))
        let rangeText = displayed.map { range in
            "\(range.lower.formatted(precision)) to \(range.upper.formatted(precision)) s"
        }
        return HStack(spacing: 7) {
            if let rangeText { Text(rangeText).monospacedDigit() }
            if requested != nil { Text("Loading new range") }
        }.foregroundStyle(.secondary)
    }
}


struct NoiseSpectrumView: View {
    let spectrum: PostRunAnalysis.Spectrum
    var accessibilityTitle = "Raw power spectral density"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let positive = spectrum.points.filter { $0.density > 0 && $0.hz >= 0 }
                guard let highest = positive.map(\.density).max(),
                      let frequency = spectrum.points.last?.hz, frequency > 0 else { return }
                let ceiling = ceil(10 * log10(highest) / 10) * 10
                let left = 36.0, right = size.width - 5, top = 5.0, bottom = size.height - 18
                guard right > left else { return }
                for i in 0...4 {
                    let y = top + (bottom - top) * Double(i) / 4
                    let decibels = Int(ceiling) - i * 20
                    context.draw(Text(decibels.formatted()).font(.caption2).foregroundStyle(.secondary),
                                 at: .init(x: left - 5, y: y), anchor: .trailing)
                    var grid = Path()
                    grid.move(to: .init(x: left, y: y))
                    grid.addLine(to: .init(x: right, y: y))
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)))
                }
                for i in 0...2 {
                    let fraction = Double(i) / 2
                    let khz = (frequency * fraction / 1000).formatted(.number.precision(.fractionLength(0...2)))
                    context.draw(Text(khz + " kHz").font(.caption2).foregroundStyle(.secondary),
                                 at: .init(x: left + (right - left) * fraction, y: size.height - 5),
                                 anchor: i == 0 ? .leading : i == 2 ? .trailing : .center)
                }
                var path = Path()
                for (i, value) in positive.enumerated() {
                    let x = left + (right - left) * value.hz / frequency
                    let ratio = max(0, min(1, (ceiling - 10 * log10(value.density)) / 80))
                    let point = CGPoint(x: x, y: top + ratio * (bottom - top))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 1)
            }.frame(height: 132).padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(accessibilityTitle + " by frequency, with decibels referenced to one ADC code squared per hertz")
            Text("\(spectrum.sampleRate.formatted(.number.precision(.fractionLength(0...2)))) samples/s · \(spectrum.windows.formatted()) windows · ADC codes²/Hz")
                .font(.caption)
            if let analyzed = spectrum.analyzedSeconds, let available = spectrum.sampledAtRateSeconds {
                Text("\(analyzed.formatted(.number.precision(.fractionLength(0...4)))) s analyzed of \(available.formatted(.number.precision(.fractionLength(0...4)))) s sampled at this rate")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Vertical scale in dB relative to 1 ADC code²/Hz").font(.caption).foregroundStyle(.secondary)
        }
    }
}
