import AppKit
import SwiftUI

struct StreamingWorkspace: View {
    @ObservedObject var bench: StreamingBench
    @State private var viewerHidden = false
    @State private var showDurationEditor = false
    @State private var confirmDurationFinish = false
    @State private var durationHours = ""
    @State private var durationMinutes = ""
    @State private var durationSeconds = ""
    @State private var name = ""
    @State private var description = ""
    @State private var minutes = 5
    @State private var manualMinutes = 120
    @State private var opticalMinutes = 120
    @State private var channel = 0
    @State private var source = "CSA"
    @State private var wiringConfirmed = false
    @State private var showWiring = false
    @State private var showHumTest = false
    @State private var deviceCandidates = false
    @State private var candidateSettings = UnoCandidateSettings()
    private var canUseDeviceCandidates: Bool {
        bench.supportsDeviceCandidates && bench.board == .unoR4 && bench.sampleRate == 100_000 &&
            bench.adcAveraging == nil && selectedChannel == 0 &&
            [.main, .manual, .diagnosis].contains(bench.mode)
    }
    @State private var humTestID: UUID?
    @State private var pin = 0
    @State private var output: UInt8?
    @State private var profileID: UUID?
    @State private var prerunLength = CalibratedPrerun.Length.five
    @State private var measurementLength = CalibratedPrerun.Measurement.five
    @State private var setupConfirmed = false
    @State private var background = true
    @State private var pendingProjectName: String?
    @State private var pendingArchive: (ProjectArchiveRequest, String)?
    @State private var liveDetails = false
    @State private var confirmAnalysisSetup = false
    @State private var showSettings = false
    @State private var showJobs = false
    @State private var showRawWiring = false
    @State private var rawWiringChecked = false
    @FocusState private var focusedPage: StreamingBench.Page?

    init(bench: StreamingBench) {
        self.bench = bench
    }

    #if STREAM_TESTING
    init(diagnosisLayout bench: StreamingBench) {
        self.bench = bench
        _showHumTest = State(initialValue: true)
    }

    init(bench: StreamingBench, layoutProfile: UUID, layoutPrerun: CalibratedPrerun.Length, layoutLiveDetails: Bool = false) {
        self.bench = bench
        _profileID = State(initialValue: layoutProfile)
        _prerunLength = State(initialValue: layoutPrerun)
        _setupConfirmed = State(initialValue: true)
        _name = State(initialValue: "Dark detector control")
        _description = State(initialValue: "Rev E.1 on the bench.")
        _liveDetails = State(initialValue: layoutLiveDetails)
        _viewerHidden = State(initialValue: layoutLiveDetails)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if bench.project != nil { header }
            if let notice = bench.notice ?? (bench.needsProjectAccess ? "Reopen the original Project to continue." : nil) {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(notice).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if bench.needsProjectAccess {
                        Button("Reopen Project…") { bench.openProject() }.fixedSize().disabled(bench.busy)
                    }
                    Button("Dismiss", systemImage: "xmark") { bench.notice = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
                }.padding(.horizontal, 20).padding(.vertical, 9).background(.background.secondary)
            }
            Divider()
            if let project = bench.project {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    if bench.recording { recordingPage }
                    else if let draft = bench.draftDecision, !bench.needsProjectAccess {
                        StreamStudioView(bench: bench, reader: .init(store: project, run: draft), rename: {}, resume: {})
                            .id(draft.id)
                    } else {
                        switch bench.page {
                        case .overview: ProjectOverviewPane(bench: bench)
                        case .study: BenchStudyView(bench: bench, project: project).id(project.identity.id)
                        case .library: StreamLibrary(bench: bench)
                        case .calibration: ProjectCalibrationPane(bench: bench)
                        default: recordingPage
                        }
                    }
                }
            } else { emptyProject }
            if let operation = bench.operation {
                Divider()
                HStack(spacing: 12) {
                    if let progress = bench.operationProgress {
                        ProgressView(value: progress).frame(width: 76)
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(operation)
                    Spacer()
                    Button("Cancel") { bench.cancelWork() }
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .sheet(item: $bench.projectDialog, onDismiss: {
            if let name = pendingProjectName {
                pendingProjectName = nil
                bench.newProject(name)
            }
        }) { _ in
            StreamMetadataSheet(title: "New Project", name: "", description: nil, actionTitle: "Choose Parent…") { name, _ in
                pendingProjectName = name
            }
        }
        .sheet(item: $bench.archiveRequest, onDismiss: {
            if let (request, name) = pendingArchive {
                pendingArchive = nil
                bench.exportProjectArchive(request, name: name)
            }
        }) { request in
            ProjectArchiveSheet(request: request) { name in pendingArchive = (request, name) }
        }
        .sheet(isPresented: $showSettings) {
            if let project = bench.project { ProjectSettingsPane(bench: bench, project: project) }
        }
        .onChange(of: bench.page, initial: true) { _, page in
            if let mode = page.recordingMode { bench.mode = mode }
            if page == .record { minutes = bench.defaults.minutes }
            rawWiringChecked = false
        }
        .onChange(of: canUseDeviceCandidates) { _, available in if !available { deviceCandidates = false } }
        .onChange(of: bench.connectionEpoch) { _, _ in setupConfirmed = false; wiringConfirmed = false; rawWiringChecked = false; pin = bench.board == .unoR4 ? 2 : 0 }
        .onChange(of: bench.project?.identity.id) { _, _ in
            setupConfirmed = false; profileID = nil; humTestID = nil; showHumTest = false
        }
        .confirmationDialog("Drive \(bench.board.digitalPin(pin))?", isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
            Button(output == 5 ? "Drive High" : "Drive Low") {
                if let output { bench.pin(pin, output) }
                output = nil
            }
        } message: {
            Text("Confirm the pin is safe to drive. Outputs release on Stop, USB loss or lease expiry.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Project") {
                    ForEach(StreamingBench.Page.allCases) { page in
                        let selected = bench.page == page
                        Button {
                            bench.page = page
                        } label: {
                            Label {
                                Text(page.rawValue).fontWeight(selected ? .semibold : .regular)
                            } icon: {
                                Image(systemName: page.symbol).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            }
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedPage, equals: page)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .listRowBackground(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(bench.recording || bench.draftDecision != nil)
            .onKeyPress(.upArrow) { moveSidebarFocus(-1) }
            .onKeyPress(.downArrow) { moveSidebarFocus(1) }
            Divider()
            SidebarActivity().padding(.horizontal, 14).padding(.vertical, 10)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 12) {
                Button("Project Settings", systemImage: "gearshape") { showSettings = true }
                    .disabled(bench.busy)
                Button("Save and Close Project", systemImage: "rectangle.portrait.and.arrow.right") { bench.closeProject() }
                    .disabled((bench.busy && !bench.recording && !bench.projectReviewRunning) || bench.needsProjectAccess)
            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(width: 185).background(.regularMaterial)
    }

    private func moveSidebarFocus(_ delta: Int) -> KeyPress.Result {
        let pages = StreamingBench.Page.allCases
        guard !bench.recording, bench.draftDecision == nil, let focusedPage, let index = pages.firstIndex(of: focusedPage) else { return .ignored }
        let next = index + delta
        if pages.indices.contains(next) {
            self.focusedPage = pages[next]
            bench.page = pages[next]
        }
        return .handled
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bench.project?.identity.name ?? "Signal Bench").font(.headline).lineLimit(1)
                    if let project = bench.project {
                        Button { NSWorkspace.shared.open(project.folder) } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 10)
                Text("Device").font(.caption).foregroundStyle(.secondary)
                Picker("Recording device", selection: Binding(get: { bench.board }, set: bench.selectBoard)) {
                    ForEach(AcquisitionBoard.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().disabled(!bench.canSwitchBoard)
                    .help(bench.canSwitchBoard ? "Choose the recording device" : "Disconnect and finish saving before switching devices")
                Button { showJobs.toggle() } label: {
                    HStack(spacing: 6) {
                        if bench.jobsActive { ProgressView().controlSize(.small) }
                        else { Image(systemName: "list.bullet.rectangle") }
                        Text("Jobs")
                    }
                }.popover(isPresented: $showJobs, arrowEdge: .bottom) { ProjectJobsView(bench: bench) }
                Menu("Project", systemImage: "folder") {
                    Button("New Project…") { bench.projectDialog = .new }
                    Button("Open Project…") { bench.openProject() }
                    Button("Export Projects as ZIP…") { bench.chooseProjectsToArchive() }
                        .disabled(!bench.canExportProjects)
                    Button("Show Exports in Finder") { bench.showExports() }.disabled(bench.project == nil)
                }.fixedSize().disabled(bench.busy || bench.draftDecision != nil)
            }
            ViewThatFits(in: .horizontal) {
                HStack { connectionLabel; Spacer(minLength: 12); connectionControls }
                VStack(alignment: .leading, spacing: 8) { connectionLabel; connectionControls }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var connectionLabel: some View {
        HStack(spacing: 8) {
            Circle().fill(bench.streaming ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(bench.status).font(.callout.weight(.medium))
            if !bench.firmware.isEmpty { Text("Firmware \(bench.firmware)").font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var connectionControls: some View {
        HStack {
            Text("USB").font(.caption).foregroundStyle(.secondary)
            Picker("USB port", selection: $bench.port) {
                if bench.ports.isEmpty { Text("No USB port").tag("") }
                ForEach(bench.ports, id: \.self) { Text(String($0.dropFirst(5))).tag($0) }
            }.labelsHidden().fixedSize().disabled(bench.connected || bench.connecting)
            Button("Refresh USB ports", systemImage: "arrow.clockwise") { bench.refreshPorts() }
                .labelStyle(.iconOnly).help("Refresh USB ports").disabled(bench.connected)
            Button(bench.connected ? "Disconnect" : "Connect") { bench.toggleConnection() }
                .disabled(bench.connecting || bench.recording || (bench.port.isEmpty && !bench.connected))
        }.fixedSize()
    }

    private var emptyProject: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Signal Bench").font(.largeTitle.weight(.semibold))
            Text("Each recording saves directly to the Project you choose.").foregroundStyle(.secondary)
            HStack {
                Button("New Project…") { bench.projectDialog = .new }.buttonStyle(.borderedProminent)
                Button("Open Project…") { bench.openProject() }
            }
            Button("Export Projects as ZIP…", systemImage: "archivebox") { bench.chooseProjectsToArchive() }
                .disabled(!bench.canExportProjects)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if bench.recording { activeRecording }
                    else {
                        Text(bench.mode.rawValue).font(.largeTitle.weight(.semibold))
                        if bench.mode == .manualRaw { rawOpticalControls }
                        if bench.mode == .calibrated {
                            calibratedControls
                        } else if bench.mode == .diagnosis, let project = bench.project {
                            Picker("Diagnosis tool", selection: $showHumTest) {
                                Text("Stage Probes").tag(false)
                                Text("60 Hz Test").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                            if showHumTest {
                                MainsHumTestView(bench: bench, project: project, selectedTest: $humTestID).id(project.identity.id)
                            } else {
                                diagnosisControls
                                Divider()
                                runFields
                            }
                        } else {
                            if bench.mode == .manual {
                                Text("Records \(bench.board.analogPin(0)) and shows GPIO state. Controllable pins start as inputs.").foregroundStyle(.secondary)
                            }
                            Divider()
                            runFields
                        }
                    }
                }.padding(20).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            if bench.mode == .calibrated && !bench.recording {
                Divider()
                calibratedFooter
            }
        }
        .onAppear { updateViewer() }
        .onChange(of: bench.current?.settings.mainsHum) { _, capture in
            if let capture { showHumTest = true; humTestID = capture.test }
        }
        .onChange(of: viewerHidden) { _, _ in updateViewer() }
        .onChange(of: bench.liveFPS) { _, _ in updateViewer() }
        .onChange(of: bench.activeMode) { _, _ in updateViewer() }
        .onChange(of: bench.mode) { _, _ in
            setupConfirmed = false
            wiringConfirmed = false
        }
        .onChange(of: channel) { _, _ in
            wiringConfirmed = false
        }
        .onChange(of: bench.sampleRate) { _, _ in
            setupConfirmed = false
            profileID = nil
            bench.invalidateSetup()
        }
        .onChange(of: bench.adcAveraging) { _, _ in
            setupConfirmed = false
            profileID = nil
            bench.invalidateSetup()
        }
        .onChange(of: source) { _, _ in wiringConfirmed = false }
    }

    private func updateViewer() {
        let shown = !viewerHidden || bench.activeMode == .manual
        bench.configureViewer(shown: shown)
    }

    private var durationInput: Binding<Int> {
        switch bench.mode {
        case .manual: $manualMinutes
        case .manualRaw: $opticalMinutes
        default: $minutes
        }
    }

    private var selectedChannel: Int { bench.mode == .diagnosis ? channel : 0 }

    private var runFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bench.mode == .diagnosis {
                TextField("Run name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            SamplingRatePicker(bench: bench, selection: $bench.sampleRate,
                               channel: selectedChannel, seconds: Double(durationInput.wrappedValue) * 60,
                               averaging: $bench.adcAveraging, gpio: bench.mode == .manual)
            if bench.mode == .main && bench.defaults.afterRecording == .profile {
                if let profile = mainAnalysisProfile {
                    Toggle("Use \(profile.name) for post processing. The checked setup is still connected.",
                           isOn: $confirmAnalysisSetup)
                } else {
                    Text("A matching dark setup check is needed for automatic pulse analysis. This run can still record raw data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if canUseDeviceCandidates {
                Toggle("Device Candidates", isOn: $deviceCandidates)
                if deviceCandidates {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Keep the input quiet for the first second. These diagnostic candidates are saved separately from the raw waveform.")
                            .font(.caption).foregroundStyle(.secondary)
                        candidateField("Threshold (ADC codes)", $candidateSettings.threshold)
                        candidateField("Minimum width (µs)", $candidateSettings.minWidthUS)
                        candidateField("Maximum width (µs)", $candidateSettings.maxWidthUS)
                        candidateField("Separation (µs)", $candidateSettings.separationUS)
                        candidateField("Baseline shift limit (ADC codes)", $candidateSettings.driftLimit)
                        candidateField("Noise limit (ADC codes RMS)", $candidateSettings.noiseLimit)
                        if !candidateSettings.valid { Text("Check the candidate limits before starting.").foregroundStyle(.orange) }
                    }.padding(.leading, 12)
                }
            }
            let isManual = bench.mode == .manual || bench.mode == .manualRaw
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { startControls(isManual: isManual) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { startControls(isManual: isManual) }
            }
            if !bench.streaming { Text("Connect \(bench.board.title) with Signal Bench firmware to start.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func candidateField(_ title: String, _ value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.grouping(.never))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
        }
    }

    @ViewBuilder private func startControls(isManual: Bool) -> some View {
        let time = durationInput
        HStack(spacing: 6) {
            Text(isManual ? "Time limit" : "Duration").foregroundStyle(.secondary)
            TextField("Minutes", value: time, format: .number).frame(width: 56)
            Text("min").foregroundStyle(.secondary)
            Stepper("Minutes", value: time, in: 1...120).labelsHidden()
        }.fixedSize()
        if bench.defaults.startupDelay > 0 {
            Text("\(bench.defaults.startupDelay) s settling before recording")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Start Recording", systemImage: "record.circle") { start() }
            .buttonStyle(.borderedProminent).disabled(!ready)
    }

    private var rawOpticalControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Relative optical response").font(.headline)
                Button("Bare sensor wiring", systemImage: "info.circle") { showRawWiring = true }
                    .labelStyle(.iconOnly).help("Bare sensor wiring")
            }
            Toggle("I checked polarity and ADC voltage with the Devboard disconnected", isOn: $rawWiringChecked)
            Text("Bench validation pending. The monitor shows ADC codes and clipping.").font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $showRawWiring) {
            StudioHelpPopup(title: "Bare FDS1010 optical check",
                            detail: bench.board == .unoR4 ? "Disconnect the Devboard. Use A0 and a verified optical input circuit with a defined return to GND. Observe the input voltage with a meter or scope before recording." : "Proposed zero bias hookup. Disconnect the Devboard and remove USB power before wiring. Verify polarity and voltage before connecting. Anode to physical pin 31 GP26. Cathode to physical pin 33 AGND.",
                            assets: bench.board == .unoR4 ? [] : ["ManualRawWiring", "SetupPicoPhoto"], illustration: false) { showRawWiring = false }
        }
    }

    private var activeRecording: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    recordingTitle.fixedSize()
                    Spacer(minLength: 10)
                    stopButton
                }
                VStack(alignment: .leading, spacing: 8) { recordingTitle; stopButton }
            }
            if let duration = bench.current?.settings.duration {
                liveDurationControls(duration)
                ProgressView(value: min(duration, recordingElapsed), total: duration)
                    .accessibilityLabel("Recording progress")
            }
            let data = bench.preview
            if bench.activeMode == .diagnosis { DiagnosisHealthView(data: data, stopping: bench.stopping) }
            let hidden = viewerHidden && bench.activeMode != .manual
            if bench.activeMode != .manual {
                HStack {
                    Button(hidden ? "Show Viewer" : "Hide Viewer", systemImage: hidden ? "eye" : "eye.slash") {
                        viewerHidden.toggle()
                    }
                    if hidden {
                        Button("Add Note…", systemImage: "note.text") { openTimeline(.note) }
                            .disabled(bench.timelineSaving)
                    }
                }
            }
            if !hidden {
                LiveWaveformPane(bench: bench, addNote: { openTimeline(.note) })
            }
            if bench.activeMode == .manual {
                Divider()
                manualControls
            }
            DisclosureGroup("Live Details", isExpanded: $liveDetails) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    timingProgress(data)
                    sampleProgress(data)
                    signalQuality(data)
                }.padding(.top, 8)
            }

        }
    }

    private var editableDuration: Bool {
        bench.recording && !bench.stopping && !bench.changingLiveDuration &&
            bench.current?.settings.allowsLiveDurationEdit == true && bench.current?.segments.last != nil && (bench.preview.received > 0 || bench.preview.settlingRemaining != nil)
    }

    private var durationInputSeconds: Double? {
        guard let hours = Int(durationHours), (0...2).contains(hours),
              let minutes = Int(durationMinutes), (0...59).contains(minutes),
              let seconds = Int(durationSeconds), (0...59).contains(seconds) else { return nil }
        let total = Double(3600 * hours + 60 * minutes + seconds)
        return (1...StreamWire.maxDuration).contains(total) ? total : nil
    }

    private func timerLabel(_ seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds).rounded(.up))).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func liveDurationControls(_ target: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { timerValues(target) }.fixedSize()
                VStack(alignment: .leading, spacing: 8) { timerValues(target) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { timeActions(target); flagActions }.fixedSize()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { timeActions(target) }
                    HStack { flagActions }
                }
            }
        }
        .sheet(isPresented: $showDurationEditor) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit Recording Duration").font(.title2.weight(.semibold))
                Text("Enter the total time from the start of logging. The startup delay is separate.")
                    .foregroundStyle(.secondary)
                HStack {
                    durationField("Hours", $durationHours)
                    durationField("Minutes", $durationMinutes)
                    durationField("Seconds", $durationSeconds)
                }.textFieldStyle(.roundedBorder)
                if let total = durationInputSeconds {
                    Text("Time remaining: " + timerLabel(total - recordingElapsed)).monospacedDigit()
                    if total <= recordingElapsed {
                        Text("The new target has elapsed. Applying it finishes and saves the current block.")
                            .foregroundStyle(.secondary)
                    } else if let run = bench.current, total > target,
                              let estimate = RecordingEstimate(rate: run.settings.nominalRate,
                                averaging: run.settings.picoAveraging, seconds: total - target,
                                gpio: run.settings.mode == .manual, location: nil, board: run.settings.board) {
                        Text("Budget about " + ByteCountFormatter.string(fromByteCount: estimate.projectBytes, countStyle: .file)
                             + " for the extension, including recording overhead.").foregroundStyle(.secondary)
                    }
                } else { Text("Enter a total between 1 second and 2 hours.").foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { showDurationEditor = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(durationInputSeconds.map { $0 <= recordingElapsed } == true ? "Finish and Save" : "Apply") {
                        guard let total = durationInputSeconds else { return }
                        if total <= recordingElapsed { confirmDurationFinish = true }
                        else { bench.changeLiveDuration(total); showDurationEditor = false }
                    }.keyboardShortcut(.defaultAction).disabled(!editableDuration || durationInputSeconds == nil)
                }
            }.padding(22).frame(width: 420)
                .confirmationDialog("Finish the recording now?", isPresented: $confirmDurationFinish) {
                    Button("Finish and Save") {
                        guard let total = durationInputSeconds else { return }
                        bench.changeLiveDuration(total, finishIfElapsed: true)
                        showDurationEditor = false
                    }
                }
        }
    }

    private func durationField(_ label: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(label, text: value).accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func timerValues(_ target: Double) -> some View {
        metric("Elapsed", timerLabel(recordingElapsed))
        metric("Remaining", timerLabel(target - recordingElapsed))
        metric("Target", timerLabel(target))
    }

    @ViewBuilder
    private func timeActions(_ target: Double) -> some View {
        if bench.current?.settings.allowsLiveDurationEdit == true {
            Button("+1 min") { bench.changeLiveDuration(target + 60) }
                .disabled(!editableDuration || target + 60 > StreamWire.maxDuration)
            Button("+5 min") { bench.changeLiveDuration(target + 300) }
                .disabled(!editableDuration || target + 300 > StreamWire.maxDuration)
            Button("Edit Duration…") {
                let whole = Int(target)
                durationHours = String(whole / 3600)
                durationMinutes = String(whole / 60 % 60)
                durationSeconds = String(whole % 60)
                showDurationEditor = true
            }.disabled(!editableDuration)
            if bench.changingLiveDuration { ProgressView().controlSize(.small).accessibilityLabel("Saving duration") }
        }
    }

    @ViewBuilder
    private var flagActions: some View {
        Button("Add Flag…", systemImage: "flag") { openTimeline(.flag) }
            .disabled(bench.preview.received == 0 || bench.timelineSaving)
        Button("Flag Manager…", systemImage: "list.bullet") { openTimeline(.review) }
            .disabled(bench.timelineSaving)
    }

    @Environment(\.openWindow) private var openWindow

    private func openTimeline(_ tool: RunTimelineRequest.Tool) {
        bench.openLiveTimeline(tool)
        if bench.timeline != nil { openWindow(id: "run-timeline") }
    }

    private var recordingElapsed: Double {
        (bench.current?.segments.last?.timelineStart ?? 0) + bench.preview.elapsed
    }

    private var recordingTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(bench.activeMode == .manual ? "Manual recording" : bench.current?.name ?? "Recording")
                .font(.title.weight(.semibold)).lineLimit(2)
            if let remaining = bench.preview.settlingRemaining, !bench.stopping {
                Text("Settling · \(Int(remaining.rounded(.up))) s before recording")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            } else if let settings = bench.current?.settings, settings.mode == .calibrated {
                Text(settings.prerunPlan == nil ? "Measurement" : "Dark prerun")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            } else if bench.activeMode != .manual {
                Text(bench.current?.settings.bench?.step.rawValue ?? bench.activeMode?.rawValue ?? "Recording")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stopButton: some View {
        Button(bench.stopping ? "Saving…" : bench.activeMode == .manual ? "Release Outputs and Stop" : "Stop",
               systemImage: "stop.circle") { bench.stop() }
            .buttonStyle(.borderedProminent).fixedSize().disabled(bench.stopping)
    }

    @ViewBuilder
    private func timingProgress(_ data: LiveStreamPreview) -> some View {
        if let settings = bench.current?.settings {
            metric("Requested",
                   settings.nominalRate.formatted() + " samples/s")
            if let rate = data.configuredRate {
                metric("ADC configured", (rate * Double(settings.factor)).formatted(.number.precision(.fractionLength(0...2))) + " samples/s")
                if settings.factor > 1 {
                    metric("Recorded cadence", rate.formatted(.number.precision(.fractionLength(0...2))) + " readings/s")
                    metric("ADC conversions received", (data.received * UInt64(settings.factor)).formatted())
                }
            }
        }
        metric("Measured recorded cadence", data.rateByPicoTimer.map {
            $0.formatted(.number.precision(.fractionLength(0...2))) + " readings/s"
        } ?? "Measuring…")
        .help("Estimated from the device’s hardware timer. USB delivery and detector pulse counts are separate.")
    }

    @ViewBuilder
    private func sampleProgress(_ data: LiveStreamPreview) -> some View {
        metric("Received", data.received.formatted())
        let draft = bench.activeMode == .manual || bench.activeMode == .manualRaw
        metric(draft ? "Written to draft" : "Saved", data.saved.formatted())
        metric("Known missing", data.loss.formatted())
        metric("ADC conversion errors", data.adcErrors.formatted())
        metric("Low rail hits", data.lowRail.formatted())
        metric("High rail hits", data.highRail.formatted())
    }

    @ViewBuilder
    private func signalQuality(_ data: LiveStreamPreview) -> some View {
        let codes: (Double?) -> String = { value in value.map { $0.formatted(.number.precision(.fractionLength(1))) + " codes" } ?? "Unavailable" }
        if bench.activeMode == .manual {
            metric("Latest \(bench.board.analogPin(0))", codes(data.latestCode.map(Double.init)))
        }
        metric("Baseline · last frame", codes(data.baseline))
        metric("Robust noise · last frame", codes(data.noise))
        metric("Baseline change", codes(data.baselineChange)).help("Change since the last displayed block.")
        let averaged = (bench.current?.settings.factor ?? 1) > 1
        metric(averaged ? "Clipped groups in last block" : "Clipped readings in last block",
               data.clipped.map { $0.formatted() } ?? "Unavailable")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
        }.accessibilityElement(children: .combine)
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GPIO").font(.headline)
                if let gpio = bench.preview.gpio, !gpio.leaseActive {
                    Text("Outputs released").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Release Outputs", systemImage: "lock.open") { bench.release() }
                    .disabled(bench.stopping || bench.preview.gpio?.leaseActive == false)
                    .help("Return controllable pins to inputs while keeping the recording running")
            }
            HStack {
                Picker("Pin", selection: $pin) {
                    ForEach((0..<29).filter { bench.controllableGPIO & (1 << $0) != 0 }, id: \.self) { Text(bench.board.digitalPin($0)).tag($0) }
                }.fixedSize()
                Button("Input") { bench.pin(pin, 3) }
                Button("Low") { output = 4 }.disabled(bench.preview.gpio?.leaseActive != true)
                Button("High") { output = 5 }.disabled(bench.preview.gpio?.leaseActive != true)
                if let gpio = bench.preview.gpio {
                    let mask = UInt32(1) << pin
                    Text(gpio.directions & mask == 0 ? "Input" : "Output")
                    Text(gpio.levels & mask == 0 ? "Low" : "High").monospaced()
                } else { Text("Waiting for pin state").foregroundStyle(.secondary) }
            }
            if bench.reservedGPIO != 0 {
                Text("GP16 through GP21 are reserved for the card, button and LED.").font(.caption).foregroundStyle(.secondary)
            }
            Text(bench.board == .unoR4 ? "D2 to D12 use 5 V logic. Keep them disconnected from the Devboard." : "GP26, GP27, GP28 and reserved pins stay protected.").font(.caption).foregroundStyle(.secondary)
        }.disabled(bench.stopping)
    }

    private var diagnosisControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Channel", selection: $channel) {
                    Text("Standard · \(bench.board.analogPin(0))").tag(0)
                    Text("Probe 1 · \(bench.board.analogPin(1))").tag(1)
                    Text("Probe 2 · \(bench.board.analogPin(2))").tag(2)
                }.fixedSize()
                if channel > 0 {
                    Picker("Connected to", selection: $source) {
                        ForEach(["VMID", "CSA", "GAIN", "SHP"], id: \.self) { Text($0) }
                    }.fixedSize()
                }
                Button("Wiring instructions", systemImage: "info.circle") { showWiring = true }
                    .labelStyle(.iconOnly).help("Show wiring and pin numbers")
                    .sheet(isPresented: $showWiring) {
                        let label = StageProbeLabel(rawValue: source) ?? .disconnected
                        DiagnosisWiringHelp(labels: [channel == 1 ? label : .disconnected,
                                                     channel == 2 ? label : .disconnected],
                                            includeOptional: channel != 0, acquisitionBoard: bench.board)
                    }
            }
            Toggle("I checked the wiring with power removed", isOn: $wiringConfirmed)
            Text("One channel per run. Floating probe readings cannot establish a connection.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var selectedProfile: CalibrationProfile? {
        if let continuation = bench.calibratedContinuation {
            return continuation.settings.profile.flatMap { profileMatches($0) ? $0 : nil }
        }
        return bench.profiles.first { $0.id == profileID && profileMatches($0) }
    }

    private var calibrationPlan: CalibratedPrerun.Plan {
        let run = bench.calibratedContinuation
        return .init(length: prerunLength, measurementSeconds: run?.settings.duration ?? measurementLength.seconds,
                     continuation: run?.id, policy: run.map { $0.settings.noisePolicy ?? .review } ?? bench.defaults.noise)
    }

    private var calibrationSettings: StreamRunSettings {
        if let run = bench.calibratedContinuation { return run.settings }
        return .init(mode: .calibrated, nominalRate: bench.sampleRate, duration: measurementLength.seconds,
                     wiring: background ? "Standard J2 · background" : "Standard J2 · measurement",
                     gain: selectedProfile?.setup.gain ?? "Unconfirmed", profile: selectedProfile,
                     noisePolicy: bench.defaults.noise, picoAveraging: bench.adcAveraging, acquisitionBoard: bench.board)
    }

    private var checkApproved: CalibratedPrerun.Link? {
        guard setupConfirmed, bench.prerunResult?.report.plan == calibrationPlan else { return nil }
        return bench.approvedPrerun(for: calibrationSettings, continuing: bench.calibratedContinuation?.id)
    }

    private var calibratedControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let run = bench.calibratedContinuation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue \(run.name)").font(.headline)
                    Text("A fresh prerun is required. The measurement will continue in a new timing segment.")
                        .foregroundStyle(.secondary)
                    Button("Cancel Continuation") { bench.clearPrerun() }
                }
            } else {
                DisclosureGroup {
                    SamplingRatePicker(bench: bench, selection: $bench.sampleRate, averaging: $bench.adcAveraging)
                        .padding(.top, 7)
                } label: {
                    Text("Sampling · \(bench.sampleRate.formatted()) samples/s · \(bench.adcAveraging?.count ?? 1)×")
                        .font(.callout.weight(.medium))
                }
                Picker("Calibration profile", selection: $profileID) {
                    Text("Choose a profile").tag(UUID?.none)
                    ForEach(bench.profiles.filter { $0.ready && profileMatches($0) }) { profile in
                        Text("\(profile.name) · revision \(profile.revision)").tag(Optional(profile.id))
                    }
                }.frame(maxWidth: 420, alignment: .leading)
                if selectedProfile == nil {
                    Text("Choose a profile for the selected device and rate, or create one in Calibration.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let profile = selectedProfile {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(profile.setup.board) · \(profile.setup.detector) · J4 \(profile.setup.gain)").font(.headline)
                    Text("Use the profile’s enclosure and cable. Keep the FDS1010 covered for the prerun.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("I checked the wiring, gain and dark enclosure", isOn: $setupConfirmed)
                    if !profile.measurementReady {
                        Label("This profile needs a matching timed fixture check.", systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Dark Prerun").font(.headline)
                Picker("Prerun duration", selection: $prerunLength) {
                    ForEach(CalibratedPrerun.Length.allCases) { Text("\($0.rawValue) min").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 265)
                if let result = bench.prerunResult {
                    PrerunReportPanel(report: result.report, approved: checkApproved != nil)
                } else if bench.lastPrerunRun != nil {
                    Text("The raw prerun is in the Library. A confirmed check is required before measurement.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let runID = bench.lastPrerunRun {
                    Button("Inspect Prerun in Library", systemImage: "waveform") { bench.showLinkedPrerun(runID) }
                }

            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Measurement").font(.headline)
                if bench.calibratedContinuation == nil {
                    Picker("Measurement duration", selection: $measurementLength) {
                        ForEach(CalibratedPrerun.Measurement.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                    Picker("Run label", selection: $background) {
                        Text("Background").tag(true)
                        Text("Measurement").tag(false)
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                    TextField("Run name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 500)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder).frame(maxWidth: 500)
                }
                Text("Exclusions: \(calibrationPlan.policy.rawValue)").font(.caption).foregroundStyle(.secondary)
                PrerunSpaceEstimate(rate: bench.sampleRate, averaging: bench.adcAveraging, board: bench.board,
                                    prerun: prerunLength.seconds, measurement: remainingMeasurement,
                                    location: bench.project?.folder, recorded: checkApproved != nil)

            }
        }
        .disabled(bench.busy)
        .onChange(of: profileID) { _, _ in setupConfirmed = false; bench.invalidateSetup() }
        .onChange(of: calibrationPlan) { _, _ in bench.invalidateSetup() }
        .onChange(of: setupConfirmed) { _, confirmed in if !confirmed { bench.invalidateSetup() } }
    }

    private var remainingMeasurement: Double {
        guard let run = bench.calibratedContinuation else { return measurementLength.seconds }
        return CalibratedPrerun.remaining(for: run)
    }

    private var calibratedFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !bench.streaming {
                Text("Connect \(bench.board.title) with Signal Bench firmware.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if checkApproved != nil && bench.calibratedContinuation == nil && !metadataReady {
                Text("Enter a run name and description to start the measurement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { measurementActions }.fixedSize()
                VStack(alignment: .leading, spacing: 8) { measurementActions }
            }
        }.padding(.horizontal, 20).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .disabled(bench.busy)
    }

    @ViewBuilder private var measurementActions: some View {
        if checkApproved != nil {
            Button(bench.calibratedContinuation == nil ? "Start Measurement" : "Continue Measurement", systemImage: "play.fill") {
                guard let checkApproved else { return }
                if let run = bench.calibratedContinuation { bench.continueCalibrated(run); return }
                var settings = calibrationSettings
                settings.prerun = checkApproved
                bench.start(name: name, description: description, settings: settings)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!bench.canStart || checkApproved == nil || (bench.calibratedContinuation == nil && !metadataReady))

            Button("Repeat Prerun") { startPrerun() }.disabled(!canRecordPrerun)
        } else {
            Button(bench.lastPrerunRun == nil ? "Record Dark Prerun" : "Retry Prerun", systemImage: "record.circle") {
                startPrerun()
            }.buttonStyle(.borderedProminent).disabled(!canRecordPrerun)
        }

        if checkApproved == nil {
            Button("Record Raw Anyway") {
                let result = bench.prerunResult
                let linked = result?.report.passed == false && result?.report.plan == calibrationPlan &&
                    result?.report.profile == selectedProfile?.id ? result?.link : nil
                let settings = StreamRunSettings(mode: .main, nominalRate: bench.sampleRate, duration: measurementLength.seconds,
                    wiring: "Raw recording · dark prerun unqualified", draft: true, picoAveraging: bench.adcAveraging,
                    acquisitionBoard: bench.board, prerun: linked)
                bench.start(name: metadataReady ? name : "Raw ADC recording", description: metadataReady ? description : "Unqualified raw waveform", settings: settings)
            }
            .disabled(!bench.canStart || !bench.rateAvailable(bench.sampleRate, averaging: bench.adcAveraging))
        }
    }

    private var canRecordPrerun: Bool {
        bench.canStart && setupConfirmed && selectedProfile?.measurementReady == true &&
            bench.rateAvailable(bench.sampleRate, averaging: bench.adcAveraging)
    }

    private func startPrerun() {
        guard canRecordPrerun, let profile = selectedProfile else { return }
        let plan = calibrationPlan
        let settings = StreamRunSettings(mode: .calibrated, nominalRate: profile.setup.nominalHz,
            duration: plan.length.seconds, wiring: "Standard J2 · dark detector", gain: profile.setup.gain,
            profile: profile, purpose: "localDarkCheck", noisePolicy: plan.policy,
            picoAveraging: profile.setup.picoAveraging, acquisitionBoard: bench.board, prerunPlan: plan)
        bench.start(name: "Dark prerun · \(plan.length.rawValue) min", description: "Dark setup check for " + profile.name, settings: settings)
    }

    private var metadataReady: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var ready: Bool {
        bench.canStart && bench.rateAvailable(bench.sampleRate, channel: selectedChannel, averaging: bench.adcAveraging) &&
        (1...120).contains(durationInput.wrappedValue) &&
        (bench.mode != .diagnosis || metadataReady && wiringConfirmed) &&
        (bench.mode != .manualRaw || rawWiringChecked)
    }

    private func profileMatches(_ profile: CalibrationProfile) -> Bool {
        profile.setup.nominalHz == bench.sampleRate && profile.setup.picoAveraging == bench.adcAveraging &&
            profile.setup.matchesFirmware(bench.firmware, board: bench.board)
    }

    private var mainAnalysisProfile: CalibrationProfile? {
        guard let id = bench.localProfile else { return nil }
        return bench.profiles.first { $0.id == id && $0.measurementReady && profileMatches($0) }
    }

    private func start() {
        let mode = bench.mode
        let manual = mode == .manual || mode == .manualRaw
        var settings = StreamRunSettings(mode: mode, nominalRate: bench.sampleRate, duration: Double(durationInput.wrappedValue * 60), picoAveraging: bench.adcAveraging)
        if canUseDeviceCandidates, deviceCandidates {
            guard candidateSettings.valid else { bench.notice = "Check the candidate limits before starting."; return }
            settings.unoCandidates = candidateSettings
        }
        deviceCandidates = false
        if mode == .main || manual { settings.draft = true }
        if mode == .manualRaw { settings.wiring = "Bare FDS1010 · \(bench.board.analogPin(0)) · relative optical" }
        if mode == .main, confirmAnalysisSetup,
           bench.defaults.afterRecording == .profile, let profile = mainAnalysisProfile {
            settings.gain = profile.setup.gain
            settings.profile = profile
            settings.wiring = "Standard J2 · confirmed dark setup"
        }
        confirmAnalysisSetup = false
        if bench.mode == .diagnosis {
            settings.channel = channel
            settings.wiring = channel == 0 ? "Standard J2 · \(bench.board.analogPin(0))" : "\(bench.board.analogPin(channel)) · \(source)"
        }
        let automaticName = mode == .main || manual
        bench.start(name: automaticName ? mode.rawValue + " recording " + String(Int(Date().timeIntervalSince1970)) : name,
                    description: automaticName ? "Raw ADC recording" : description, settings: settings)
    }
}

struct StreamMetadataSheet: View {
    let title: String
    @State var name: String
    @State var description: String?
    let actionTitle: String
    var reviewTimeline: (() -> Void)? = nil
    var dismissAfterAction = true
    let action: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if description != nil {
                TextField("Description", text: Binding(get: { description ?? "" }, set: { description = $0 }), axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder)
            }
            HStack {
                if let reviewTimeline {
                    Button("Flags & Notes…", systemImage: "flag", action: reviewTimeline)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    action(name, description ?? "")
                    if dismissAfterAction { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled((try? SessionStore.projectName(name)) == nil || description.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true)
            }
        }.padding(22).frame(width: 410)
    }
}

struct SamplingRatePicker: View {
    @ObservedObject var bench: StreamingBench
    @Binding var selection: Int
    var channel = 0
    var seconds: Double? = nil
    var locked = false
    var averaging: Binding<ADCAveraging?>? = nil
    var gpio = false
    @State private var customEntry = false
    @State private var customText = ""

    private var preset: ADCAveraging? { averaging?.wrappedValue }
    private var usesCustom: Bool { customEntry || !bench.board.selectableRates.contains(selection) }
    private var allowsCustom: Bool { !bench.connected || bench.customRates }
    private var rangeLabel: String {
        "\(bench.board.liveRange.lowerBound.formatted()) to \(bench.board.liveRange.upperBound.formatted())"
    }
    private var rateMenu: Binding<Int> {
        Binding(get: { usesCustom ? -1 : selection }, set: { value in
            if value == -1 {
                customText = String(selection)
                customEntry = true
            } else {
                customEntry = false
                selection = value
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !locked {
                ViewThatFits(in: .horizontal) {
                    HStack { profiles }.fixedSize()
                    VStack(alignment: .leading) { profiles }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { rawRate; average; recorded }.fixedSize()
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 14) { rawRate; average }.fixedSize()
                    recorded.fixedSize()
                }.fixedSize()
            }
            if usesCustom && !locked && allowsCustom {
                TextField("Raw samples per second", text: $customText, prompt: Text(rangeLabel))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 225).disabled(bench.busy)
                    .onChange(of: customText) { _, text in
                        guard usesCustom else { return }
                        let value = Int(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                        selection = bench.board.liveRange.contains(value) ? value : 0
                    }
                    .onAppear { if customText.isEmpty && selection > 0 { customText = String(selection) } }
                if !bench.board.liveRange.contains(selection) {
                    Text("Enter \(rangeLabel) samples/s.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if bench.board.liveRange.contains(selection) {
                let configured = bench.board.rate(selection)
                if abs(configured - Double(selection)) >= 0.005 {
                    Text("Configured ADC rate \(format(configured)) samples/s").font(.caption).foregroundStyle(.secondary)
                }
            }
            if preset != nil {
                Text("The device saves each group’s exact sum and quality counts. Individual conversions cannot be recovered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if bench.connected && !bench.rateAvailable(selection, channel: channel, averaging: preset) && !bench.busy {
                Text(preset != nil && !bench.deviceAveragingAvailable
                     ? "This firmware does not support on-device averaging. Choose 1× or update the firmware."
                     : "This rate is unavailable for the connected firmware and input.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let seconds, seconds >= 1 {
                RecordingStorageEstimate(rate: selection, averaging: preset, seconds: seconds, gpio: gpio,
                                         location: bench.project?.folder, board: bench.board)
            }
        }
        .onChange(of: bench.board) { _, _ in customEntry = false; customText = "" }
    }

    private func format(_ rate: Double) -> String { rate.formatted(.number.precision(.fractionLength(0...2))) }

    private var rawRate: some View {
        HStack(spacing: 6) {
            Text("Raw")
            Picker("Raw ADC rate", selection: rateMenu) {
                ForEach(bench.board.selectableRates.sorted(), id: \.self) { rate in
                    Text("\(rate.formatted()) samples/s").tag(rate)
                        .disabled(bench.connected && !bench.rateAvailable(rate, channel: channel))
                }
                if allowsCustom || usesCustom { Text("Custom…").tag(-1).disabled(!allowsCustom) }
            }.labelsHidden().fixedSize().disabled(bench.busy || locked)
        }
    }

    private var average: some View {
        HStack(spacing: 6) {
            Text("Average")
            Picker("Average", selection: averaging ?? .constant(nil)) {
                Text("1×").tag(ADCAveraging?.none)
                ForEach(ADCAveraging.allCases, id: \.self) { factor in
                    Text("\(factor.count)×").tag(Optional(factor))
                        .disabled(bench.connected && !bench.deviceAveragingAvailable)
                }
            }.labelsHidden().fixedSize().disabled(bench.busy || locked || averaging == nil)
        }
    }

    private var recorded: some View {
        HStack(spacing: 6) {
            Text("Recorded")
            let rate = bench.board.rate(selection) / Double(preset?.count ?? 1)
            Text(bench.board.liveRange.contains(selection) ? "\(format(rate)) readings/s" : "Unavailable")
                .monospacedDigit().padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var profiles: some View {
        profile("Balanced", rate: 100_000, factor: nil)
        profile("Smoothed", rate: bench.board == .unoR4 ? 200_000 : 500_000, factor: .eight)
        profile("Full Detail", rate: bench.board.liveRange.upperBound, factor: nil)
    }

    private func profile(_ title: String, rate: Int, factor: ADCAveraging?) -> some View {
        Button(title) {
            customEntry = false
            selection = rate
            averaging?.wrappedValue = factor
        }
        .help("\(rate.formatted()) raw samples/s at \(factor?.count ?? 1)×")
        .disabled(bench.busy || (factor != nil && averaging == nil) ||
                  (bench.connected && !bench.rateAvailable(rate, channel: channel, averaging: factor)))
    }
}

struct RecordingStorageEstimate: View {
    let rate: Int
    let averaging: ADCAveraging?
    let seconds: Double
    let gpio: Bool
    let location: URL?
    var board: AcquisitionBoard = .picoW

    var body: some View {
        if let estimate = RecordingEstimate(rate: rate, averaging: averaging, seconds: seconds, gpio: gpio, location: location, board: board) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage Estimate").font(.callout.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    row("ADC conversions", estimate.conversions.formatted())
                    row("Recorded readings", estimate.readings.formatted())
                    row("Reading payload", bytes(estimate.payload))
                    row("Estimated Project data", bytes(estimate.projectBytes))
                    row("Free space required", bytes(estimate.requiredBytes))
                    row("Available on Project volume", estimate.availableBytes.map(bytes) ?? "Unavailable")
                }.font(.caption)
                if let available = estimate.availableBytes, available < estimate.requiredBytes {
                    Label("Free space is below the recording estimate.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
