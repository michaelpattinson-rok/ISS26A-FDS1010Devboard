import SwiftUI

struct RunTimelineEditor: View {
    @ObservedObject var bench: StreamingBench
    let request: RunTimelineRequest
    @State private var content: RunTimelineContent?
    @State private var range: StreamSelection?
    @State private var plot: StudioPlot?
    @State private var renderedRange: StreamSelection?
    @State private var original: RunTimelineEntry?
    @State private var picked: WaveformSample?
    @State private var pickWork: Task<Void, Never>?
    @State private var picking = false
    @State private var label = ""
    @State private var note = ""
    @State private var flag = false
    @State private var status: String?
    @State private var problem = false
    @State private var height = WaveformHeight.standard
    @State private var metalFailed = false
    @State private var metalPresented = false
    @State private var confirmRemoval = false
    @State private var loading = true

    private var live: Bool { bench.recording && bench.current?.id == request.runID }
    private var bounds: StreamSelection? {
        if let frozen = request.frozen { return frozen.bounds }
        guard let content, content.duration > 0 else { return nil }
        return .init(lower: 0, upper: content.duration)
    }
    private var hasChanges: Bool { label != (original?.label ?? "") || note != (original?.note ?? "") || picked != nil }
    private var canSave: Bool {
        guard !bench.timelineSaving, !picking, !bench.needsProjectAccess, content != nil,
              label.utf8.count <= 120, note.utf8.count <= 8192 else { return false }
        return flag ? ((picked != nil || original?.position != nil) && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            : !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { layout in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    header
                    if bounds != nil { waveform(compact: layout.size.height < 570) }
                    else if flag && !loading { Text("No saved samples are available for flag placement.").foregroundStyle(.secondary) }
                    if loading && content == nil { ProgressView("Reading recording") }
                    form
                    if let entries = content?.entries, !entries.isEmpty { entryList(entries) }
                }
                .padding(20).frame(maxWidth: 950, alignment: .leading).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer.padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(minWidth: 495, minHeight: 450)
        .task(id: request.id) {
            newEntry(flag: request.tool != .note)
            range = request.frozen?.bounds
            await refresh(initial: true)
        }
        .task(id: PlotRequest(range: range, density: bench.waveformStyle == .points ? bench.dotDensity : nil,
                              indexed: content?.overview != nil)) {
            await updatePlot()
        }
        .onDisappear { cancelPick() }
        .onChange(of: flag) { _, _ in cancelPick() }
        .onChange(of: hasChanges) { _, dirty in bench.timelineChanged(request.id, dirty: dirty) }
        .onChange(of: live) { _, _ in Task { await refresh() } }
        .onChange(of: bench.qualityRevisions[request.runID]) { _, _ in
            if !live && request.frozen == nil { Task { await refresh() } }
        }
        .onChange(of: bench.preview.committedBoundary) { _, boundary in
            guard live, content?.entries.contains(where: {
                $0.state == .pending && ($0.position?.index ?? .max) < boundary
            }) == true else { return }
            Task { await refresh() }
        }
        .confirmationDialog("Remove this timeline entry?", isPresented: $confirmRemoval) {
            Button("Remove Entry", role: .destructive) { if let original { persist(original, remove: true) } }
        } message: {
            Text("The raw samples stay in the recording.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(request.frozen == nil ? "Flags & Notes" : "Place a Flag").font(.title2.weight(.semibold))
                Spacer()
                if live {
                    Button(bench.stopping ? "Saving…" : bench.activeMode == .manual ? "Release Outputs and Stop" : "Stop Recording",
                           systemImage: "stop.circle") { bench.stop() }.disabled(bench.stopping)
                } else if request.frozen != nil || request.tool == .note {
                    Button("Review Full Run") { bench.openRunTimeline(request.runID, replacing: true) }
                        .disabled(hasChanges || bench.timelineSaving)
                }
            }
            if live { Label("Recording continues", systemImage: "record.circle").font(.caption).foregroundStyle(.secondary) }
            if live && request.frozen == nil {
                Button("Capture Flag Window…") { bench.openLiveTimeline(.flag, replacing: true) }
                    .disabled(hasChanges || bench.preview.received == 0)
            }
            if let frozen = request.frozen {
                Text("Frozen at \(frozen.click.formatted(date: .omitted, time: .standard)) · Mac click time · Dotted line marks the received boundary")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let run = content?.reader.run {
                Text(run.name).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func waveform(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let bounds, let range {
                WaveformZoomControl(bounds: bounds, selection: range, minimum: minimumWidth,
                                    change: { setRange(center: (range.lower + range.upper) / 2, width: $0) },
                                    home: { self.range = bounds })
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
                    heightPicker
                }.fixedSize()
                VStack(alignment: .leading, spacing: 7) {
                    WaveformDisplayControls(style: $bench.waveformStyle, scale: $bench.waveformScale)
                    heightPicker
                }
            }
            if bench.waveformStyle == .points {
                DotDensityControl(percent: $bench.dotDensity, plot: plot,
                                  rendererLimited: !metalPresented || metalFailed)
            }
            WaveformFPSControl(fps: $bench.reviewFPS)
            if let plot, let renderedRange {
                chart(plot, in: renderedRange, compact: compact)
                if let bounds, let range {
                    WaveformPositionControl(bounds: bounds, selection: range) {
                        setRange(center: $0, width: range.upper - range.lower)
                    }
                }
            } else {
                ProgressView("Preparing waveform").frame(maxWidth: .infinity, minHeight: 130)
            }
            if let selection = range {
                Text("\(format(selection.lower)) to \(format(selection.upper)) s · Click a sample or drag to pan")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let plot {
                DisclosureGroup("Signal quality") {
                    WaveformSignalQuality(stats: plot.stats, estimated: plot.indexed, board: recordingBoard).padding(.top, 4)
                }.font(.caption)
            }
        }
    }

    private var heightPicker: some View {
        Picker("Height", selection: $height) {
            ForEach(WaveformHeight.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().accessibilityLabel("Waveform height").fixedSize()
    }

    private var recordingBoard: AcquisitionBoard { request.frozen?.recordingBoard ?? content?.reader.run.settings.board ?? bench.board }

    private func chart(_ plot: StudioPlot, in selection: StreamSelection, compact: Bool) -> StreamWaveform {
        var view = StreamWaveform(columns: plot.columns, breaks: plot.breaks, selection: selection,
                                  height: compact && height == .standard ? 150 : height.points, xAxis: true)
        view.board = recordingBoard
        view.style = bench.waveformStyle
        view.baseline = plot.stats.baseline
        view.baselineSpan = bench.waveformScale.baselineSpan ?? 0
        view.fullScale = bench.waveformScale == .full
        view.faults = plot.faults
        view.rails = plot.rails
        view.lowRails = plot.lowRails
        view.highRails = plot.highRails
        view.dots = plot.dots
        view.means = plot.means
        view.metalFailed = $metalFailed
        view.metalPresentation = $metalPresented
        view.gaps = plot.gaps
        view.samples = plot.samples
        view.flagTimes = (content?.entries ?? []).filter { $0.state == .placed }.compactMap { time($0.position) }
        view.cursorTimes = [picked?.time ?? (original?.state == .unavailable ? nil : time(original?.position))].compactMap { $0 }
        view.referenceTime = request.frozen?.bounds.upper
        view.navigate = navigate
        view.cursor = pick
        view.home = { range = bounds }
        return view
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(original == nil ? (flag ? "New Flag" : "New Note") : (flag ? "Edit Flag" : "Edit Note"))
                    .font(.headline)
                Spacer()
                if original == nil, bounds != nil {
                    Picker("Entry type", selection: $flag) {
                        Text("Flag").tag(true)
                        Text("Note").tag(false)
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            if flag {
                if let picked {
                    let value = picked.readingLabel
                    Text("\(format(picked.time)) s · \(picked.indexLabel) · \(value)")
                        .font(.callout.monospacedDigit())
                } else if let position = original?.position, let seconds = time(position) {
                    let value = position.readingLabel
                    Text("\(format(seconds)) s · Sample \(position.index.formatted()) · \(value)").font(.callout.monospacedDigit())
                } else {
                    Text("Click the waveform to choose a sample.").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Flag label", text: $label).textFieldStyle(.roundedBorder)
            }
            TextField(flag ? "Note (optional)" : "Note", text: $note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            if label.utf8.count > 120 || note.utf8.count > 8192 {
                Text("Shorten the label to 120 bytes or the note to 8,192 bytes.").font(.caption).foregroundStyle(.secondary)
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(problem ? Color.orange : .secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if original != nil {
                Button("New Entry") { newEntry(flag: flag) }.disabled(bench.timelineSaving)
                Button("Remove…", role: .destructive) { confirmRemoval = true }.disabled(bench.timelineSaving)
            }
            if hasChanges {
                Button("Discard Changes") {
                    cancelPick()
                    picked = nil
                    label = original?.label ?? ""
                    note = original?.note ?? ""
                    status = nil
                    problem = false
                }.disabled(bench.timelineSaving)
            }
            Spacer()
            Button(bench.timelineSaving ? "Saving…" : flag ? "Save Flag" : "Save Note", action: save)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
        }
    }

    private func entryList(_ entries: [RunTimelineEntry]) -> some View {
        DisclosureGroup("Saved flags and notes (\(entries.count))") {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(entries) { entry in
                    Button {
                        cancelPick()
                        original = entry
                        flag = entry.position != nil
                        label = entry.label
                        note = entry.note
                        picked = nil
                        status = stateText(entry)
                        problem = entry.state == .unavailable
                        if let value = time(entry.position), let bounds, value >= bounds.lower, value < bounds.upper {
                            setRange(center: value, width: min(2, bounds.upper - bounds.lower))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(entry.label.isEmpty ? entry.note : entry.label, systemImage: entry.position == nil ? "note.text" : "flag")
                                .lineLimit(1)
                            Text(stateText(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.link).disabled(bench.timelineSaving)
                }
            }.padding(.top, 7)
        }
    }

    private func time(_ position: RunTimelineEntry.Position?) -> Double? {
        guard let position else { return nil }
        if let run = content?.reader.run { return RunTimeline.time(of: position, in: run) }
        if let frozen = request.frozen, position.segment == frozen.segment { return frozen.time(position.index) }
        return nil
    }

    private func stateText(_ entry: RunTimelineEntry) -> String {
        switch entry.state {
        case .note: entry.created.formatted(date: .abbreviated, time: .shortened)
        case .pending: "Waiting for the selected sample to reach disk"
        case .unavailable: "The selected sample was lost. The label and any note were kept."
        case .placed: time(entry.position).map { "\(format($0)) s" } ?? "Sample saved"
        }
    }

    private func newEntry(flag: Bool) {
        cancelPick()
        original = nil
        picked = nil
        label = ""
        note = ""
        status = nil
        problem = false
        self.flag = flag
    }

    private func save() {
        var entry = original ?? RunTimelineEntry(click: request.frozen?.click)
        entry.label = flag ? label.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        entry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if flag, let picked {
            entry.position = RunTimelineEntry.Position(picked)
            entry.state = .pending
        } else if !flag {
            entry.position = nil
            entry.state = .note
        }
        persist(entry, remove: false)
    }

    private func persist(_ entry: RunTimelineEntry, remove: Bool) {
        let revision = original?.revision
        Task {
            do {
                let saved = try await bench.writeTimeline(entry, replacing: revision, run: request.runID, removing: remove)
                if remove { newEntry(flag: flag) }
                else {
                    original = saved
                    label = saved.label
                    note = saved.note
                    picked = nil
                    problem = saved.state == .unavailable
                    status = saved.state == .pending || saved.state == .unavailable ? stateText(saved) : saved.state == .note ? "Note saved." : "Flag saved."
                }
                await refresh()
            } catch { status = error.localizedDescription; problem = true }
        }
    }

    private func refresh(initial: Bool = false) async {
        let startedLive = live
        do {
            let latest = try await bench.timelineLoad(for: request)
            guard !Task.isCancelled, bench.timeline?.id == request.id, startedLive == live else { return }
            content = latest
            if (initial || range == nil) && request.frozen == nil, latest.duration > 0 {
                range = .init(lower: 0, upper: latest.overview == nil ? min(2, latest.duration) : latest.duration)
            }
            if let original, original.state == .pending,
               let updated = latest.entries.first(where: { $0.id == original.id }), updated.state != .pending {
                self.original = updated
                status = updated.state == .placed ? "Flag saved." : stateText(updated)
                problem = updated.state == .unavailable
            }
        } catch {
            if !Task.isCancelled { status = error.localizedDescription; problem = true }
        }
        loading = false
    }

    private func navigate(_ anchor: Double?, _ amount: Double) {
        guard let range else { return }
        let width = range.upper - range.lower
        if let anchor {
            let next = width * exp2(amount)
            let limited = min((bounds?.upper ?? range.upper) - (bounds?.lower ?? range.lower),
                              max(next, minimumWidth))
            setRange(center: range.lower + anchor * width + (0.5 - anchor) * limited, width: limited)
        } else {
            setRange(center: (range.lower + range.upper) / 2 + amount * width, width: width)
        }
    }

    private var minimumWidth: Double { 2 / (request.frozen?.rate ?? (content?.reader.run.settings.recordedRate ?? Double(StreamWire.rate))) }

    private func setRange(center: Double, width: Double) {
        guard let bounds else { return }
        let width = min(bounds.upper - bounds.lower, max(minimumWidth, width))
        let start = max(bounds.lower, min(bounds.upper - width, center - width / 2))
        range = .init(lower: start, upper: min(bounds.upper, start + width))
    }

    private struct PlotRequest: Equatable {
        var range: StreamSelection?
        var density: Double?
        var indexed: Bool
    }

    private func updatePlot() async {
        guard let range else { return }
        let frozen = request.frozen, reader = content?.reader, overview = content?.overview
        let density = bench.waveformStyle == .points ? bench.dotDensity : nil
        try? await Task.sleep(for: .nanoseconds(1_000_000_000 / max(1, bench.reviewFPS)))
        guard !Task.isCancelled else { return }
        if plot != nil { try? await Task.sleep(for: .milliseconds(35)) }
        guard !Task.isCancelled else { return }
        let worker = Task.detached(priority: .utility) {
            if let frozen { return try frozen.plot(range, dotPercent: density) }
            guard let reader else { throw StreamFailure.storage("Open the saved recording to view its waveform.") }
            let span = range.upper - range.lower
            let rawPossible = span * reader.run.settings.recordedRate
            if let overview, density == nil ? span > 12 : rawPossible > Double(WaveformDots.rawReadLimit) {
                var summary = overview.plot(range)
                if let density { summary.dots = .averages(summary.means, percent: density) }
                return summary
            }
            guard rawPossible <= Double(WaveformDots.rawReadLimit) else {
                throw StreamFailure.storage("Choose a shorter range while the overview is being prepared.")
            }
            return try StreamStudio.plot(reader, selection: range, dotPercent: density)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            renderedRange = range
            plot = result
        } catch {
            if !Task.isCancelled { status = error.localizedDescription; problem = true }
        }
    }

    private func cancelPick() {
        pickWork?.cancel()
        picking = false
    }

    private func pick(_ time: Double) {
        guard flag, renderedRange == range else { return }
        cancelPick()
        if let frozen = request.frozen { accept(frozen.sample(at: time)); return }
        guard let reader = content?.reader else { return }
        picking = true
        pickWork = Task {
            let worker = Task.detached { try RunTimeline.sample(at: time, in: reader) }
            do {
                let sample = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                picking = false
                accept(sample)
            } catch {
                if !Task.isCancelled { picking = false; status = error.localizedDescription; problem = true }
            }
        }
    }

    private func accept(_ sample: WaveformSample?) {
        guard let sample else { status = "No sample at this position. Choose outside the gap."; problem = true; return }
        picked = sample
        status = nil
        problem = false
    }

    private func format(_ seconds: Double) -> String { seconds.formatted(.number.precision(.fractionLength(0...6))) }
}
