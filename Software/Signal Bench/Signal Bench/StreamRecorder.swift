import Darwin
import Foundation

nonisolated struct LiveStreamPreview: Sendable {
    var columns: [ClosedRange<UInt16>?] = []
    var elapsed: Double = 0
    var received: UInt64 = 0
    var saved: UInt64 = 0
    var committedBoundary: UInt64 = 0
    var adcErrors: UInt64 = 0
    var loss: UInt64 = 0
    var rateByPicoTimer: Double?
    var configuredRate: Double?
    var lowRail: UInt64 = 0
    var highRail: UInt64 = 0
    var gpio: StreamGPIO?
    var baseline: Double?
    var noise: Double?
    var baselineChange: Double?
    var clipped: Int?
    var manualTimeUpper: Double?
    var latestCode: UInt16?
    var latestAverage: ADCAveraging.Group?
    var waveformFaults: [Bool] = []
    var waveformBins: [LiveWaveformBin] = []
    var waveformSamples: [WaveformSample] = []
    var waveformBinSeconds = 0.005
    var waveformOverview: LiveWaveformOverview?
    var waveformSegmentStart = 0.0
    var waveformBoundary: Double?

    mutating func accountQuality(_ frame: StreamFrame, board: AcquisitionBoard) {
        var clippedReadings = 0
        if let groups = frame.groups {
            for group in groups {
                adcErrors += UInt64(group.adcErrors)
                lowRail += UInt64(group.lowRail)
                highRail += UInt64(group.highRail)
                if group.lowRail + group.highRail > 0 { clippedReadings += 1 }
            }
        } else {
            let maximum = board.maxCode
            frame.payload.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 2) {
                    let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    if word & 0x8000 != 0 { adcErrors += 1; continue }
                    let code = word & maximum
                    if code == 0 { lowRail += 1; clippedReadings += 1 }
                    if code == maximum { highRail += 1; clippedReadings += 1 }
                }
            }
        }
        clipped = clippedReadings
    }
}

nonisolated struct LiveWaveformBin: Sendable {
    var range: ClosedRange<UInt16>?
    var count = 0
    var lowRail = 0
    var highRail = 0
    var errors = 0
    var codeSum = 0.0
    var usable = 0
    var gap = false
    var clipped = 0

    init(gap: Bool = false) { self.gap = gap }

    init(range: ClosedRange<UInt16>?, count: Int, clipped: Int, errors: Int, gap: Bool) {
        self.init(gap: gap)
        self.range = range
        self.count = count
        lowRail = range?.lowerBound == 0 ? clipped : 0
        highRail = clipped - lowRail
        self.clipped = clipped
        self.errors = errors
        usable = max(0, count - errors)
    }

    init(_ words: Data, board: AcquisitionBoard) {
        self.init()
        words.withUnsafeBytes { bytes in
            let samples = stride(from: 0, to: bytes.count, by: 2).lazy.map {
                UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt16.self))
            }
            append(samples, board: board)
        }
    }

    mutating func append<S: Sequence>(_ words: S, board: AcquisitionBoard = .picoW) where S.Element == UInt16 {
        var low = range?.lowerBound ?? UInt16.max
        var high = range?.upperBound ?? 0
        for word in words {
            count += 1
            if word & 0x8000 != 0 { errors += 1; continue }
            let code = board.sampleCode(word)
            usable += 1
            codeSum += Double(code)
            if code == 0 { lowRail += 1; clipped += 1 }
            if code == board.maxCode { highRail += 1; clipped += 1 }
            low = min(low, code)
            high = max(high, code)
        }
        if low <= high { range = low...high }
    }

    mutating func append(_ groups: ArraySlice<ADCAveraging.Group>) {
        for group in groups {
            count += 1
            if group.adcErrors > 0 { errors += 1 }
            if group.lowRail > 0 { lowRail += 1 }
            if group.highRail > 0 { highRail += 1 }
            if group.lowRail + group.highRail > 0 { clipped += 1 }
            guard let mean = group.mean else { continue }
            let code = UInt16(mean.rounded())
            usable += 1
            codeSum += mean
            let existing = range ?? code...code
            range = min(existing.lowerBound, code)...max(existing.upperBound, code)
        }
    }

    mutating func merge(_ bin: Self) {
        if let values = bin.range {
            let existing = range ?? values
            range = min(existing.lowerBound, values.lowerBound)...max(existing.upperBound, values.upperBound)
        }
        count += bin.count
        codeSum += bin.codeSum
        lowRail += bin.lowRail
        highRail += bin.highRail
        errors += bin.errors
        usable += bin.usable
        clipped += bin.clipped
        gap = gap || bin.gap
    }
}

// A rolling display envelope keyed by the original ADC sample index.
// The writer receives each full frame independently of these bins.
nonisolated struct ManualLiveWindow {
    static let binsPerSecond = 200
    static let capacity = 30 * binsPerSecond

    private struct Bin {
        var index: UInt64
        var summary = LiveWaveformBin()
    }

    private let samplesPerBin: UInt64
    let binSeconds: Double
    private var bins = [Bin?](repeating: nil, count: capacity)
    private(set) var end: UInt64 = 0
    private(set) var overview: LiveWaveformOverview

    init(rate: Int) { self.init(configuredRate: Double(rate)) }

    init(configuredRate: Double) {
        samplesPerBin = UInt64(max(1, (configuredRate / Double(Self.binsPerSecond)).rounded()))
        binSeconds = Double(samplesPerBin) / configuredRate
        overview = .init(samplesPerBin: samplesPerBin)
    }

    mutating func append(_ words: [UInt16], at first: UInt64, groups: [ADCAveraging.Group]? = nil, board: AcquisitionBoard = .picoW) {
        if first > end {
            if end % samplesPerBin != 0 { markGap(end / samplesPerBin) }
            if first % samplesPerBin != 0 { markGap(first / samplesPerBin) }
        }
        var offset = 0
        while offset < words.count {
            let index = first + UInt64(offset)
            let id = index / samplesPerBin
            let slot = Int(id % UInt64(Self.capacity))
            let stop = min(words.count, offset + Int(samplesPerBin - index % samplesPerBin))
            var bin = bins[slot].flatMap { $0.index == id ? $0 : nil } ?? Bin(index: id)
            var delta = LiveWaveformBin()
            if let groups { delta.append(groups[offset..<stop]) }
            else { delta.append(words[offset..<stop], board: board) }
            bin.summary.merge(delta)
            overview.append(delta, first: index, count: UInt64(stop - offset))
            bins[slot] = bin
            offset = stop
        }
        end = first + UInt64(words.count)
    }

    private mutating func markGap(_ id: UInt64) {
        let slot = Int(id % UInt64(Self.capacity))
        var bin = bins[slot].flatMap { $0.index == id ? $0 : nil } ?? Bin(index: id)
        bin.summary.gap = true
        bins[slot] = bin
    }

    func snapshot() -> (columns: [ClosedRange<UInt16>?], upper: Double, faults: [Bool], bins: [LiveWaveformBin])? {
        guard end > 0 else { return nil }
        let last = (end - 1) / samplesPerBin
        let count = UInt64(Self.capacity)
        let start = last + 1 - min(last + 1, count)
        let summaries = (start...last).map { index in
            let bin = bins[Int(index % count)]
            return bin?.index == index ? bin?.summary ?? .init(gap: true) : .init(gap: true)
        }
        return (summaries.map { $0.gap ? nil : $0.range }, Double(last + 1) * binSeconds,
                summaries.map { $0.errors > 0 }, summaries)
    }
}

nonisolated enum StreamRecorderEvent: Sendable {
    case streamCapabilities(averaging: Bool)
    case connecting
    case connected(streaming: Bool, firmware: String, pending: Bool, rates: Set<Int>, diagnosticChannels: Set<Int>, customRates: Bool)
    case disconnected(String)
    case started(StreamRun)
    case preview(LiveStreamPreview)
    case stopping(String)
    case finished(StreamRun?, issue: String?)
}

nonisolated final class StreamRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SignalBench.stream.transport", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let disk = DispatchQueue(label: "SignalBench.stream.writer", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let allowBenchmark: Bool
    private let event: @Sendable (StreamRecorderEvent) -> Void
    private var fd: Int32 = -1
    private var portGeneration = UUID()
    private var sleeping = false
    private var input: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var board: AcquisitionBoard = .picoW
    private var connected = false
    private var streaming = false
    private var identityBoot: UInt64?
    private var negotiatedRates: Set<Int> = []
    private var negotiatedChannels: Set<Int> = []
    private var negotiatedCustomRates = false
    private var negotiatedAveraging = false
    private var negotiatedTiming = false
    private var handshakeAt: UInt64 = 0
    private var headerText = Data()
    private var output: [Data] = []
    private var outputOffset = 0
    private var active: Active?
    private var previewInterval: UInt64 = 100_000_000
    private var showViewer = true

    func configureViewer(shown: Bool, fps: Int) {
        queue.async {
            self.showViewer = shown
            self.previewInterval = 1_000_000_000 / UInt64(max(5, min(60, fps)))
            if !shown {
                self.active?.preview.waveformOverview = nil
                self.active?.preview.waveformBins = []
                self.active?.preview.columns = []
                self.active?.preview.waveformSamples = []
            }
        }
    }
    private var openingRun = false
    private var stopWhileOpening = false
    private var disconnectAfterFinish = false

    private final class Active: @unchecked Sendable {
        let id: UUID
        let writer: StreamRunWriter
        let duration: Double
        let slots = DispatchSemaphore(value: 12)
        let metricsLock = NSLock()
        var queued = 0
        var queuePeak = 0
        var maxWriterUS: UInt64 = 0
        var parser: StreamParser
        var accounting: StreamAccounting
        var issue: String?
        var preview = LiveStreamPreview()
        var manualWindow: ManualLiveWindow?
        var startedAt: UInt64?
        var lastSampleAt: UInt64?
        var discardIncoming = false
        var deferredRelease: StreamFrame?
        var requestAt: UInt64
        var stopAt: UInt64?
        var deadlineReached = false
        var pingAt: UInt64
        var publishAt: UInt64
        var parserFailed = false
        var finishing = false
        var flagHistory: LiveFlagHistory?
        var diskError: String? // Used only by the writer queue.
        var diskPublishedSamples: UInt64 = 0
        var run: StreamRun

        init(_ writer: StreamRunWriter, stream: UInt64, now: UInt64, timing: Bool) {
            self.writer = writer
            duration = writer.segmentDuration
            run = writer.run
            id = run.id
            let settings = run.settings
            accounting = .init(stream: stream, channel: settings.channel, rate: settings.nominalRate, averaging: settings.picoAveraging, board: settings.board)
            parser = .init(allowsPacked: settings.board == .unoR4 ? settings.nominalRate >= 250_000 : StreamWire.requiresPacking(settings.nominalRate), averaging: settings.picoAveraging, timing: timing, board: settings.board)
            requestAt = now
            pingAt = now
            publishAt = now
        }
    }

    init(allowBenchmark: Bool = false, event: @escaping @Sendable (StreamRecorderEvent) -> Void) {
        self.allowBenchmark = allowBenchmark
        self.event = event
    }
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    func connect(to path: String, board: AcquisitionBoard = .picoW) {
        #if STREAM_TESTING
        let supported = Self.ports().contains(path) || path.hasPrefix("/dev/ttys")
        #else
        let supported = Self.ports().contains(path)
        #endif
        queue.async { [self] in
            guard self.fd < 0, self.active == nil, !self.openingRun, !self.sleeping, supported else { return }
            self.board = board
            self.event(.connecting)
            let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { self.event(.disconnected("Could not open the device’s USB port.")); return }
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else {
                Darwin.close(fd); self.event(.disconnected("Could not configure the device’s USB port.")); return
            }
            cfmakeraw(&settings)
            settings.c_cflag |= UInt(CLOCAL | CREAD)
            cfsetspeed(&settings, speed_t(B115200))
            guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
                Darwin.close(fd); self.event(.disconnected("Could not configure the device’s USB port.")); return
            }
            _ = ioctl(fd, TIOCEXCL)
            _ = tcflush(fd, TCIOFLUSH)
            self.fd = fd
            let generation = UUID()
            self.portGeneration = generation
            self.handshakeAt = self.now
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            read.setEventHandler { [weak self] in
                guard let self, self.portGeneration == generation else { return }
                self.receive()
            }
            self.input = read
            read.resume()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, self.portGeneration == generation else { return }
                self.tick()
            }
            self.timer = timer
            timer.resume()
            if board == .unoR4 { var modem = Int32(TIOCM_DTR); _ = ioctl(fd, TIOCMBIS, &modem) }
            self.enqueue(Data("?".utf8))
        }
    }

    func start(store: StreamProjectStore, run: StreamRun, continuationPrerun: CalibratedPrerun.Link? = nil) {
        queue.async {
            guard self.connected, self.streaming, self.active == nil, !self.openingRun, !self.sleeping else {
                self.event(.finished(run, issue: "Connect the streaming firmware before recording."))
                return
            }
            let settings = run.settings
            guard settings.board == self.board else {
                self.event(.finished(run, issue: "The connected board does not match this run."))
                return
            }
            let bench = settings.benchSampling == true || (self.allowBenchmark && settings.purpose == "rateBenchmark")
            guard settings.picoAveraging == nil || self.negotiatedAveraging else {
                self.event(.finished(run, issue: "This average requires Pico firmware with AVG1 support. Choose 1× or connect firmware 1.10."))
                return
            }
            let legacyBench = self.discoveredFirmware == "1.7-bench"
            guard self.negotiatedRates.contains(settings.nominalRate) ||
                  (self.negotiatedCustomRates && StreamWire.customRates.contains(settings.nominalRate)),
                  self.negotiatedChannels.contains(settings.channel),
                  settings.board.standardRate(settings.nominalRate, channel: settings.channel) || bench,
                  !legacyBench || (settings.channel == 0 && settings.mode.wireMode == "RAW") else {
                self.event(.finished(run, issue: "This rate or channel is unavailable for the recording mode."))
                return
            }
            self.openingRun = true
            self.stopWhileOpening = false
            let token = UInt64.random(in: 1...UInt64.max)
            let firmware = self.discoveredFirmware
            let generation = self.portGeneration
            self.disk.async {
                let candidate = Result { try StreamRunWriter(store: store, run: run, stream: token, firmware: firmware, continuationPrerun: continuationPrerun) }
                self.queue.async {
                    self.openingRun = false
                    switch candidate {
                    case .success(let writer):
                        let active = Active(writer, stream: token, now: self.now, timing: self.negotiatedTiming)
                        self.active = active
                        if self.stopWhileOpening {
                            self.finish(active, issue: "Stopped before recording started.")
                            return
                        }
                        guard self.connected, self.streaming, !self.sleeping, self.portGeneration == generation else {
                            self.finish(active, issue: "USB disconnected before recording started.")
                            return
                        }
                        let settings = run.settings
                        let packing: String
                        if settings.board == .unoR4 { packing = settings.nominalRate >= 250_000 ? " PACK14" : " RAW14" }
                        else if let averaging = settings.picoAveraging { packing = " AVG1 \(averaging.count)" }
                        else {
                            packing = (StreamWire.requiresPacking(settings.nominalRate) ? " PACK12" : "") +
                                (self.negotiatedTiming ? " METRICS" : "")
                        }
                        let command = "SB1 STREAM \(String(format: "%016llx", token)) \(settings.channel) \(settings.mode.wireMode) \(settings.nominalRate)\(packing)\n"
                        self.enqueue(Data(command.utf8))
                    case .failure(let error):
                        self.event(.finished(run, issue: error.localizedDescription))
                    }
                }
            }
        }
    }

    func stop() {
        queue.async {
            if let active = self.active { self.requestStop(active, issue: nil) }
            else if self.openingRun { self.stopWhileOpening = true }
        }
    }

    #if STREAM_TESTING
    func delayWriterForTest(_ seconds: TimeInterval) {
        disk.async { Thread.sleep(forTimeInterval: seconds) }
    }
    #endif

    func sleepStarted() {
        queue.async {
            self.sleeping = true
            self.stopWhileOpening = self.openingRun
            if let active = self.active {
                self.disconnectAfterFinish = true
                self.requestStop(active, issue: "Mac sleep interrupted the recording. Reconnect to continue in a new segment.")
            } else if self.fd >= 0 {
                self.lost("Mac sleep closed the USB connection.")
            }
        }
    }

    func woke() {
        queue.async {
            self.sleeping = false
            guard self.fd >= 0 else { return }
            self.lost("Mac sleep interrupted the USB connection. Reconnect to continue in a new segment.")
        }
    }

    func disconnect() {
        queue.async {
            if let active = self.active {
                self.disconnectAfterFinish = true
                self.requestStop(active, issue: nil)
            } else {
                self.closePort()
                self.event(.disconnected("Disconnected"))
            }
        }
    }

    func pin(_ pin: Int, operation: UInt8) {
        queue.async {
            guard let run = self.active, run.startedAt != nil, run.stopAt == nil,
                  run.preview.gpio?.leaseActive == true, run.run.settings.mode == .manual, (0..<29).contains(pin),
                  run.run.settings.board.gpioMask & (UInt32(1) << pin) != 0, (3...5).contains(operation) else { return }
            self.enqueue(StreamWire.control(operation, stream: run.accounting.stream, pin: UInt8(pin)))
        }
    }

    func freezeFlagWindow(run: UUID, at instant: UInt64, date: Date,
                          completion: @escaping @Sendable (FrozenFlagWaveform?) -> Void) {
        queue.async {
            guard let active = self.active, active.id == run, let segment = active.run.segments.last else {
                completion(nil)
                return
            }
            completion(active.flagHistory?.freeze(at: instant, date: date, segment: segment))
        }
    }

    func captureWaveform(run: UUID, at instant: UInt64, date: Date, seconds: Double,
                         completion: @escaping @Sendable (LiveWaveformCapture?) -> Void) {
        queue.async {
            guard let active = self.active, active.id == run, let segment = active.run.segments.last,
                  let raw = active.flagHistory?.freeze(at: instant, date: date, segment: segment, seconds: seconds) else {
                completion(nil)
                return
            }
            completion(.init(raw: raw, overview: active.manualWindow?.overview))
        }
    }

    func releaseOutputs() {
        queue.async {
            guard let run = self.active, run.startedAt != nil, run.run.settings.mode == .manual, run.stopAt == nil, !run.finishing else { return }
            self.prioritize(StreamWire.control(6, stream: run.accounting.stream))
        }
    }

    private func closePort() {
        portGeneration = UUID()
        input?.cancel()
        input = nil
        timer?.cancel()
        timer = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        connected = false
        streaming = false
        identityBoot = nil
        negotiatedRates = []
        negotiatedCustomRates = false
        negotiatedAveraging = false
        negotiatedTiming = false
        negotiatedChannels = []
        output = []
        outputOffset = 0
        headerText.removeAll(keepingCapacity: true)
        discoveredFirmware = nil
    }

    private func enqueue(_ message: Data) {
        guard fd >= 0, output.count < 32 else { return }
        output.append(message)
        write()
    }

    private func prioritize(_ message: Data) {
        // Retain a partly written frame, then drop queued pin and ping commands.
        if outputOffset > 0, let current = output.first { output = [current] }
        else { output.removeAll(keepingCapacity: true); outputOffset = 0 }
        enqueue(message)
    }

    private func write() {
        while fd >= 0, let message = output.first {
            let offset = outputOffset
            let n = message.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), message.count - offset) }
            if n > 0 {
                outputOffset += n
                if outputOffset == message.count { output.removeFirst(); outputOffset = 0 }
            } else if n < 0 && errno == EINTR { continue }
            else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { lost("The USB write failed."); return }
        }
    }

    private func tick() {
        write()
        let now = self.now
        if !connected, fd >= 0, now - handshakeAt >= 4_000_000_000 {
            lost("The device did not answer the Signal Bench identity probe.")
        }
        guard let active, !active.finishing else { return }
        if let stopAt = active.stopAt {
            if now - stopAt >= 5_000_000_000 {
                closePort()
                finish(active, issue: active.issue ?? "The final stream counters did not arrive.")
            }
            return
        }
        if let started = active.startedAt {
            if let lastSample = active.lastSampleAt, now - lastSample >= 2_000_000_000 {
                disconnectAfterFinish = true
                requestStop(active, issue: "The device stopped sending samples. Reconnect to continue in a new segment.")
                return
            }
            if Double(now - started) / 1e9 >= active.duration {
                active.deadlineReached = true
                requestStop(active, issue: nil)
                return
            }
        } else if now - active.requestAt >= 5_000_000_000 {
            requestStop(active, issue: "The stream start timed out.")
            return
        }
        if !sleeping, active.startedAt != nil, now - active.pingAt >= 1_000_000_000 {
            active.pingAt = now
            enqueue(StreamWire.control(2, stream: active.accounting.stream))
        }
    }

    private func receive() {
        var bytes = [UInt8](repeating: 0, count: 32_768)
        // Limit reads per event so control and timers always get serviced.
        for _ in 0..<4 {
            guard fd >= 0 else { return }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { lost("USB disconnected. The committed recording prefix is available."); return }
            let data = Data(bytes.prefix(count))
            if let active {
                guard !active.parserFailed && !active.finishing else { continue }
                do {
                    // Avoid an overlapping access to Active while the frame
                    // decoder is invoking the handler.
                    var parser = active.parser
                    try parser.append(data) { try self.consume($0, active: active) }
                    active.parser = parser
                } catch {
                    active.parserFailed = true
                    requestStop(active, issue: error.localizedDescription)
                }
            } else {
                receiveIdentity(data)
            }
        }
    }

    private func receiveIdentity(_ data: Data) {
        guard !connected else { return }
        guard headerText.count + data.count <= 4096 else { lost("Invalid device identity response."); return }
        headerText.append(data)
        while let end = headerText.firstIndex(of: 10) {
            let line = String(decoding: headerText[..<end], as: UTF8.self)
            headerText.removeSubrange(...end)
            if line.hasPrefix("SB1 HELLO ") {
                let fields = line.split(whereSeparator: \.isWhitespace).dropFirst(2)
                let dictionary = SBRecordAssembler.fields(fields)
                let advertisesStream = dictionary["stream"] == "1"
                let boot = dictionary["boot_id"].flatMap { UInt64($0, radix: 16) }.flatMap { $0 == 0 ? nil : $0 }
                guard dictionary["version"] == "1", dictionary["target"] == board.rawValue, dictionary["fixture"] == "0",
                      board == .picoW || (dictionary["adc"] == "raw14" && dictionary["pack14"] == "1"),
                      let firmware = dictionary["firmware"], (1...32).contains(firmware.utf8.count),
                      !advertisesStream || boot != nil else {
                    lost("The selected port did not identify as \(board.title) with Signal Bench firmware."); return
                }
                identityBoot = boot
                streaming = advertisesStream && (dictionary["bench_rates"] != "1" || allowBenchmark)
                if let rates = dictionary["rates"], let channels = dictionary["diag_channels"] {
                    negotiatedRates = Set(rates.split(separator: ",").compactMap { Int($0) }).intersection(board.benchRates)
                    // Maximum rate requires the negotiated packed USB path.
                    // Earlier builds stay usable at their lower rates.
                    if board == .picoW && dictionary["pack12"] != "1" {
                        negotiatedRates = negotiatedRates.filter { !StreamWire.requiresPacking($0) }
                    }
                    negotiatedCustomRates = board == .picoW && dictionary["pack12"] == "1" && dictionary["custom_rates"] == "10000-500000"
                    negotiatedChannels = Set(channels.split(separator: ",").compactMap { Int($0) }).intersection([0, 1, 2])
                    streaming = streaming && !negotiatedRates.isEmpty && negotiatedChannels.contains(0)
                } else if board == .unoR4 || dictionary["rates"] != nil || dictionary["diag_channels"] != nil || firmware == "1.8" || firmware.hasPrefix("1.8.") {
                    lost("The device rate capabilities are incomplete.")
                    return
                } else {
                    negotiatedRates = dictionary["bench_rates"] == "1" && allowBenchmark ? [StreamWire.rate, 250_000] : [StreamWire.rate]
                    negotiatedChannels = dictionary["bench_rates"] == "1" ? [0] : [0, 1, 2]
                }
                // Consume the STATUS line emitted immediately after HELLO
                // before exposing the device as ready for binary negotiation.
                negotiatedTiming = board == .picoW && dictionary["stream_timing"] == "1"
                negotiatedAveraging = negotiatedTiming && dictionary["avg_stream"] == "1"
                discoveredFirmware = firmware
            } else if line.hasPrefix("SB1 STATUS "), let firmware = discoveredFirmware {
                let fields = SBRecordAssembler.fields(line.split(whereSeparator: \.isWhitespace).dropFirst(2))
                guard let pending = fields["pending"] else { lost("The device status is missing its pending-record state."); return }
                connected = true
                streaming = streaming && (pending == "-" || pending == "0")
                event(.streamCapabilities(averaging: streaming && negotiatedAveraging))
                event(.connected(streaming: streaming, firmware: firmware, pending: pending != "-" && pending != "0",
                                 rates: streaming ? negotiatedRates : [], diagnosticChannels: streaming ? negotiatedChannels : [],
                                 customRates: streaming && negotiatedCustomRates))
                return
            }
        }
    }
    private var discoveredFirmware: String?

    private func consume(_ frame: StreamFrame, active: Active) throws {
        guard frame.boot == identityBoot else { throw StreamFailure.protocolError("The device boot identity changed.") }
        try active.accounting.accept(frame)
        if frame.kind == .start {
            active.preview.configuredRate = active.accounting.configuredRate
            if let rate = active.accounting.configuredRate {
                let window = ManualLiveWindow(configuredRate: rate)
                active.manualWindow = window
                active.flagHistory = .init(rate: rate, averaging: active.run.settings.picoAveraging)
                active.preview.waveformBinSeconds = window.binSeconds
            }
            active.startedAt = now
            active.lastSampleAt = active.startedAt
            if active.stopAt == nil { event(.started(active.run)) }
        }
        if frame.kind == .end {
            active.preview.loss = active.accounting.knownLoss
            event(.preview(active.preview))
            finish(active, issue: active.issue)
            return
        }
        if frame.kind == .gpio {
            guard active.run.settings.mode == .manual else { throw StreamFailure.protocolError("Unexpected GPIO frame.") }
            active.preview.gpio = .init(segment: active.run.segments.last!.id, deviceUS: frame.timeUS,
                                        completedSampleBoundary: frame.index,
                                        directions: StreamWire.read(UInt32.self, frame.payload, at: 0),
                                        levels: StreamWire.read(UInt32.self, frame.payload, at: 4),
                                        latches: StreamWire.read(UInt32.self, frame.payload, at: 8),
                                        leaseActive: StreamWire.read(UInt32.self, frame.payload, at: 12) == 1)
        }
        if frame.kind == .samples {
            let receivedAt = now
            active.lastSampleAt = receivedAt
            active.flagHistory?.append(first: frame.index, at: receivedAt, words: frame.payload)
            let shouldPublish = now - active.publishAt >= previewInterval
            let board = active.run.settings.board
            let words = showViewer || shouldPublish ? frame.words : []
            active.preview.accountQuality(frame, board: board)
            if showViewer { active.manualWindow?.append(words, at: frame.index, groups: frame.groups, board: board) }
            if shouldPublish {
                active.preview.latestAverage = frame.groups?.last ?? active.run.settings.adcAveraging?.latest(in: words, at: frame.index)
                do {
                    let last = active.preview.baseline
                    let good = frame.groups?.compactMap(\.mean) ?? words.compactMap { word -> Double? in
                        let code = board.sampleCode(word)
                        return word & 0x8000 == 0 && code > 0 && code < board.maxCode ? Double(code) : nil
                    }
                    let baseline = ProfileAnalyzer.median(good)
                    active.preview.baseline = baseline
                    active.preview.noise = baseline.flatMap { center in ProfileAnalyzer.median(good.map { abs($0 - center) }) }
                        .map { $0 * 1.4826 }
                    active.preview.baselineChange = baseline.flatMap { value in last.map { value - $0 } }
                }
                if showViewer, let timeline = active.manualWindow?.snapshot(), let rate = active.accounting.configuredRate {
                    active.preview.columns = timeline.columns
                    active.preview.manualTimeUpper = timeline.upper
                    active.preview.waveformFaults = timeline.faults
                    active.preview.waveformBins = timeline.bins
                    active.preview.waveformOverview = active.manualWindow?.overview
                    let segmentStart = active.run.segments.last?.timelineStart ?? 0
                    active.preview.waveformSegmentStart = segmentStart
                    active.preview.waveformBoundary = segmentStart + Double(frame.index + UInt64(words.count)) / rate
                    let first = max(0, words.count - 256)
                    active.preview.waveformSamples = words.indices.suffix(from: first).map { offset in
                        let index = frame.index + UInt64(offset)
                        return .init(segment: active.run.segments.last?.id, index: index, time: segmentStart + Double(index) / rate, word: words[offset],
                                     group: frame.groups?[offset], board: board)
                    }
                    active.preview.latestCode = words.reversed().first { $0 & 0x8000 == 0 }.map { board.sampleCode($0) }
                }
            }
        }
        active.preview.elapsed = active.startedAt.map { Double(now - $0) / 1e9 } ?? 0
        active.preview.received = active.accounting.received
        active.preview.loss = active.accounting.knownLoss
        active.preview.rateByPicoTimer = active.accounting.sampleCadenceEstimate
        if frame.kind == .samples, let cadence = active.preview.rateByPicoTimer, active.stopAt == nil,
           let configured = active.accounting.configuredRate, abs(cadence - configured) > configured / 100 {
            requestStop(active, issue: "The measured sample cadence differs from the configured rate. The saved prefix is available.")
        }
        if now - active.publishAt >= previewInterval || frame.kind == .gpio {
            active.publishAt = now
            event(.preview(active.preview))
        }
        let isRelease = frame.kind == .gpio && active.preview.gpio?.leaseActive == false
        guard !active.discardIncoming else {
            if isRelease { active.deferredRelease = frame }
            return
        }
        guard active.slots.wait(timeout: .now()) == .success else {
            if isRelease { active.deferredRelease = frame }
            active.discardIncoming = true
            requestStop(active, issue: "Disk writer fell behind. The committed prefix is available.")
            return
        }
        active.metricsLock.withLock {
            active.queued += 1
            active.queuePeak = max(active.queuePeak, active.queued)
        }
        disk.async {
            let began = DispatchTime.now().uptimeNanoseconds
            defer {
                let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1000
                active.metricsLock.withLock {
                    active.queued -= 1
                    active.maxWriterUS = max(active.maxWriterUS, elapsed)
                }
                active.slots.signal()
            }
            guard active.diskError == nil else { return }
            do {
                try active.writer.append(frame)
                let saved = active.writer.run.segments.last?.savedSamples ?? 0
                if saved != active.diskPublishedSamples {
                    active.diskPublishedSamples = saved
                    let boundary = active.writer.run.segments.last?.accountedSamples ?? 0
                    self.queue.async {
                        guard self.active === active else { return }
                        active.preview.saved = saved
                        active.preview.committedBoundary = boundary
                    }
                }
            } catch {
                active.diskError = error.localizedDescription
                self.queue.async {
                    if self.active === active {
                        active.discardIncoming = true
                        self.requestStop(active, issue: "Storage error: " + error.localizedDescription)
                    }
                }
            }
        }
    }

    private func requestStop(_ active: Active, issue: String?) {
        if active.issue == nil { active.issue = issue }
        guard active.stopAt == nil, !active.finishing else { return }
        active.stopAt = now
        event(.stopping(active.issue ?? "Finishing the current sample block and saving."))
        if active.startedAt == nil, outputOffset == 0, output.first?.starts(with: Data("SB1 STREAM ".utf8)) == true {
            // An entirely queued Start can be cancelled locally. The device
            // has received no command and cannot supply final counters.
            finish(active, issue: active.issue ?? "Stopped before recording started.")
            output.removeAll()
            return
        }
        prioritize(StreamWire.control(1, stream: active.accounting.stream))
    }

    private func lost(_ reason: String) {
        closePort()
        if let active { finish(active, issue: active.issue ?? reason) }
        else { event(.disconnected(reason)) }
    }

    private func finish(_ active: Active, issue: String?) {
        guard !active.finishing else { return }
        active.finishing = true
        event(.stopping("Saving received samples"))
        let state = active.accounting
        let releaseEvidence = active.deferredRelease
        let deadlineReached = active.deadlineReached
        disk.async {
            var problem = active.diskError.map { "Storage error: " + $0 } ?? issue
            var run: StreamRun?
            if let releaseEvidence, active.diskError == nil {
                do { try active.writer.append(releaseEvidence) }
                catch { problem = (problem ?? "Recording stopped.") + " Could not save the GPIO release snapshot." }
            }
            do {
                var final = state
                active.metricsLock.withLock {
                    final.hostQueuePeak = active.queuePeak
                    final.maximumWriterUS = active.maxWriterUS
                }
                run = try active.writer.finish(accounting: final, issue: problem, discardUncommitted: active.diskError != nil,
                                                     deadlineReached: deadlineReached)
            } catch {
                problem = problem ?? "Storage error: " + error.localizedDescription
                run = try? active.writer.store.openRun(active.id)
            }
            if run == nil {
                var interrupted = active.run
                interrupted.status = .interrupted
                interrupted.message = problem
                interrupted.segments[interrupted.segments.count - 1].unknown = true
                run = interrupted
            }
            let outcome = run, detail = problem
            self.queue.async {
                guard self.active === active else { return }
                self.active = nil
                if self.disconnectAfterFinish || active.parserFailed || self.fd < 0 {
                    self.closePort()
                    self.disconnectAfterFinish = false
                    self.event(.disconnected("Disconnected"))
                }
                self.event(.finished(outcome, issue: detail))
            }
        }
    }
}
