import SwiftUI

struct RunWorkspaceView: View {
    enum Area: String, CaseIterable, Identifiable {
        case waveform = "Waveform", data = "Data", analysis = "Analysis", notes = "Notes & Flags"
        var id: Self { self }
    }

    @ObservedObject var bench: StreamingBench
    let reader: StreamRangeReader
    let rename: () -> Void
    let resume: () -> Void
    var sampleJump: LibrarySampleJump? = nil
    @State private var area: Area
    @State private var curves: [CurveManifest] = []
    @State private var selected: UUID?
    @State private var curve: CurveReader?
    @State private var selection = StreamSelection(lower: 0, upper: 1)
    @State private var rawDuration = 0.0
    @State private var exactRanges: [ReviewRange] = []
    @State private var issue: String?
    @State private var showingFit = false
    @State private var showingTrash = false
    @State private var showingExport = false
    @State private var notes: [RunTimelineEntry] = []
    @State private var flags: [RunEventFlag] = []
    @State private var historical: [StreamAnalysisManifest] = []
    @State private var source: StreamRun?
    @State private var sourceBytes: Int64?
    @State private var reportURL: URL?
    @State private var trashBlockers: [String] = []
    @State private var loading = true
    @State private var curveLoading = false
    @State private var resolvedPreference = false
    @State private var showOriginalAnalysis = false

    init(bench: StreamingBench, reader: StreamRangeReader, rename: @escaping () -> Void, resume: @escaping () -> Void,
         sampleJump: LibrarySampleJump? = nil, initialArea: Area = .waveform) {
        self.bench = bench
        self.reader = reader
        self.rename = rename
        self.resume = resume
        self.sampleJump = sampleJump
        _area = State(initialValue: initialArea)
    }

    private var run: StreamRun { reader.run }
    private var standalone: Bool { run.curveSource != nil }
    private var manifest: CurveManifest? { curves.first { $0.id == selected } }

    var body: some View {
        if run.isManualDraft {
            rawWaveform
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker("Run workspace", selection: $area) {
                        ForEach(Area.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 470)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if area == .waveform && !standalone && selected == nil {
                    VStack(spacing: 0) {
                        if !curves.isEmpty { representationPicker.padding(.horizontal, 20).padding(.vertical, 8) }
                        rawWaveform
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).textSelection(.enabled) }
                            switch area {
                            case .waveform:
                                representationPicker
                                if let curve {
                                    CurveWaveformPane(reader: curve, original: originalReader, selection: $selection,
                                        masks: masks, bench: bench, keep: standalone ? nil : { keep($0) })
                                        .id(curve.manifest.id)
                                } else if loading || curveLoading {
                                    ProgressView("Opening waveform")
                                } else {
                                    ContentUnavailableView("Waveform unavailable", systemImage: "waveform.slash")
                                }
                            case .data: data
                            case .analysis:
                                if let curve {
                                    CurveDiagnosticsPane(reader: curve, selection: selection, source: reader)
                                }
                                if !standalone {
                                    Button("Post Process Original…", systemImage: "waveform.path") {
                                        selected = nil
                                        showOriginalAnalysis = true
                                        area = .waveform
                                    }
                                }
                                if !historical.isEmpty { historicalReports }
                            case .notes: notesPane
                            }
                        }.frame(maxWidth: 850, alignment: .leading).padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .task(id: ReloadKey(revision: bench.curveRevision, run: reader.run)) { await reload() }
            .task(id: bench.timelineRevision) { await reloadNotes() }
            .task(id: selected) { await openSelected() }
            .onChange(of: sampleJump?.id) { _, id in
                if id != nil && !standalone { selected = nil; area = .waveform }
            }
            .sheet(isPresented: $showingFit) {
                CurveFitSheet(runName: run.name, duration: rawDuration, selection: selection, preserve: exactRanges,
                              reader: reader, bench: bench) { showingFit = false }
            }
            .sheet(isPresented: $showingExport) {
                if let manifest {
                    CurveExportSheet(reader: reader, manifest: manifest, selection: selection, bench: bench) { showingExport = false }
                }
            }
            .sheet(isPresented: $showingDuplicate) {
                if let duplicateCurve {
                    CurveCopySheet(reader: reader, manifest: duplicateCurve, bench: bench)
                }
            }
            .sheet(isPresented: $showingTrash) {
                if let source {
                    CurveTrashSheet(source: source, bytes: sourceBytes, standalone: run,
                                    bench: bench, blockers: trashBlockers)
                }
            }
        }
    }

    @State private var masks: [StreamSelection] = []

    private struct ReloadKey: Equatable {
        let revision: UUID
        let run: StreamRun
    }

    private var rawWaveform: some View {
        StreamStudioView(bench: bench, reader: reader, rename: rename, resume: resume, sampleJump: sampleJump,
            workspaceRange: { range in selection = range }, openAnalysisOnLoad: showOriginalAnalysis,
            requestedRangeOnLoad: selection.valid && rawDuration > 0 ? selection : nil,
            didOpenAnalysis: { showOriginalAnalysis = false }, keepExactRange: { keep($0) })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(run.name).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text("\(run.boardLabel) · \(run.settings.board.bits) bit ADC").font(.callout).foregroundStyle(.secondary)
            if standalone { Label("Standalone curve", systemImage: "waveform.path").font(.callout).foregroundStyle(.secondary) }
            Text(run.description).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var representationPicker: some View {
        Picker("Representation", selection: $selected) {
            if !standalone { Text("Original ADC data").tag(UUID?.none) }
            ForEach(curves) { Text($0.name).tag(Optional($0.id)) }
        }.frame(maxWidth: 480, alignment: .leading)
    }

    private var originalReader: StreamRangeReader? {
        if !standalone { return reader }
        return source.map { StreamRangeReader(store: reader.store, run: $0) }
    }

    private var data: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Representations").font(.headline)
                Spacer()
                if !standalone {
                    Button("Add Curve to Run…", systemImage: "plus") { showingFit = true }
                        .disabled(rawDuration <= 0 || bench.busy)
                }
            }
            if !standalone {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Original ADC data").fontWeight(.medium)
                        Text("Original readings, device timing, and capture quality.").foregroundStyle(.secondary)
                        Button("View Original") { selected = nil; area = .waveform }
                        Button("Set Original as Default") { setDefault(nil) }.disabled(bench.busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
            }
            if !exactRanges.isEmpty && !standalone {
                HStack {
                    Label("\(exactRanges.count) exact ranges selected for the next fit", systemImage: "pin")
                    Button("Clear") { exactRanges.removeAll() }
                }.font(.callout)
            }
            ForEach(curves) { item in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).font(.headline)
                            Spacer()
                            Text(storage(item.storedBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        CurveQualityView(manifest: item)
                        ViewThatFits(in: .horizontal) {
                            HStack { curveActions(item) }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading) { curveActions(item) }
                        }
                    }.padding(6)
                }
            }
            if curves.isEmpty && !loading {
                Text(standalone ? "This standalone waveform could not be read." : "Saved curves appear here. Each fit includes a quality report.")
                    .foregroundStyle(.secondary)
            }
            if standalone {
                Divider()
                Text("Source Recording").font(.headline)
                if let source {
                    Text(source.name)
                    Button("Open Original Run") { bench.selection = source.id }
                    if let sourceBytes { Text("Current source sample storage \(storage(sourceBytes))").foregroundStyle(.secondary) }
                    if !trashBlockers.isEmpty {
                        Text(trashBlockers.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Move Source to Trash…", systemImage: "trash") { showingTrash = true }
                        .disabled(!trashBlockers.isEmpty || bench.busy || bench.projectJobsUnfinished)
                } else {
                    Text("The original is unavailable. The curve, timing, and copied reports are stored in this run.").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func curveActions(_ item: CurveManifest) -> some View {
        Button("Inspect") { selected = item.id; area = .waveform }
        Button("Set as Default") { setDefault(item.id) }.disabled(standalone || bench.busy)
        Button("Export…") { selected = item.id; showingExport = true }.disabled(bench.busy)
        if item.wholeRun && !standalone {
            Button("Create Standalone Curve Run…") { duplicate(item) }.disabled(bench.busy)
        }
    }

    @State private var duplicateCurve: CurveManifest?

    private func duplicate(_ item: CurveManifest) {
        duplicateCurve = item
        showingDuplicate = true
    }

    @State private var showingDuplicate = false

    private var historicalReports: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(standalone ? "Original Analysis Reports" : "Saved Analyses").font(.headline)
            if standalone {
                Text("These results were calculated from the original recording. New pulse analysis requires original ADC data.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(historical) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.analyzer == "signalbench.studio-range" ? "Range Review" :
                         item.pulseSummary == nil ? "Waveform Analysis" : "Pulse Analysis").fontWeight(.medium)
                    Text(item.created.formatted() + " · " + item.selection.lower.formatted() + " to " + item.selection.upper.formatted() + " s")
                        .font(.caption).foregroundStyle(.secondary)
                    if let pulses = item.pulseSummary {
                        Text("\(pulses.matches.formatted()) Pulse Matches").font(.callout)
                    }
                    if let reportURL {
                        Button("Show Report Files in Finder") {
                            bench.revealRunReport(reportURL.appendingPathComponent(item.id.uuidString))
                        }.buttonStyle(.link)
                    }
                }.padding(.vertical, 5)
                Divider()
            }
        }
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes & Flags").font(.headline)
                Spacer()
                Button(standalone ? "Add Note…" : "Edit Flags & Notes…", systemImage: "flag") { bench.openRunTimeline(run.id) }
                    .disabled(bench.busy)
            }
            if notes.isEmpty && flags.isEmpty { Text("No notes or flags in this run.").foregroundStyle(.secondary) }
            ForEach(flags) { flag in
                if let segment = run.segments.first(where: { $0.id == flag.segment }) {
                    let seconds = segment.timelineStart + Double(flag.sample) / segment.configuredRate(run.settings.nominalRate)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(flag.description).fontWeight(.medium)
                        Text("\(seconds.formatted(.number.precision(.fractionLength(0...6)))) s · Reading \(flag.sample.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    Divider()
                }
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.label.isEmpty ? "Note" : note.label).fontWeight(.medium)
                    if !note.note.isEmpty { Text(note.note).textSelection(.enabled) }
                    if let position = note.position, let time = RunTimeline.time(of: position, in: run) {
                        Text("\(time.formatted(.number.precision(.fractionLength(0...6)))) s · Reading \(position.index.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Divider()
            }
        }
    }

    private func setDefault(_ id: UUID?) {
        let reader = reader
        bench.perform("Saving waveform preference") {
            let root = try reader.store.runDirectory(reader.run.id)
            let url = root.appendingPathComponent("waveform-preference.json")
            let exists = try StreamFiles.isPresent(url)
            if let id { try StreamFiles.publish(id, at: url, replace: exists) }
            else if exists {
                try FileManager.default.removeItem(at: url)
                try StreamFiles.sync(root)
            }
        } completion: { _ in selected = id; area = .waveform }
    }

    private func keep(_ range: StreamSelection) {
        for segment in run.segments where exactRanges.count < 256 {
            let indices = ReviewInput.indices(range, segment: segment, rate: run.settings.nominalRate)
            let end = min(segment.accountedSamples, indices.upperBound)
            if indices.lowerBound < end {
                exactRanges.append(.init(segment: segment.id, first: indices.lowerBound, end: end))
            }
        }
        bench.notice = "This range will be kept exact in the next curve."
    }

    private func reload() async {
        let input = reader
        issue = nil
        let task = Task.detached(priority: .utility) {
            let list = try CurveStore.list(input.store, input.run)
            let duration = try input.duration()
            let root = try input.store.runDirectory(input.run.id)
            let preference = try? StreamFiles.read(UUID.self, root.appendingPathComponent("waveform-preference.json"))
            let source = input.run.curveSource.flatMap { try? input.store.openRun($0) }
            let blockers = try source.map { try CurveDelivery.blockers(input.store, original: $0) } ?? []
            let size = source.flatMap { try? RunCompression.inventory(.init(store: input.store, run: $0)).stored }
            let directory = root.appendingPathComponent(input.run.curveSource == nil ? "analyses" : "source-analyses")
            let reports = try StreamStudio.analyses(in: directory, sourceRun: input.run.curveSource ?? input.run.id)
            let annotations = try RunAnnotations.read(input)
            let masks = annotations?.masks ?? []
            let intervals = masks.compactMap { item -> StreamSelection? in
                guard let segment = input.run.segments.first(where: { $0.id == item.range.segment }) else { return nil }
                let rate = segment.configuredRate(input.run.settings.nominalRate)
                return .init(lower: segment.timelineStart + Double(item.range.first) / rate,
                             upper: segment.timelineStart + Double(item.range.end) / rate)
            }
            return (list, duration, preference, source, blockers, size, directory, reports, intervals, annotations?.flags ?? [])
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            curves = value.0
            rawDuration = value.1
            source = value.3
            trashBlockers = value.4
            sourceBytes = value.5.map(Int64.init)
            reportURL = value.6
            historical = value.7
            masks = value.8
            flags = value.9
            if let requested = bench.requestedCurve, curves.contains(where: { $0.id == requested }) {
                selected = requested
                area = .waveform
                resolvedPreference = true
                bench.consumeCurveSelection()
            } else if !resolvedPreference {
                resolvedPreference = true
                selected = run.primaryCurve ?? value.2.flatMap { id in curves.contains(where: { $0.id == id }) ? id : nil }
            }
        } catch is CancellationError {
        } catch { issue = error.localizedDescription }
        loading = false
    }

    private func openSelected() async {
        guard let selected else { curve = nil; return }
        let input = reader
        curve = nil
        curveLoading = true
        defer { if self.selected == selected { curveLoading = false } }
        let task = Task.detached(priority: .utility) { try CurveStore.open(input.store, run: input.run, id: selected) }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            curve = value
            selection = value.manifest.selection
        } catch is CancellationError {
        } catch { curve = nil; issue = error.localizedDescription }
    }

    private func reloadNotes() async {
        let input = reader
        let task = Task.detached { try RunTimeline.entries(input, finished: true, resolving: input.run.curveSource == nil) }
        do { notes = try await task.value }
        catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }

    private func storage(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
