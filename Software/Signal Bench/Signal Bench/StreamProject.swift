import CryptoKit
import Darwin
import Foundation

nonisolated enum RecordingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case main = "Main", manual = "Manual", manualRaw = "Manual Raw", calibrated = "Calibrated Run", calibration = "Calibration Phase", diagnosis = "Diagnosis"
    var id: String { rawValue }
    var wireMode: String { self == .manual ? "MANUAL" : self == .diagnosis ? "DIAG" : "RAW" }
}

nonisolated struct StreamProjectIdentity: Codable, Equatable, Sendable {
    var type = "com.issa26.signal-bench-project"
    var version = 3
    var id = UUID()
    var name: String
    var created = Date()
}

nonisolated struct StreamChunkSummary: Codable, Equatable, Sendable {
    let id: UUID
    let segment: UUID
    let bytes: Int
    let sha256: String
    let first: UInt64
    let end: UInt64
    let picoAveraging: ADCAveraging?
    let averagingBoard: AcquisitionBoard?
    var board: AcquisitionBoard { averagingBoard ?? .picoW }

    var readingCount: Int { bytes / PicoAverage.stride(picoAveraging, board: board) }
    var valid: Bool {
        (PicoAverage.stride(picoAveraging, board: board)...StreamProjectStore.chunkLimit).contains(bytes)
            && bytes.isMultiple(of: PicoAverage.stride(picoAveraging, board: board))
            && first < end && end <= StreamWire.maxSampleBoundary / UInt64(picoAveraging?.count ?? 1)
            && UInt64(readingCount) <= end - first && ProfileDigest.valid(sha256)
    }

    init(_ chunk: StreamChunk) {
        let last = chunk.slices[chunk.slices.count - 1]
        id = chunk.id
        segment = chunk.segment
        bytes = chunk.bytes
        picoAveraging = chunk.picoAveraging
        averagingBoard = chunk.averagingBoard
        sha256 = chunk.sha256
        first = chunk.slices[0].first
        end = last.first + UInt64(last.count)
    }
}

nonisolated private struct StreamChunkHeader: Codable, Equatable, Sendable {
    var version = 2
    var summary: StreamChunkSummary
    var frameIndexSHA256: String
}

nonisolated struct StreamRunSettings: Codable, Equatable, Sendable {
    var mode: RecordingMode
    var channel: Int = 0
    var nominalRate = StreamWire.rate
    var duration: Double = 300
    var wiring = ""
    var gain = "Unconfirmed"
    var calibrationAttempt: UUID?
    var calibrationPhase: CalibrationPhase?
    var calibrationSetup: CalibrationSetup? = nil
    var profile: CalibrationProfile?
    var purpose: String? = nil
    var bench: BenchRunContext? = nil
    var draft: Bool? = nil
    var noisePolicy: NoisePolicy? = nil
    var benchSampling: Bool? = nil
    var adcAveraging: ADCAveraging? = nil
    var picoAveraging: ADCAveraging? = nil
    var acquisitionBoard: AcquisitionBoard? = nil
    var prerunPlan: CalibratedPrerun.Plan? = nil
    var prerun: CalibratedPrerun.Link? = nil
    var mainsHum: MainsHumCapture? = nil
    var unoCandidates: UnoCandidateSettings? = nil
    var startupDelaySeconds: Int? = nil
    var allowsLiveDurationEdit: Bool { usesStartupDelay && prerunPlan == nil }
    var usesStartupDelay: Bool { mode != .calibration && purpose == nil && bench == nil && mainsHum == nil }
    var board: AcquisitionBoard { acquisitionBoard ?? .picoW }
    var factor: Int { picoAveraging?.count ?? 1 }
    var runVersion: Int { board == .unoR4 ? (picoAveraging == nil ? 4 : 5) : (picoAveraging == nil ? 1 : 2) }
    var rawConfiguredRate: Double { board.rate(nominalRate) }
    var recordedRate: Double { rawConfiguredRate / Double(factor) }
    var libraryRecordedRate: Double { adcAveraging?.rate(from: rawConfiguredRate) ?? recordedRate }
    var libraryRateLabel: String {
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        if picoAveraging != nil {
            return "\(recordedRate.formatted(precision)) readings/s · \(nominalRate.formatted()) raw · \(factor)×"
        }
        if let adcAveraging {
            return "\(adcAveraging.rate(from: rawConfiguredRate).formatted(precision)) averaged/s on Mac · \(nominalRate.formatted()) raw"
        }
        return "\(nominalRate.formatted()) samples/s requested"
    }
    var valid: Bool {
        StreamWire.customRates.contains(nominalRate) && (1...StreamWire.maxDuration).contains(duration) && (0...2).contains(channel)
        && (startupDelaySeconds.map { usesStartupDelay && StreamStartupDelay.supported.contains($0) } ?? true)
        && (unoCandidates.map { $0.valid && board == .unoR4 && nominalRate == 100_000 && channel == 0 &&
            picoAveraging == nil && adcAveraging == nil && [.main, .manual, .diagnosis].contains(mode) } ?? true)
        && (mode == .diagnosis || channel == 0) && wiring.utf8.count <= 1024
        && (picoAveraging == nil || adcAveraging == nil)
        && (board == .picoW || (board.supportsSavedRate(nominalRate) && (nominalRate != 500_000 || picoAveraging == nil) && adcAveraging == nil))
        && [profile?.setup, calibrationSetup, bench?.setup].compactMap { $0 }.allSatisfy { $0.acquisitionDevice == board }
        && (profile.map { $0.setup.picoAveraging == picoAveraging } ?? true)
        && (calibrationSetup.map { $0.picoAveraging == picoAveraging } ?? true)
        && (bench.map { $0.setup.picoAveraging == picoAveraging } ?? true)
        && (adcAveraging == nil || (channel == 0 && nominalRate == ADCAveraging.sourceRate &&
            [.main, .manual, .manualRaw, .diagnosis].contains(mode) && bench == nil))
        && ["LOW","HIGH","Unconfirmed"].contains(gain)
        && (mode != .calibrated || (profile?.valid == true && profile?.ready == true && profile?.setup.gain == gain && profile?.setup.nominalHz == nominalRate))
        && (mode != .calibration || (calibrationAttempt != nil && calibrationPhase != nil && calibrationSetup?.valid == true && calibrationSetup?.gain == gain && calibrationSetup?.nominalHz == nominalRate))
        && (mode != .diagnosis || !wiring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (mainsHum.map { $0.matches(self) && purpose == nil && profile == nil && bench == nil } ?? true)
        && (purpose == nil || (mode == .calibrated && purpose == "localDarkCheck") || (mode == .main && purpose == "rateBenchmark"))
        && (prerunPlan.map { $0.valid && mode == .calibrated && purpose == "localDarkCheck" && duration == $0.length.seconds && prerun == nil } ?? true)
        && (prerun.map { $0.valid && purpose == nil && (mode == .calibrated || (mode == .main && profile == nil)) } ?? true)
        && (bench.map { mode == .main && $0.setup.valid && $0.setup.gain == gain && $0.setup.nominalHz == nominalRate } ?? true)
    }
}

nonisolated struct ManualSampleQuality: Codable, Equatable, Sendable {
    var samples: UInt64 = 0
    var adcErrors: UInt64 = 0
    var railSamples: UInt64 = 0
    var sourceADCErrors: UInt64? = nil
    var sourceLowRails: UInt64? = nil
    var sourceHighRails: UInt64? = nil
    var combinedFaultGroups: UInt64? = nil

    func fits(savedSamples: UInt64) -> Bool {
        samples <= savedSamples && adcErrors <= samples && railSamples <= samples
            && (combinedFaultGroups.map { $0 <= adcErrors && $0 <= railSamples && railSamples - $0 <= samples - adcErrors }
                ?? (railSamples <= samples - adcErrors))
    }

    mutating func append(_ data: Data, averaging: ADCAveraging?, board: AcquisitionBoard = .picoW) throws {
        guard let averaging else { append(data, board: board); return }
        let size = PicoAverage.stride(averaging, board: board)
        try data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: size) {
                guard let group = PicoAverage.group(bytes, offset: offset, first: 0, factor: averaging, board: board) else {
                    throw StreamFailure.storage("A saved group has invalid ADC quality counts.")
                }
                samples += 1
                if group.adcErrors > 0 { adcErrors += 1 }
                if group.lowRail + group.highRail > 0 { railSamples += 1 }
                if group.adcErrors > 0 && group.lowRail + group.highRail > 0 { combinedFaultGroups = (combinedFaultGroups ?? 0) + 1 }
                sourceADCErrors = (sourceADCErrors ?? 0) + UInt64(group.adcErrors)
                sourceLowRails = (sourceLowRails ?? 0) + UInt64(group.lowRail)
                sourceHighRails = (sourceHighRails ?? 0) + UInt64(group.highRail)
            }
        }
    }

    mutating func append(_ data: Data, board: AcquisitionBoard = .picoW) {
        samples += UInt64(data.count / 2)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                if word & 0x8000 != 0 {
                    adcErrors += 1
                } else if board.sampleCode(word) == 0 || board.sampleCode(word) == board.maxCode {
                    railSamples += 1
                }
            }
        }
    }
}

nonisolated struct StreamRunSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var stream: UInt64
    var started = Date()
    var timelineStart: Double
    var boot: UInt64?
    var firstDeviceUS: UInt64?
    var finalDeviceUS: UInt64?
    var adcClock: UInt32?
    var divider256: UInt32?
    var savedSamples: UInt64 = 0
    var accountedSamples: UInt64 = 0
    var knownLoss: UInt64 = 0
    var unknown = false
    var measuredByPicoTimer: Double?
    var cadenceWindowUS: UInt64?
    var firmware: String?
    var endReason: String?
    var gpioEvents = 0
    var firmwareQueuePeak: UInt32?
    var firmwareStopCode: UInt32?
    var hostQueuePeak: Int?
    var maximumWriterUS: UInt64?
    var manualQuality: ManualSampleQuality?
    var manualOutputsReleased: Bool?
    var picoAveraging: ADCAveraging? = nil
    var maximumPackingUS: UInt32? = nil
    var maximumUSBBackpressureUS: UInt64? = nil
    var totalUSBBackpressureUS: UInt64? = nil
    var deadlineReached: Bool? = nil
    var prerun: CalibratedPrerun.Link? = nil
    var candidatePeakUS: UInt32? = nil
    var startup: StreamStartupEvidence? = nil

    var acquisitionBoard: AcquisitionBoard? = nil
    var board: AcquisitionBoard { acquisitionBoard ?? .picoW }
    var factor: UInt64 { UInt64(picoAveraging?.count ?? 1) }
    var displayEndReason: String? {
        if let firmwareStopCode, firmwareStopCode != 0,
           endReason == nil || endReason == "Pico ended the stream before a clean stop" {
            return Self.stopReason(firmwareStopCode, board: board)
        }
        return endReason
    }

    static func stopReason(_ code: UInt32, board: AcquisitionBoard = .picoW) -> String? {
        switch code {
        case 1: board == .unoR4 ? "UNO R4 Minima streaming buffer filled" : "Pico streaming buffer filled"
        case 2: board == .unoR4 ? "UNO ADC transfer could not rearm in time. Tail coverage is unknown." : "Pico ADC FIFO overran. The exact conversion loss is unknown."
        case 3: "\(board.title) detected a USB link interruption."
        case 4: "\(board.title) stopped receiving connection keepalives."
        default: nil
        }
    }

    func configuredRate(_ requested: Int) -> Double { rawConfiguredRate(requested) / Double(factor) }

    func rawConfiguredRate(_ requested: Int) -> Double {
        guard let adcClock, let divider256,
              board.accepts(adcClock, divider256, rate: requested) else {
            return picoAveraging == nil ? Double(requested) : board.rate(requested)
        }
        return board.measuredConfiguration(adcClock, counter: divider256)
    }
}

nonisolated struct StreamRun: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case recording, complete, interrupted }
    var type = "com.issa26.signal-bench-run"
    var version = 1
    var id = UUID()
    var project: UUID
    var name: String
    var description: String
    var created = Date()
    var status = Status.recording
    var message: String?
    var settings: StreamRunSettings
    var boardLabel: String { settings.acquisitionBoard?.title ?? "Pico W · legacy" }
    var segments: [StreamRunSegment] = []
    var rate_exposure_valid = 0
    var picoCardOrigin: PicoCardImport.Origin? = nil
    var curveSource: UUID? = nil
    var primaryCurve: UUID? = nil
    var prerunReport: CalibratedPrerun.Report? = nil

    struct DurationChange: Codable, Equatable, Sendable {
        let changed: Date
        let segment: UUID
        let elapsed: Double
        let previous: Double
        let target: Double

        var valid: Bool {
            (0...StreamWire.maxDuration + StreamWire.stopReserveSeconds).contains(elapsed)
                && (1...StreamWire.maxDuration).contains(previous) && (1...StreamWire.maxDuration).contains(target)
        }
    }

    var durationChanges: [DurationChange]? = nil
    var initialDuration: Double { durationChanges?.first?.previous ?? settings.duration }
    var validDurationHistory: Bool {
        guard let changes = durationChanges else { return true }
        return settings.allowsLiveDurationEdit && (1...256).contains(changes.count)
            && changes.last?.target == settings.duration
            && changes.allSatisfy { change in change.valid && segments.contains { $0.id == change.segment } }
            && zip(changes, changes.dropFirst()).allSatisfy { $0.target == $1.previous }
    }

    var linkedPreruns: [CalibratedPrerun.Link] {
        var seen = Set<CalibratedPrerun.Link>()
        return ([settings.prerun].compactMap { $0 } + segments.compactMap(\.prerun)).filter { seen.insert($0).inserted }
    }
    var displayMessage: String? {
        if message == "Pico ended the stream before a clean stop" { return segments.last?.displayEndReason ?? message }
        return message
    }
    var isManualDraft: Bool { settings.draft == true && (settings.mode == .manual || settings.mode == .manualRaw) }
    var hasUnknownCoverage: Bool { segments.count > 1 || segments.contains(where: \.unknown) }
    var hasCadenceMismatch: Bool {
        segments.contains { segment in
            let configured = segment.configuredRate(settings.nominalRate)
            return segment.measuredByPicoTimer.map { abs($0 - configured) > configured / 100 } ?? false
        }
    }
}

nonisolated struct StreamRunItem: Identifiable, Sendable {
    var id: UUID
    var run: StreamRun?
    var issue: String?
}

nonisolated struct StreamSlice: Codable, Equatable, Sendable {
    var first: UInt64
    var count: Int
    var byteOffset: Int
    var sequence: UInt32
    var deviceEndUS: UInt64
}

nonisolated struct StreamChunk: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    var id = UUID()
    var segment: UUID
    var bytes: Int
    var sha256: String
    var slices: [StreamSlice]
    var picoAveraging: ADCAveraging? = nil
    var averagingBoard: AcquisitionBoard? = nil
    var board: AcquisitionBoard { averagingBoard ?? .picoW }
    var formatVersion: Int { picoAveraging == nil ? 1 : (board == .unoR4 ? 3 : 2) }
}

nonisolated struct StreamGPIO: Codable, Sendable {
    var segment: UUID
    var deviceUS: UInt64
    var completedSampleBoundary: UInt64
    var directions: UInt32
    var levels: UInt32
    var latches: UInt32
    var leaseActive: Bool
}

nonisolated enum StreamFiles {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func directory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw StreamFailure.storage("The storage directory is linked or unavailable.")
        }
    }

    static func directory(_ name: String, in root: URL, create: Bool) throws -> URL {
        guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw StreamFailure.storage("Invalid directory name.")
        }
        try directory(root)
        let url = root.appendingPathComponent(name, isDirectory: true)
        if create, mkdir(url.path, 0o700) != 0, errno != EEXIST { throw posix() }
        try directory(url)
        return url
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func isPresent(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw posix()
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        try directory(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= limit else { throw StreamFailure.storage("Invalid or oversized recording file.") }
        let length = Int(info.st_size)
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < length {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), length - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StreamFailure.storage("A recording file changed during reading.") }
                offset += n
            }
        }
        var last = UInt8(0)
        var extra = Darwin.read(fd, &last, 1)
        while extra < 0 && errno == EINTR { extra = Darwin.read(fd, &last, 1) }
        guard extra == 0 else { throw StreamFailure.storage("A recording file changed during reading.") }
        return data
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try decoder.decode(type, from: read(url, limit: 1_048_576))
    }

    static func sync(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw posix() }
    }

    static func publish(_ bytes: Data, at url: URL, replace: Bool = false) throws {
        let parent = url.deletingLastPathComponent()
        try directory(parent)
        let temp = parent.appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); _ = unlink(temp.path) }
        try file.write(contentsOf: bytes)
        try file.synchronize()
        try file.close()
        if replace {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  rename(temp.path, url.path) == 0 else { throw posix() }
        } else {
            guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw posix() }
        }
        try sync(parent)
    }

    static func publish<T: Encodable>(_ value: T, at url: URL, replace: Bool = false) throws {
        let bytes = try encoder.encode(value)
        guard bytes.count <= 1_048_576 else { throw StreamFailure.storage("Recording metadata is too large.") }
        try publish(bytes, at: url, replace: replace)
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

nonisolated final class StreamRunLock {
    private let fd: Int32

    init(_ directory: URL) throws {
        let path = directory.appendingPathComponent(".writer-lock").path
        let handle = Darwin.open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard handle >= 0 else { throw StreamFiles.posix() }
        var info = stat()
        guard fstat(handle, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(handle)
            throw StreamFailure.storage("This run is in use by another Signal Bench window or process.")
        }
        fd = handle
    }

    deinit { Darwin.close(fd) }
}

nonisolated struct StreamProjectStore: Sendable {
    let folder: URL
    let identity: StreamProjectIdentity
    private let device: dev_t
    private let inode: ino_t
    static let chunkLimit = 512 * 1024

    init(opening folder: URL) throws {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        try StreamFiles.directory(root)
        let manifest = root.appendingPathComponent("project.json")
        if !StreamFiles.exists(manifest), StreamFiles.exists(root.appendingPathComponent("session.json")) {
            throw StreamFailure.project("This is a Signal Bench 1.x Project. Open it in 1.3 or create a new streaming Project.")
        }
        let project = try StreamFiles.read(StreamProjectIdentity.self, manifest)
        if project.type == "com.issa26.signal-bench-project", project.version == 2 {
            throw StreamFailure.project("This is a Signal Bench 2 Project. Open it in Signal Bench 2.2.1.")
        }
        guard project.type == "com.issa26.signal-bench-project", project.version == 3,
              (try? SessionStore.projectName(project.name)) == project.name else {
            throw StreamFailure.project("This Project format is not supported.")
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw StreamFiles.posix() }
        self.folder = root
        self.identity = project
        self.device = info.st_dev
        self.inode = info.st_ino
    }

    static func create(named enteredName: String, in parent: URL) throws -> Self {
        let name = try SessionStore.projectName(enteredName)
        let root = parent.standardizedFileURL.resolvingSymlinksInPath()
        try StreamFiles.directory(root)
        guard !StreamFiles.exists(root.appendingPathComponent("session.json")),
              !StreamFiles.exists(root.appendingPathComponent("project.json")) else {
            throw StreamFailure.project("Choose a parent outside an existing Project.")
        }
        let location = root.appendingPathComponent(name, isDirectory: true)
        guard mkdir(location.path, 0o700) == 0 else { throw StreamFiles.posix() }
        try StreamFiles.publish(StreamProjectIdentity(name: name), at: location.appendingPathComponent("project.json"))
        try StreamFiles.sync(root)
        return try Self(opening: location)
    }

    func verify() throws {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_dev == device, info.st_ino == inode,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              try Self(opening: folder).identity.id == identity.id else {
            throw StreamFailure.project("The Project folder moved or changed. Reopen the original Project to recover the run.")
        }
    }

    func defaults() throws -> ProjectDefaults {
        try verify()
        let url = folder.appendingPathComponent("settings.json")
        guard try StreamFiles.isPresent(url) else { return .init() }
        let value = try StreamFiles.read(ProjectDefaults.self, url)
        guard value.valid else { throw StreamFailure.project("Project settings could not be read.") }
        return value
    }

    func saveDefaults(_ value: ProjectDefaults) throws {
        try verify()
        guard value.valid else { throw StreamFailure.project("Check the Project defaults.") }
        let url = folder.appendingPathComponent("settings.json")
        try StreamFiles.publish(value, at: url, replace: try StreamFiles.isPresent(url))
    }

    func keepDraft(_ id: UUID, name: String? = nil, description: String? = nil) throws -> StreamRun {
        try verify()
        let lock = try StreamRunLock(runDirectory(id))
        defer { withExtendedLifetime(lock) {} }
        var run = try openRun(id)
        guard run.isManualDraft else { throw StreamFailure.project("This recording is already saved.") }
        if let name { run.name = try SessionStore.projectName(name) }
        if let description { run.description = try checkedDescription(description) }
        run.settings.draft = false
        try save(run)
        return run
    }

    func makeRun(name: String, description: String, settings: StreamRunSettings, id: UUID = UUID()) throws -> StreamRun {
        try verify()
        let title = try SessionStore.projectName(name)
        let notes = try checkedDescription(description)
        guard settings.valid else { throw StreamFailure.project("The recording settings are invalid.") }
        var run = StreamRun(id: id, project: identity.id, name: title, description: notes, settings: settings)
        run.version = settings.runVersion
        let parent = try StreamFiles.directory("runs", in: folder, create: true)
        let dir = parent.appendingPathComponent(run.id.uuidString, isDirectory: true)
        guard mkdir(dir.path, 0o700) == 0 else { throw StreamFiles.posix() }
        try StreamFiles.publish(run, at: dir.appendingPathComponent("run.json"))
        try StreamFiles.sync(parent)
        return try openRun(run.id, active: true)
    }

    private func checkedDescription(_ description: String) throws -> String {
        let notes = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, notes.utf8.count <= 8192, !notes.contains("\0") else {
            throw StreamFailure.project("Enter a description of 1 to 8,192 bytes.")
        }
        return notes
    }

    func runDirectory(_ id: UUID) throws -> URL {
        let parent = try StreamFiles.directory("runs", in: folder, create: false)
        return try StreamFiles.directory(id.uuidString, in: parent, create: false)
    }

    func finderFolder(for id: UUID) throws -> URL {
        try verify()
        return try runDirectory(id)
    }

    func list() throws -> [StreamRunItem] {
        try verify()
        let runs = folder.appendingPathComponent("runs")
        guard try StreamFiles.isPresent(runs) else { return [] }
        try StreamFiles.directory(runs)
        let entries = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)
        guard entries.count <= 10_000 else { throw StreamFailure.storage("Too many runs in this Project.") }
        return try entries.compactMap { url in
            try Task.checkCancellation()
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            do { return StreamRunItem(id: id, run: try openRun(id), issue: nil) }
            catch { return StreamRunItem(id: id, run: nil, issue: error.localizedDescription) }
        }.sorted { ($0.run?.created ?? .distantPast) > ($1.run?.created ?? .distantPast) }
    }

    func openRun(_ id: UUID, active: Bool = false) throws -> StreamRun {
        let dir = try runDirectory(id)
        var run = try StreamFiles.read(StreamRun.self, dir.appendingPathComponent("run.json"))
        guard run.id == id, run.project == identity.id, run.type == "com.issa26.signal-bench-run",
              (run.version == 3 ? run.curveSource != nil && run.curveSource != run.id && run.primaryCurve != nil
                && run.status != .recording && !run.isManualDraft :
                run.version == run.settings.runVersion && run.curveSource == nil && run.primaryCurve == nil),
              run.prerunReport.map({ $0.matches(run) }) ?? true,
              run.linkedPreruns.allSatisfy({ $0.valid && $0.run != id }),
              Set(run.linkedPreruns.map(\.run)).count == run.linkedPreruns.count,
              run.rate_exposure_valid == 0, run.settings.valid, run.segments.count <= 1_000, run.validDurationHistory,
              (try? SessionStore.projectName(run.name)) == run.name, (try? checkedDescription(run.description)) == run.description,
              Set(run.segments.map(\.id)).count == run.segments.count,
              run.segments.allSatisfy({
                  (0...86_400).contains($0.timelineStart) && $0.stream != 0 && $0.savedSamples <= $0.accountedSamples
                  && $0.picoAveraging == run.settings.picoAveraging && $0.board == run.settings.board
                  && ($0.prerun.map { $0.valid && $0.run != id && run.settings.purpose == nil &&
                       (run.settings.mode == .calibrated || run.settings.mode == .main) } ?? true)
                  && $0.accountedSamples <= StreamWire.maxSampleBoundary / $0.factor && $0.knownLoss <= $0.accountedSamples
                  && ($0.startup?.valid(factor: $0.factor) ?? true)
                  && ($0.manualQuality?.fits(savedSamples: $0.savedSamples) ?? true)
                  && ($0.firstDeviceUS ?? 0) <= StreamWire.maxDeviceTimeUS && ($0.finalDeviceUS ?? 0) <= StreamWire.maxDeviceTimeUS
              })
        else { throw StreamFailure.storage("The run manifest is incompatible or corrupt.") }
        if !active && run.status == .recording {
            run.status = .interrupted
            run.message = "Recording ended before final reconciliation. The committed prefix is available."
            if !run.segments.isEmpty { run.segments[run.segments.count - 1].unknown = true }
        }
        return run
    }

    func save(_ run: StreamRun) throws {
        try verify()
        guard run.project == identity.id else { throw StreamFailure.storage("The Project changed before saving.") }
        let url = try runDirectory(run.id).appendingPathComponent("run.json")
        try StreamFiles.publish(run, at: url, replace: true)
    }

    func rename(_ id: UUID, name: String, description: String) throws -> StreamRun {
        try verify()
        let lock = try StreamRunLock(runDirectory(id))
        defer { withExtendedLifetime(lock) {} }
        var run = try openRun(id)
        run.name = try SessionStore.projectName(name)
        run.description = try checkedDescription(description)
        if run.settings.mode == .main { run.settings.draft = false }
        try save(run)
        return run
    }

    func chunks(_ run: StreamRun) throws -> [StreamChunk] {
        try chunkSummaries(run).map { try chunk($0, run: run) }
    }

    func chunkSummaries(_ run: StreamRun) throws -> [StreamChunkSummary] {
        guard run.curveSource == nil else { return [] }
        let path = try runDirectory(run.id).appendingPathComponent("chunks")
        guard try StreamFiles.isPresent(path) else { return [] }
        try StreamFiles.directory(path)
        let entries = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard entries.count <= 16_000 else { throw StreamFailure.storage("The chunk index exceeds its limit.") }
        let order = Dictionary(uniqueKeysWithValues: run.segments.enumerated().map { ($1.id, $0) })
        var index: [(position: Int, summary: StreamChunkSummary)] = []
        index.reserveCapacity(entries.count)
        for url in entries {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try StreamFiles.read(url, limit: 1_048_576)
                let summary: StreamChunkSummary
                if let header = try readChunkHeader(bytes, url: url) {
                    summary = header.summary
                } else {
                    summary = StreamChunkSummary(try validateChunk(StreamFiles.decoder.decode(StreamChunk.self, from: bytes), url: url))
                }
                guard let position = order[summary.segment], summary.picoAveraging == run.settings.picoAveraging,
                      summary.averagingBoard == (run.settings.board == .unoR4 && summary.picoAveraging != nil ? .unoR4 : nil) else {
                    throw StreamFailure.storage("A raw chunk has no timing segment.")
                }
                index.append((position, summary))
            }
        }
        index.sort { ($0.position, $0.summary.first) < ($1.position, $1.summary.first) }
        var ends: [UUID: UInt64] = [:]
        for (_, summary) in index {
            guard summary.first >= ends[summary.segment, default: 0] else {
                throw StreamFailure.storage("Raw chunks overlap.")
            }
            ends[summary.segment] = summary.end
        }
        return index.map(\.summary)
    }

    private func readChunkHeader(_ data: Data, url: URL) throws -> StreamChunkHeader? {
        guard let header = try? StreamFiles.decoder.decode(StreamChunkHeader.self, from: data) else { return nil }
        guard header.version == 2, header.summary.valid, header.summary.id.uuidString + ".json" == url.lastPathComponent,
              ProfileDigest.valid(header.frameIndexSHA256) else {
            throw StreamFailure.storage("A raw chunk summary is invalid.")
        }
        return header
    }

    private func validateChunk(_ item: StreamChunk, url: URL) throws -> StreamChunk {
        let stride = PicoAverage.stride(item.picoAveraging, board: item.board)
        let boundary = StreamWire.maxSampleBoundary / UInt64(item.picoAveraging?.count ?? 1)
        guard item.version == item.formatVersion, item.id.uuidString + ".json" == url.lastPathComponent,
              (2...Self.chunkLimit).contains(item.bytes), ProfileDigest.valid(item.sha256),
              (1...256).contains(item.slices.count) else {
            throw StreamFailure.storage("A raw chunk index is invalid.")
        }
        var offset = 0
        var end: UInt64 = 0
        for slice in item.slices {
            guard slice.byteOffset == offset, (1...StreamWire.maxSamples).contains(slice.count),
                  slice.first >= end, slice.first <= boundary - UInt64(slice.count),
                  (1...StreamWire.maxDeviceTimeUS).contains(slice.deviceEndUS) else {
                throw StreamFailure.storage("A raw chunk range is invalid.")
            }
            offset += stride * slice.count
            end = slice.first + UInt64(slice.count)
        }
        guard offset == item.bytes else { throw StreamFailure.storage("A chunk byte count did not reconcile.") }
        return item
    }

    func chunk(_ summary: StreamChunkSummary, run: StreamRun) throws -> StreamChunk {
        let folder = try StreamFiles.directory("chunks", in: runDirectory(run.id), create: false)
        let base = folder.appendingPathComponent(summary.id.uuidString)
        let url = base.appendingPathExtension("json")
        let index = try StreamFiles.read(url, limit: 1_048_576)
        let bytes: Data
        if let header = try readChunkHeader(index, url: url) {
            bytes = try StreamFiles.read(base.appendingPathExtension("frames"), limit: 1_048_576)
            guard StreamFiles.sha(bytes) == header.frameIndexSHA256 else {
                throw StreamFailure.storage("A frame index failed SHA-256 verification.")
            }
        } else {
            bytes = index
        }
        let value = try validateChunk(StreamFiles.decoder.decode(StreamChunk.self, from: bytes), url: url)
        guard StreamChunkSummary(value) == summary else {
            throw StreamFailure.storage("The raw index changed. Reopen the recording.")
        }
        return value
    }

    func data(_ chunk: StreamChunk, run: StreamRun) throws -> Data {
        try data(StreamChunkSummary(chunk), run: run)
    }

    func data(_ summary: StreamChunkSummary, run: StreamRun) throws -> Data {
        let parent = try StreamFiles.directory("chunks", in: runDirectory(run.id), create: false)
        return try RunCompression.read(parent.appendingPathComponent(summary.id.uuidString + ".bin"), summary: summary)
    }

    func exports() throws -> URL {
        try verify()
        return try StreamFiles.directory("Exports", in: folder, create: true)
    }
}

/// Only called on the writer queue. One commit can hold at most 512 KiB.
nonisolated final class StreamRunWriter: @unchecked Sendable {
    let store: StreamProjectStore
    private(set) var run: StreamRun
    private let directory: URL
    private let chunks: URL
    private var data = Data()
    private var slices: [StreamSlice] = []
    private var pendingChunk: StreamChunk?
    #if STREAM_TESTING
    var testAfterIndexPublication: (() throws -> Void)?
    #endif
    private var activeSegment: UUID
    private var pendingCandidates: [UnoCandidateBlock] = []
    private var candidateRawChunk: StreamChunk?
    private let candidateStorage = DispatchQueue(label: "SignalBench.device-candidates", qos: .utility)
    private let candidateStorageSlots = DispatchSemaphore(value: 2)
    #if STREAM_TESTING
    func waitForCandidateStorage() { candidateStorage.sync {} }
    #endif
    private var lock: StreamRunLock?
    private var segmentIndex: Int { run.segments.count - 1 }
    var segmentDuration: Double { max(0, run.settings.duration - run.segments[segmentIndex].timelineStart) }

    init(store: StreamProjectStore, run: StreamRun, stream: UInt64, firmware: String? = nil,
         continuationPrerun: CalibratedPrerun.Link? = nil) throws {
        guard run.curveSource == nil else { throw StreamFailure.storage("Curve runs are saved for diagnostic review.") }
        try store.verify()
        self.store = store
        directory = try store.runDirectory(run.id)
        lock = try StreamRunLock(directory)
        let persisted = try store.openRun(run.id, active: run.status == .recording)
        guard persisted == run else { throw StreamFailure.storage("This run changed. Reopen it before continuing.") }
        var updated = run
        var timeline: Double = 0
        if !run.segments.isEmpty {
            let previous = run.segments[run.segments.count - 1]
            let indexed = try store.chunkSummaries(run).filter { $0.segment == previous.id }
            for chunk in indexed {
                try Task.checkCancellation()
                try autoreleasepool {
                    _ = try store.chunk(chunk, run: run)
                    _ = try store.data(chunk, run: run)
                }
            }
            let prefix = indexed.last?.end ?? 0
            let saved = indexed.reduce(0) { $0 + UInt64($1.readingCount) }
            let accounted = max(prefix, previous.accountedSamples)
            timeline = previous.timelineStart + Double(accounted) / previous.configuredRate(run.settings.nominalRate)
            updated.segments[updated.segments.count - 1].savedSamples = saved
            updated.segments[updated.segments.count - 1].accountedSamples = accounted
            updated.segments[updated.segments.count - 1].knownLoss = accounted - saved
            if previous.manualQuality?.samples != saved {
                updated.segments[updated.segments.count - 1].manualQuality = nil
            }
        }
        guard run.settings.duration > timeline else {
            throw StreamFailure.storage("The requested duration is already accounted for. Create a new run to record again.")
        }
        try RecordingEstimate.requireSpace(for: run.settings, seconds: run.settings.duration - timeline, in: store.folder)
        var segment = StreamRunSegment(stream: stream, timelineStart: timeline, firmware: firmware,
                                       picoAveraging: run.settings.picoAveraging, acquisitionBoard: run.settings.acquisitionBoard)
        segment.prerun = run.segments.isEmpty ? run.settings.prerun ?? continuationPrerun : continuationPrerun
        activeSegment = segment.id
        updated.segments.append(segment)
        updated.status = .recording
        updated.message = nil
        self.run = updated
        chunks = try StreamFiles.directory("chunks", in: directory, create: true)
        try store.save(updated)
    }

    func changeDuration(_ change: StreamRun.DurationChange) throws -> StreamRun {
        guard run.status == .recording, run.settings.allowsLiveDurationEdit, change.valid,
              change.segment == activeSegment, change.previous == run.settings.duration,
              (run.durationChanges?.count ?? 0) < 256 else {
            throw StreamFailure.storage("The recording no longer accepts this duration change.")
        }
        var updated = run
        updated.settings.duration = change.target
        updated.durationChanges = (updated.durationChanges ?? []) + [change]
        try store.save(updated)
        run = updated
        return updated
    }

    func append(_ frame: StreamFrame) throws {
        guard frame.stream == run.segments[segmentIndex].stream else {
            throw StreamFailure.storage("The frame belongs to a different recording segment.")
        }
        switch frame.kind {
        case .start:
            guard run.segments[segmentIndex].firstDeviceUS == nil else {
                throw StreamFailure.storage("The recording segment already started.")
            }
            run.segments[segmentIndex].boot = frame.boot
            run.segments[segmentIndex].firstDeviceUS = frame.timeUS
            run.segments[segmentIndex].adcClock = StreamWire.read(UInt32.self, frame.payload, at: 0)
            run.segments[segmentIndex].divider256 = StreamWire.read(UInt32.self, frame.payload, at: 4)
            try store.save(run)
        case .samples:
            let averaging = run.settings.picoAveraging
            guard frame.payload.count == Int(frame.count) * PicoAverage.stride(averaging, board: run.settings.board) else {
                throw StreamFailure.storage("The reading format does not match the recording.")
            }
            if pendingChunk != nil || slices.count == 256 || data.count + frame.payload.count > StreamProjectStore.chunkLimit {
                try commit()
            }
            let previousEnd = slices.last.map { $0.first + UInt64($0.count) } ?? run.segments[segmentIndex].accountedSamples
            guard run.segments[segmentIndex].firstDeviceUS != nil, frame.index >= previousEnd else {
                throw StreamFailure.storage("The sample frame overlaps an existing recording range.")
            }
            slices.append(.init(first: frame.index, count: Int(frame.count), byteOffset: data.count,
                                sequence: frame.sequence, deviceEndUS: frame.timeUS))
            data.append(frame.payload)
            // Bound the uncommitted interval as well as the byte count for AVG1.
            // At the raw ceiling 256 frames span just over one second.
            if data.count == StreamProjectStore.chunkLimit ||
                (averaging != nil && frame.timeUS >= (slices.first?.deviceEndUS ?? frame.timeUS) + 1_000_000) {
                try commit()
            }
        case .gpio:
            try store.verify()
            let location = try StreamFiles.directory("gpio", in: directory, create: true)
            let record = StreamGPIO(segment: activeSegment, deviceUS: frame.timeUS, completedSampleBoundary: frame.index,
                                    directions: StreamWire.read(UInt32.self, frame.payload, at: 0),
                                    levels: StreamWire.read(UInt32.self, frame.payload, at: 4),
                                    latches: StreamWire.read(UInt32.self, frame.payload, at: 8),
                                    leaseActive: StreamWire.read(UInt32.self, frame.payload, at: 12) == 1)
            try StreamFiles.publish(record, at: location.appendingPathComponent("\(activeSegment.uuidString)-\(frame.sequence).json"))
            run.segments[segmentIndex].gpioEvents += 1
            run.segments[segmentIndex].manualOutputsReleased = !record.leaseActive && record.directions == 0
        case .end, .health, .candidates: break
        }
    }

    func noteStartup(_ evidence: StreamStartupEvidence) throws {
        run.segments[segmentIndex].startup = evidence
        try store.save(run)
    }

    func appendCandidates(_ block: UnoCandidateBlock) {
        guard run.settings.unoCandidates != nil, pendingCandidates.count < 512 else { return }
        pendingCandidates.append(block)
    }

    private func publishCandidates(_ chunk: StreamChunk) {
        guard let settings = run.settings.unoCandidates, !pendingCandidates.isEmpty,
              let end = chunk.slices.last.map({ $0.first + UInt64($0.count) }) else { return }
        let boundaries = Set(chunk.slices.filter { $0.count == Int(UnoCandidateBlock.width) }.map(\.first))
        let eligible = pendingCandidates.filter { boundaries.contains($0.first) }
        pendingCandidates.removeAll { $0.end <= end }
        guard !eligible.isEmpty else { return }
        // Do not wait for sidecar I/O on the raw writer. The raw checkpoint
        // has already synced. A skipped sidecar is missing candidate coverage.
        guard candidateStorageSlots.wait(timeout: .now()) == .success else { return }
        let archive = UnoCandidateArchive(segment: activeSegment, stream: run.segments[segmentIndex].stream,
            rawChunk: chunk.id, rawSHA256: chunk.sha256, settings: settings, blocks: eligible)
        let slots = candidateStorageSlots
        candidateStorage.async { [store, directory] in
            defer { slots.signal() }
            do {
                try store.verify()
                let folder = try StreamFiles.directory("device-candidates", in: directory, create: true)
                try StreamFiles.publish(archive, at: folder.appendingPathComponent(chunk.id.uuidString + ".json"))
            } catch { }
        }
    }

    func commit() throws {
        guard !slices.isEmpty, let last = slices.last else { return }
        try store.verify()
        let averaging = run.settings.picoAveraging
        let unoAverage = averaging != nil && run.settings.board == .unoR4
        let chunk = pendingChunk ?? StreamChunk(version: averaging == nil ? 1 : (unoAverage ? 3 : 2),
                                               segment: activeSegment, bytes: data.count, sha256: StreamFiles.sha(data),
                                               slices: slices, picoAveraging: averaging, averagingBoard: unoAverage ? .unoR4 : nil)
        pendingChunk = chunk
        let base = chunks.appendingPathComponent(chunk.id.uuidString)
        let raw = base.appendingPathExtension("bin")
        let index = base.appendingPathExtension("json")
        if try StreamFiles.isPresent(raw) {
            guard try StreamFiles.read(raw, limit: StreamProjectStore.chunkLimit) == data else {
                throw StreamFailure.storage("A checkpoint retry found different raw bytes.")
            }
        } else {
            try StreamFiles.publish(data, at: raw)
        }
        let frames = base.appendingPathExtension("frames")
        let frameIndex = try StreamFiles.encoder.encode(chunk)
        if try StreamFiles.isPresent(frames) {
            guard try StreamFiles.read(frames, limit: 1_048_576) == frameIndex else {
                throw StreamFailure.storage("A checkpoint retry found different frame anchors.")
            }
        } else {
            try StreamFiles.publish(frameIndex, at: frames)
        }
        let header = StreamChunkHeader(summary: StreamChunkSummary(chunk), frameIndexSHA256: StreamFiles.sha(frameIndex))
        if try StreamFiles.isPresent(index) {
            guard try StreamFiles.read(StreamChunkHeader.self, index) == header else {
                throw StreamFailure.storage("A checkpoint retry found a different index.")
            }
        } else {
            try StreamFiles.publish(header, at: index)
        }
        #if STREAM_TESTING
        try testAfterIndexPublication?()
        #endif
        // A rename can succeed before the containing directory sync fails.
        // Retrying verifies the same UUID and bytes before counting them.
        try StreamFiles.sync(chunks)
        pendingChunk = nil
        run.segments[segmentIndex].savedSamples += UInt64(chunk.bytes / PicoAverage.stride(averaging, board: chunk.board))
        run.segments[segmentIndex].accountedSamples = last.first + UInt64(last.count)
        if run.settings.mode == .manual || run.settings.mode == .manualRaw {
            var quality = run.segments[segmentIndex].manualQuality ?? ManualSampleQuality()
            try quality.append(data, averaging: averaging, board: run.settings.board)
            run.segments[segmentIndex].manualQuality = quality
        }
        data.removeAll(keepingCapacity: true)
        slices.removeAll(keepingCapacity: true)
        try store.save(run)
        if run.settings.unoCandidates != nil {
            if let earlier = candidateRawChunk { publishCandidates(earlier) }
            candidateRawChunk = chunk
        }
    }

    @discardableResult
    func finish(accounting: StreamAccounting, issue: String?, discardUncommitted: Bool = false, deadlineReached: Bool? = nil, startup: StreamStartupEvidence? = nil) throws -> StreamRun {
        defer { lock = nil }
        if !discardUncommitted { try commit() }
        if discardUncommitted, let pendingChunk,
           try StreamFiles.isPresent(chunks.appendingPathComponent(pendingChunk.id.uuidString).appendingPathExtension("json")) {
            // Recover a checkpoint whose index reached disk before the
            // failure. The original bytes and UUID must still match.
            try commit()
        }
        if let committed = candidateRawChunk { publishCandidates(committed) }
        var segment = run.segments[segmentIndex]
        let end = accounting.end
        let reconciled = end != nil && segment.savedSamples == accounting.received
        segment.accountedSamples = max(segment.accountedSamples, accounting.nextIndex)
        segment.knownLoss = accounting.knownLoss + (accounting.received - min(accounting.received, segment.savedSamples))
        segment.finalDeviceUS = end?.timeUS
        segment.measuredByPicoTimer = accounting.sampleCadenceEstimate
        segment.cadenceWindowUS = accounting.cadenceWindowUS
        segment.firmwareQueuePeak = accounting.firmwareQueuePeak
        segment.firmwareStopCode = end?.auxiliary
        segment.hostQueuePeak = accounting.hostQueuePeak
        segment.maximumWriterUS = accounting.maximumWriterUS
        segment.candidatePeakUS = accounting.candidatePeakUS
        segment.maximumPackingUS = accounting.maximumPackingUS
        segment.maximumUSBBackpressureUS = accounting.maximumUSBBackpressureUS
        segment.totalUSBBackpressureUS = accounting.totalUSBBackpressureUS
        segment.unknown = end.map { $0.flags & 1 != 0 } ?? true
        let complete = issue == nil && reconciled && !segment.unknown && segment.knownLoss == 0 && end?.auxiliary == 0
        segment.deadlineReached = deadlineReached
        if let startup { segment.startup = startup }
        segment.endReason = issue ?? (complete ? "Stop reconciled" :
            end.flatMap { StreamRunSegment.stopReason($0.auxiliary, board: run.settings.board) } ?? "The stream ended before a clean stop.")
        run.segments[segmentIndex] = segment
        let wholeRunComplete = complete && run.segments.count == 1
        run.status = wholeRunComplete ? .complete : .interrupted
        run.message = complete && !wholeRunComplete
            ? "The new segment was saved. This run includes an earlier interruption and unknown time between segments."
            : segment.endReason
        try store.save(run)
        return run
    }
}
