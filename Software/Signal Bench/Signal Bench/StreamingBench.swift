import AppKit
import Combine
import SwiftUI

private final class StreamFolderGrant: @unchecked Sendable {
    let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

nonisolated struct ProjectArchiveRequest: Identifiable, Sendable {
    let id = UUID()
    fileprivate let grants: [StreamFolderGrant]
    var folders: [URL] { grants.map(\.url) }
}

nonisolated struct PicoCardRequest: Identifiable, Sendable {
    let id = UUID()
    let projectID: UUID
    let runs: [PicoCardImport.Preview]
    let issues: [String]
    fileprivate let grants: [StreamFolderGrant]

    #if STREAM_TESTING
    static func sample(runs: [PicoCardImport.Preview], issues: [String]) -> Self {
        .init(projectID: UUID(), runs: runs, issues: issues, grants: [])
    }
    #endif
}

@MainActor
final class StreamingBench: ObservableObject {
    enum Dialog: String, Identifiable { case new; var id: String { rawValue } }
    enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview", record = "Main", manual = "Manual", manualRaw = "Manual Raw"
        case diagnosis = "Diagnosis", calibration = "Calibration", calibrated = "Calibrated Run"
        case library = "Run Library", study = "Bench Test"

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .record: "record.circle"
            case .manual: "switch.2"
            case .manualRaw: "sun.max"
            case .diagnosis: "stethoscope"
            case .calibration: "slider.horizontal.3"
            case .calibrated: "waveform.path.ecg"
            case .library: "books.vertical"
            case .study: "checklist"
            }
        }

        var recordingMode: RecordingMode? {
            switch self {
            case .record: .main
            case .manual: .manual
            case .manualRaw: .manualRaw
            case .diagnosis: .diagnosis
            case .calibrated: .calibrated
            default: nil
            }
        }
        var id: Self { self }
    }

    @Published var page = Page.overview
    @Published var defaults = ProjectDefaults()
    @Published var draftDecision: StreamRun?
    @Published var renamePrompt = false
    private var closeAfterDrain = false
    @Published var project: StreamProjectStore?
    let localAI = LocalAISettings()
    @Published var runs: [StreamRunItem] = []
    @Published var selection: UUID?
    @Published var studySelection: UUID?
    @Published private(set) var timeline: RunTimelineRequest?
    @Published private(set) var timelineSaving = false
    @Published private(set) var timelineRevision = UUID()
    private var openingTimeline = false
    private var timelineHasChanges = false
    @Published var mode = RecordingMode.main
    @Published private(set) var boardHints: [String: AcquisitionBoard] = [:]
    @Published var ports = StreamRecorder.ports()
    @Published var port = StreamRecorder.ports().first ?? ""
    @Published private(set) var board: AcquisitionBoard = .picoW
    @Published var firmware = ""
    @Published private(set) var customRates = false
    @Published private(set) var deviceAveragingAvailable = false
    @Published private(set) var deviceRates: Set<Int> = []
    @Published private(set) var diagnosticChannels: Set<Int> = []
    @Published var sampleRate = StreamWire.rate
    @Published var adcAveraging: ADCAveraging?
    @Published var waveformStyle = WaveformStyle.envelope
    @Published var dotDensity = 100.0
    @Published var liveFPS = 10
    @Published var reviewFPS = 30
    @Published var waveformScale = WaveformScale.fit

    func selectBoard(_ value: AcquisitionBoard) {
        guard canSwitchBoard, board != value else { return }
        board = value
        sampleRate = StreamWire.rate
        adcAveraging = nil
        connectionEpoch = UUID()
        invalidateSetup()
        refreshPorts()
    }

    var canSwitchBoard: Bool { !connected && !connecting && !busy && !pendingRecording && draftDecision == nil && !quitting }

    func rateAvailable(_ rate: Int, channel: Int = 0, averaging: ADCAveraging? = nil) -> Bool {
        streaming && (averaging == nil || deviceAveragingAvailable) && (deviceRates.contains(rate) || (customRates && board.liveRange.contains(rate)))
            && diagnosticChannels.contains(channel)
            && board.liveRange.contains(rate)
    }
    #if STREAM_TESTING
    func setDeviceCapabilitiesForTest(averaging: Bool = false) {
        deviceAveragingAvailable = averaging
        customRates = true
        deviceRates = Set(StreamWire.rates)
        diagnosticChannels = [0, 1, 2]
    }
    func setPrerunForTest(_ result: CalibratedPrerun.Result?) {
        prerunResult = result
        lastPrerunRun = result?.link.run
        prerunEpoch = result?.report.passed == true ? connectionEpoch : nil
    }

    func setJobsForLayout(_ values: [ProjectJob]) { jobs = values }
    func setTimelineForTest(_ request: RunTimelineRequest) { timeline = request }
    func setQualityForLayout(_ id: UUID, progress: WaveformOverview.Progress) { qualityProgress[id] = progress }
    #endif

    @Published var streaming = false
    @Published private(set) var supportsDeviceCandidates = false
    @Published var connecting = false
    @Published var connected = false
    @Published var status = "Disconnected"
    @Published var notice: String?
    @Published var recording = false
    @Published var stopping = false
    @Published var needsProjectAccess = false
    @Published private(set) var quitting = false
    @Published var activeMode: RecordingMode?
    @Published var current: StreamRun?
    @Published var preview = LiveStreamPreview()
    @Published var projectDialog: Dialog?
    @Published var archiveRequest: ProjectArchiveRequest?
    @Published var picoCardRequest: PicoCardRequest?
    @Published private(set) var reservedGPIO: UInt32 = 0
    private var picoSDState: String?
    var controllableGPIO: UInt32 { board.gpioMask & ~reservedGPIO }

    func choosePicoCard() {
        guard let project, !busy, !quitting, verifyProjectAccess() else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose a Pico Card or Recording Files"
        picker.prompt = "Check Recordings"
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let grants = picker.urls.map(StreamFolderGrant.init)
        let projectID = project.identity.id
        performWithProgress("Checking Pico card") { progress in
            let files = try PicoCardImport.candidates(grants.map(\.url))
            var runs: [PicoCardImport.Preview] = []
            var issues: [String] = []
            var seen = Set<UUID>()
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                do {
                    let run = try PicoCardImport.preview(file)
                    if seen.insert(run.id).inserted { runs.append(run) }
                    else { issues.append("\(file.lastPathComponent): duplicate ID in this selection.") }
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append("\(file.lastPathComponent): \(error.localizedDescription)") }
                progress(Double(index + 1) / Double(files.count))
            }
            return PicoCardRequest(projectID: projectID, runs: runs, issues: issues, grants: grants)
        } completion: { [self] request in
            guard self.project?.identity.id == request.projectID else { return }
            picoCardRequest = request
        }
    }

    func importPicoCard(_ request: PicoCardRequest, entries: [PicoCardImport.Preview],
                        wiring: PicoCardImport.Wiring, date: Date?) {
        guard let project, project.identity.id == request.projectID, !entries.isEmpty,
              !busy, !quitting, verifyProjectAccess() else { return }
        let projectGrant = folderAccess
        performWithProgress("Importing Pico recordings", failure: { [weak self] in self?.reload() }) { progress in
            try withExtendedLifetime((request, projectGrant)) {
                var last: UUID?
                for (index, entry) in entries.enumerated() {
                    try Task.checkCancellation()
                    last = try PicoCardImport.publish(entry, in: project, wiring: wiring, approximateStart: date)
                    progress(Double(index + 1) / Double(entries.count))
                }
                return last
            }
        } completion: { [self] id in
            reload(id)
            notice = "Pico recordings are available in the Run Library."
        }
    }
    @Published var operation: String?
    @Published private(set) var operationProgress: Double?
    @Published private(set) var projectReviewRunning = false
    @Published private(set) var jobs: [ProjectJob] = []
    @Published private(set) var pendingRecording = false
    private var jobTask: Task<Void, Never>?
    private var jobControl: ProjectJobControl?
    private var jobID: UUID?
    private var jobDestinations: [UUID: StreamFolderGrant] = [:]
    private var jobProgressWrites: [UUID: Double] = [:]
    private var jobClosureState: ProjectJob.State?
    var projectJobsUnfinished: Bool { jobTask != nil || jobs.contains { $0.state.unfinished } }
    var jobsActive: Bool { jobID != nil && !recording || projectReviewRunning || !qualityProgress.isEmpty }

    @Published var projectReviewToolReplies = 0
    @Published var profiles: [CalibrationProfile] = []
    @Published var attempts: [CalibrationAttempt] = []
    @Published var localProfile: UUID?
    @Published private(set) var prerunResult: CalibratedPrerun.Result?
    @Published private(set) var lastPrerunRun: UUID?
    @Published private(set) var calibratedContinuation: StreamRun?
    private var prerunEpoch: UUID?
    private var setupRevision = UUID()
    @Published private(set) var qualityProgress: [UUID: WaveformOverview.Progress] = [:]
    @Published private(set) var qualityIssues: [UUID: String] = [:]
    @Published private(set) var qualityRevisions: [UUID: UUID] = [:]
    private var qualityDone = Set<UUID>()
    private var qualityTask: Task<Void, Never>?
    private var qualityWorker: Task<Bool, Error>?
    @Published private(set) var qualityPaused = Set<UUID>()
    @Published var connectionEpoch = UUID()
    private var activeEpoch: UUID?
    private var activeSetupRevision: UUID?
    private var work: Task<Void, Never>?
    private var cancel: (() -> Void)?
    private var folderAccess: StreamFolderGrant?
    private var libraryLoad: Task<Void, Never>?
    private var quitTimeout: Task<Void, Never>?
    private var quitReply: ((Bool) -> Void)?
    private var power: NSObjectProtocol?
    private lazy var recorder: StreamRecorder = {
        let (frames, continuation) = AsyncStream.makeStream(of: LiveStreamPreview.self, bufferingPolicy: .bufferingNewest(1))
        previewConsumer = Task { [weak self] in
            for await frame in frames {
                if let self, self.recording {
                    self.preview = frame
                    if !self.stopping, self.status == "Settling", frame.settlingRemaining == nil, frame.received > 0 {
                        self.status = "Recording"
                    }
                }
            }
        }
        return StreamRecorder { [weak self] event in
            if case .preview(let frame) = event {
                continuation.yield(frame)
            } else if let bench = self {
                Task { @MainActor in bench.receive(event) }
            }
        }
    }()
    private var previewConsumer: Task<Void, Never>?

    deinit { previewConsumer?.cancel(); libraryLoad?.cancel(); quitTimeout?.cancel(); qualityWorker?.cancel(); jobControl?.cancel() }

    var busy: Bool { recording || operation != nil }
    var needsQuitDrain: Bool { !quitting && (busy || timelineSaving || projectJobsUnfinished || qualityTask != nil) }
    var selectedRun: StreamRun? { runs.first { $0.id == selection }?.run }
    var canStart: Bool {
        streaming && project != nil && (!busy || projectReviewRunning) && !pendingRecording &&
            !quitting && !needsProjectAccess && draftDecision == nil
    }

    func refreshPorts() {
        let hints = AcquisitionPorts.boardHints()
        boardHints = hints
        ports = StreamRecorder.ports().filter { hints[$0] == nil || hints[$0] == board }
        if !ports.contains(port) || hints[port] == nil {
            port = ports.first { hints[$0] == board } ?? (ports.contains(port) ? port : ports.first ?? "")
        }
    }

    func toggleConnection() {
        if connected { recorder.disconnect() }
        else if !port.isEmpty && !connecting { recorder.connect(to: port, board: board) }
    }

    func newProject(_ name: String) { chooseFolder(name: name) }
    func openProject() { chooseFolder(name: nil) }

    var canExportProjects: Bool {
        !busy && !timelineSaving && !quitting && jobTask == nil && archiveRequest == nil
    }

    func chooseProjectsToArchive() {
        guard canExportProjects else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Projects as ZIP"
        panel.message = "Hold ⌘ Command and click each Signal Bench Project folder to include."
        panel.prompt = "Choose Projects"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = project?.folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, !panel.urls.isEmpty, canExportProjects else { return }
        archiveRequest = .init(grants: panel.urls.map(StreamFolderGrant.init))
    }

    func exportProjectArchive(_ request: ProjectArchiveRequest, name: String) {
        guard canExportProjects else { return }
        let panel = NSOpenPanel()
        panel.title = "Save Project ZIP"
        panel.message = "Choose a destination outside the selected Projects."
        panel.prompt = "Save ZIP Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = request.folders.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url, canExportProjects else { return }
        let destination = StreamFolderGrant(folder)
        notice = nil
        performWithProgress("Exporting and verifying Project ZIP") { update in
            do {
                return try withExtendedLifetime(request.grants) {
                    try withExtendedLifetime(destination) {
                        try ProjectArchive.export(request.folders, named: name, to: destination.url, progress: update)
                    }
                }
            } catch let error as POSIXError where error.code == .EEXIST {
                throw StreamFailure.storage("That ZIP already exists. Choose a different name or destination.")
            }
        } completion: { [self, destination] url in
            notice = "Exported and verified \(url.lastPathComponent)."
            withExtendedLifetime(destination) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func chooseFolder(name: String?) {
        guard !busy, !timelineSaving, !quitting, jobTask == nil, draftDecision == nil || needsProjectAccess,
              name == nil || !needsProjectAccess else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = name != nil
        panel.prompt = name == nil ? "Open Project" : "Choose Parent"
        if name == nil, let project { panel.directoryURL = project.folder.deletingLastPathComponent() }
        panel.message = name == nil ? "Select a Signal Bench 3 Project folder." : "Choose where to create the Project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let grant = StreamFolderGrant(url)
        let previousProject = project?.identity.id
        let previousRun = selection
        let expected = needsProjectAccess ? previousProject : nil
        perform(name == nil ? "Opening Project" : "Creating Project") {
            let next = try name.map { try StreamProjectStore.create(named: $0, in: grant.url) } ?? StreamProjectStore(opening: grant.url)
            guard expected == nil || next.identity.id == expected else {
                throw StreamFailure.project("Select the original Project to restore access.")
            }
            let entries = try next.list()
            let defaults = try next.defaults()
            try Task.checkCancellation()
            let paused = Set(entries.compactMap { item -> UUID? in
                guard let folder = try? next.runDirectory(item.id),
                      StreamFiles.exists(folder.appendingPathComponent(WaveformOverview.pauseMarker)) else { return nil }
                return item.id
            })
            return (next, entries, defaults, Result { try ProjectJobFiles.load(next) }, paused)
        } completion: { [self] next, entries, defaults, restoredJobs, paused in
            stopProjectJobs()
            jobs = (try? restoredJobs.get()) ?? []
            libraryLoad?.cancel()
            resetPostRunQueue()
            qualityPaused = paused
            folderAccess = grant
            project = next
            self.defaults = defaults
            if previousProject != next.identity.id {
                closeTimeline()
                page = .overview
                sampleRate = StreamWire.rate
                adcAveraging = nil
            }
            draftDecision = nil
            if let draft = entries.compactMap(\.run).first(where: \.isManualDraft) {
                presentDraft(draft)
            }
            runs = entries
            selection = previousProject == next.identity.id ? previousRun : nil
            studySelection = nil
            clearPrerun()
            invalidateSetup()
            needsProjectAccess = false
            notice = restoredJobs.failureDescription
            refreshCalibration()
            schedulePostRun()
        }
    }

    func closeProject() {
        guard !quitting else { return }
        if recording { closeAfterDrain = true; stop(); return }
        if projectReviewRunning {
            closeAfterDrain = true
            cancelWork()
            return
        }
        guard !busy, !timelineSaving, !needsProjectAccess, verifyProjectAccess() else { return }
        if jobTask != nil {
            closeAfterDrain = true
            stopProjectJobs()
            return
        }
        if let draft = draftDecision ?? runs.compactMap(\.run).first(where: \.isManualDraft) {
            closeAfterDrain = true
            presentDraft(draft)
            return
        }
        finishProjectClose()
    }

    private func finishProjectClose() {
        if jobTask != nil {
            closeAfterDrain = true
            stopProjectJobs()
            return
        }
        stopProjectJobs()
        jobs = []
        exclusionJob = nil
        resetPostRunQueue()
        closeTimeline()
        libraryLoad?.cancel()
        project = nil
        clearPrerun()
        folderAccess = nil
        runs = []
        profiles = []
        attempts = []
        selection = nil
        diagnosisSource = nil
        studySelection = nil
        invalidateSetup()
        draftDecision = nil
        closeAfterDrain = false
        notice = nil
        page = .overview
    }

    private func presentDraft(_ run: StreamRun) {
        draftDecision = run
        page = run.settings.mode == .manualRaw ? .manualRaw : .manual
    }

    func resolveDraft(keep: Bool, name: String? = nil, description: String? = nil) {
        guard let project, let draft = draftDecision, !busy, !timelineSaving, verifyProjectAccess() else { return }
        if timeline?.runID == draft.id, !keep { closeTimeline() }
        let grant = folderAccess
        perform(keep ? "Saving to Run Library" : "Discarding draft") {
            try withExtendedLifetime(grant) {
                try Task.checkCancellation()
                if keep { return try project.keepDraft(draft.id, name: name, description: description) }
                try project.verify()
                let folder = try project.runDirectory(draft.id)
                let lock = try StreamRunLock(folder)
                defer { withExtendedLifetime(lock) {} }
                guard try project.openRun(draft.id).isManualDraft else {
                    throw StreamFailure.project("This recording is already saved.")
                }
                try FileManager.default.removeItem(at: folder)
                return nil
            }
        } completion: { [self] (saved: StreamRun?) in
            draftDecision = nil
            notice = nil
            runs.removeAll { $0.id == draft.id }
            if let saved { runs.insert(.init(id: saved.id, run: saved, issue: nil), at: 0) }
            if closeAfterDrain { closeProject() }
            else {
                selection = saved?.id
                reload(saved?.id)
                if saved != nil { page = .library }
            }
        }
    }

    private func closeProjectAfterResolution(_ id: UUID) {
        runs.removeAll { $0.id == id }
        closeProject()
    }

    @discardableResult private func verifyProjectAccess() -> Bool {
        guard let project else { return true }
        do {
            try project.verify()
            return true
        } catch {
            needsProjectAccess = true
            invalidateSetup()
            notice = "Reopen the original Project folder to restore access. " + error.localizedDescription
            return false
        }
    }

    func saveDefaults(_ value: ProjectDefaults) {
        guard !busy, let project else { return }
        do {
            try project.saveDefaults(value)
            if defaults.afterRecording != value.afterRecording {
                let paused = qualityPaused
                resetPostRunQueue()
                qualityPaused = paused
            }
            defaults = value
            schedulePostRun()
        }
        catch { notice = error.localizedDescription }
    }

    func trashProject(typed name: String) {
        guard let project, !busy, !projectJobsUnfinished, !jobsActive, !timelineSaving, !quitting, !needsProjectAccess, draftDecision == nil,
              name == project.identity.name else { return }
        do {
            try project.verify()
            guard !(try project.list()).contains(where: { $0.run?.isManualDraft == true }) else {
                throw StreamFailure.project("Resolve the unsaved recording before moving this Project to Trash.")
            }
            qualityWorker?.cancel()
            try FileManager.default.trashItem(at: project.folder, resultingItemURL: nil)
            finishProjectClose()
        } catch { notice = error.localizedDescription }
    }

    func refreshCalibration() {
        guard let project else { return }
        do {
            profiles = try StreamingCalibration.profiles(project)
            attempts = try StreamingCalibration.attempts(project)
        } catch { notice = error.localizedDescription }
    }

    func reload(_ id: UUID? = nil) {
        guard let project else { return }
        libraryLoad?.cancel()
        let grant = folderAccess
        let worker = Task.detached { try withExtendedLifetime(grant) { try project.list() } }
        libraryLoad = Task {
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let entries):
                runs = entries
                needsProjectAccess = false
                if let id { selection = id }
                schedulePostRun()
            case .failure(let error):
                needsProjectAccess = true
                notice = "Could not read the Project. Reopen the original folder to recover this run. " + error.localizedDescription
            }
        }
    }

    func approvedPrerun(for settings: StreamRunSettings, continuing: UUID? = nil) -> CalibratedPrerun.Link? {
        guard connected, prerunEpoch == connectionEpoch, let result = prerunResult,
              settings.board == board, settings.nominalRate == sampleRate, settings.picoAveraging == adcAveraging,
              result.report.project == project?.identity.id,
              CalibratedPrerun.validate(result, for: settings, continuation: continuing) else { return nil }
        return result.link
    }

    func prepareCalibratedContinuation(_ run: StreamRun) {
        guard canStart, run.project == project?.identity.id, run.curveSource == nil, !run.isManualDraft,
              run.status == .interrupted, run.settings.mode == .calibrated, run.settings.purpose == nil,
              !run.hasCadenceMismatch, run.settings.board == board, let profile = run.settings.profile,
              profile.measurementReady, profile.setup.matchesFirmware(firmware, board: board),
              CalibratedPrerun.remaining(for: run) > 0,
              rateAvailable(run.settings.nominalRate, channel: run.settings.channel, averaging: run.settings.picoAveraging) else {
            notice = "Reconnect the original recording device and enable the matching rate before continuing."
            return
        }
        clearPrerun()
        sampleRate = run.settings.nominalRate
        adcAveraging = run.settings.picoAveraging
        calibratedContinuation = run
        mode = .calibrated
        page = .calibrated
    }

    func clearPrerun() {
        invalidateSetup()
        prerunResult = nil
        lastPrerunRun = nil
        calibratedContinuation = nil
    }

    func continueCalibrated(_ run: StreamRun) {
        guard calibratedContinuation?.id == run.id, let check = approvedPrerun(for: run.settings, continuing: run.id) else {
            notice = "Record a passing prerun for this connection before continuing."
            return
        }
        resume(run, with: check)
    }

    func showLinkedPrerun(_ id: UUID) {
        guard runs.contains(where: { $0.id == id && $0.run != nil }) else {
            notice = "The prerun is unavailable in this Project."
            return
        }
        selection = id
        page = .library
    }

    func start(name: String, description: String, settings: StreamRunSettings) {
        guard canStart, let project, verifyProjectAccess() else { return }
        if projectReviewRunning {
            afterCancellingAI { [weak self] in self?.start(name: name, description: description, settings: settings) }
            return
        }
        guard rateAvailable(settings.nominalRate, channel: settings.channel, averaging: settings.picoAveraging) else {
            notice = "The connected firmware does not support this rate, input or averaging factor."
            return
        }
        if settings.mode == .calibrated, settings.purpose == nil || settings.prerunPlan != nil {
            guard settings.profile?.measurementReady == true else {
                notice = "Use a matching profile with the required local fixture validation."
                return
            }
        }
        if settings.mode == .calibrated, settings.purpose == nil {
            guard let link = settings.prerun, approvedPrerun(for: settings) == link else {
                notice = "Record a passing prerun for this connection before starting."
                return
            }
        }
        var configured = settings
        configured.acquisitionBoard = board
        if configured.usesStartupDelay { configured.startupDelaySeconds = defaults.startupDelay }
        let selectedSettings = configured
        if let setup = settings.profile?.setup ?? settings.calibrationSetup ?? settings.bench?.setup,
           !setup.matchesFirmware(firmware, board: board) {
            notice = "The setup specifies \(setup.firmware). Use the firmware that recorded this setup or create a matching setup."
            return
        }
        let epoch = connectionEpoch
        let revision = setupRevision
        let requiresConfirmedSetup = settings.mode == .calibrated
        pauseProjectJob()
        perform("Preparing recording") {
            try Task.checkCancellation()
            if selectedSettings.purpose != "localDarkCheck" || selectedSettings.prerunPlan != nil,
               let profile = selectedSettings.profile {
                try ProfileFixtureValidation.verify(profile, in: project)
            }
            if let link = selectedSettings.prerun {
                try CalibratedPrerun.verifyForRecording(link, settings: selectedSettings, in: project)
            }
            let nextDuration: Double?
            if let target = selectedSettings.prerunPlan?.continuation {
                let interrupted = try project.openRun(target)
                guard interrupted.status == .interrupted, interrupted.settings.mode == .calibrated,
                      interrupted.settings.profile == selectedSettings.profile,
                      interrupted.settings.nominalRate == selectedSettings.nominalRate,
                      interrupted.settings.picoAveraging == selectedSettings.picoAveraging,
                      interrupted.settings.duration == selectedSettings.prerunPlan?.measurementSeconds,
                      CalibratedPrerun.remaining(for: interrupted) > 0 else {
                    throw StreamFailure.storage("The interrupted measurement changed. Reopen it before continuing.")
                }
                nextDuration = CalibratedPrerun.remaining(for: interrupted)
            } else {
                nextDuration = selectedSettings.prerunPlan?.measurementSeconds
            }
            try RecordingEstimate.requireSpace(for: selectedSettings, seconds: selectedSettings.duration, in: project.folder,
                                               additionalSeconds: nextDuration)
            return try project.makeRun(name: name, description: description, settings: selectedSettings)
        } completion: { [self] run in
            guard streaming, epoch == connectionEpoch, self.project?.identity.id == project.identity.id,
                  !requiresConfirmedSetup || revision == setupRevision else {
                if run.isManualDraft { presentDraft(run) }
                else { page = .library }
                reload(run.id)
                notice = "The connection or setup changed before recording began. Recheck the setup and start again."
                return
            }
            begin(run, in: project)
        }
    }

    func resume(_ run: StreamRun) {
        guard run.picoCardOrigin == nil else {
            notice = "Start a new run on the Pico to record more data."
            return
        }
        guard run.settings.mainsHum == nil else {
            notice = "Repeat this step in the 60 Hz Test to keep the comparison on one capture."
            return
        }
        if run.settings.mode == .calibrated {
            prepareCalibratedContinuation(run)
            return
        }
        resume(run, with: nil)
    }

    private func resume(_ run: StreamRun, with check: CalibratedPrerun.Link?) {
        guard run.settings.board == board else { notice = "Reconnect \(run.settings.board.title) to resume this run."; return }
        guard canStart, let project, run.curveSource == nil, run.status == .interrupted, !run.hasCadenceMismatch, rateAvailable(run.settings.nominalRate, channel: run.settings.channel, averaging: run.settings.picoAveraging),
              run.settings.mode != .calibrated || (check != nil && check == approvedPrerun(for: run.settings, continuing: run.id)) else { return }
        if let setup = run.settings.profile?.setup ?? run.settings.calibrationSetup ?? run.settings.bench?.setup,
           !setup.matchesFirmware(firmware, board: board) {
            notice = "Reconnect the firmware that recorded this setup before continuing."
            return
        }
        if projectReviewRunning {
            afterCancellingAI { [weak self] in self?.resume(run, with: check) }
            return
        }
        if let jobTask, let id = jobID, let job = jobs.first(where: { $0.id == id }),
           job.input.run == run.id || job.fixtureInputs?.contains(run.id) == true {
            // The job holds a shared lease on the run. Release it before
            // acquiring the writer lock, and require a fresh job plan afterward.
            jobClosureState = .interrupted
            jobControl?.cancel()
            afterWork(jobTask) { [weak self] in self?.resume(run, with: check) }
            return
        }
        if let check, let profile = run.settings.profile {
            let epoch = connectionEpoch
            let revision = setupRevision
            perform("Verifying saved prerun") {
                try ProfileFixtureValidation.verify(profile, in: project)
                try CalibratedPrerun.verifyForRecording(check, settings: run.settings, in: project, continuing: run.id)
                return check
            } completion: { [self] verified in
                guard epoch == connectionEpoch, revision == setupRevision, self.project?.identity.id == project.identity.id,
                      verified == approvedPrerun(for: run.settings, continuing: run.id) else {
                    notice = "The connection or setup changed. Record a fresh prerun."
                    return
                }
                begin(run, in: project, continuationPrerun: verified)
            }
        } else {
            begin(run, in: project)
        }
    }

    private func afterCancellingAI(_ start: @escaping @MainActor () -> Void) {
        guard let work, !pendingRecording else { return }
        cancelWork()
        afterWork(work, start: start)
    }

    private func afterWork(_ work: Task<Void, Never>, start: @escaping @MainActor () -> Void) {
        pendingRecording = true
        Task {
            await work.value
            pendingRecording = false
            if !quitting, !closeAfterDrain { start() }
        }
    }

    private func begin(_ run: StreamRun, in store: StreamProjectStore, continuationPrerun: CalibratedPrerun.Link? = nil) {
        if let qualityTask {
            let epoch = connectionEpoch
            let revision = setupRevision
            qualityWorker?.cancel()
            afterWork(qualityTask) { [weak self] in
                guard let self else { return }
                guard self.project?.identity.id == store.identity.id, self.streaming, epoch == self.connectionEpoch,
                      revision == self.setupRevision else {
                    self.notice = "The recording setup changed. Check it and start again."
                    self.reload()
                    return
                }
                self.begin(run, in: store, continuationPrerun: continuationPrerun)
            }
            return
        }
        pauseProjectJob()
        qualityDone.remove(run.id)
        qualityIssues[run.id] = nil
        if run.settings.mode != .calibrated {
            invalidateSetup()
        }
        notice = nil
        preview = .init()
        current = run
        activeMode = run.settings.mode
        activeEpoch = connectionEpoch
        if run.settings.purpose == "localDarkCheck" {
            invalidateSetup()
            prerunResult = nil
            lastPrerunRun = nil
        } else if run.settings.mode == .calibrated && (run.settings.prerun != nil || continuationPrerun != nil) {
            clearPrerun()
        }
        activeSetupRevision = setupRevision
        recording = true
        stopping = false
        status = "Preparing recording"
        power = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Saving Signal Bench acquisition")
        recorder.start(store: store, run: run, continuationPrerun: continuationPrerun)
    }

    @Published private(set) var changingLiveDuration = false

    func changeLiveDuration(_ seconds: Double, finishIfElapsed: Bool = false) {
        guard recording, !stopping, !changingLiveDuration, let run = current else { return }
        changingLiveDuration = true
        recorder.changeDuration(run: run.id, to: seconds, finishIfElapsed: finishIfElapsed) { [weak self] issue in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.changingLiveDuration = false
                if let issue { self.notice = issue }
            }
        }
    }

    func stop() {
        guard recording, !stopping else { return }
        stopping = true
        status = "Stopping recording"
        if activeMode == .manual { recorder.releaseOutputs() }
        recorder.stop()
    }

    func sleepStarted() {
        invalidateSetup()
        recorder.sleepStarted()
        if projectReviewRunning { cancelWork() }
    }
    func woke() { recorder.woke() }

    func prepareToQuit(_ reply: @escaping (Bool) -> Void) {
        guard !quitting else { return }
        quitting = true
        stopProjectJobs()
        qualityWorker?.cancel()
        quitReply = reply
        if recording { stop() } else { cancelWork() }
        quitTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let reply = self.quitReply else { return }
            self.quitReply = nil
            self.quitting = false
            self.notice = "Quit paused while storage finishes. You can quit again after the current work ends."
            reply(false)
        }
        finishQuitIfIdle()
    }

    private func finishQuitIfIdle() {
        guard quitting, !busy, jobTask == nil, !timelineSaving, qualityTask == nil, let reply = quitReply else { return }
        quitTimeout?.cancel()
        quitReply = nil
        reply(true)
    }
    func revealRun(_ id: UUID) {
        guard let project else { return }
        do {
            let folder = try project.finderFolder(for: id)
            guard NSWorkspace.shared.open(folder) else { throw StreamFailure.storage("Finder could not open this run folder.") }
        } catch {
            if verifyProjectAccess() { notice = "Could not open the run in Finder. " + error.localizedDescription }
        }
    }

    func configureViewer(shown: Bool) { recorder.configureViewer(shown: shown, fps: shown ? liveFPS : 10) }

    func captureWaveform(at instant: UInt64, date: Date, seconds: Double) async -> LiveWaveformCapture? {
        guard recording, let run = current else { return nil }
        return await withCheckedContinuation { continuation in
            recorder.captureWaveform(run: run.id, at: instant, date: date, seconds: seconds) {
                continuation.resume(returning: $0)
            }
        }
    }

    @Published var diagnosisSource: DiagnosisSource?

    struct DiagnosisSource {
        let run: UUID
        let range: StreamSelection
    }

    func openDiagnosisSource(_ run: StreamRun, range: StreamSelection) {
        guard project?.identity.id == run.project, !recording else { return }
        diagnosisSource = .init(run: run.id, range: range)
        selection = run.id
        page = .library
    }

    func compareMainsHum(in run: StreamRun, segment: UUID, start: Double) async throws -> MainsHumCapture.Reading {
        guard let project, project.identity.id == run.project, !busy else {
            throw StreamFailure.storage("Open the source Project and finish recording before comparing runs.")
        }
        let grant = folderAccess
        let worker = Task.detached(priority: .utility) {
            try withExtendedLifetime(grant) {
                let current = try project.openRun(run.id)
                return try MainsHumCapture.compare(.init(store: project, run: current), segmentID: segment, start: start)
            }
        }
        let reading = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard self.project?.identity.id == run.project, !busy else { throw CancellationError() }
        return reading
    }

    func readRecordingWaveform(_ range: StreamSelection, density: Double?, limit: Int) async throws -> StudioPlot? {
        guard recording, let current, let project else { return nil }
        let grant = folderAccess
        let worker = Task.detached(priority: .utility) {
            try withExtendedLifetime(grant) {
                let run = try project.openRun(current.id, active: true)
                return try StreamStudio.plot(.init(store: project, run: run), selection: range,
                                             dotPercent: density, dotLimit: limit)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func previousWaveformOverview() async throws -> WaveformOverview? {
        guard let project, let current, current.segments.count > 1 else { return nil }
        let grant = folderAccess
        let worker = Task.detached(priority: .background) { () throws -> WaveformOverview? in
            try withExtendedLifetime(grant) {
                let run = try project.openRun(current.id, active: true)
                let chunks = try project.chunkSummaries(run)
                var earlier = run
                earlier.segments.removeLast()
                let ids = Set(earlier.segments.map(\.id))
                let reader = StreamRangeReader(store: project, run: earlier, index: chunks.filter { ids.contains($0.segment) })
                if let overview = try? WaveformOverview.read(reader) { return overview }
                return try WaveformOverview.build(reader, publish: false)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func openLiveTimeline(_ tool: RunTimelineRequest.Tool, replacing: Bool = false) {
        guard recording, let run = current, !openingTimeline, !quitting else { return }
        guard !timelineSaving else { return }
        if let timeline, timeline.runID == run.id, timeline.tool == tool, !replacing { return }
        guard !timelineHasChanges else { notice = "Save or discard the current flag or note before opening another editor."; return }
        if tool != .flag {
            timeline = .init(runID: run.id, tool: tool, frozen: nil)
            return
        }
        let instant = DispatchTime.now().uptimeNanoseconds
        let date = Date()
        openingTimeline = true
        recorder.freezeFlagWindow(run: run.id, at: instant, date: date) { [weak self] frozen in
            guard let bench = self else { return }
            Task { @MainActor in
                bench.openingTimeline = false
                guard bench.project?.identity.id == run.project, !bench.quitting, !bench.timelineHasChanges else { return }
                if let frozen { bench.timeline = .init(runID: run.id, tool: .flag, frozen: frozen) }
                else { bench.notice = "Wait for the first waveform samples before adding a flag." }
            }
        }
    }

    func openRunTimeline(_ id: UUID, replacing: Bool = false) {
        guard project != nil, !recording, !timelineSaving else { return }
        if timeline?.runID == id && !replacing { return }
        guard !timelineHasChanges else { notice = "Save or discard the current flag or note before opening another run."; return }
        let isCurve = runs.first { $0.id == id }?.run?.curveSource != nil
        timeline = .init(runID: id, tool: isCurve ? .note : .review, frozen: nil)
    }

    func timelineChanged(_ request: UUID, dirty: Bool) {
        if timeline?.id == request { timelineHasChanges = dirty }
    }

    func closeTimeline() {
        timelineHasChanges = false
        timeline = nil
    }

    func timelineLoad(for request: RunTimelineRequest, waveform: Bool = true) async throws -> RunTimelineContent {
        guard let project else { throw StreamFailure.storage("Open the recording’s Project first.") }
        let live = recording && current?.id == request.runID
        let grant = folderAccess
        let worker = Task.detached(priority: .utility) {
            try withExtendedLifetime(grant) {
                let run = try project.openRun(request.runID, active: live)
                let reader = StreamRangeReader(store: project, run: run)
                let entries = try RunTimeline.entries(reader, finished: !live, resolving: run.curveSource == nil)
                if run.curveSource != nil { return RunTimelineContent(reader: reader, entries: entries, duration: 0, overview: nil) }
                guard waveform else { return RunTimelineContent(reader: reader, entries: entries, duration: 0, overview: nil) }
                let prepared = try reader.prepared()
                return RunTimelineContent(reader: prepared, entries: entries, duration: try prepared.duration(),
                                          overview: live ? nil : try? WaveformOverview.read(prepared))
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func writeTimeline(_ entry: RunTimelineEntry, replacing: UUID?, run id: UUID, removing: Bool = false) async throws -> RunTimelineEntry {
        guard !timelineSaving, !quitting, let project else { throw StreamFailure.storage("The timeline is busy or its Project is unavailable.") }
        timelineSaving = true
        let live = recording && current?.id == id
        let check = !live || entry.position.map { $0.index < preview.committedBoundary } == true
        let grant = folderAccess
        let worker = Task.detached(priority: .utility) {
            try withExtendedLifetime(grant) {
                let run = try project.openRun(id, active: live)
                let reader = StreamRangeReader(store: project, run: run)
                if removing {
                    try RunTimeline.remove(entry, from: reader)
                    return entry
                }
                return try RunTimeline.save(entry, replacing: replacing, in: reader, finished: !live, checkCommitted: check)
            }
        }
        defer {
            timelineSaving = false
            if quitting { finishQuitIfIdle() }
            else if closeAfterDrain && !recording && draftDecision == nil && !busy && verifyProjectAccess() { finishProjectClose() }
        }
        let result = try await worker.value
        timelineRevision = UUID()
        return result
    }
    func release() { recorder.releaseOutputs() }
    func pin(_ number: Int, _ operation: UInt8) {
        guard (0..<32).contains(number), controllableGPIO & (1 << number) != 0 else { return }
        recorder.pin(number, operation: operation)
    }

    func invalidateSetup() {
        localProfile = nil
        prerunEpoch = nil
        setupRevision = UUID()
    }

    private func receive(_ event: StreamRecorderEvent) {
        switch event {
        case .deviceCandidates(let available):
            supportsDeviceCandidates = available
        case .streamCapabilities(let averaging):
            deviceAveragingAvailable = averaging
        case let .sdCapabilities(mask, state):
            reservedGPIO = mask
            picoSDState = state
        case .connecting:
            connecting = true
            status = "Checking firmware"
        case let .connected(capable, identity, pending, rates, channels, custom):
            customRates = custom
            deviceRates = rates
            diagnosticChannels = channels
            connected = true
            connecting = false
            streaming = capable
            firmware = identity
            connectionEpoch = UUID()
            invalidateSetup()
            if pending { status = "Finite capture pending" }
            else if let picoSDState, ["preparing", "countdown", "recording", "saving"].contains(picoSDState) { status = "Pico card recorder active" }
            else if identity.hasSuffix("-bench") { status = "Bench firmware detected" }
            else { status = capable ? "Connected" : "Streaming firmware required" }
            if pending { notice = "Recover the Pico’s pending finite capture in Signal Bench 1.3 before streaming." }
        case .disconnected(let message):
            connected = false
            connecting = false
            streaming = false
            supportsDeviceCandidates = false
            customRates = false
            reservedGPIO = 0
            picoSDState = nil
            deviceAveragingAvailable = false
            deviceRates = []
            diagnosticChannels = []
            firmware = ""
            connectionEpoch = UUID()
            invalidateSetup()
            status = message
            refreshPorts()
        case .started(let run):
            current = run
            status = (run.settings.startupDelaySeconds ?? 0) > 0 ? "Settling" : "Recording"
            if preview.received > 0 { status = "Recording" }
        case .durationChanged(let run):
            if recording, current?.id == run.id { current = run }
        case .preview(let data):
            preview = data
        case .stopping(let message):
            stopping = true
            status = message
        case let .finished(run, issue):
            if let power { ProcessInfo.processInfo.endActivity(power) }
            power = nil
            recording = false
            stopping = false
            activeMode = nil
            current = nil
            defer { schedulePostRun(); scheduleProjectJobs() }
            status = connected ? (streaming ? "Connected" : "Streaming firmware required") : "Disconnected"
            notice = issue ?? (run?.status == .interrupted ? run?.displayMessage : nil)
            if quitting { finishQuitIfIdle(); return }
            if let run {
                runs.removeAll { $0.id == run.id }
                runs.insert(.init(id: run.id, run: run, issue: issue), at: 0)
                selection = run.id
                reload(run.id)
                if run.isManualDraft { presentDraft(run); return }
                page = run.settings.mainsHum != nil ? .diagnosis : (run.settings.bench == nil ? .library : .study)
                if closeAfterDrain {
                    if !timelineSaving, verifyProjectAccess() { finishProjectClose() }
                    return
                }
                if run.settings.mode == .main, run.settings.draft == true { renamePrompt = true }
                if run.settings.prerunPlan != nil, let project {
                    assessPrerun(run, in: project)
                } else if run.settings.purpose == "localDarkCheck", !run.hasCadenceMismatch, let profile = run.settings.profile, let project,
                   activeEpoch == connectionEpoch {
                    let epoch = connectionEpoch
                    perform("Checking dark baseline") {
                        try StreamingCalibration.check(StreamRangeReader(store: project, run: run), profile: profile)
                        return profile.id
                    } completion: { [weak self] id in
                        if self?.connectionEpoch == epoch && self?.connected == true {
                            self?.localProfile = id
                            self?.notice = "Dark setup check passed for this connection."
                        }
                    }
                    page = .calibrated
                }
            } else if closeAfterDrain {
                if verifyProjectAccess() { closeAfterDrain = false }
            }
        }
    }

    private func assessPrerun(_ run: StreamRun, in project: StreamProjectStore) {
        let epoch = activeEpoch
        let revision = activeSetupRevision
        lastPrerunRun = run.id
        page = .calibrated
        performWithProgress("Checking dark prerun") { progress in
            try StreamingCalibration.assessPrerun(run.id, in: project, progress: progress)
        } completion: { [self] result in
            guard self.project?.identity.id == project.identity.id else { return }
            prerunResult = result
            if result.report.passed && connected && connectionEpoch == epoch && revision == setupRevision {
                prerunEpoch = epoch
                localProfile = result.report.profile
            }
            reload(run.id)
        }
    }

    func rename(_ name: String, description: String) {
        guard let project, let selectedRun else { return }
        do { _ = try project.rename(selectedRun.id, name: name, description: description); reload(selectedRun.id) }
        catch { notice = error.localizedDescription }
    }

    func showExports() {
        guard let project else { return }
        do { NSWorkspace.shared.open(try project.exports()) }
        catch { notice = error.localizedDescription }
    }

    func export(toFolderFor store: StreamProjectStore, title: String, progress: String,
                onSelection: () -> Void = {},
                write: @escaping @Sendable (URL) throws -> URL) {
        export(toFolderFor: store, title: title, progress: progress, onSelection: onSelection) { folder, _ in
            try write(folder)
        }
    }

    func export(toFolderFor store: StreamProjectStore, title: String, progress: String,
                onSelection: () -> Void = {}, verifiedZIP: Bool = false,
                write: @escaping @Sendable (URL, @Sendable (Double) -> Void) throws -> URL) {
        guard !busy, !quitting, project?.identity.id == store.identity.id, verifyProjectAccess() else { return }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose the folder where Signal Bench should save the export."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let projectExports = store.folder.appendingPathComponent("Exports", isDirectory: true)
        panel.directoryURL = (try? StreamFiles.directory(projectExports)) == nil ? store.folder : projectExports

        guard panel.runModal() == .OK, let folder = panel.url,
              !busy, !quitting, project?.identity.id == store.identity.id else { return }
        let grant = StreamFolderGrant(folder)
        onSelection()
        notice = nil
        performWithProgress(progress) { update in
            try Task.checkCancellation()
            do {
                return try withExtendedLifetime(grant) { try write(grant.url, update) }
            } catch let error as POSIXError where error.code == .EEXIST {
                throw StreamFailure.storage("That name already exists in the selected folder. Choose a different name or folder.")
            }
        } completion: { [self, grant] url in
            withExtendedLifetime(grant) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            notice = verifiedZIP ? "Exported and verified \(url.lastPathComponent)." : "Exported \(url.lastPathComponent)."
        }
    }

    func perform<T: Sendable>(_ title: String, action: @escaping @Sendable () async throws -> T,
                             completion: @escaping (T) -> Void) {
        performWithProgress(title, action: { _ in try await action() }, completion: completion)
    }

    func performWithProgress<T: Sendable>(_ title: String, projectReview: Bool = false,
                                          failure: (() -> Void)? = nil,
                                          action: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> T,
                                          completion: @escaping (T) -> Void) {
        guard !busy, !quitting else { return }
        qualityWorker?.cancel()
        operation = title
        operationProgress = nil
        projectReviewRunning = projectReview
        projectReviewToolReplies = 0
        let id = UUID()
        operationID = id
        let task = Task.detached(priority: .utility) { [weak self] in
            let value = try await action { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == id else { return }
                    self.operationProgress = max(self.operationProgress ?? 0, min(1, progress))
                }
            }
            if projectReview { try Task.checkCancellation() }
            return value
        }
        cancel = { task.cancel() }
        work = Task {
            let result = await task.result
            operation = nil
            operationID = nil
            operationProgress = nil
            projectReviewRunning = false
            cancel = nil
            work = nil
            if quitting { finishQuitIfIdle(); return }
            if projectReview, closeAfterDrain { closeProject(); return }
            defer { scheduleProjectJobs(); schedulePostRun() }
            switch result {
            case .success(let value): completion(value)
            case .failure(is CancellationError):
                failure?()
                notice = projectReview && pendingRecording ? "Local AI review stopped for recording. Run the review again when recording ends." : "Cancelled."
            case .failure(let error):
                if verifyProjectAccess() {
                    notice = error.localizedDescription
                    failure?()
                }
            }
        }
    }

    private var operationID: UUID?

    func cancelWork() { cancel?() }

    func queueCurve(_ reader: StreamRangeReader, name: String, selection: StreamSelection,
                    spec: CurveJobSpec, destination: Bool = false, onQueued: @escaping () -> Void = {}) {
        guard let project, !busy, !quitting, project.identity.id == reader.store.identity.id, verifyProjectAccess() else { return }
        let grant = destination ? chooseJobDestination(project) : nil
        if destination && grant == nil { return }
        perform("Preparing waveform job") {
            let input: ProjectJob.Input
            if spec.action == .fit {
                input = try ProjectJob.Input.pin(reader, selection: selection)
            } else {
                input = try CurveDelivery.pin(CurveStore.open(project, run: reader.run, id: spec.curve), selection: selection)
            }
            let estimate = Int64(input.recordedReadings) * (spec.action == .csv ? 140 : Int64(PicoAverage.stride(reader.run.settings.picoAveraging, board: reader.run.settings.board)))
            return ProjectJob(project: project.identity.id, kind: .waveformCurve, input: input,
                              name: try SessionStore.projectName(name), estimatedBytes: estimate,
                              needsDestination: grant != nil, curve: spec)
        } completion: { [weak self] job in
            if self?.approveJobs([job], destination: grant).isEmpty == false { onQueued() }
        }
    }

    func trashCurveSource(_ run: StreamRun, typed: String) {
        guard let project, !busy, !timelineSaving, !projectJobsUnfinished, verifyProjectAccess() else { return }
        perform("Verifying standalone waveform") {
            try CurveDelivery.trashSource(for: run, in: project, typed: typed)
        } completion: { [weak self] _ in
            self?.reload(run.id)
            self?.curveRevision = UUID()
            self?.notice = "Source run moved to Trash."
        }
    }

    func revealRunReport(_ folder: URL) {
        do {
            try StreamFiles.directory(folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { notice = error.localizedDescription }
    }

    @Published private(set) var curveRevision = UUID()
    @Published private(set) var requestedCurve: UUID?

    func openCurveJob(_ job: ProjectJob) {
        guard job.state == .completed, let spec = job.curve, project?.identity.id == job.project else { return }
        page = .library
        selection = spec.action == .standalone ? job.id : job.input.run
        requestedCurve = spec.curve
        curveRevision = UUID()
    }

    func consumeCurveSelection() { requestedCurve = nil }

    func queueExport(_ reader: StreamRangeReader, name: String, selection: StreamSelection, format: StreamExporter.Format,
                     includeAnalyses: Bool, onSelection: () -> Void) {
        guard !busy, !quitting, project?.identity.id == reader.store.identity.id, verifyProjectAccess(),
              let grant = chooseJobDestination(reader.store) else { return }
        onSelection()
        perform("Preparing export") {
            var job = try ProjectJob.export(reader, name: name, selection: selection, format: format,
                                            includeAnalyses: includeAnalyses, external: true)
            let local = reader.store.folder.appendingPathComponent("Exports").resolvingSymlinksInPath().path
            if grant.url.resolvingSymlinksInPath().path == local {
                job.needsDestination = false
            }
            return job
        } completion: { [weak self] job in
            self?.approveJobs([job], destination: grant)
        }
    }

    func exportSelectedRuns(_ ids: [UUID], projectID: UUID, name: String) {
        guard let project, project.identity.id == projectID else { return }
        export(toFolderFor: project, title: "Save Run ZIP", progress: "Exporting and verifying runs", verifiedZIP: true) {
            folder, update in
            try RunBatchArchive.export(ids, in: project, named: name, to: folder, progress: update)
        }
    }

    func queueLibraryExports(_ runs: [StreamRun], format: StreamExporter.Format) {
        guard let project, !busy, !quitting, verifyProjectAccess(),
              (1...10_000).contains(runs.count), let destination = chooseJobDestination(project) else { return }
        let local = project.folder.appendingPathComponent("Exports").resolvingSymlinksInPath().path
        let external = destination.url.resolvingSymlinksInPath().path != local
        performWithProgress("Preparing run exports") { update in
            var jobs: [ProjectJob] = []
            for (offset, run) in runs.enumerated() {
                try Task.checkCancellation()
                let reader = try StreamRangeReader(store: project, run: run).prepared()
                guard let range = try? FixtureTemplateStudy.fullRange(reader) else { continue }
                var title = run.name
                while title.utf8.count > 100 { title.removeLast() }
                title += " " + run.id.uuidString.prefix(8)
                jobs.append(try ProjectJob.export(reader, name: title, selection: range, format: format,
                                                  includeAnalyses: true, external: external))
                if offset.isMultiple(of: 20) { update(Double(offset + 1) / Double(runs.count)) }
            }
            guard !jobs.isEmpty else { throw StreamFailure.storage("None of these runs has verified readings to export.") }
            return jobs
        } completion: { [weak self] jobs in
            self?.approveJobs(jobs, destination: destination)
        }
    }

    private func chooseJobDestination(_ store: StreamProjectStore) -> StreamFolderGrant? {
        let panel = NSOpenPanel()
        panel.title = "Export Run"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let projectExports = store.folder.appendingPathComponent("Exports", isDirectory: true)
        panel.directoryURL = (try? StreamFiles.directory(projectExports)) == nil ? store.folder : projectExports
        guard panel.runModal() == .OK, let url = panel.url, project?.identity.id == store.identity.id else { return nil }
        return StreamFolderGrant(url)
    }

    @discardableResult
    func approveJobs(_ approved: [ProjectJob]) -> Set<UUID> { approveJobs(approved, destination: nil) }

    @discardableResult
    private func approveJobs(_ approved: [ProjectJob], destination: StreamFolderGrant?) -> Set<UUID> {
        let prior = Set(jobs.map(\.id))
        guard let project, !quitting, !closeAfterDrain, verifyProjectAccess(),
              !approved.isEmpty, approved.count + jobs.count <= 10_000,
              Set(approved.map(\.id)).count == approved.count,
              approved.allSatisfy({ $0.project == project.identity.id && $0.state == .queued &&
                  (!($0.needsDestination) || destination != nil) && !prior.contains($0.id) }) else { return [] }
        var queued = Set<UUID>()
        for job in approved {
            do {
                try ProjectJobFiles.save(job, in: project)
                jobs.insert(job, at: 0)
                queued.insert(job.id)
                if let destination { jobDestinations[job.id] = destination }
            } catch { notice = "Some jobs could not be queued. " + error.localizedDescription; break }
        }
        scheduleProjectJobs()
        return queued
    }

    func retryJob(_ id: UUID, name: String? = nil) {
        guard let project, !quitting, verifyProjectAccess(), let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state.retryable else { return }
        var job = jobs[index]
        if job.needsDestination, jobDestinations[id] == nil || job.message?.contains("already exists") == true {
            guard let grant = chooseJobDestination(project) else { return }
            jobDestinations[id] = grant
        }
        if let name, job.picksDestination {
            guard let checked = try? SessionStore.projectName(name) else { return }
            job.name = checked
        }
        job.state = .queued
        job.progress = 0
        job.message = nil
        job.output = nil
        if updateJob(job, in: project) { scheduleProjectJobs() }
    }

    func cancelJob(_ id: UUID) {
        guard let project, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.unfinished else { return }
        if id == jobID {
            jobClosureState = .cancelled
            jobControl?.cancel()
        } else {
            var job = jobs[index]
            job.state = .cancelled
            job.message = "Cancelled before starting."
            _ = updateJob(job, in: project)
        }
    }

    func revealJob(_ id: UUID) {
        guard let project, let job = jobs.first(where: { $0.id == id }), job.state == .completed,
              let file = job.output, verifyProjectAccess() else { return }
        do {
            let folder: URL
            if job.needsDestination {
                guard let grant = jobDestinations[id] else { throw StreamFailure.storage("The export was saved to a separately selected folder. Its access expired when the Project closed.") }
                folder = grant.url
            } else if job.picksDestination {
                folder = try project.exports()
            } else if job.curve?.action == .fit {
                folder = try CurveStore.root(project, project.openRun(job.input.run), create: false)
            } else if job.curve?.action == .standalone {
                folder = try StreamFiles.directory("runs", in: project.folder, create: false)
            } else {
                folder = try ProjectJobFiles.resultFolder(project, create: false)
            }
            let target = folder.appendingPathComponent(file)
            guard try StreamFiles.isPresent(target) else { throw StreamFailure.storage("The job output moved or was deleted.") }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { notice = error.localizedDescription }
    }

    func inspectJob(_ job: ProjectJob) {
        guard job.kind == .exclusions, job.state == .completed, !busy, project?.identity.id == job.project else { return }
        page = .library
        selection = job.input.run
        exclusionJob = job
    }

    @Published var exclusionJob: ProjectJob?

    func jobHasFinderLocation(_ job: ProjectJob) -> Bool {
        job.state == .completed && (!job.needsDestination || jobDestinations[job.id] != nil)
    }

    @discardableResult private func updateJob(_ job: ProjectJob, in store: StreamProjectStore) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return false }
        jobs[index] = job
        do { try ProjectJobFiles.save(job, in: store); return true }
        catch { notice = "Job history could not be saved. " + error.localizedDescription; return false }
    }

    private func pauseProjectJob() {
        guard let project, let id = jobID, var job = jobs.first(where: { $0.id == id }), job.state == .running else { return }
        jobControl?.setPaused(true)
        job.state = .paused
        _ = updateJob(job, in: project)
    }

    private func stopProjectJobs() {
        if let project {
            for var job in jobs where job.id != jobID && job.state.unfinished {
                job.state = .interrupted
                job.message = "The Project closed before this job started. Retry when ready."
                _ = updateJob(job, in: project)
            }
        }
        jobClosureState = .interrupted
        jobControl?.cancel()
        jobDestinations.removeAll()
        jobProgressWrites.removeAll()
    }

    private func scheduleProjectJobs() {
        guard let project, !busy, !pendingRecording, !quitting, !closeAfterDrain, !needsProjectAccess else { return }
        if let id = jobID, var job = jobs.first(where: { $0.id == id }), job.state == .paused {
            job.state = .running
            _ = updateJob(job, in: project)
            jobControl?.setPaused(false)
            return
        }
        guard jobTask == nil, !busy, let next = jobs.last(where: { $0.state == .queued }) else { return }
        if qualityTask != nil { qualityWorker?.cancel(); return }
        let control = ProjectJobControl()
        let destination = jobDestinations[next.id], access = folderAccess
        var state = next
        state.state = .running
        guard updateJob(state, in: project) else {
            state.state = .failed
            state.message = "The job history could not be updated."
            _ = updateJob(state, in: project)
            return
        }
        jobID = next.id
        jobControl = control
        jobClosureState = nil
        let worker = Task.detached(priority: .utility) { [weak self] in
            try withExtendedLifetime((destination, access)) {
                try ProjectJobFiles.execute(next, store: project, destination: destination?.url, control: control) { value in
                    Task { @MainActor [weak self] in self?.reportJobProgress(value, id: next.id, store: project) }
                }
            }
        }
        jobTask = Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            let disposition = jobClosureState
            jobControl = nil
            jobID = nil
            jobTask = nil
            jobClosureState = nil
            var final = jobs.first(where: { $0.id == next.id }) ?? next
            switch result {
            case .success(let url):
                final.state = .completed
                final.progress = 1
                final.output = url.lastPathComponent
                final.message = nil
                if next.kind == .comparison { timelineRevision = UUID() }
                if next.curve?.action == .fit || next.curve?.action == .standalone {
                    curveRevision = UUID()
                    if next.curve?.action == .standalone { reload(next.id) }
                }
            case .failure(is CancellationError):
                final.state = disposition ?? .interrupted
                final.message = final.state == .cancelled ? "Cancelled. No output was published." : "The job stopped before publishing. Retry when ready."
            case .failure(let error):
                final.state = .failed
                final.message = (error as? POSIXError)?.code == .EEXIST ?
                    "That export already exists. Choose a different folder or export name." : String(error.localizedDescription.prefix(1500))
            }
            _ = updateJob(final, in: project)
            jobProgressWrites[next.id] = nil
            if quitting { finishQuitIfIdle() }
            else if closeAfterDrain, !recording { closeProject() }
            else { scheduleProjectJobs(); schedulePostRun() }
        }
    }

    private func reportJobProgress(_ fraction: Double, id: UUID, store: StreamProjectStore) {
        guard jobID == id, !recording, let index = jobs.firstIndex(where: { $0.id == id }), fraction.isFinite else { return }
        jobs[index].progress = max(jobs[index].progress, min(1, fraction))
        if fraction - (jobProgressWrites[id] ?? 0) >= 0.05 {
            jobProgressWrites[id] = fraction
            do { try ProjectJobFiles.save(jobs[index], in: store) }
            catch { jobControl?.cancel(); notice = "Job progress could not be saved. " + error.localizedDescription }
        }
    }

    private func resetPostRunQueue() {
        qualityWorker?.cancel()
        qualityDone.removeAll()
        qualityPaused.removeAll()
        qualityIssues.removeAll()
        qualityProgress.removeAll()
        qualityRevisions.removeAll()
    }

    func pausePostRun(_ id: UUID) {
        do {
            guard let project else { return }
            try project.verify()
            let marker = try project.runDirectory(id).appendingPathComponent(WaveformOverview.pauseMarker)
            if try !StreamFiles.isPresent(marker) { try StreamFiles.publish(Data(), at: marker) }
            qualityPaused.insert(id)
            if qualityProgress[id] != nil { qualityWorker?.cancel() }
        } catch { notice = "Could not save the pause. " + error.localizedDescription }
    }

    func retryPostRun(_ id: UUID) {
        do {
            guard let project else { return }
            try project.verify()
            let marker = try project.runDirectory(id).appendingPathComponent(WaveformOverview.pauseMarker)
            if try StreamFiles.isPresent(marker) {
                try FileManager.default.removeItem(at: marker)
                try StreamFiles.sync(marker.deletingLastPathComponent())
            }
            qualityPaused.remove(id)
            qualityDone.remove(id)
            qualityIssues[id] = nil
            schedulePostRun(preferred: id)
        } catch { notice = "Could not resume the summary. " + error.localizedDescription }
    }

    private func schedulePostRun(preferred: UUID? = nil) {
        guard !busy, !pendingRecording, jobTask == nil, !quitting, !closeAfterDrain, !needsProjectAccess, qualityTask == nil, let project else { return }
        let pending = runs.compactMap(\.run).filter {
            !$0.isManualDraft && $0.curveSource == nil && $0.status != .recording && !$0.segments.isEmpty &&
                !qualityDone.contains($0.id) && !qualityPaused.contains($0.id) && qualityIssues[$0.id] == nil
        }
        guard let run = pending.first(where: { $0.id == preferred }) ?? pending.first else { return }
        let id = run.id
        let projectID = project.identity.id
        let grant = folderAccess
        let option = defaults.afterRecording ?? .quality
        qualityProgress[id] = .init()
        let worker = Task.detached(priority: .utility) { [weak self] in
            try withExtendedLifetime(grant) {
                let reader = try StreamRangeReader(store: project, run: run).prepared()
                let existing = try? WaveformOverview.read(reader)
                let saved = existing?.hasAverages == true && existing?.hasRailBreakdown == true ? existing : nil
                let overview = try saved ?? WaveformOverview.build(reader, resume: true) { fraction in
                    Task { @MainActor [weak self] in
                        guard self?.project?.identity.id == projectID, self?.qualityProgress[id] != nil else { return }
                        self?.qualityProgress[id] = fraction
                    }
                }
                guard let overview else { return false }
                try Task.checkCancellation()
                let calibrated = run.settings.mode == .calibrated && run.settings.purpose == nil
                if option == .noise || option == .profile || calibrated {
                    let count = overview.minutes.reduce(UInt64(0)) { $0 + $1.samples }
                    Task { @MainActor [weak self] in
                        guard self?.project?.identity.id == projectID, self?.qualityProgress[id] != nil else { return }
                        self?.qualityProgress[id] = .init(stage: .analyzing, scanned: count, total: count)
                    }
                    let results = try StreamStudio.analyses(reader)
                    if option == .noise && !results.contains(where: {
                        $0.analyzer == PostRunAnalysis.noiseAnalyzer && $0.sourceHash == overview.sourceHash
                    }) {
                        _ = try PostRunAnalysis.noise(reader, overview: overview)
                    }
                    if (calibrated || option == .profile && run.settings.purpose == nil),
                       let profile = run.settings.profile, profile.valid, profile.measurementReady,
                       run.settings.channel == 0, !run.hasCadenceMismatch,
                       !results.contains(where: {
                           $0.analyzer == "signalbench.profile-pulses" && $0.profileRevision == profile.id &&
                               ($0.sourceHash == overview.sourceHash ||
                                ($0.sourceHash == nil && $0.selection.lower == 0 && $0.selection.upper == overview.duration &&
                                 $0.created >= (run.segments.last?.started ?? .distantFuture)))
                       }) {
                        let range = StreamSelection(lower: 0, upper: overview.duration)
                        let policy = run.settings.noisePolicy ?? .review
                        if calibrated, policy != .review, try RunAnnotations.read(reader) == nil {
                            let settings = ReviewSettings(profile: profile)
                            let masks = try RunAnnotations.preview(reader, selection: range, policy: policy, settings: settings)
                            try Task.checkCancellation()
                            _ = try RunAnnotations.save(.init(masks: masks, policy: policy, autoSettings: settings, noiseProfile: profile.id),
                                                        reader: reader, replacing: nil)
                        }
                        _ = try StreamStudio.save(reader, selection: range, rules: profile.rules, sourceHash: overview.sourceHash)
                    }
                }
                return true
            }
        }
        qualityWorker = worker
        qualityTask = Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            qualityTask = nil
            qualityWorker = nil
            qualityProgress[id] = nil
            if self.project?.identity.id == projectID {
                switch result {
                case .success(let published):
                    if !worker.isCancelled { qualityDone.insert(id) }
                    if published { qualityRevisions[id] = UUID() }
                case .failure(is CancellationError):
                    qualityRevisions[id] = UUID()
                case .failure(let error):
                    qualityIssues[id] = error.localizedDescription
                    qualityRevisions[id] = UUID()
                }
            }
            if quitting { finishQuitIfIdle() }
            else { scheduleProjectJobs(); schedulePostRun() }
        }
    }
}

private extension Result {
    var failureDescription: String? {
        if case .failure(let error) = self { return error.localizedDescription }
        return nil
    }
}
