import Foundation
import AppKit
import Combine

nonisolated struct ManualSnapshot: Sendable {
    let timeUS: UInt64
    let adc: Int?
    let adcError: Bool
    let directions: UInt32
    let levels: UInt32
    let outputs: UInt32
}

enum MeasurementStep: Equatable {
    case connect, reconnect, checking, capturing, receiving, confirmingSave, exporting
    case stopDiagnostics, recoverySession, recover, session, gain, calibration, ready
}

struct MeasurementRun {
    enum Phase { case running, pausing, paused, completed, interrupted }

    static let maximumCaptures = 1_000
    let target: Int
    var id = UUID()
    var durationSeconds: Double?
    var accumulatedSeconds: Double = 0
    var startedNS: UInt64 = DispatchTime.now().uptimeNanoseconds
    var startedAt = Date()
    var workspace = "Measurements"
    var channel = 0
    var probeSource = "Final ADC"
    var sampledSeconds: Double = 0
    var gapSeconds: Double = 0
    var observationOnly = false
    var observationWindows = 0
    var mainObservationOptions: MainObservationOptions? = nil
    var profileAcquisition: ProfileAcquisition? = nil
    var profileSegments: [ProfileRunSegment] = []
    var profilePauseReason: String? = nil
    var finishAfterCapture = false
    var profile = "POSITIVE"
    // Historical field name stores the configured value. Pair with confirmation
    // before interpreting it as the physical jumper position.
    var physicalGain = "LOW"
    var gainConfirmed: Bool? = nil
    var clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var elapsedSeconds: Double {
        accumulatedSeconds + ((phase == .running || phase == .pausing) && startedNS > 0 ? Double(clock() >= startedNS ? clock() - startedNS : 0) / 1e9 : 0)
    }
    mutating func stopClock() { accumulatedSeconds = elapsedSeconds; startedNS = 0 }
    let tag: String
    let sessionID: UUID
    let sessionName: String
    var calibrationRecordID: String
    var completed = 0
    var candidates = 0
    var qualifiedPulses = 0
    var rejectedWindows = 0
    var phase: Phase = .running

    var inProgress: Bool { phase == .running || phase == .pausing }

    mutating func count(_ record: CaptureRecord) {
        completed += 1
        candidates += Int(record.metadata["candidates"] ?? "") ?? 0
        if record.metadata["observation_only"] == "1" {
            observationWindows += 1
            if record.metadata["acq_flags"] != "0" || record.metadata["quality_flags"] != "0" { rejectedWindows += 1 }
        } else if record.metadata["usable"] == "1" {
            qualifiedPulses += record.events.filter { $0["qualified"] == "1" }.count
        } else {
            rejectedWindows += 1
        }
        if let hz = record.metadata["sample_hz"].flatMap(Double.init), hz > 0 {
            sampledSeconds += Double(record.samples.count) / hz
        }
        gapSeconds += (Double(record.metadata["gap_before_us"] ?? "") ?? 0) / 1e6
        if (durationSeconds == nil && completed >= target) || durationSeconds.map({ elapsedSeconds >= $0 }) == true {
            stopClock(); phase = .completed
        }
    }
}

@MainActor final class BenchModel: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published var connectionStatus = "Disconnected"
    @Published var deviceInfo = ""
    @Published var connected = false
    @Published var busy = false
    @Published private(set) var shutdownInProgress = false
    private var shutdownStorageIssue: String?
    private var shutdownManualReleaseConfirmed = false
    private var selectionRevision = UUID()
    private var sessionRevision = UUID()
    @Published var pendingUnsaved = false
    @Published var calibrated = false
    @Published var gainConfirmed = false
    @Published var gain = "LOW"
    @Published var status = "Choose a session and connect a Pico W."
    @Published var error: String?
    @Published private(set) var captureSaveIssue: String?
    @Published var currentSession: SessionMetadata?
    @Published var sessionURL: URL?
    @Published var records: [CaptureRecord] = []
    @Published var selectedRecord: CaptureRecord?
    @Published private(set) var measurementRun: MeasurementRun?
    @Published private(set) var burstSupported = false
    @Published private(set) var observationsSupported = false
    @Published private(set) var observationOnly = false
    @Published var exportScope: ExportScope?
    var canRecordMeasurements: Bool { observationOnly && observationsSupported || activeCalibrationRecord != nil }

    @Published private(set) var processingProfile = "POSITIVE"
    @Published private(set) var calibrationProgress = ""
    @Published private(set) var runRecoveryNote = ""
    @Published private(set) var savedRuns: [RunArchive] = []
    @Published private(set) var profileLiveCoverage = ProfileCoverage()
    private var profileProof: (id: UUID, generation: UUID, setup: CalibrationSetup)?
    private var profileBlockCoverage: [Int: ProfileCoverage] = [:]
    var profileConnection: UUID { connectionGeneration }
    var profileBoot: String? { connected ? deviceBootID : nil }
    var profileCanCapture: Bool { readyForAcquisition(observing: true) && deviceInfo == "Pico W · firmware 1.5" && gainConfirmed }
    func hasProfileSetup(_ profile: CalibrationProfile) -> Bool {
        guard let proof = profileProof else { return false }
        return connected && proof.id == profile.id && proof.generation == connectionGeneration
            && proof.setup == profile.setup && gainConfirmed && gain == profile.setup.gain
    }
    func forgetProfileSetup() { profileProof = nil }
    nonisolated static func isProfileAccessError(_ error: Error) -> Bool { permissionError(error) }
    func restoreProfileFolderAccess() throws { try reauthorizeSession() }
    func profileProjectContext() -> MainNoiseReviewContext? {
        guard let store, let folder = sessionURL, let id = currentSession?.id else { return nil }
        return MainNoiseReviewContext(store: store, folder: folder, sessionID: id)
    }
    func acceptProfileSetup(_ profile: CalibrationProfile, check: RunArchive, result: ProfileSetupEvaluation,
                            connection: UUID) {
        guard result.passed, check.phase == "completed", check.sessionID == currentSession?.id,
              check.profileAcquisition?.purpose == .setupCheck, check.profileAcquisition?.snapshot == profile,
              check.profileAcquisition?.boot == profileBoot, connection == connectionGeneration,
              profileCanCapture, gain == profile.setup.gain else { return }
        profileProof = (profile.id, connection, profile.setup)
    }
    @Published private(set) var savedAnalyses: [SignalAnalysisResult] = []
    @Published private(set) var exporting = false
    private var exportCancellation = ExportCancellation()
    private struct ExportContext {
        let sessionID: UUID
        let folder: URL
        let scope: ExportScope
        let record: CaptureRecord?
        let run: RunArchive?
    }
    private var exportContext: ExportContext?
    @Published private(set) var lastExportURL: URL?
    var exportRecordCount: Int {
        guard let context = exportContext else { return 0 }
        switch context.scope {
        case .record: return context.record == nil ? 0 : 1
        case .run: return records.filter { $0.metadata["host_run_id"] == context.run?.id.uuidString }.count
        case .session: return records.count
        }
    }

    var runClock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    private var deviceBootID: String?
    private var binarySupported = false
    private var calSeriesSupported = false
    private var profileSupported = false
    private var profileConfigured = false
    private var calibrationWindowsRemaining = 0
    private var calibrationSeriesActive = false
    private var calibrationWindowAccepted = false
    private var lastCommittedRecord: CaptureRecord?
    private let ioQueue = DispatchQueue(label: "SignalBench.Persistence", qos: .utility)
    private var recordingActivity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var burstRequest: (workspace: String, channel: Int, source: String)?

    var sequenceRunning: Bool { measurementRun?.inProgress == true }
    @Published private(set) var manualSupported = false
    @Published private(set) var manualActive = false
    @Published private(set) var manualSnapshot: ManualSnapshot?
    @Published private(set) var manualHistory: [ManualSnapshot] = []
    @Published private(set) var appRootURL: URL?
    @Published private(set) var manualRateIndex = 0
    @Published private(set) var manualObservedRateHz: Double?
    @Published private(set) var manualTotalReadings: UInt64 = 0
    @Published private(set) var manualADCErrorReadings: UInt64 = 0
    @Published private(set) var manualStopping = false
    @Published private(set) var manualPinPending = false
    @Published private(set) var stageSupported = false
    @Published private(set) var stageActive = false
    @Published private(set) var stageStopping = false
    @Published private(set) var stageHistory: [StageSnapshot] = []
    @Published private(set) var stageLabels: [StageProbeLabel] = [.disconnected, .disconnected]
    @Published private(set) var stageWiringConfirmed = false
    @Published private(set) var stageConfirmedAt: Date?
    @Published private(set) var stageLastReceivedAt: Date?
    private var stageBuffer = StageHistory()
    private var stagePoll: Task<Void, Never>?
    private var stageExitRequested = false
    private var stageSequence: UInt32 = 0
    private var stageFirmware = ""
    private var stageRunConfirmedAt: Date?
    private var stageRunLabels: [StageProbeLabel] = [.disconnected, .disconnected]
    static let manualHistoryLimit = 4096
    private var manualBuffer = ManualSampleBuffer()
    @Published private(set) var manualCSVBusy = false
    @Published private(set) var manualCSVActive = false
    @Published private(set) var manualCSVDeadline: ContinuousClock.Instant?
    @Published private(set) var manualCSVExporting = false
    @Published private(set) var manualCSVStatus: String?
    @Published private(set) var manualCSVReports: [ManualCSVReport] = []
    private var manualCSVProjectID: UUID?
    private var manualCSVStartRequest: UUID?
    private var manualCSVRecorder: ManualCSVRecording?
    private var manualCSVQueuedRows = 0
    private var manualCSVFailure = false
    private var manualCSVDurationSeconds = ManualCSVRecording.durationRange.upperBound
    private var manualCSVTimer: Task<Void, Never>?
    private var manualCSVReachedDuration = false
    private var manualCSVExportCancellation: ExportCancellation?
    private var manualDisplayTask: Task<Void, Never>?
    private var manualLastPublishedNS: UInt64 = 0
    private var manualLastRequestNS: UInt64 = 0
    private var pendingManualPin: (pin: Int, action: String)?
    private let link: SerialTransport
    private let folderSelector: ((String, URL?) -> URL?)?
    private let recordWriter: (SessionStore, CaptureRecord, URL) throws -> Void
    private var accessibleURL: URL?
    private var accessibleAppRootURL: URL?
    private var assembler: SBRecordAssembler?
    private var activeToken: String?
    private var waitingAck: String?
    private var countedRunTokens = Set<String>()
    private var runCaptureToken: String?
    private var watchdog: Task<Void, Never>?
    private var store: SessionStore?
    private enum Response { case idle, hello, status, gain, profile, calibrationBegin, capture, transfer, saving, acknowledgement, manualEnter, manualExit, manualRead, manualPin, stageEnter, stageRead, stageExit }
    private var response: Response = .idle
    private var manualPoll: Task<Void, Never>?
    private var manualExitRequested = false
    // GP27/28 are permanently reserved for optional J3 probes, on every firmware.
    static let manualPins = Array(0...14) + Array(16...22)
    private static let manualMask = manualPins.reduce(UInt32(0)) { $0 | (UInt32(1) << $1) }
    private static let legacyManualInputMask = manualMask | (3 << 27)
    private var devicePending: String?
    private struct SessionCalibration {
        let sessionID: UUID
        let recordID: String
        let deviceID: UInt64
        let gain: String
        let profile: String
    }
    private var sessionCalibration: SessionCalibration?
    private var calibrationAttemptToken: String?
    private var activeIntent: CaptureIntent?
    private var connectionGeneration = UUID()

    var activeCalibrationRecord: CaptureRecord? {
        guard calibrated, let calibration = sessionCalibration else { return nil }
        return records.first { $0.id == calibration.recordID && $0.complete }
    }

    private func invalidateCalibration(interruptRecording: Bool = true) {
        if interruptRecording { interruptRun() }
        calibrated = false
        sessionCalibration = nil
        calibrationAttemptToken = nil
        calibrationSeriesActive = false
        calibrationWindowsRemaining = 0
    }

    var pendingCaptureToken: String? { devicePending ?? activeToken }

    var recoveryMatchesSession: Bool {
        guard let token = pendingCaptureToken, let session = currentSession else { return false }
        if let intent = activeIntent, intent.token == token { return intent.sessionID == session.id }
        return !CaptureIntent.isBound(token) || CaptureIntent.matchesSession(token, session.id)
    }

    var recoveryIsUnlinked: Bool {
        pendingCaptureToken.map { !CaptureIntent.isBound($0) } ?? false
    }

    func measurementStep(selectedGain: String) -> MeasurementStep {
        if busy {
            if exporting { return .exporting }
            switch response {
            case .capture: return .capturing
            case .transfer: return .receiving
            case .acknowledgement, .saving: return .confirmingSave
            default: return .checking
            }
        }
        if !connected { return pendingUnsaved ? .reconnect : .connect }
        if manualActive || stageActive { return .stopDiagnostics }
        if pendingUnsaved { return recoveryMatchesSession ? .recover : .recoverySession }
        if currentSession == nil { return .session }
        if (!gainConfirmed || selectedGain != gain) && !(observationOnly && observationsSupported) { return .gain }
        return canRecordMeasurements ? .ready : .calibration
    }

    var pendingHasSavedCopy: Bool {
        guard let token = devicePending ?? activeToken else { return false }
        return records.contains { $0.id == token && $0.complete }
    }

    init(link: SerialTransport? = nil, folderSelector: ((String, URL?) -> URL?)? = nil,
         recordWriter: ((SessionStore, CaptureRecord, URL) throws -> Void)? = nil) {
        self.link = link ?? SerialLink()
        self.folderSelector = folderSelector
        self.recordWriter = recordWriter ?? { try $0.saveRecord($1, to: $2) }
        self.link.onLine = { [weak self] line in self?.received(line) }
        self.link.onDisconnect = { [weak self] message in self?.lost(message) }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.interruptRun()
                self?.status = "Recording interrupted by Mac sleep. Recover any pending capture before continuing."
            }
        }
        refreshPorts()
    }
    private func noteShutdownStorageIssue(_ message: String) {
        if shutdownInProgress { shutdownStorageIssue = message }
    }

    /// Let the current finite record finish, release live modes and drain local
    /// writes before the application decides whether it can close safely.
    /// A nonnil result requires a user decision; it never claims Pico RAM is durable.
    func prepareForShutdown(timeout: TimeInterval = 30) async -> String? {
        guard !shutdownInProgress else { return "Signal Bench is already finishing its current work." }
        shutdownInProgress = true
        shutdownStorageIssue = nil; shutdownManualReleaseConfirmed = false
        let manualReleaseRequired = manualActive || response == .manualEnter || response == .manualExit
        let interval = timeout.isFinite ? min(120, max(0.05, timeout)) : 30
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(interval * 1_000_000_000)
        pauseRun()
        // Do not acquire another quiet window after the outstanding one.
        calibrationSeriesActive = false; calibrationWindowsRemaining = 0
        cancelExport(); cancelManualCSVExport(); exitManual(); exitStageDiagnostics()
        while busy || sequenceRunning || manualActive || stageActive || exporting || manualCSVBusy {
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { break }
        }
        let timedOut = busy || sequenceRunning || manualActive || stageActive || exporting || manualCSVBusy
        let unresolvedRecord = pendingUnsaved || activeToken != nil
        // Disconnect first: its interruption checkpoint and partial preservation
        // must be included in the persistence drain, not queued afterward.
        disconnect()
        var drained = await drainPersistence(until: deadline)
        // An earlier IO completion may enqueue its run checkpoint on the main
        // actor. A second barrier includes that checkpoint before returning.
        if drained { drained = await drainPersistence(until: deadline) }
        var attention: [String] = []
        if timedOut { attention.append("The current device or export operation did not finish before the close deadline.") }
        if !drained { attention.append("Local file work has not confirmed completion. Closing now may leave an incomplete write; original committed records are retained.") }
        if let shutdownStorageIssue { attention.append("A file could not be saved while preparing to close. \(shutdownStorageIssue)") }
        if unresolvedRecord {
            attention.append("A capture is still unresolved. Keep the Pico powered, reconnect and recover it into its original session. Unsaved Pico RAM cannot be recovered after power loss.")
        }
        if manualReleaseRequired && !shutdownManualReleaseConfirmed {
            attention.append("Manual outputs were not confirmed released. Their state is unknown; the firmware lease is not an independent safety interlock.")
        }
        return attention.isEmpty ? nil : attention.joined(separator: "\n\n")
    }

    func cancelShutdown() {
        shutdownInProgress = false; shutdownStorageIssue = nil
        // The connection stays stopped. Never resume a run or restore outputs.
    }

    private func drainPersistence(until deadline: UInt64) async -> Bool {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
        return await withCheckedContinuation { continuation in
            var returned = false
            let finish: (Bool) -> Void = { value in
                guard !returned else { return }
                returned = true; continuation.resume(returning: value)
            }
            ioQueue.async { DispatchQueue.main.async { finish(true) } }
            DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { finish(false) }
        }
    }

    func refreshPorts() { ports = SerialLink.ports(); if !ports.contains(selectedPort) { selectedPort = "" } }
    func checkDeviceStatus() { guard !shutdownInProgress, connected, !busy, !manualActive, !stageActive else { return }; busy = true; status = "Checking device status."; command("SB1 STATUS", expecting: .status) }
    func connect() {
        guard !shutdownInProgress, !busy, !connected else { return }
        invalidateCalibration(); profileConfigured = false
        do {
            try link.openPort(selectedPort); response = .hello; connected = false; busy = true; calibrated = false; gainConfirmed = false; manualSupported = false; stageSupported = false; burstSupported = false; observationsSupported = false; observationOnly = false; binarySupported = false; profileSupported = false; stageWiringConfirmed = false
            connectionStatus = "Checking device"; status = "Checking the connected firmware."
            try link.send("?"); startWatchdog(seconds: 5)
        } catch { disconnect(); fail(error.localizedDescription) }
    }
    private func preservePartial() {
        guard let a = assembler, !a.metadata.isEmpty, let store, let url = sessionURL,
              let intent = activeIntent, intent.token == a.token, intent.sessionID == currentSession?.id else { return }
        assembler = nil
        var metadata = a.metadata
        metadata["transfer_state"] = "incomplete"
        metadata["protocol"] = "SB1"
        addCaptureContext(intent, to: &metadata)
        let partial = CaptureRecord(id: a.token, capturedAt: intent.startedAt, metadata: metadata,
                                    events: a.events, samples: a.samples, complete: false)
        let writer = recordWriter, revision = sessionRevision
        ioQueue.async { [weak self] in
            do {
                guard try store.openSession(url).id == intent.sessionID else { throw StorageError.invalidSession }
                try writer(store, partial, url)
                let summaries = try store.listRecordSummaries(url)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionRevision == revision,
                          self.sessionURL == url, self.currentSession?.id == intent.sessionID else { return }
                    self.records = summaries
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.noteShutdownStorageIssue(error.localizedDescription)
                    guard self.sessionRevision == revision,
                          self.sessionURL == url, self.currentSession?.id == intent.sessionID else { return }
                    self.error = "Could not preserve the partial record. \(error.localizedDescription) Reconnect and retry the pending record to restore folder access."
                }
            }
        }
    }
    func disconnect() {
        let wasManual = manualActive || response == .manualEnter || response == .manualExit
        let wasStage = stageActive || response == .stageEnter || response == .stageExit
        manualPoll?.cancel(); manualPoll = nil
        if manualSupported && (manualActive || response == .manualEnter || response == .manualExit) {
            try? link.send("SB1 MANUAL EXIT\n")
        }
        finishManualCSV(.disconnected)
        manualActive = false; resetManualDisplay(); manualExitRequested = false; manualStopping = false; manualPinPending = false; pendingManualPin = nil; manualSupported = false
        stagePoll?.cancel(); stagePoll = nil
        if stageSupported && (stageActive || response == .stageEnter || response == .stageExit) { try? link.send("SB1 DIAG EXIT\n") }
        stageActive = false; stageStopping = false; stageExitRequested = false; stageSupported = false; stageWiringConfirmed = false
        connectionGeneration = UUID()
        invalidateCalibration()
        watchdog?.cancel(); link.closePort(); response = .idle; connected = false; busy = true; gainConfirmed = false
        preservePartial()
        busy = false
        connectionStatus = "Disconnected"; if activeToken != nil || pendingUnsaved { pendingUnsaved = true; status = "A record may still be pending on the Pico. Reconnect to check." }
        else if wasManual { status = "Output state is unknown. The device lease should expire after five seconds if firmware is running." }
        else if wasStage { status = "Stage diagnostics disconnected. Retained readings are stale. Reconnect and calibrate before measurement." }
    }
    private func lost(_ message: String) {
        let wasManual = manualActive || response == .manualEnter || response == .manualExit
        disconnect()
        let detail = wasManual ? " Output state is unknown. The device lease should expire after five seconds if firmware is running." : ""
        error = error.map { "\(message) \($0)\(detail)" } ?? (message + detail)
    }
    private func startWatchdog(seconds: UInt64 = 20) {
        watchdog?.cancel(); watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let wasHandshake = self.response == .hello || (!self.connected && self.response == .status)
            let wasManual = self.manualActive || self.response == .manualEnter || self.response == .manualExit
            let wasStage = self.stageActive || self.response == .stageEnter || self.response == .stageExit
            self.disconnect()
            if wasHandshake { self.connectionStatus = "Not identified"; self.error = "The device did not complete the Signal Bench handshake. Check the firmware and reconnect." }
            else if wasManual { self.error = "The Pico did not respond. Manual output state is unknown; the device lease should expire after five seconds if firmware is running." }
            else if wasStage { self.error = "Stage diagnostics timed out. Retained readings are stale. Reconnect and run a fresh quiet calibration before measurement." }
            else { self.error = "The device did not complete the request. Reconnect and check the pending record." }
        }
    }
    private func command(_ value: String, expecting next: Response, timeout: UInt64 = 20) {
        response = next
        do { try link.send(value + "\n"); startWatchdog(seconds: timeout) }
        catch {
            let wasManual = manualActive || next == .manualEnter || next == .manualExit
            disconnect()
            fail(error.localizedDescription + (wasManual ? " Output state is unknown; the device lease should expire after five seconds if firmware is running." : ""))
        }
    }
    private func fail(_ message: String) { watchdog?.cancel(); busy = false; interruptRun(); error = message; status = message }
    private func received(_ line: String) {
        guard line.hasPrefix("SB1 ") else { return }
        let p = line.split(separator: " "); guard p.count >= 2 else { return }
        switch p[1] {
        case "HELLO":
            guard response == .hello else { return }
            guard let f = try? StageWire.fields(line, prefix: "SB1 HELLO", limit: 256), f["version"] == "1", f["target"] == "pico_w", f["fixture"] == "0", let firmware = f["firmware"], !firmware.isEmpty,
                  f["manual"] == nil || f["manual"] == "1", f["stage_diag"] == nil || f["stage_diag"] == "1" else { disconnect(); fail("Unsupported firmware or board target."); return }
            manualSupported = f["manual"] == "1"
            stageSupported = f["stage_diag"] == "1"
            deviceBootID = f["boot_id"]
            guard ["burst", "binary", "profile", "cal_series", "observe"].allSatisfy({ f[$0] == nil || f[$0] == "1" }) else { disconnect(); fail("Unsupported firmware capabilities."); return }
            observationsSupported = f["observe"] == "1"
            observationOnly = observationsSupported
            burstSupported = f["burst"] == "1"
            calSeriesSupported = f["cal_series"] == "1"
            if burstSupported {
                guard let boot = deviceBootID, boot.count == 16, UInt64(boot, radix: 16) != nil,
                      f["profile"] == "1" else { disconnect(); fail("Firmware identity is incomplete."); return }
            }
            binarySupported = f["binary"] == "1"
            profileSupported = f["profile"] == "1"
            response = .status; deviceInfo = "Pico W · firmware \(firmware)"; status = "Checking device status."
        case "CALIBRATION":
            guard response == .calibrationBegin, p.count == 3, p[2] == "windows=3" else { disconnect(); fail("Invalid quiet calibration response."); return }
            watchdog?.cancel(); busy = false; response = .idle
            calibrationSeriesActive = true; calibrationWindowsRemaining = 3
            beginCapture(tag: "CAL", partOfRun: false)
        case "DIAG":
            guard response == .stageEnter || response == .stageExit else { return }
            let entering = response == .stageEnter
            guard let f = try? StageWire.fields(line, prefix: "SB1 DIAG", limit: 96), f.count == 2,
                  f["state"] == (entering ? "active" : "idle"), f["lease_ms"] == (entering ? "5000" : "0") else {
                disconnect(); fail("Invalid stage diagnostics response. Reconnect before measuring."); return
            }
            watchdog?.cancel(); response = .idle; busy = false; stageActive = entering; invalidateCalibration()
            if entering {
                status = "Stage diagnostics active. Quiet calibration is required before measurement."
                if stageExitRequested { exitStageDiagnostics() } else { readStageDiagnostics() }
            } else {
                stageStopping = false; stageExitRequested = false
                status = "Stage diagnostics stopped. Run a fresh quiet calibration."
                checkDeviceStatus()
            }
        case "STAGES":
            guard response == .stageRead, stageActive else { return }
            do {
                let value = try StageSnapshot.parse(line, expectedSequence: stageSequence, after: stageHistory.last)
                stageBuffer.append(value); stageHistory = stageBuffer.snapshots; stageLastReceivedAt = Date()
                watchdog?.cancel(); response = .idle
                if stageExitRequested { exitStageDiagnostics() } else { scheduleStageRead() }
            } catch { disconnect(); fail(error.localizedDescription + " Reconnect before measuring.") }
        case "MANUAL":
            guard response == .manualEnter || response == .manualExit else { return }
            let f = SBRecordAssembler.fields(p.dropFirst(2))
            let entering = response == .manualEnter
            guard p.count == 4, f.count == 2, f["state"] == (entering ? "active" : "idle"), f["lease_ms"] == (entering ? "5000" : "0") else { disconnect(); fail("Invalid manual mode response. Output state is unknown; the device lease should expire after five seconds if firmware is running."); return }
            watchdog?.cancel(); response = .idle; busy = false; manualActive = entering; resetManualDisplay(); manualPinPending = false; pendingManualPin = nil
            if shutdownInProgress && !entering { shutdownManualReleaseConfirmed = true }
            if entering {
                invalidateCalibration()
                status = "Manual mode active. Calibration is required before another capture."
                if manualExitRequested { exitManual() }
                else { startManualCSVTimer(); readManual() }
            }
            else {
                manualExitRequested = false; manualStopping = false
                finishManualCSV(manualCSVReachedDuration ? .durationReached : .stopped)
                status = "Manual mode closed. Check gain and calibrate before capturing."
                checkDeviceStatus()
            }
        case "LIVE":
            guard response == .manualRead || response == .manualPin, manualActive else { return }
            let f = SBRecordAssembler.fields(p.dropFirst(2))
            func mask(_ key: String) -> UInt32? {
                guard let s = f[key], s.utf8.count == 8, s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
                return UInt32(s, radix: 16)
            }
            guard p.count == 8, f.count == 6, let time = f["time_us"].flatMap(UInt64.init), let adcText = f["adc"], let err = f["adc_error"], let dirs = mask("dirs"), let levels = mask("levels"), let outputs = mask("outputs"), (dirs | outputs) & ~Self.manualMask == 0, levels & ~Self.legacyManualInputMask == 0, outputs & ~dirs == 0, (adcText == "-" && err == "1") || (err == "0" && Int(adcText).map { (0...4095).contains($0) } == true) else { disconnect(); fail("Invalid live data or a reserved pin configured as output. Output state is unknown; the device lease should expire after five seconds if firmware is running."); return }
            if let previous = manualBuffer.latest, time < previous.timeUS { disconnect(); fail("The device clock changed. Output state is unknown; the device lease should expire after five seconds if firmware is running."); return }
            let wasPin = response == .manualPin
            let sample = ManualSnapshot(timeUS: time, adc: Int(adcText), adcError: err == "1", directions: dirs, levels: levels, outputs: outputs)
            manualBuffer.append(sample)
            publishManualDisplay(force: wasPin)
            watchdog?.cancel(); response = .idle
            if busy { busy = false }
            if wasPin { manualPinPending = false }
            if !queueManualCSV(sample, fromPinChange: wasPin) { return }
            if manualExitRequested { exitManual() }
            else if pendingManualPin != nil { sendPendingManualPin() }
            else { scheduleManualRead() }
        case "STATUS":
            guard response == .status || response == .gain || response == .profile else { return }; watchdog?.cancel()
            let f = SBRecordAssembler.fields(p.dropFirst(2))
            guard f.count == p.count - 2, (!profileSupported || ["POSITIVE", "NEGATIVE"].contains(f["profile"] ?? "")), let deviceGain = f["gain"], ["LOW", "HIGH"].contains(deviceGain), let cal = f["calibrated"], ["0", "1"].contains(cal), let confirmation = f["gain_confirmed"], ["0", "1"].contains(confirmation), let pending = f["pending"], pending == "-" || (pending.utf8.count == 32 && pending.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })), let calibrationID = f["calibration_id"].flatMap(UInt64.init) else {
                pendingUnsaved = true; fail("The device returned an invalid status. Reconnect before capturing."); disconnect(); return
            }
            connected = true; connectionStatus = "Connected"; response = .idle
            gain = deviceGain
            processingProfile = f["profile"] ?? "POSITIVE"
            gainConfirmed = confirmation == "1"
            if let calibration = sessionCalibration, gainConfirmed, cal == "1",
               calibration.deviceID == calibrationID, calibration.gain == gain, calibration.profile == processingProfile,
               calibration.sessionID == currentSession?.id,
               records.contains(where: { $0.id == calibration.recordID && $0.complete }) {
                calibrated = true
            } else if !calibrationSeriesActive {
                invalidateCalibration(interruptRecording: measurementRun?.observationOnly != true)
            }
            if let pending = f["pending"], pending != "-" {
                interruptRun()
                devicePending = pending; pendingUnsaved = true
                busy = false; status = "The Pico is holding a record. Open its original session to recover it."
            } else {
                if activeToken != nil && waitingAck == nil { error = "The Pico no longer holds the pending record. It may have reset or lost power." }
                devicePending = nil; activeToken = nil; activeIntent = nil; waitingAck = nil; pendingUnsaved = false; captureSaveIssue = nil; busy = false
                status = observationOnly && observationsSupported ? "Ready to record raw observations." : !gainConfirmed ? "Confirm the physical gain before recording." : calibrated ? "Ready to capture." : "Quiet calibration required."
                if runCaptureToken != nil {
                    // A status with no retained record cannot replace an ACK.
                    runCaptureToken = nil
                    interruptRun()
                }
                if profileSupported && !profileConfigured {
                    profileConfigured = true; selectProcessingProfile("NEGATIVE"); return
                }
                if calibrationSeriesActive && calibrationWindowsRemaining > 0 {
                    beginCapture(tag: "CAL", partOfRun: false)
                } else { advanceRun() }
            }
        case "READY":
            guard response == .capture else { return }
            guard p.count == 3, String(p[2]) == activeToken else { disconnect(); fail("Unexpected record identity. Reconnect to check the pending record."); return }
            pendingUnsaved = true; assembler = SBRecordAssembler(token: String(p[2])); status = "Receiving record."; command("SB1 \(binarySupported ? "GETB" : "GET") \(p[2])", expecting: .transfer)
        case "BEGIN", "EVENT", "DATA", "META", "END":
            guard response == .transfer else { return }
            guard var record = assembler else { fail("Unexpected record data."); return }
            do {
                let result = try record.accept(line); assembler = record; startWatchdog()
                if result.complete, let crc = result.crc { watchdog?.cancel(); finish(record, crc: crc) }
            } catch { pendingUnsaved = true; disconnect(); fail(error.localizedDescription) }
        case "ACKED":
            guard response == .acknowledgement else { return }
            guard p.count == 3, String(p[2]) == waitingAck, let token = waitingAck else {
                disconnect()
                fail("Unexpected save acknowledgement. Reconnect to check the saved record.")
                return
            }
            watchdog?.cancel()
            if calibrationAttemptToken == token, let session = currentSession,
               let record = lastCommittedRecord, record.id == token,
               record.metadata["tag"] == "CAL", record.metadata["calibrated"] == "1",
               !record.samples.isEmpty, record.metadata["acq_flags"] == "0",
               record.metadata["quality_flags"] == "0", record.metadata["candidates"] == "0",
               let id = record.metadata["calibration_id"].flatMap(UInt64.init),
               let recordedGain = record.metadata["gain"] {
                sessionCalibration = .init(sessionID: session.id, recordID: token, deviceID: id, gain: recordedGain, profile: record.metadata["profile"] ?? "POSITIVE")
            }
            if calibrationAttemptToken == token, calibrationSeriesActive, let record = lastCommittedRecord {
                calibrationWindowAccepted = record.metadata["cal_window_accepted"] == "1"
                calibrationWindowsRemaining = Int(record.metadata["calibration_remaining"] ?? "") ?? 0
                if !calibrationWindowAccepted { calibrationSeriesActive = false; calibrationProgress = "Quiet calibration rejected. Inspect the saved attempt." }
                else if calibrationWindowsRemaining > 0 { calibrationProgress = "Quiet windows saved: \(3 - calibrationWindowsRemaining) of 3" }
                else { calibrationSeriesActive = false; calibrationProgress = "Three quiet windows saved and accepted." }
            }
            calibrationAttemptToken = nil
            if let record = lastCommittedRecord, record.id == token, record.metadata["tag"] == "STAGE" { invalidateCalibration() }
            if runCaptureToken != token, let store, let url = sessionURL {
                // Failure to remove a receipt leaves recoverable evidence on disk.
                try? store.clearCaptureIntent(token, in: url)
            }
            activeToken = nil; waitingAck = nil; pendingUnsaved = false; busy = true; status = "Record saved."
            if runCaptureToken == token { countRunRecord(acknowledgedToken: token) }
            else { command("SB1 STATUS", expecting: .status) }
        case "ERROR":
            guard response != .idle && response != .hello else { return }
            if stageActive || response == .stageEnter || response == .stageExit {
                let message = p.dropFirst(2).joined(separator: " ")
                disconnect(); fail("Stage diagnostics error: \(message). Reconnect and check the device before measuring."); return
            }
            if manualActive || response == .manualEnter || response == .manualExit {
                let message = p.dropFirst(2).joined(separator: " ")
                disconnect()
                switch message {
                case "MANUAL_ADC_RELEASED":
                    fail("The Pico reported an ADC fault and released Manual outputs. Reconnect and check the input before starting again.")
                case "MANUAL_TIMER_UNAVAILABLE":
                    fail("The Pico could not arm its Manual output timer. Reconnect before using Manual mode.")
                default:
                    fail("Manual mode error: \(message). Output state is unknown; the device lease should expire after five seconds if firmware is running.")
                }
                return
            }
            preservePartial(); pendingUnsaved = activeToken != nil || pendingUnsaved; fail("Device error: \(p.dropFirst(2).joined(separator: " ")). Check device status before retrying.")
            if connected { busy = true; command("SB1 STATUS", expecting: .status) } else { disconnect() }
        default: break
        }
    }
    private func addCaptureContext(_ intent: CaptureIntent, to metadata: inout [String: String]) {
        metadata["host_profile_purpose"] = intent.profileStamp?.purpose.rawValue
        metadata["host_profile_owner"] = intent.profileStamp?.owner.uuidString
        metadata["host_profile_segment"] = intent.profileStamp?.segment.uuidString
        metadata["host_profile_elapsed"] = intent.profileStamp.map { String($0.elapsedSeconds) }
        metadata["host_processing_profile"] = intent.processingProfile
        metadata["host_workspace"] = intent.workspace
        metadata["host_run_id"] = intent.runID
        metadata["probe_source"] = intent.probeSource
        metadata["host_gain_confirmed"] = intent.gainConfirmed.map { $0 ? "1" : "0" }
        metadata["host_observation_only"] = intent.observationOnly == true ? "1" : "0"
        // Take the Main rules from the durable intent, including on retry.
        for key in MainObservationOptions().metadata.keys { metadata.removeValue(forKey: key) }
        if let options = intent.mainObservationOptions {
            metadata.merge(options.metadata) { _, saved in saved }
        }
        for key in Array(metadata.keys) where key.hasPrefix("session_") || key == "calibration_record_id" || key == "recovered_into_session_id" {
            metadata.removeValue(forKey: key)
        }
        metadata["device"] = intent.device
        metadata["capture_provenance"] = intent.linked ? "session" : "unlinked"
        if intent.linked {
            metadata["calibration_record_id"] = intent.calibrationRecordID
            for (key, value) in intent.sessionDetails { metadata["session_\(key)"] = value }
            metadata["session_id"] = intent.sessionID.uuidString
        } else {
            metadata["recovered_into_session_id"] = intent.sessionID.uuidString
        }
    }

    private func finish(_ incoming: SBRecordAssembler, crc: UInt32) {
        guard let url = sessionURL, let store, let intent = activeIntent,
              intent.token == incoming.token, intent.sessionID == currentSession?.id else {
            pendingUnsaved = true; fail("Open the original session to recover this record."); return
        }
        let generation = connectionGeneration
        assembler = nil
        var metadata = incoming.metadata
        metadata["crc32"] = String(format: "%08x", crc)
        metadata["protocol"] = binarySupported ? "SB1 binary1" : "SB1"
        addCaptureContext(intent, to: &metadata)
        let record = CaptureRecord(id: incoming.token, capturedAt: intent.startedAt, metadata: metadata,
                                   events: incoming.events, samples: incoming.samples, complete: true)
        do {
            if burstSupported {
                guard incoming.metadata["boot_id"] == deviceBootID,
                      incoming.metadata["profile"] == intent.processingProfile,
                      incoming.metadata["algorithm"] == "2",
                      incoming.metadata["channel"] == "ADC\(intent.channel ?? 0)" else {
                    throw SBProtocolError.invalid("Waveform identity or processing metadata is missing.")
                }
            }
            if let boot = deviceBootID, let recordBoot = incoming.metadata["boot_id"], boot != recordBoot {
                throw SBProtocolError.invalid("The Pico restarted during the transfer.")
            }
            if intent.tag == "CAL", calibrationSeriesActive {
                let accepted = incoming.metadata["cal_window_accepted"] == "1"
                let remaining = incoming.metadata["calibration_remaining"].flatMap(Int.init)
                guard let remaining, (0...2).contains(remaining),
                      accepted ? (incoming.metadata["calibration_windows"] == "3" && remaining == calibrationWindowsRemaining - 1 && incoming.metadata["calibrated"] == (remaining == 0 ? "1" : "0")) : (remaining == 0 && incoming.metadata["calibrated"] == "0") else {
                    throw SBProtocolError.invalid("The quiet calibration window sequence is invalid.")
                }
            }
            if intent.linked {
                guard incoming.metadata["tag"] == intent.tag, incoming.metadata["gain"] == intent.gain else {
                    throw SBProtocolError.invalid("The Pico record does not match the saved capture settings.")
                }
                if intent.observationOnly == true {
                    guard incoming.metadata["observation_only"] == "1",
                          incoming.metadata["gain_confirmed"] == intent.gainConfirmed.map({ $0 ? "1" : "0" }), incoming.metadata["calibrated"] == "0",
                          incoming.metadata["calibration_id"] == "0", incoming.metadata["usable"] == "0",
                          incoming.metadata["threshold_origin"] == "record_noise",
                          incoming.events.allSatisfy({ $0["qualified"] == "0" }) else {
                        throw SBProtocolError.invalid("Raw observations were incorrectly marked qualified.")
                    }
                } else if incoming.metadata["observation_only"] == "1" {
                    throw SBProtocolError.invalid("The capture recording policy changed.")
                } else if intent.tag != "CAL" && !(intent.tag == "STAGE" && intent.calibrationID == nil) {
                    guard incoming.metadata["calibrated"] == "1",
                          incoming.metadata["calibration_id"].flatMap(UInt64.init) == intent.calibrationID else {
                        throw SBProtocolError.invalid("The capture calibration changed.")
                    }
                }
                if let profile = intent.processingProfile, let reported = incoming.metadata["profile"], reported != profile {
                    throw SBProtocolError.invalid("Processing profile changed during capture.")
                }
                if let channel = intent.channel, let reported = incoming.metadata["channel"],
                   reported != String(channel) && reported != "ADC\(channel)" {
                    throw SBProtocolError.invalid("ADC channel changed during capture.")
                }
            }
            try withSessionAccess { guard try store.openSession(url).id == intent.sessionID else { throw StorageError.invalidSession } }
        } catch {
            if error is SBProtocolError { invalidateCalibration() }
            if let storageError = error as? StorageError, case .invalidSession = storageError { invalidateCalibration() }
            savingFailed(error, incoming: incoming); return
        }
        status = "Saving and verifying record."; response = .saving
        let writer = recordWriter
        ioQueue.async { [weak self] in
            do {
                guard try store.openSession(url).id == intent.sessionID else { throw StorageError.invalidSession }
                var committed = record
                if !intent.linked, let existing = try? store.loadRecord(record.id, in: url) {
                    guard existing.samples == incoming.samples, existing.events == incoming.events,
                          existing.metadata["crc32"] == metadata["crc32"],
                          incoming.metadata.allSatisfy({ existing.metadata[$0.key] == $0.value }) else {
                        throw StorageError.duplicateRecord
                    }
                    committed = existing
                }
                try writer(store, committed, url)
                let saved = try store.loadRecord(committed.id, in: url)
                guard try store.openSession(url).id == intent.sessionID else { throw StorageError.invalidSession }
                guard saved.metadata == committed.metadata, saved.samples == committed.samples,
                      saved.events == committed.events, saved.complete else { throw StorageError.corruptRecord(committed.id) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectionGeneration == generation, self.activeToken == intent.token,
                          self.sessionURL == url else { return }
                    var summary = saved
                    summary.metadata["host_sample_count"] = String(saved.samples.count)
                    summary.metadata["host_samples_loaded"] = "0"
                    summary.samples = []
                    self.records.removeAll { $0.id == saved.id && $0.complete }
                    self.records.append(summary)
                    self.selectionRevision = UUID()
                    self.lastCommittedRecord = saved
                    if intent.profileStamp?.purpose != .calibrationPhase {
                        self.selectedRecord = saved
                        self.savedAnalyses = []
                    }
                    self.waitingAck = saved.id
                    self.status = "Saved. Confirming receipt with Pico."
                    self.command("SB1 ACK \(saved.id) \(String(format: "%08x", crc))", expecting: .acknowledgement)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.noteShutdownStorageIssue(error.localizedDescription)
                    guard self.connectionGeneration == generation else { return }
                    self.savingFailed(error, incoming: incoming)
                }
            }
        }
    }

    private func savingFailed(_ error: Error, incoming: SBRecordAssembler) {
        assembler = incoming; pendingUnsaved = true
        noteShutdownStorageIssue(error.localizedDescription)
        captureSaveIssue = error.localizedDescription; watchdog?.cancel()
        response = .idle; busy = false; interruptRun()
        if Self.permissionError(error) { try? reauthorizeSession() }
        status = "Could not finish saving. The Pico is retaining the record."
    }

    func setObservationOnly(_ enabled: Bool) {
        guard !shutdownInProgress, !busy, !pendingUnsaved, !sequenceRunning, !manualActive, !stageActive else { return }
        // Workspace selection is available offline. Acquisition still checks capability.
        guard observationOnly != enabled else { return }
        observationOnly = enabled
        if enabled { invalidateCalibration() } else { interruptRun() }
        status = enabled ? "Ready to record raw observations. Quiet calibration is optional for this recording policy." : "Quiet calibration is required for qualified pulses."
    }

    func calibrateForQualification() {
        if observationOnly { setObservationOnly(false) }
        calibrate()
    }

    func calibrate() {
        guard !shutdownInProgress, !busy, !pendingUnsaved, !manualActive, !stageActive, connected, gainConfirmed, currentSession != nil else { return }
        if calSeriesSupported {
            invalidateCalibration(); busy = true; calibrationProgress = "Preparing three quiet windows."
            command("SB1 CALBEGIN 3", expecting: .calibrationBegin)
        } else { capture(tag: "CAL") }
    }
    func selectProcessingProfile(_ profile: String) {
        guard !shutdownInProgress, profileSupported, !busy, !pendingUnsaved, !manualActive, !stageActive,
              !sequenceRunning, ["NEGATIVE", "POSITIVE"].contains(profile) else { return }
        profileConfigured = true; invalidateCalibration(); busy = true
        command("SB1 PROFILE \(profile)", expecting: .profile)
    }

    func capture(tag: String, mainOptions: MainObservationOptions? = nil) {
        guard !sequenceRunning else { return }
        beginCapture(tag: tag, partOfRun: false, mainOptions: mainOptions)
    }

    private func validateMainOptions(_ options: MainObservationOptions?, observing: Bool) -> Bool {
        guard let options else { return true }
        guard observing, observationsSupported else {
            error = "Pulse criteria and detector setup can only be saved with a Main observation."
            return false
        }
        guard options.isValid else {
            error = "Check the pulse criteria before recording."
            return false
        }
        return true
    }

    private func beginCapture(tag: String, partOfRun: Bool, mainOptions: MainObservationOptions? = nil) {
        let observing = ["BACKGROUND", "SOURCE"].contains(tag) && (partOfRun ? measurementRun?.observationOnly == true : observationOnly)
        let options = partOfRun ? measurementRun?.mainObservationOptions : mainOptions
        guard validateMainOptions(options, observing: observing) else {
            if partOfRun { interruptRun() }
            return
        }
        guard !shutdownInProgress, connected, (gainConfirmed || observing && observationsSupported), !busy, !pendingUnsaved, !manualActive, !stageActive,
              let session = currentSession, let url = sessionURL, let store else {
            error = "Stop diagnostics, connect the Pico, confirm the physical gain, and open a session before capturing."
            if partOfRun { interruptRun() }
            return
        }
        guard !observing || observationsSupported else { error = "Update the Pico firmware for raw observations."; return }
        let calibration = (observing || tag == "CAL" || (tag == "STAGE" && (burstRequest?.channel ?? 0) > 0)) ? nil : sessionCalibration
        guard observing || tag == "CAL" || (tag == "STAGE" && burstRequest != nil) || (["BACKGROUND", "SOURCE", "MANUAL", "STAGE"].contains(tag) && calibrated &&
              calibration?.sessionID == session.id && calibration?.gain == gain && activeCalibrationRecord != nil) else {
            error = "Run a successful quiet calibration in this session first."
            if partOfRun { interruptRun() }
            return
        }
        let burst = (tag == "MANUAL" || tag == "STAGE") ? burstRequest : nil
        let token = CaptureIntent.makeToken(sessionID: session.id)
        let stamp: ProfileCaptureStamp?
        if partOfRun, let run = measurementRun, let acquisition = run.profileAcquisition, let segment = run.profileSegments.last {
            stamp = .init(purpose: acquisition.purpose, owner: acquisition.owner, segment: segment.id,
                          elapsedSeconds: acquisition.offsetSeconds + run.elapsedSeconds)
        } else { stamp = nil }
        let intent = CaptureIntent(token: token, sessionID: session.id, tag: tag, gain: gain,
                                   calibrationRecordID: calibration?.recordID, calibrationID: calibration?.deviceID,
                                   sessionDetails: session.details, device: deviceInfo, startedAt: Date(),
                                   processingProfile: processingProfile, channel: burst?.channel ?? 0,
                                   workspace: (partOfRun ? measurementRun?.workspace : burst?.workspace) == "Manual" ? "manual" : (burst?.workspace == "Stage Diagnostics" ? "stage" : "measurements"),
                                   runID: partOfRun ? measurementRun?.id.uuidString : nil, probeSource: burst?.source == "Final ADC" ? "ADC0" : burst?.source ?? "ADC0", observationOnly: observing ? true : nil, gainConfirmed: gainConfirmed,
                                   mainObservationOptions: options, profileStamp: stamp)
        let generation = connectionGeneration
        busy = true
        status = "Preparing capture."
        do {
            try withSessionAccess {
                guard connectionGeneration == generation, sessionURL == url, currentSession?.id == session.id else {
                    throw SBProtocolError.invalid("The connection or session changed before capture.")
                }
                try store.saveCaptureIntent(intent, in: url)
            }
        } catch {
            guard connectionGeneration == generation else { return }
            fail("Could not prepare capture in this session. \(error.localizedDescription)")
            return
        }
        guard connectionGeneration == generation, connected else { return }
        if partOfRun, measurementRun?.phase != .running {
            // Pause may arrive while the session access panel is open.
            try? store.clearCaptureIntent(token, in: url)
            busy = false
            advanceRun()
            return
        }
        if partOfRun { runCaptureToken = token }
        if tag == "CAL" {
            let series = calibrationSeriesActive
            let remaining = calibrationWindowsRemaining
            invalidateCalibration()
            calibrationSeriesActive = series; calibrationWindowsRemaining = remaining
            calibrationAttemptToken = token
        }
        activeToken = token
        activeIntent = intent
        pendingUnsaved = true
        captureSaveIssue = nil
        status = "Capturing \(tag.lowercased()) record."
        if tag == "MANUAL" || tag == "STAGE" {
            command("SB1 BURST \(tag) ADC\(intent.channel ?? 0) \(token)", expecting: .capture)
        } else { command("SB1 \(observing ? "OBSERVE" : "CAPTURE") \(tag) \(token)", expecting: .capture) }
    }
    private func readyForAcquisition(observing: Bool) -> Bool {
        !shutdownInProgress && connected && (observing ? observationsSupported : (gainConfirmed && activeCalibrationRecord != nil))
            && !busy && !pendingUnsaved && !manualActive && !stageActive && !manualCSVBusy
            && currentSession != nil && sessionURL != nil && store != nil
    }

    @discardableResult
    func startProfileAcquisition(_ acquisition: ProfileAcquisition, seconds: Double, measurement: Bool = false) -> Bool {
        guard profileCanCapture, acquisition.valid, acquisition.setup.gain == gain,
              acquisition.boot == profileBoot, (1...7200).contains(seconds),
              acquisition.purpose != .profileRun || acquisition.snapshot.map(hasProfileSetup) == true else { return false }
        if acquisition.purpose != .profileRun { forgetProfileSetup() }
        let previous = measurementRun?.id
        startRecording(tag: measurement ? "SOURCE" : "BACKGROUND", count: Int.max, seconds: seconds,
                       workspace: "Measurements", mainOptions: nil, profileAcquisition: acquisition)
        return measurementRun?.id != previous
    }

    var canResumeRun: Bool {
        guard let run = measurementRun, run.phase == .paused || run.phase == .interrupted else { return false }
        if let acquisition = run.profileAcquisition {
            guard acquisition.purpose == .profileRun, let profile = acquisition.snapshot, hasProfileSetup(profile),
                  profileCanCapture, run.durationSeconds.map({ run.elapsedSeconds < $0 }) == true else { return false }
            return run.sessionID == currentSession?.id && run.physicalGain == gain && run.profile == processingProfile
        }
        return readyForAcquisition(observing: run.observationOnly) && run.sessionID == currentSession?.id && run.completed < run.target &&
            run.profile == processingProfile && run.physicalGain == gain &&
            (run.workspace == "Manual" || run.observationOnly == observationOnly) &&
            (run.gainConfirmed == nil || run.gainConfirmed == gainConfirmed) &&
            (run.observationOnly ? observationsSupported : activeCalibrationRecord != nil) &&
            (run.durationSeconds == nil || run.elapsedSeconds < run.durationSeconds!)
    }

    func startRun(tag: String, count: Int, mainOptions: MainObservationOptions? = nil) {
        guard ["BACKGROUND", "SOURCE", "MANUAL"].contains(tag), (1...MeasurementRun.maximumCaptures).contains(count) else {
            error = "Choose a capture count from 1 to \(MeasurementRun.maximumCaptures)."; return
        }
        startRecording(tag: tag, count: count, seconds: nil, workspace: tag == "MANUAL" ? "Manual" : "Measurements", mainOptions: mainOptions)
    }

    func startTimedRun(tag: String, seconds: Double, workspace: String = "Measurements", mainOptions: MainObservationOptions? = nil) {
        guard ["BACKGROUND", "SOURCE", "MANUAL"].contains(tag), seconds.isFinite, (1...7200).contains(seconds) else {
            error = "Choose a duration from 1 second to 2 hours."; return
        }
        startRecording(tag: tag, count: Int.max, seconds: seconds, workspace: workspace, mainOptions: mainOptions)
    }

    private func startRecording(tag: String, count: Int, seconds: Double?, workspace: String,
                                mainOptions: MainObservationOptions?, profileAcquisition: ProfileAcquisition? = nil) {
        let observing = tag != "MANUAL" && (profileAcquisition != nil || observationOnly && observationsSupported)
        guard !sequenceRunning, validateMainOptions(mainOptions, observing: observing && workspace == "Measurements"),
              readyForAcquisition(observing: observing), let session = currentSession,
              observing || activeCalibrationRecord != nil else { return }
        let calibration = observing ? nil : activeCalibrationRecord
        runCaptureToken = nil; countedRunTokens = []; runRecoveryNote = ""
        var run = MeasurementRun(target: count, tag: tag, sessionID: session.id,
                                 sessionName: session.name, calibrationRecordID: calibration?.id ?? "")
        run.observationOnly = observing; run.profile = processingProfile; run.physicalGain = gain; run.gainConfirmed = gainConfirmed
        run.mainObservationOptions = mainOptions
        run.profileAcquisition = profileAcquisition
        if let acquisition = profileAcquisition {
            run.profileSegments = [.init(id: acquisition.segment, boot: acquisition.boot, elapsedAtStart: 0, unmeasuredGapBefore: false)]
            profileLiveCoverage = ProfileCoverage()
            profileBlockCoverage = [:]
        }
        run.durationSeconds = seconds; run.workspace = workspace
        run.clock = runClock; run.startedNS = runClock()
        measurementRun = run
        recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Saving a Signal Bench measurement run")
        busy = true
        persistRun { [weak self] in self?.busy = false; self?.advanceRun() }
    }

    func stopMainRun() {
        guard measurementRun?.observationOnly == true, measurementRun?.phase == .running else { return }
        measurementRun?.finishAfterCapture = true
        pauseRun()
    }

    func pauseRun() {
        guard measurementRun?.phase == .running else { return }
        measurementRun?.phase = .pausing
        if !busy { advanceRun() }
    }

    func resumeRun() {
        guard canResumeRun, let run = measurementRun else { return }
        if run.profileAcquisition == nil { observationOnly = run.observationOnly }
        if run.profileAcquisition != nil, let boot = profileBoot {
            measurementRun?.profileSegments.append(.init(id: UUID(), boot: boot, elapsedAtStart: run.accumulatedSeconds, unmeasuredGapBefore: true))
            profileBlockCoverage = [:]
            profileLiveCoverage.uncertainInterruption = true
        }
        if run.gainConfirmed == nil { measurementRun?.gainConfirmed = gainConfirmed }
        measurementRun?.calibrationRecordID = run.observationOnly ? "" : activeCalibrationRecord?.id ?? ""
        measurementRun?.phase = .running
        measurementRun?.clock = runClock
        measurementRun?.startedNS = runClock()
        recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Saving a Signal Bench measurement run")
        busy = true
        persistRun { [weak self] in self?.busy = false; self?.advanceRun() }
    }

    private func endRecordingActivity() {
        if let activity = recordingActivity { ProcessInfo.processInfo.endActivity(activity); recordingActivity = nil }
    }

    private func advanceRun() {
        guard let run = measurementRun else { return }
        if run.phase == .pausing {
            measurementRun?.stopClock()
            measurementRun?.phase = run.finishAfterCapture ? .completed : .paused
            endRecordingActivity(); persistRun(); return
        }
        guard run.phase == .running else { endRecordingActivity(); return }
        if let duration = run.durationSeconds, run.elapsedSeconds >= duration {
            measurementRun?.stopClock(); measurementRun?.phase = .completed
            endRecordingActivity(); persistRun(); return
        }
        guard readyForAcquisition(observing: run.observationOnly), run.sessionID == currentSession?.id, run.profile == processingProfile, run.physicalGain == gain,
              run.gainConfirmed == nil || run.gainConfirmed == gainConfirmed,
              run.observationOnly ? observationsSupported : run.calibrationRecordID == activeCalibrationRecord?.id else { interruptRun(); return }
        if run.tag == "MANUAL" { burstRequest = ("Manual", 0, "Final ADC") }
        beginCapture(tag: run.tag, partOfRun: true)
    }

    private func interruptRun() {
        guard let run = measurementRun, run.inProgress || run.phase == .paused else { return }
        measurementRun?.stopClock(); measurementRun?.phase = .interrupted
        endRecordingActivity(); persistRun()
    }

    private func countRunRecord(acknowledgedToken token: String) {
        guard runCaptureToken == token else { return }
        runCaptureToken = nil
        guard !countedRunTokens.contains(token) else { command("SB1 STATUS", expecting: .status); return }
        guard let run = measurementRun, run.completed < run.target,
              let record = lastCommittedRecord, record.id == token,
              record.metadata["tag"] == run.tag,
              record.metadata["session_id"] == run.sessionID.uuidString,
              (run.observationOnly ? record.metadata["observation_only"] == "1" : record.metadata["calibration_record_id"] == run.calibrationRecordID),
              let store, let url = sessionURL else { interruptRun(); return }
        // The acknowledgement marker is durable before the next capture begins.
        let generation = connectionGeneration
        busy = true
        ioQueue.async { [weak self] in
            do {
                _ = try store.acknowledgeRecord(record, runID: run.id, in: url)
                try store.clearCaptureIntent(token, in: url)
                var calculated: ProfileWindowResult?
                var analysisIssue: String?
                if let acquisition = run.profileAcquisition {
                    do {
                        let offset = record.metadata["host_profile_elapsed"].flatMap(Double.init) ?? 0
                        let profile = acquisition.snapshot
                        let result = try ProfileAnalyzer.evaluate(record, rules: profile?.rules ?? ProfilePulseRules(),
                                                                  limits: profile?.limits, envelope: acquisition.purpose == .fixture ? nil : profile?.envelope,
                                                                  elapsed: offset)
                        if acquisition.purpose == .profileRun {
                            try store.saveProfileWindow(result, for: run.id, revisionID: run.id, in: url)
                        }
                        calculated = result
                    } catch { analysisIssue = error.localizedDescription }
                }
                let result = calculated, issue = analysisIssue
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionURL == url, self.currentSession?.id == run.sessionID,
                          var run = self.measurementRun, run.id == record.metadata["host_run_id"].flatMap(UUID.init(uuidString:)) else { return }
                    run.count(record)
                    if let result {
                        self.profileLiveCoverage.add(result)
                        self.profileLiveCoverage.elapsed = run.elapsedSeconds
                        self.profileLiveCoverage.unknown = max(0, run.elapsedSeconds - self.profileLiveCoverage.sampled)
                        if run.profileAcquisition?.purpose == .profileRun {
                            let minute = Int(result.elapsed / 60)
                            self.profileBlockCoverage[minute, default: ProfileCoverage()].add(result)
                            if minute >= 2 && [minute - 1, minute - 2].allSatisfy({ key in
                                guard let block = self.profileBlockCoverage[key], block.windows > 0 else { return false }
                                return block.outside * 2 > block.windows
                            }) && run.phase == .running {
                                run.phase = .pausing
                                run.profilePauseReason = "Noise exceeded the profile in two successive minutes. Check the setup."
                                self.forgetProfileSetup()
                            }
                        }
                    }
                    if let issue {
                        self.error = "The raw window was saved. Analysis could not be saved: \(issue)"
                        run.profilePauseReason = "The raw window was saved. Analysis needs attention."
                        self.forgetProfileSetup()
                        if run.phase == .running { run.phase = .pausing }
                    }
                    self.countedRunTokens.insert(record.id)
                    self.measurementRun = run
                    self.persistRun { [weak self] in
                        guard let self, self.connectionGeneration == generation, self.connected else { return }
                        self.command("SB1 STATUS", expecting: .status)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.noteShutdownStorageIssue(error.localizedDescription)
                    guard self.connectionGeneration == generation, self.sessionURL == url, self.measurementRun?.id == run.id else { return }
                    self.busy = false; self.interruptRun()
                    self.error = "Capture saved, but run progress could not be committed. \(error.localizedDescription)"
                }
            }
        }
    }

    private func archive(_ run: MeasurementRun) -> RunArchive {
        var result = RunArchive(sessionID: run.sessionID, tag: run.tag)
        result.observationOnly = run.observationOnly ? true : nil
        result.observationWindows = run.observationWindows
        result.mainObservationOptions = run.mainObservationOptions
        result.profileAcquisition = run.profileAcquisition
        result.profileSegments = run.profileAcquisition == nil ? nil : run.profileSegments
        result.profilePauseReason = run.profilePauseReason
        result.processingProfile = run.profile; result.physicalGain = run.physicalGain; result.gainConfirmed = run.gainConfirmed
        result.id = run.id; result.workspace = run.workspace == "Manual" ? "manual" : "measurements"
        result.targetCount = run.durationSeconds == nil ? run.target : nil
        result.durationSeconds = run.durationSeconds; result.elapsedActiveSeconds = run.elapsedSeconds
        result.phase = String(describing: run.phase); result.startedAt = run.startedAt
        result.calibrationRecordIDs = records.filter { $0.metadata["host_run_id"] == run.id.uuidString }
            .compactMap { $0.metadata["calibration_record_id"] }.reduce(into: run.calibrationRecordID.isEmpty ? [] : [run.calibrationRecordID]) { if !$0.contains($1) { $0.append($1) } }
        result.completed = run.completed; result.candidates = run.candidates
        result.qualifiedPulses = run.qualifiedPulses; result.rejectedWindows = run.rejectedWindows
        result.sampledSeconds = run.sampledSeconds; result.gapSeconds = max(0, run.elapsedSeconds - run.sampledSeconds)
        return result
    }

    private func persistRun(completion: (() -> Void)? = nil) {
        guard let run = measurementRun, let store, let url = sessionURL, run.sessionID == currentSession?.id else { return }
        let snapshot = archive(run)
        ioQueue.async { [weak self] in
            do {
                try store.saveRun(snapshot, in: url)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionURL == url, self.currentSession?.id == snapshot.sessionID, self.measurementRun?.id == snapshot.id else { return }
                    self.savedRuns.removeAll { $0.id == snapshot.id }; self.savedRuns.append(snapshot)
                    completion?()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.noteShutdownStorageIssue(error.localizedDescription)
                    guard self.sessionURL == url, self.measurementRun?.id == snapshot.id, self.currentSession?.id == snapshot.sessionID else { return }
                    self.measurementRun?.stopClock(); self.measurementRun?.phase = .interrupted
                    self.endRecordingActivity(); self.busy = false
                    self.error = "Run progress could not be saved. \(error.localizedDescription)"
                }
            }
        }
    }

    func restoreRun(_ saved: RunArchive) {
        guard !shutdownInProgress, !busy, !sequenceRunning, saved.sessionID == currentSession?.id, let session = currentSession else { return }
        runRecoveryNote = ["running", "pausing"].contains(saved.phase) ? "Elapsed time is through the last saved checkpoint. The interval before interruption is unknown. Continue explicitly after checking the device and calibration." : ""
        var run = MeasurementRun(target: saved.targetCount ?? Int.max, tag: saved.tag,
                                 sessionID: session.id, sessionName: session.name,
                                 calibrationRecordID: saved.calibrationRecordIDs.last ?? "")
        run.clock = runClock
        run.observationOnly = saved.observationOnly ?? false; run.observationWindows = saved.observationWindows ?? 0
        run.mainObservationOptions = saved.mainObservationOptions
        run.profileAcquisition = saved.profileAcquisition
        run.profileSegments = saved.profileSegments ?? []
        run.profilePauseReason = saved.profilePauseReason
        profileLiveCoverage = ProfileCoverage(elapsed: saved.elapsedActiveSeconds, sampled: saved.sampledSeconds,
                                              unknown: max(0, saved.elapsedActiveSeconds - saved.sampledSeconds),
                                              uncertainInterruption: saved.phase != "completed", windows: saved.completed)
        profileBlockCoverage = [:]
        run.profile = saved.processingProfile ?? processingProfile; run.physicalGain = saved.physicalGain ?? gain; run.gainConfirmed = saved.gainConfirmed
        run.id = saved.id; run.durationSeconds = saved.durationSeconds
        run.accumulatedSeconds = saved.elapsedActiveSeconds; run.startedNS = 0
        run.workspace = saved.workspace == "manual" ? "Manual" : "Measurements"; run.startedAt = saved.startedAt
        run.completed = saved.completed; run.candidates = saved.candidates
        run.qualifiedPulses = saved.qualifiedPulses; run.rejectedWindows = saved.rejectedWindows
        run.sampledSeconds = saved.sampledSeconds; run.gapSeconds = saved.gapSeconds
        run.phase = saved.phase == "completed" ? .completed : .interrupted
        if let store, let url = sessionURL, let totals = try? store.runTotals(runID: saved.id, in: url) {
            run.completed = totals.completed; run.candidates = totals.candidates
            run.qualifiedPulses = totals.qualifiedPulses; run.rejectedWindows = totals.rejectedWindows
            run.sampledSeconds = totals.sampledSeconds; run.gapSeconds = totals.gapSeconds
            run.observationWindows = totals.observationWindows
        }
        if let store, let url = sessionURL {
            countedRunTokens = Set((try? store.acknowledgedRecords(runID: saved.id, in: url))?.map(\.id) ?? [])
        }
        measurementRun = run
    }

    func recordBurst(workspace: String, channel: Int = 0) {
        guard !shutdownInProgress, burstSupported, connected, !busy, !pendingUnsaved, !manualActive, !stageActive,
              !sequenceRunning, currentSession != nil, (0...2).contains(channel) else { return }
        if workspace == "Manual", channel != 0 { return }
        if channel == 0 && !calibrated { error = "Run quiet calibration before recording the final signal."; return }
        let source = channel == 0 ? "Final ADC" : stageLabels[channel - 1].rawValue
        guard channel == 0 || (stageWiringConfirmed && source != StageProbeLabel.disconnected.rawValue) else {
            error = "Confirm the actual optional probe wiring first."; return
        }
        burstRequest = (workspace, channel, source)
        beginCapture(tag: workspace == "Manual" ? "MANUAL" : "STAGE", partOfRun: false)
    }

    func mainNoiseReviewContext() -> MainNoiseReviewContext? {
        guard !shutdownInProgress, let store, let folder = sessionURL, let session = currentSession else { return nil }
        return MainNoiseReviewContext(store: store, folder: folder, sessionID: session.id)
    }

    func selectRecord(_ summary: CaptureRecord) {
        guard !shutdownInProgress, let store, let url = sessionURL else { return }
        let identity = currentSession?.id
        let revision = UUID()
        selectionRevision = revision
        ioQueue.async { [weak self] in
            do {
                let record = try store.loadRecord(summary, in: url)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var analyses: [SignalAnalysisResult] = []
                var analysisIssue: String?
                do { analyses = try store.readAnalyses(recordID: record.id, in: url).map { try decoder.decode(SignalAnalysisResult.self, from: $0) } }
                catch { analysisIssue = "The raw waveform is available, but saved analysis could not be read. \(error.localizedDescription) Original files are retained." }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectionRevision == revision,
                          self.currentSession?.id == identity, self.sessionURL == url else { return }
                    self.selectedRecord = record; self.savedAnalyses = analyses.sorted { $0.createdAt < $1.createdAt }
                    if let analysisIssue { self.presentExportError(analysisIssue) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectionRevision == revision,
                          self.currentSession?.id == identity, self.sessionURL == url else { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func saveAnalysis(_ analysis: SignalAnalysisResult) {
        guard canExportFiles, let store, let url = sessionURL, let record = selectedRecord, analysis.recordID == record.id else { return }
        ioQueue.async { [weak self] in
            do {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(analysis)
                try store.saveAnalysis(data, id: analysis.id, recordID: record.id, inputSHA256: analysis.inputSHA256, in: url)
                DispatchQueue.main.async { [weak self] in guard let self, self.sessionURL == url else { return }; self.status = "Analysis saved with the original record."; if self.selectedRecord?.id == record.id { self.savedAnalyses.append(analysis) } }
            } catch { DispatchQueue.main.async { [weak self] in self?.noteShutdownStorageIssue(error.localizedDescription); self?.presentExportError(error.localizedDescription) } }
        }
    }

    @discardableResult
    func exportProjectCSV(_ source: ProjectCSVSource, request: ProjectCSVRequest) -> Bool {
        exportProjectCSV(source, request: request, retryAccess: true)
    }

    @discardableResult
    private func exportProjectCSV(_ source: ProjectCSVSource, request: ProjectCSVRequest, retryAccess: Bool) -> Bool {
        guard canExportFiles, let session = currentSession, let url = sessionURL, let store else { return false }
        let runID: UUID?
        let recordID: String?
        switch source {
        case .waveformRun(let id): runID = id; recordID = nil
        case .record(let id): runID = nil; recordID = id
        }
        do {
            try withSessionAccess {
                guard try store.openSession(url).id == session.id else { throw StorageError.invalidSession }
                _ = try store.projectExportsDirectory(in: url, create: true)
            }
        } catch { presentExportError(error.localizedDescription); return false }
        busy = true; exporting = true
        exportCancellation = ExportCancellation()
        let cancellation = exportCancellation
        ioQueue.async { [weak self] in
            do {
                let result = try store.exportProjectCSV(runID: runID, recordID: recordID, request: request,
                                                        projectID: session.id, in: url,
                                                        cancelled: { cancellation.isCancelled })
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busy = false; self.exporting = false
                    self.lastExportURL = result; self.status = "CSV saved in Exports."
                }
            } catch {
                let cancelled = (error as? CocoaError)?.code == .userCancelled
                let accessDenied = Self.permissionError(error)
                let message = (error as? CocoaError)?.code == .fileWriteFileExists
                    ? "A file already has that name in Exports. Choose a different filename."
                    : error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busy = false; self.exporting = false
                    if cancelled { self.status = "CSV export cancelled." }
                    else if accessDenied, retryAccess, self.currentSession?.id == session.id, self.sessionURL == url {
                        do {
                            try self.reauthorizeSession()
                            self.exportProjectCSV(source, request: request, retryAccess: false)
                        } catch { self.presentExportError(error.localizedDescription) }
                    } else { self.presentExportError("CSV export did not complete. \(message)") }
                }
            }
        }
        return true
    }

    func requestExport(_ scope: ExportScope) {
        guard canExportFiles, let session = currentSession, let url = sessionURL,
              scope != .record || selectedRecord != nil,
              scope != .run || measurementRun != nil else { return }
        exportContext = ExportContext(sessionID: session.id, folder: url, scope: scope,
                                      record: selectedRecord, run: measurementRun.map(archive))
        exportScope = scope
    }

    func exportSelectedData(_ options: ExportOptions) {
        guard canExportFiles, let context = exportContext, let store,
              context.sessionID == currentSession?.id, context.folder == sessionURL,
              options.scope == context.scope, exportScope == context.scope, options.includesDetailedData else {
            presentExportError("The export context changed. Choose Export again."); return
        }
        let destination: URL
        do {
            let parent = try withSessionAccess {
                guard try store.openSession(context.folder).id == context.sessionID else { throw StorageError.invalidSession }
                return try store.projectExportsDirectory(in: context.folder, create: true)
            }
            destination = parent.appendingPathComponent("Signal Bench Export \(UUID().uuidString)", isDirectory: true)
        } catch { presentExportError(error.localizedDescription); return }
        var localOptions = options
        localOptions.destination = .session
        let exportOptions = localOptions
        let selected = options.scope == .record ? context.record.map { [$0] } : nil
        let ids = selected?.map(\.id) ?? []
        exportScope = nil; exportContext = nil; busy = true; exporting = true
        exportCancellation = ExportCancellation()
        let cancellation = exportCancellation
        ioQueue.async { [weak self] in
            do {
                guard try store.openSession(context.folder).id == context.sessionID else { throw StorageError.invalidSession }
                try store.exportData(recordIDs: ids, run: options.scope == .run ? context.run : nil,
                                     options: exportOptions, in: context.folder, to: destination,
                                     selectedRecords: selected,
                                     cancelled: { cancellation.isCancelled })
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busy = false; self.exporting = false
                    self.lastExportURL = destination; self.status = "Selected data exported."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busy = false; self.exporting = false
                    self.presentExportError("Export did not complete. \(error.localizedDescription)")
                }
            }
        }
    }

    func showLastExport() {
        if let url = lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func cancelExport() { exportCancellation.cancel() }

    func exportRun(includeRaw: Bool) {
        guard canExportFiles, let run = measurementRun, let store, let url = sessionURL else { return }
        let snapshot = archive(run)
        let destination = url.appendingPathComponent("Export \(run.id.uuidString) \(UUID().uuidString)")
        busy = true; exporting = true
        exportCancellation = ExportCancellation()
        let cancellation = exportCancellation
        ioQueue.async { [weak self] in
            do {
                try store.exportRun(snapshot, in: url, to: destination, includeRawSamples: includeRaw, cancelled: { cancellation.isCancelled })
                DispatchQueue.main.async { [weak self] in self?.busy = false; self?.exporting = false; self?.status = "Run exported inside the session folder." }
            } catch { DispatchQueue.main.async { [weak self] in self?.busy = false; self?.exporting = false; self?.presentExportError(error.localizedDescription) } }
        }
    }

    func changeGain(_ value: String) {
        guard !shutdownInProgress, connected, !busy, !pendingUnsaved, !manualActive, !stageActive, value == "LOW" || value == "HIGH" else { return }
        forgetProfileSetup()
        invalidateCalibration(); gainConfirmed = false; gain = value; busy = true; status = "Confirming gain. Calibrate again after the device responds."; command("SB1 GAIN \(value)", expecting: .gain)
    }
    var selectedManualRate: ManualRateOption { ManualRateOption.choices[manualRateIndex] }

    @discardableResult func setManualRateIndex(_ index: Int) -> Bool {
        guard !shutdownInProgress, !manualActive, !busy, ManualRateOption.choices.indices.contains(index) else { return false }
        manualRateIndex = index
        return true
    }

    func enterManual() { enterManual(recordCSV: false) }

    func enterManual(recordCSV: Bool, durationSeconds: Double = ManualCSVRecording.durationRange.upperBound) {
        enterManual(recordCSV: recordCSV, durationSeconds: durationSeconds, retryAccess: true)
    }

    private func enterManual(recordCSV: Bool, durationSeconds: Double, retryAccess: Bool) {
        guard !shutdownInProgress, connected, manualSupported, !manualActive, !stageActive, !busy, !pendingUnsaved,
              !sequenceRunning, !manualCSVBusy else { return }
        guard recordCSV else { sendManualEnter(); return }
        guard ManualCSVRecording.durationRange.contains(durationSeconds) else {
            manualCSVStatus = "Choose a duration from 1 second to 2 hours."
            return
        }
        guard let folder = sessionURL, let projectID = currentSession?.id, let store else {
            manualCSVStatus = "Open or create a project before recording monitor readings."
            return
        }
        do {
            try withSessionAccess {
                guard try store.openSession(folder).id == projectID else { throw StorageError.invalidSession }
            }
        } catch { manualCSVStatus = error.localizedDescription; return }
        manualCSVBusy = true
        manualCSVProjectID = projectID
        manualCSVStatus = "Preparing the monitor recording."
        let generation = connectionGeneration
        let rate = selectedManualRate.hz
        let request = UUID()
        manualCSVStartRequest = request
        ioQueue.async { [weak self] in
            let result = Result {
                try ManualCSVRecording(project: folder, projectID: projectID, rateHz: rate, durationSeconds: durationSeconds)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let startRequested = self.manualCSVStartRequest == request
                self.manualCSVStartRequest = nil
                self.manualCSVBusy = false
                switch result {
                case .success(let recorder):
                    self.manualCSVRecorder = recorder
                    self.manualCSVQueuedRows = 0
                    self.manualCSVFailure = false
                    self.manualCSVDurationSeconds = durationSeconds
                    self.manualCSVReachedDuration = false
                    guard startRequested else { self.finishManualCSV(.appInterrupted); return }
                    guard self.connectionGeneration == generation, self.connected, !self.shutdownInProgress,
                          self.currentSession?.id == projectID, !self.busy, !self.pendingUnsaved,
                          !self.sequenceRunning, !self.stageActive, !self.manualActive else {
                        self.finishManualCSV(.disconnected); return
                    }
                    self.manualCSVActive = true
                    self.manualCSVStatus = "Recording monitor readings to this project."
                    self.sendManualEnter()
                case .failure(let error):
                    guard startRequested else { self.manualCSVStatus = "Monitor recording start cancelled."; return }
                    if retryAccess, Self.permissionError(error), !self.shutdownInProgress,
                       self.connectionGeneration == generation, self.currentSession?.id == projectID {
                        do {
                            try self.reauthorizeSession()
                            self.enterManual(recordCSV: true, durationSeconds: durationSeconds, retryAccess: false)
                        } catch { self.manualCSVStatus = error.localizedDescription }
                        return
                    }
                    self.manualCSVStatus = "Could not start recording. \(error.localizedDescription)"
                    self.noteShutdownStorageIssue(error.localizedDescription)
                }
            }
        }
    }

    private func sendManualEnter() {
        forgetProfileSetup()
        invalidateCalibration(); manualExitRequested = false; manualStopping = false
        manualPinPending = false; pendingManualPin = nil; busy = true
        command("SB1 MANUAL ENTER", expecting: .manualEnter, timeout: 3)
    }

    private func queueManualCSV(_ sample: ManualSnapshot, fromPinChange: Bool) -> Bool {
        guard let recorder = manualCSVRecorder else { return true }
        guard !manualCSVFailure else { exitManual(); return false }
        let capacity = 512
        guard manualCSVQueuedRows < capacity else {
            stopManualForStorage("The project could not save readings fast enough.")
            return false
        }
        manualCSVQueuedRows += 1
        ioQueue.async { [weak self] in
            let result = Result { try recorder.append(sample, fromPinChange: fromPinChange) }
            Task { @MainActor [weak self] in
                guard let self, self.manualCSVRecorder?.id == recorder.id else { return }
                self.manualCSVQueuedRows -= 1
                if case .failure(let error) = result { self.stopManualForStorage(error.localizedDescription) }
            }
        }
        if manualCSVQueuedRows == capacity {
            stopManualForStorage("The project could not save readings fast enough.")
            return false
        }
        return true
    }

    private func stopManualForStorage(_ reason: String) {
        guard !manualCSVFailure else { return }
        manualCSVFailure = true
        exitManual()
        manualCSVStatus = "Monitor recording interrupted. \(reason)"
        noteShutdownStorageIssue(reason)
    }

    private func startManualCSVTimer() {
        guard let recordingID = manualCSVRecorder?.id else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(manualCSVDurationSeconds))
        manualCSVDeadline = deadline
        manualCSVTimer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled, let self, self.manualActive, self.manualCSVRecorder?.id == recordingID else { return }
            self.manualCSVReachedDuration = true
            self.exitManual()
        }
    }

    private func cancelManualCSVTimer() {
        manualCSVTimer?.cancel()
        manualCSVTimer = nil
        manualCSVDeadline = nil
    }

    private func finishManualCSV(_ reason: ManualCSVReport.Reason) {
        cancelManualCSVTimer()
        guard let recorder = manualCSVRecorder else { return }
        let finalReason: ManualCSVReport.Reason = manualCSVFailure ? .storageError : reason
        manualCSVRecorder = nil
        manualCSVActive = false
        manualCSVBusy = true
        if !manualCSVFailure { manualCSVStatus = "Saving the monitor recording." }
        ioQueue.async { [weak self] in
            let result = Result { try recorder.finish(finalReason) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.manualCSVBusy = false
                switch result {
                case .success(let report):
                    self.manualCSVStatus = switch report.reason {
                    case .stopped: "Monitor recording saved."
                    case .durationReached: "Time limit reached. Monitor recording saved."
                    case .storageError: "Incomplete monitor recording retained after a storage error."
                    default: "Incomplete monitor recording retained."
                    }
                case .failure(let error):
                    self.manualCSVStatus = "Could not finish the monitor recording. \(error.localizedDescription)"
                    self.noteShutdownStorageIssue(error.localizedDescription)
                }
                self.refreshManualCSVReports()
            }
        }
    }

    func refreshManualCSVReports() {
        let projectID = currentSession?.id
        if manualCSVProjectID != projectID {
            manualCSVProjectID = projectID
            manualCSVReports = []
            if !manualCSVBusy { manualCSVStatus = nil }
        }
        guard !shutdownInProgress, let projectID, let folder = sessionURL else { return }
        ioQueue.async { [weak self] in
            let result = Result { try ManualCSVRecording.list(in: folder, projectID: projectID) }
            Task { @MainActor [weak self] in
                guard let self, self.currentSession?.id == projectID else { return }
                switch result {
                case .success(let reports):
                    self.manualCSVReports = reports.filter { $0.id != self.manualCSVRecorder?.id }
                case .failure(let error):
                    if !self.manualCSVBusy { self.manualCSVStatus = "Could not reopen monitor recordings. \(error.localizedDescription)" }
                }
            }
        }
    }

    func exportManualCSV(_ id: UUID) {
        exportManualCSV(id, retryAccess: true)
    }

    private func exportManualCSV(_ id: UUID, retryAccess: Bool) {
        guard canExportFiles, !manualCSVBusy, let folder = sessionURL, let projectID = currentSession?.id, let store,
              manualCSVReports.contains(where: { $0.id == id && $0.projectID == projectID }) else { return }
        do {
            try withSessionAccess {
                guard try store.openSession(folder).id == projectID else { throw StorageError.invalidSession }
            }
        } catch { manualCSVStatus = error.localizedDescription; return }
        manualCSVBusy = true
        manualCSVExporting = true
        manualCSVStatus = "Exporting the monitor CSV."
        let cancellation = ExportCancellation()
        manualCSVExportCancellation = cancellation
        ioQueue.async { [weak self] in
            let result = Result {
                try ManualCSVRecording.export(id, in: folder, projectID: projectID, cancelled: { cancellation.isCancelled })
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.manualCSVBusy = false
                self.manualCSVExporting = false
                self.manualCSVExportCancellation = nil
                switch result {
                case .success:
                    self.manualCSVStatus = "Monitor CSV saved in Exports."
                case .failure(let error):
                    if cancellation.isCancelled {
                        self.manualCSVStatus = "Monitor CSV export cancelled."
                    } else if retryAccess, Self.permissionError(error), !self.shutdownInProgress,
                              self.currentSession?.id == projectID {
                        do {
                            try self.reauthorizeSession()
                            self.exportManualCSV(id, retryAccess: false)
                        } catch { self.manualCSVStatus = error.localizedDescription }
                    } else {
                        self.manualCSVStatus = "Monitor CSV export failed. \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func cancelManualCSVExport() { manualCSVExportCancellation?.cancel() }
    func exitManual() {
        manualCSVStartRequest = nil
        cancelManualCSVTimer()
        manualPoll?.cancel(); manualPoll = nil
        guard manualActive || response == .manualEnter else { return }
        pendingManualPin = nil; manualPinPending = false
        manualStopping = true; manualExitRequested = true
        // READ and PIN share an unnumbered LIVE reply. Drain the current reply
        // before EXIT; never confuse it with a subsequent command's response.
        guard response == .idle, !busy else { return }
        busy = true
        command("SB1 MANUAL EXIT", expecting: .manualExit, timeout: 3)
    }
    private func readManual() {
        guard !shutdownInProgress, connected, manualActive, response == .idle, !busy, !manualExitRequested else { return }
        if pendingManualPin != nil { sendPendingManualPin(); return }
        manualLastRequestNS = DispatchTime.now().uptimeNanoseconds
        // A background READ does not toggle published busy on every sample.
        // The explicit response state still enforces one outstanding command.
        command("SB1 MANUAL READ", expecting: .manualRead, timeout: 3)
    }
    private func scheduleManualRead() {
        manualPoll?.cancel()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= manualLastRequestNS ? now - manualLastRequestNS : 0
        let interval = selectedManualRate.intervalNS
        let delay = interval > elapsed ? interval - elapsed : 0
        manualPoll = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
            } else {
                // Even Fastest yields so Stop and GPIO actions can run.
                await Task.yield()
            }
            guard !Task.isCancelled, let self else { return }
            self.readManual()
        }
    }
    func setManualPin(_ pin: Int, action: String) {
        guard !shutdownInProgress, connected, manualActive, !manualExitRequested, !manualStopping,
              Self.manualPins.contains(pin), ["INPUT", "LOW", "HIGH"].contains(action) else { return }
        guard !manualPinPending, !busy, response == .idle || response == .manualRead else {
            error = "A pin change is already waiting for the Pico."; return
        }
        manualPoll?.cancel(); manualPoll = nil
        pendingManualPin = (pin, action); manualPinPending = true
        if response == .idle { sendPendingManualPin() }
    }
    private func sendPendingManualPin() {
        guard !shutdownInProgress, response == .idle, !busy, !manualExitRequested, let request = pendingManualPin else { return }
        pendingManualPin = nil; busy = true
        command("SB1 PIN \(request.pin) \(request.action)", expecting: .manualPin, timeout: 3)
    }
    private func resetManualDisplay() {
        manualDisplayTask?.cancel(); manualDisplayTask = nil
        manualBuffer.reset(); manualSnapshot = nil; manualHistory = []
        manualObservedRateHz = nil; manualTotalReadings = 0; manualADCErrorReadings = 0
        manualLastPublishedNS = 0; manualLastRequestNS = 0
    }
    private func publishManualDisplay(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= manualLastPublishedNS ? now - manualLastPublishedNS : 0
        if force || manualSnapshot == nil || elapsed >= 50_000_000 {
            manualDisplayTask?.cancel(); manualDisplayTask = nil
            manualSnapshot = manualBuffer.latest
            manualHistory = manualBuffer.orderedSamples()
            manualObservedRateHz = manualBuffer.observedRateHz
            manualTotalReadings = manualBuffer.totalReadings
            manualADCErrorReadings = manualBuffer.errorReadings
            manualLastPublishedNS = now
        } else if manualDisplayTask == nil {
            let delay = 50_000_000 - elapsed
            manualDisplayTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, let self, self.manualActive else { return }
                self.publishManualDisplay(force: true)
            }
        }
    }

    @discardableResult func setStageLabel(_ index: Int, label: StageProbeLabel) -> Bool {
        guard !shutdownInProgress, stageLabels.indices.contains(index), !stageActive, !busy else { return false }
        if stageLabels[index] != label {
            stageLabels[index] = label; stageWiringConfirmed = false; stageConfirmedAt = nil
        }
        return true
    }
    @discardableResult func confirmStageWiring() -> Bool {
        guard !shutdownInProgress, connected, stageSupported, !busy, !stageActive, !manualActive, !pendingUnsaved else { return false }
        stageWiringConfirmed = true; stageConfirmedAt = Date()
        return true
    }
    func stageReadingIsStale(at date: Date) -> Bool {
        guard stageActive, let received = stageLastReceivedAt else { return true }
        let age = date.timeIntervalSince(received)
        return age < 0 || age > 2
    }
    func enterStageDiagnostics() {
        guard !shutdownInProgress, connected, stageSupported, stageWiringConfirmed, !stageActive, !manualActive,
              !busy, !pendingUnsaved, !sequenceRunning else { return }
        stageBuffer = StageHistory(); stageHistory = []; stageLastReceivedAt = nil
        stageFirmware = deviceInfo; stageRunConfirmedAt = stageConfirmedAt; stageRunLabels = stageLabels
        stageSequence = 0; stageExitRequested = false; stageStopping = false
        invalidateCalibration(); busy = true
        command("SB1 DIAG ENTER", expecting: .stageEnter, timeout: 3)
    }
    func exitStageDiagnostics() {
        stagePoll?.cancel(); stagePoll = nil
        guard stageActive || response == .stageEnter else { return }
        stageStopping = true; stageExitRequested = true
        guard response == .idle, !busy else { return }
        busy = true
        command("SB1 DIAG EXIT", expecting: .stageExit, timeout: 3)
    }
    private func readStageDiagnostics() {
        guard !shutdownInProgress, connected, stageActive, response == .idle, !busy, !stageExitRequested else { return }
        guard stageSequence < .max else { exitStageDiagnostics(); return }
        stageSequence += 1
        command("SB1 DIAG READ \(stageSequence)", expecting: .stageRead, timeout: 3)
    }
    private func scheduleStageRead() {
        stagePoll?.cancel()
        stagePoll = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.readStageDiagnostics()
        }
    }
    var stageReport: StageDiagnosticReport? {
        guard !stageActive, !manualActive, !busy, !stageHistory.isEmpty, let confirmed = stageRunConfirmedAt else { return nil }
        return .init(formatVersion: 1, firmware: stageFirmware, protocolVersion: 1,
                     exportedAt: Date(), wiringConfirmedAt: confirmed, optionalProbeLabels: stageRunLabels,
                     totalSweeps: stageBuffer.totalSweeps, readings: stageHistory,
                     limitations: "Sequential slow readings, not simultaneous waveforms. Labels are operator declarations, not detected wiring. Nominal mV assumes 3300 mV / 4096 codes and is uncalibrated. Disconnected probe codes can float. Retained history is limited to 120 sweeps and 60 seconds. No pulse, radiation, measured supply or energy result is established.")
    }
    var stageDisplayedLabels: [StageProbeLabel] { stageHistory.isEmpty ? stageLabels : stageRunLabels }
    func exportStageReport() {
        guard canExportFiles, let report = stageReport, let root = sessionURL ?? appRootURL else { return }
        let session = sessionURL
        let sessionID = currentSession?.id
        if let session, let sessionID, let store {
            do {
                let directory = try withSessionAccess {
                    guard try store.openSession(session).id == sessionID else { throw StorageError.invalidSession }
                    return try store.projectExportsDirectory(in: session, create: true)
                }
                let destination = directory.appendingPathComponent("stage-diagnostics-\(UUID().uuidString).json")
                busy = true; exporting = true
                ioQueue.async { [weak self] in
                    do {
                        guard try store.openSession(session).id == sessionID,
                              try store.projectExportsDirectory(in: session, create: false) == directory else { throw StorageError.invalidSession }
                        try StageReportExporter.write(report, to: destination, within: directory)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.busy = false; self.exporting = false
                            self.lastExportURL = destination; self.status = "Diagnostic report saved in Exports."
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.busy = false; self.exporting = false
                            self.presentExportError("Diagnostic export did not complete. \(error.localizedDescription)")
                        }
                    }
                }
            } catch { presentExportError(error.localizedDescription) }
            return
        }
        let panel = NSSavePanel(); panel.canCreateDirectories = false; panel.directoryURL = root
        panel.message = "Save the diagnostic report directly inside the current session or Signal Bench folder."
        panel.nameFieldStringValue = "stage-diagnostics-\(UUID().uuidString).json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let write = {
                try self.checkExportAvailability()
                guard self.sessionURL == session, self.currentSession?.id == sessionID,
                      (self.sessionURL ?? self.appRootURL) == root else {
                    throw SBProtocolError.invalid("The export folder changed. Choose Export Report again.")
                }
                if let session {
                    guard let sessionID, let store = self.store,
                          try store.openSession(session).id == sessionID else {
                        throw SBProtocolError.invalid("The session folder no longer matches the open session.")
                    }
                }
                try StageReportExporter.write(report, to: destination, within: root)
            }
            if session != nil {
                try withSessionAccess(write)
            } else {
                try withAppFolderAccess(write)
            }
            status = "Diagnostic report exported."
        } catch {
            presentExportError("Diagnostic export did not complete. \(error.localizedDescription) Check the destination before retrying.")
        }
    }
    private func folderPanel(message: String, directory: URL? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = message
        panel.directoryURL = directory
        return panel
    }

    private func chooseFolder(message: String = "Choose a folder.", directory: URL? = nil) -> URL? {
        if let selector = folderSelector { return selector(message, directory) }
        let panel = folderPanel(message: message, directory: directory)
        return panel.runModal() == .OK ? panel.url : nil
    }
    var appStorage: StorageManager? { appRootURL.map { StorageManager(root: $0) } }
    func chooseAppFolder() {
        guard !shutdownInProgress, !busy, !stageActive, !sequenceRunning, !pendingUnsaved, currentSession == nil else { error = "Stop diagnostics, close the session and finish saving before changing the Signal Bench folder."; return }
        guard let root = chooseFolder(message: "Select the Signal Bench project folder for app data.", directory: appRootURL?.deletingLastPathComponent()) else { return }
        let started = root.startAccessingSecurityScopedResource()
        guard root.lastPathComponent == "Signal Bench", FileManager.default.fileExists(atPath: root.appendingPathComponent("Signal Bench.xcodeproj").path) else { if started { root.stopAccessingSecurityScopedResource() }; error = "Select the Signal Bench folder that contains Signal Bench.xcodeproj."; return }
        if let old = accessibleAppRootURL { old.stopAccessingSecurityScopedResource() }
        accessibleAppRootURL = started ? root : nil
        appRootURL = root
        status = "Signal Bench folder selected."
    }
    nonisolated private static func permissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<6 {
            guard let e = current else { return false }
            if e.domain == NSPOSIXErrorDomain && (e.code == Int(EACCES) || e.code == Int(EPERM)) { return true }
            if e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoPermissionError || e.code == NSFileWriteNoPermissionError) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    /// The app folder can be reauthorized while a session remains open, but it
    /// cannot silently switch to a different project during a pending capture.
    func withAppFolderAccess<T>(_ operation: () throws -> T) throws -> T {
        guard let original = appRootURL else { throw SBProtocolError.invalid("Select the Signal Bench folder first.") }
        do { return try operation() }
        catch {
            guard Self.permissionError(error) else { throw error }
            guard let selected = chooseFolder(message: "Folder access is needed. Select the Signal Bench folder again.", directory: original.deletingLastPathComponent()) else { throw SBProtocolError.invalid("Signal Bench folder access was not granted.") }
            guard appRootURL == original,
                  selected.standardizedFileURL.resolvingSymlinksInPath() == original.standardizedFileURL.resolvingSymlinksInPath() else { throw SBProtocolError.invalid("Select the same Signal Bench folder to restore access.") }
            let started = selected.startAccessingSecurityScopedResource()
            guard selected.lastPathComponent == "Signal Bench", FileManager.default.fileExists(atPath: selected.appendingPathComponent("Signal Bench.xcodeproj").path) else {
                if started { selected.stopAccessingSecurityScopedResource() }
                throw SBProtocolError.invalid("The selected Signal Bench project folder is unavailable.")
            }
            if let old = accessibleAppRootURL { old.stopAccessingSecurityScopedResource() }
            accessibleAppRootURL = started ? selected : nil
            appRootURL = selected
            return try operation()
        }
    }
    /// Reacquire only the same session, and verify the session identity before retrying.
    private func reauthorizeSession() throws {
        guard let original = sessionURL, let session = currentSession else { throw SBProtocolError.invalid("Open a project first.") }
        guard let selected = chooseFolder(message: "Folder access is needed. Select the current project folder again.", directory: original.deletingLastPathComponent()) else { throw SBProtocolError.invalid("Folder access was not granted.") }
        guard sessionURL == original, currentSession?.id == session.id,
              selected.standardizedFileURL.resolvingSymlinksInPath() == original.standardizedFileURL.resolvingSymlinksInPath() else { throw SBProtocolError.invalid("Select the current project folder to restore access.") }
        let started = selected.startAccessingSecurityScopedResource()
        do {
            let verified = try SessionStore(root: selected.deletingLastPathComponent()).openSession(selected)
            guard verified.id == session.id else { throw SBProtocolError.invalid("The selected folder no longer matches the open project.") }
            adoptAccess(selected, started: started)
        } catch { if started { selected.stopAccessingSecurityScopedResource() }; throw error }
    }
    func withSessionAccess<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            guard Self.permissionError(error) else { throw error }
            try reauthorizeSession()
            return try operation()
        }
    }
    private func safeSessionLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let manager = appStorage else { return true }
        let p = manager.dataURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path != p && !path.hasPrefix(p + "/")
    }
    private func releaseAccessAfterWrites(_ url: URL) {
        // Existing session writes retain their original folder grant until they
        // finish. Scope does not expand and the grant is then released on main.
        ioQueue.async { DispatchQueue.main.async { url.stopAccessingSecurityScopedResource() } }
    }
    private func adoptAccess(_ url: URL, started: Bool) {
        if let old = accessibleURL { releaseAccessAfterWrites(old) }
        accessibleURL = started ? url : nil
    }
    private func presentSessionError(_ message: String) { error = message }

    /// Clear presentation and run ownership, without discarding a Pico record
    /// or the receipt needed to recover it in its original session.
    private func resetSessionPresentation() {
        selectionRevision = UUID(); sessionRevision = UUID()
        measurementRun = nil; savedRuns = []; savedAnalyses = []
        forgetProfileSetup()
        profileLiveCoverage = ProfileCoverage()
        profileBlockCoverage = [:]
        selectedRecord = nil; records = []; lastCommittedRecord = nil
        runCaptureToken = nil; countedRunTokens = []; runRecoveryNote = ""
        calibrationProgress = ""
        exportContext = nil; exportScope = nil; lastExportURL = nil
    }

    var canOpenProject: Bool {
        !shutdownInProgress && !busy && !sequenceRunning && !manualActive && !stageActive && !exporting && !manualCSVBusy
    }
    var canCreateProject: Bool { canOpenProject && !pendingUnsaved }
    var canManageProject: Bool { canCreateProject && currentSession != nil && sessionURL != nil }

    private func chooseNewProject() -> (root: URL, name: String)? {
        let defaultName = "Project \(Date().formatted(date: .abbreviated, time: .omitted))"
        let message = "Name your project and choose a parent folder. Signal Bench will create a project folder inside it."
        if let selector = folderSelector {
            return selector(message, sessionURL?.deletingLastPathComponent()).map { ($0, defaultName) }
        }
        let panel = folderPanel(message: message, directory: sessionURL?.deletingLastPathComponent())
        panel.title = "New Project"
        panel.prompt = "Create Project"
        panel.canCreateDirectories = true
        let nameField = NSTextField(string: defaultName)
        nameField.setAccessibilityLabel("Project name")
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Project name"), nameField])
        accessory.alignment = .firstBaseline
        accessory.spacing = 10
        accessory.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        while panel.runModal() == .OK, let root = panel.url {
            do { return (root, try SessionStore.projectName(nameField.stringValue)) }
            catch {
                panel.message = error.localizedDescription
                panel.directoryURL = root
            }
        }
        return nil
    }

    func createSession() {
        guard canCreateProject, let project = chooseNewProject(), canCreateProject else { return }
        do { try createProject(named: project.name, in: project.root) }
        catch {
            guard Self.permissionError(error),
                  let selected = chooseFolder(message: "Select the same project destination to restore folder access.",
                                              directory: project.root.deletingLastPathComponent()) else {
                presentSessionError(error.localizedDescription); return
            }
            guard selected.standardizedFileURL.resolvingSymlinksInPath() == project.root.standardizedFileURL.resolvingSymlinksInPath() else {
                presentSessionError("Select the same project destination to restore access."); return
            }
            do { try createProject(named: project.name, in: selected) }
            catch { presentSessionError(error.localizedDescription) }
        }
    }

    func createProject(named name: String, in root: URL) throws {
        guard canCreateProject else { throw SBProtocolError.invalid("Finish the current operation before creating a project.") }
        guard safeSessionLocation(root) else { throw SBProtocolError.invalid("Choose a project destination outside Signal Bench app data and cache.") }
        let started = root.startAccessingSecurityScopedResource()
        do {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            if let openPath = sessionURL?.standardizedFileURL.resolvingSymlinksInPath().path,
               path == openPath || path.hasPrefix(openPath + "/") {
                throw SBProtocolError.invalid("Choose a parent folder outside the open project.")
            }
            let s = SessionStore(root: root)
            let url = try s.createProject(name: name)
            let session = try s.openSession(url)
            invalidateCalibration(); resetSessionPresentation()
            adoptAccess(root, started: started)
            store = s; sessionURL = url; currentSession = session
            status = "Project created."
        } catch { if started { root.stopAccessingSecurityScopedResource() }; throw error }
    }
    func openSession() {
        guard canOpenProject,
              let url = chooseFolder(message: "Select an existing Signal Bench project folder containing session.json.") else { return }
        do { try loadSession(at: url) }
        catch {
            guard Self.permissionError(error), let reselected = chooseFolder(message: "Access is required. Select this project folder again.", directory: url.deletingLastPathComponent()) else { presentSessionError(error.localizedDescription); return }
            guard reselected.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() else { presentSessionError("Select the same project folder to restore access."); return }
            do { try loadSession(at: reselected) } catch { presentSessionError(error.localizedDescription) }
        }
    }
    func loadSession(at url: URL) throws {
        guard canOpenProject else { throw SBProtocolError.invalid("Finish the current operation before opening a project.") }
        guard safeSessionLocation(url) else { throw SBProtocolError.invalid("Choose a project folder outside Signal Bench app data and cache.") }
        let started = url.startAccessingSecurityScopedResource()
        do {
            let nextStore = SessionStore(root: url.deletingLastPathComponent())
            let session = try nextStore.openSession(url)
            let loaded = try nextStore.listRecordSummaries(url)
            let runs = try nextStore.loadRuns(url)
            // Adoption is transactional. Failed reads leave the current session
            // and its folder grant intact.
            invalidateCalibration(); resetSessionPresentation()
            adoptAccess(url, started: started)
            store = nextStore; sessionURL = url; currentSession = session
            records = loaded; savedRuns = runs
            if let latest = runs.last { restoreRun(latest) }
            if let first = loaded.first(where: { $0.metadata["host_profile_purpose"] != ProfileAcquisition.Purpose.calibrationPhase.rawValue }) {
                selectRecord(first)
            }
            status = "Project opened."
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func saveDetails(_ details: [String: String]) {
        guard let session = currentSession else { return }
        do { try saveProjectDetails(name: session.name, details: details, expected: session) }
        catch { presentSessionError(error.localizedDescription) }
    }

    func saveProjectDetails(name: String, details: [String: String], expected: SessionMetadata) throws {
        guard canManageProject, let url = sessionURL, let store, currentSession?.id == expected.id else {
            throw SBProtocolError.invalid("Finish the current operation before editing the project.")
        }
        guard name != expected.name || details != expected.details else { return }
        let saved = try withSessionAccess {
            guard canManageProject, currentSession?.id == expected.id, sessionURL == url else {
                throw ProjectStorageError.projectChanged
            }
            return try ioQueue.sync { try store.saveProjectMetadata(name: name, details: details, expected: expected, in: url) }
        }
        if details != expected.details { invalidateCalibration() }
        currentSession = saved
    }

    func closeSession() {
        guard canManageProject else { return }
        invalidateCalibration(); resetSessionPresentation()
        if let url = accessibleURL { releaseAccessAfterWrites(url) }
        accessibleURL = nil; store = nil; sessionURL = nil; currentSession = nil
    }

    func retryPending(allowUnlinked: Bool = false, expectedToken: String? = nil, expectedSession: UUID? = nil) {
        guard !shutdownInProgress, connected, !busy, !stageActive, !manualActive, pendingUnsaved,
              let token = pendingCaptureToken, let session = currentSession, let url = sessionURL, let store else { return }
        guard (expectedToken == nil || expectedToken == token),
              (expectedSession == nil || expectedSession == session.id), recoveryMatchesSession else {
            presentSessionError("The pending record or destination changed. Open the original session and confirm recovery again.")
            return
        }
        let generation = connectionGeneration
        busy = true
        status = "Checking the capture receipt."
        do {
            let intent = try withSessionAccess {
                guard connectionGeneration == generation, sessionURL == url,
                      currentSession?.id == session.id, try store.openSession(url).id == session.id else {
                    throw SBProtocolError.invalid("The connection or session changed before recovery.")
                }
                if let saved = try store.readCaptureIntent(token, in: url) { return saved }
                guard !CaptureIntent.isBound(token) else {
                    throw SBProtocolError.invalid("The capture receipt is missing. Reopen the original session with its receipt to recover the record.")
                }
                guard allowUnlinked else {
                    throw SBProtocolError.invalid("Confirm an unlinked import before recovering this older record.")
                }
                let unlinked = CaptureIntent(token: token, sessionID: session.id, tag: nil, gain: nil,
                                             calibrationRecordID: nil, calibrationID: nil, sessionDetails: [:],
                                             device: deviceInfo, startedAt: Date())
                try store.saveCaptureIntent(unlinked, in: url)
                return unlinked
            }
            guard connectionGeneration == generation, connected else { return }
            if let stamp = intent.profileStamp {
                guard let saved = savedRuns.first(where: { $0.id.uuidString == intent.runID }),
                      saved.profileAcquisition?.owner == stamp.owner, saved.profileAcquisition?.purpose == stamp.purpose,
                      saved.profileSegments?.contains(where: { $0.id == stamp.segment }) == true else {
                    throw ProfileWorkflowError.invalidEvidence
                }
                if measurementRun?.id != saved.id {
                    busy = false
                    restoreRun(saved)
                    busy = true
                    guard measurementRun?.id == saved.id else { throw ProfileWorkflowError.invalidEvidence }
                }
            }
            if !intent.linked { invalidateCalibration() }
            captureSaveIssue = nil
            activeIntent = intent
            if let runID = intent.runID, measurementRun?.id.uuidString == runID { runCaptureToken = token }
            activeToken = token
            assembler = SBRecordAssembler(token: token)
            status = "Receiving retained record."
            command("SB1 \(binarySupported ? "GETB" : "GET") \(token)", expecting: .transfer)
        } catch {
            guard connectionGeneration == generation else { return }
            busy = false
            presentSessionError(error.localizedDescription)
        }
    }

    func projectTrashSelection() throws -> ProjectTrashSelection {
        guard canManageProject, let url = sessionURL, let store, let project = currentSession else {
            throw SBProtocolError.invalid("Finish recording or recover pending data before moving a project to the Trash.")
        }
        return try withSessionAccess {
            guard canManageProject, sessionURL == url, currentSession?.id == project.id else { throw ProjectStorageError.projectChanged }
            let selection = try store.projectTrashSelection(in: url)
            guard selection.id == project.id, selection.name == project.name else { throw ProjectStorageError.projectChanged }
            return selection
        }
    }

    func moveProjectToTrash(_ selection: ProjectTrashSelection, typedName: String) throws {
        guard canManageProject, let store else {
            throw SBProtocolError.invalid("Finish recording or recover pending data before moving a project to the Trash.")
        }
        try withSessionAccess {
            guard canManageProject, sessionURL?.standardizedFileURL.path == selection.folder.path,
                  currentSession?.id == selection.id, currentSession?.name == selection.name else {
                throw ProjectStorageError.projectChanged
            }
            // This queue owns persisted progress and recovery files. Drain it
            // before moving the exact folder named in the confirmation.
            try ioQueue.sync { try store.trashProject(selection, typedName: typedName) }
        }
        closeSession()
        status = "Project moved to Trash."
    }

    func openSessionFolder() { if let url = sessionURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func openProjectExports() {
        guard canOpenProject, let folder = sessionURL, let project = currentSession, let store else { return }
        do {
            let exports = try withSessionAccess {
                guard sessionURL == folder, currentSession?.id == project.id,
                      try store.openSession(folder).id == project.id else { throw ProjectStorageError.projectChanged }
                return try store.projectExportsDirectory(in: folder, create: false)
            }
            NSWorkspace.shared.activateFileViewerSelecting([exports])
        } catch StorageError.noData {
            presentSessionError("This project has no exports yet.")
        } catch {
            presentSessionError(error.localizedDescription)
        }
    }
    var canExportFiles: Bool { !shutdownInProgress && !busy && !sequenceRunning && !manualActive && !stageActive && !manualCSVBusy }

    func checkExportAvailability() throws {
        guard canExportFiles else {
            throw SBProtocolError.invalid("Finish the active operation before exporting.")
        }
    }

    private func presentExportError(_ message: String) {
        // File errors never cancel a serial watchdog or change capture state.
        if error == nil { error = message }
    }

    func exportRecord() {
        exportRecord { session, filename in
            let panel = NSSavePanel()
            panel.canCreateDirectories = false
            panel.directoryURL = session
            panel.message = "Save this export inside the open session folder."
            panel.nameFieldStringValue = filename
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    func exportRecord(chooseDestination: (URL, String) -> URL?) {
        guard canExportFiles, let record = selectedRecord, let store, let session = sessionURL,
              let sessionID = currentSession?.id,
              let destination = chooseDestination(session, "record-\(record.id).csv") else { return }
        do {
            try withSessionAccess {
                try checkExportAvailability()
                guard sessionURL == session, currentSession?.id == sessionID,
                      try store.openSession(session).id == sessionID else {
                    throw SBProtocolError.invalid("The session changed. Choose Export CSV again.")
                }
                let root = session.resolvingSymlinksInPath().standardizedFileURL.path
                let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                guard parent == root || parent.hasPrefix(root + "/") else {
                    throw SBProtocolError.invalid("Save exports inside the current session folder.")
                }
                try store.exportRecord(record, to: destination)
            }
            status = "Record exported."
        } catch {
            presentExportError("CSV export did not complete. \(error.localizedDescription)")
        }
    }
}
