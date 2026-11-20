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
    @State private var invalidPick = false
    @State private var suggested: WaveformSample?
    @State private var selectedFlagID: UUID?
    @State private var undo: FlagUndo?
    private struct FlagUndo {
        let before: RunTimelineEntry
        let after: UUID?
    }
    private var chosen: WaveformSample? { picked ?? (flag && original == nil ? suggested : nil) }
    private var orderedFlags: [RunTimelineEntry] {
        (content?.entries ?? []).filter { $0.state == .placed || $0.state == .pending }
            .sorted { (time($0.position) ?? .infinity, $0.id.uuidString) < (time($1.position) ?? .infinity, $1.id.uuidString) }
    }

    private func neighbor(_ forward: Bool) -> RunTimelineEntry? {
        let flags = orderedFlags
        if let i = flags.firstIndex(where: { $0.id == selectedFlagID }) {
            let next = i + (forward ? 1 : -1)
            return flags.indices.contains(next) ? flags[next] : nil
        }
        let anchor = chosen?.time ?? range?.lower ?? 0
        return forward ? flags.first { (time($0.position) ?? .infinity) >= anchor } ?? flags.first
            : flags.last { (time($0.position) ?? .infinity) <= anchor } ?? flags.last
    }

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
    @State private var usingSavedWaveform = false
    @State private var timeInput = ""
    @State private var pendingRemoval: RunTimelineEntry?
    private var frozen: FrozenFlagWaveform? { usingSavedWaveform ? nil : request.frozen }

    private var live: Bool { bench.recording && bench.current?.id == request.runID }
    private var bounds: StreamSelection? {
        if let frozen { return frozen.bounds }
        guard let content, content.duration > 0 else { return nil }
        return .init(lower: 0, upper: content.duration)
    }
    private var hasChanges: Bool { label != (original?.label ?? "") || note != (original?.note ?? "") || picked != nil }
    private var canSave: Bool {
        guard !bench.timelineSaving, !picking, (!flag || !invalidPick), !bench.needsProjectAccess, content != nil,
              label.utf8.count <= 120, note.utf8.count <= 8192 else { return false }
        return flag ? ((chosen != nil || original?.position != nil) && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    if let entries = content?.entries { entryList(entries) }
                }
                .padding(20).frame(maxWidth: 950, alignment: .leading).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer.padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(minWidth: 495, minHeight: 450)
        .task(id: request.id) {
            newEntry(flag: request.tool != .note)
            usingSavedWaveform = false
            range = frozen?.bounds
            if request.tool == .flag, let frozen, frozen.end > frozen.first {
                suggested = frozen.sample(atIndex: frozen.end - 1)
                timeInput = suggested.map { format($0.time) } ?? ""
            }
            await refresh(initial: true)
        }
        .task(id: PlotRequest(range: range, density: bench.waveformStyle == .points ? bench.dotDensity : nil,
                              indexed: content?.overview != nil, usingSavedWaveform: usingSavedWaveform)) {
            await updatePlot()
        }
        .onDisappear { cancelPick() }
        .onChange(of: flag) { _, _ in cancelPick() }
        .onChange(of: hasChanges) { _, dirty in bench.timelineChanged(request.id, dirty: dirty) }
        .onChange(of: live) { _, isLive in
            if !isLive { usingSavedWaveform = true }
            Task { await refresh() }
        }
        .onChange(of: bench.timelineRevision) { _, _ in
            if !bench.timelineSaving { Task { await refresh() } }
        }
        .onChange(of: bench.qualityRevisions[request.runID]) { _, _ in
            if !live && request.frozen == nil { Task { await refresh() } }
        }
        .onChange(of: bench.preview.committedBoundary) { _, boundary in
            guard live, content?.entries.contains(where: {
                $0.state == .pending && ($0.position?.index ?? .max) < boundary
            }) == true else { return }
            Task { await refresh() }
        }
        .confirmationDialog("Remove this flag or note?", isPresented: $confirmRemoval) {
            Button("Remove Entry", role: .destructive) {
                if let pendingRemoval { persist(pendingRemoval, remove: true) }
                pendingRemoval = nil
            }
        } message: {
            Text("The raw samples stay in the recording.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(frozen != nil ? "Place a Flag" : request.tool == .note ? "Flags & Notes" : "Flag Manager").font(.title2.weight(.semibold))
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
            if live {
                if frozen == nil {
                    Button("Freeze Latest Waveform…") { bench.openLiveTimeline(.flag, replacing: true) }
                        .disabled(hasChanges || bench.preview.received == 0)
                } else {
                    Button("Browse Saved Samples") {
                        usingSavedWaveform = true
                        Task { await refresh() }
                    }.disabled(content?.duration == 0)
                }
            }
            if let frozen {
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
            HStack {
                Button("Previous Flag") { if let prior = neighbor(false) { Task { await jump(to: prior) } } }
                    .disabled(neighbor(false) == nil || hasChanges)
                Button("Next Flag") { if let next = neighbor(true) { Task { await jump(to: next) } } }
                    .disabled(neighbor(true) == nil || hasChanges)
                if let entry = orderedFlags.first(where: { $0.id == selectedFlagID }), let time = time(entry.position) {
                    Text("\(entry.label) · \(format(time)) s").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
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
        view.pendingFlagTimes = (content?.entries ?? []).filter { $0.state == .pending }.compactMap { time($0.position) }
        let selected = orderedFlags.first { $0.id == selectedFlagID }
        view.cursorTimes = [picked?.time ?? time(selected?.position)
            ?? (original?.state == .unavailable ? nil : time(original?.position)) ?? chosen?.time].compactMap { $0 }
        view.referenceTime = request.frozen?.bounds.upper
        view.navigate = navigate
        view.cursor = { pick($0) }
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
                if invalidPick {
                    Text("Choose a sample to place the flag.").font(.callout).foregroundStyle(.secondary)
                } else if let picked = chosen {
                    let value = picked.readingLabel
                    Text("\(format(picked.time)) s · \(picked.indexLabel) · \(value)")
                        .font(.callout.monospacedDigit())
                } else if let position = original?.position, let seconds = time(position) {
                    let value = position.readingLabel
                    Text("\(format(seconds)) s · Sample \(position.index.formatted()) · \(value)").font(.callout.monospacedDigit())
                } else {
                    Text("Click the waveform to choose a sample.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Elapsed time in seconds", text: $timeInput)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        .accessibilityLabel("Flag elapsed time in seconds")
                    Button("Use Time") {
                        guard let value = enteredTime else { return }
                        Task {
                            if let recent = request.frozen, live, recent.bounds.containsTime(value) {
                                usingSavedWaveform = false
                            } else {
                                usingSavedWaveform = true
                                if live { await refresh() }
                            }
                            seek(value)
                        }
                    }.disabled(enteredTime == nil || picking || bench.timelineSaving)
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
            if original != nil && !hasChanges {
                Button("New Entry") { newEntry(flag: flag) }.disabled(bench.timelineSaving)
                Button("Remove…", role: .destructive) {
                    pendingRemoval = original
                    confirmRemoval = true
                }.disabled(bench.timelineSaving)
            }
            if hasChanges {
                Button("Discard Changes") {
                    cancelPick()
                    picked = nil
                    invalidPick = false
                    label = original?.label ?? ""
                    note = original?.note ?? ""
                    status = nil
                    problem = false
                }.disabled(bench.timelineSaving)
            }
            if undo != nil && !hasChanges {
                Button("Undo Flag Change", action: undoFlagChange).keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(bench.timelineSaving)
            }
            Spacer()
            Button(bench.timelineSaving ? "Saving…" : flag ? "Save" : "Save Note") { save(close: false) }
                .buttonStyle(.bordered).keyboardShortcut("s", modifiers: .command).disabled(!canSave)
            if flag && (live || request.frozen != nil) {
                Button("Save and Close Flag") { save(close: true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!canSave)
            }
        }
    }

    private func entryList(_ entries: [RunTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("Earlier Flags and Notes").font(.headline)
            if entries.isEmpty { Text("No flags or notes yet.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(entry.label.isEmpty ? entry.note : entry.label,
                              systemImage: entry.position == nil ? "note.text" : "flag")
                            .lineLimit(1)
                        Text(stateText(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if entry.position != nil && entry.state != .unavailable {
                        Button("Jump") { Task { await jump(to: entry) } }
                    }
                    Button("Edit") {
                        newEntry(flag: entry.position != nil)
                        original = entry
                        label = entry.label
                        note = entry.note
                        timeInput = time(entry.position).map(format) ?? ""
                        status = stateText(entry)
                        problem = entry.state == .unavailable
                        Task { await jump(to: entry) }
                    }
                    Button("Remove…") { pendingRemoval = entry; confirmRemoval = true }
                }.disabled(bench.timelineSaving || hasChanges)
            }
        }
    }

    private func jump(to entry: RunTimelineEntry) async {
        guard let position = entry.position, let timestamp = time(position) else { return }
        if let recent = request.frozen, recent.bounds.containsTime(timestamp), entry.state == .pending {
            usingSavedWaveform = false
        } else if frozen?.bounds.containsTime(timestamp) != true {
            usingSavedWaveform = true
            if live { await refresh() }
        }
        guard let bounds, bounds.containsTime(timestamp) else {
            status = "This position is outside the saved waveform. Wait for the sample to be committed."
            problem = true
            return
        }
        selectedFlagID = entry.id
        setRange(center: timestamp, width: min(2, bounds.upper - bounds.lower))
    }

    private var enteredTime: Double? {
        let trimmed = timeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed) ?? (try? Double(trimmed, format: .number)),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func seek(_ seconds: Double) {
        guard let bounds, bounds.containsTime(seconds) else {
            accept(nil)
            return
        }
        if range?.containsTime(seconds) != true {
            setRange(center: seconds, width: range.map { min(2, $0.upper - $0.lower) } ?? 2)
        }
        pick(seconds, requireRenderedRange: false)
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
        case .pending: (time(entry.position).map { "\(format($0)) s · " } ?? "") + "Pending sample save"
        case .unavailable: "The selected sample was lost. The label and any note were kept."
        case .placed: time(entry.position).map { "\(format($0)) s" } ?? "Sample saved"
        }
    }

    private func newEntry(flag: Bool) {
        cancelPick()
        original = nil
        picked = nil
        invalidPick = false
        suggested = nil
        selectedFlagID = nil
        label = ""
        note = ""
        timeInput = ""
        status = nil
        problem = false
        self.flag = flag
    }

    private func save(close: Bool) {
        var entry = original ?? RunTimelineEntry(click: request.frozen?.click)
        entry.label = flag ? label.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        entry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if flag, let picked = chosen {
            entry.position = RunTimelineEntry.Position(picked)
            entry.state = .pending
        } else if !flag {
            entry.position = nil
            entry.state = .note
        }
        persist(entry, remove: false, close: close)
    }

    private func persist(_ entry: RunTimelineEntry, remove: Bool, close: Bool = false) {
        let revision = original?.revision
        let before = original
        let addingLive = live && flag && original == nil && !remove
        Task {
            do {
                let saved = try await bench.writeTimeline(entry, replacing: revision, run: request.runID, removing: remove)
                if close, bench.timeline?.id == request.id {
                    if saved.state == .pending { bench.notice = "Flag saved. Its selected sample is pending." }
                    bench.closeTimeline()
                    return
                }
                if remove {
                    if entry.position != nil { undo = .init(before: entry, after: nil) }
                    if selectedFlagID == entry.id { selectedFlagID = nil }
                    if original?.id == entry.id { newEntry(flag: flag) }
                    status = "Entry removed."
                } else if addingLive {
                    newEntry(flag: true)
                    status = saved.state == .pending ? "Flag saved. Its selected sample is pending." : "Flag saved."
                } else {
                    if let before, before.position != saved.position { undo = .init(before: before, after: saved.revision) }
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

    private func undoFlagChange() {
        guard let undo else { return }
        Task {
            do {
                let restored = try await bench.writeTimeline(undo.before, replacing: undo.after, run: request.runID)
                newEntry(flag: true)
                self.undo = nil
                await refresh()
                await jump(to: restored)
                status = "Flag restored."
            } catch {
                status = error.localizedDescription
                problem = true
            }
        }
    }

    private func refresh(initial: Bool = false) async {
        let startedLive = live
        do {
            let latest = try await bench.timelineLoad(for: request)
            guard !Task.isCancelled, bench.timeline?.id == request.id, startedLive == live else { return }
            content = latest
            if frozen == nil {
                if latest.duration <= 0 {
                    range = nil
                    plot = nil
                    renderedRange = nil
                } else if initial || range.map({ $0.upper > latest.duration }) != false {
                    range = .init(lower: 0, upper: latest.overview == nil ? min(2, latest.duration) : latest.duration)
                }
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
        var usingSavedWaveform: Bool
    }

    private func updatePlot() async {
        guard let range else { return }
        let frozen = self.frozen, reader = content?.reader, overview = content?.overview
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

    private func pick(_ time: Double, requireRenderedRange: Bool = true) {
        guard flag, !requireRenderedRange || renderedRange == range else { return }
        cancelPick()
        if let frozen { accept(frozen.sample(at: time)); return }
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
        guard let sample else {
            invalidPick = true
            picked = nil
            status = "No sample at this position. Choose outside the gap."
            problem = true
            return
        }
        invalidPick = false
        picked = sample
        selectedFlagID = nil
        timeInput = format(sample.time)
        status = nil
        problem = false
    }

    private func format(_ seconds: Double) -> String { seconds.formatted(.number.precision(.fractionLength(0...6))) }
}
