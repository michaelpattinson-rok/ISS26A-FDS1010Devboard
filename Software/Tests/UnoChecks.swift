import Foundation
import Darwin


#if !UNO_SCREENS
@main enum UnoChecks {
    static func main() {
        setbuf(stdout, nil)

        do { try verify() }
        catch {
            FileHandle.standardError.write(Data("Uno checks failed: \(error.localizedDescription) [\(error)]\n".utf8))
            exit(1)
        }
    }

    private static func verify() throws {
        print("Testing frame parsing")

        let board = AcquisitionBoard.unoR4
        let values: [UInt16] = [0, 4095, 8192, 16383]
        let packed = values.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (14 * $1.offset)) }
        let payload = Data((0..<7).map { UInt8(truncatingIfNeeded: packed >> ($0 * 8)) })
        let frame = StreamFrame(kind: .samples, sequence: 1, stream: 4, boot: 5, index: 0, timeUS: 1000,
                                count: 4, auxiliary: 0, flags: 8, payload: payload)
        let bytes = StreamWire.encode(frame)
        var parser = StreamParser(allowsPacked: true, board: board)
        var decoded: [StreamFrame] = []
        for byte in bytes { decoded += try parser.append(Data([byte])) }
        try CurveChecks.require(decoded.count == 1 && decoded[0].words == values, "Fragmented PACK14 preserves all 14 bits")
        try reject(bytes, parser: .init(allowsPacked: true))
        try reject(bytes, parser: .init(board: board))
        var corrupt = bytes
        corrupt[corrupt.count - 1] ^= 1
        try reject(corrupt, parser: .init(allowsPacked: true, board: board))
        var raw = frame
        raw.flags = 0
        raw.count = 1
        raw.payload = Data([0, 0x40])
        try reject(StreamWire.encode(raw), parser: .init(board: board))
        raw.payload = Data([0x21, 0xA0])
        let accepted = try parser.append(StreamWire.encode(raw))
        try CurveChecks.require(accepted.first?.words == [0xA021], "RAW14 ADC error word stays intact")
        try liveQuality()
        try CurveChecks.require(board.accepts(48_000_000, 192, rate: 250_000) && !board.accepts(48_000_000, 193, rate: 250_000),
                                "Require exact Uno hardware timing")
        try CurveChecks.require(!AcquisitionBoard.picoW.accepts(48_000_000, 192, rate: 250_000),
                                "Pico timing never uses Uno GPT ticks")
        let picoSetup = CalibrationSetup(board: "E.1", detector: "FDS1010", cable: "Short", enclosure: "Dark", conditions: "Bench",
                                         firmware: CalibrationSetup.firmwareLabel("1.10"))
        var unoSetup = picoSetup
        unoSetup.acquisitionBoard = .unoR4
        unoSetup.firmware = CalibrationSetup.firmwareLabel("1.0", board: .unoR4)
        try CurveChecks.require(unoSetup.valid && picoSetup.valid && unoSetup.requiresLocalFixture && !picoSetup.requiresLocalFixture,
                                "Require distinct local fixture evidence for an Uno profile")
        try CurveChecks.require(!unoSetup.matchesAcquisition(picoSetup), "Device setups cannot share calibration")
        try CurveChecks.require(board.gpioMask & (1 << 14) == 0 && board.gpioMask & (1 << 2) != 0,
                                "Uno ADC and reserved pins are outside Manual's GPIO allowlist")
        print("Testing Project and waveform")

        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "Dual receiver", in: folder)
        let uno = try CurveChecks.make(store, count: 8192, rate: 100_000, gapped: true, name: "Uno", board: board)
        let legacy = try CurveChecks.make(store, count: 8192, rate: 100_000, name: "Legacy")
        try CurveChecks.require(uno.run.version == 4 && uno.run.settings.board == board && uno.run.segments.first?.board == board,
                                "Run stores Uno at both run and segment levels")
        try CurveChecks.require(legacy.run.version == 1 && legacy.run.settings.board == .picoW && legacy.run.settings.acquisitionBoard == nil,
                                "Legacy projects keep their Pico format and inferred device")
        try averagedRun(in: store)
        try signalHealth(in: store)
        let selection = try FixtureTemplateStudy.fullRange(uno)
        let prepared = try uno.prepared()
        let plot = try StreamStudio.plot(prepared, selection: selection)
        try CurveChecks.require(plot.stats.highRail == 1 && plot.stats.clipped == 1 && plot.stats.adcErrors == 1,
                                "Saved Uno quality distinguishes 14-bit clipping from error")
        print("Testing curve")

        let curve = try CurveChecks.fit(prepared, tolerance: 4)
        try CurveChecks.require(curve.manifest.stats.clipped == 1 && curve.manifest.stats.invalid == 1,
                                "Uno curve retains exact faults")
        let rawReading = try CurveInspection.sample(curve, source: prepared, at: 0.003)
        try CurveChecks.require(rawReading?.original ?? 0 > 8191, "Curve cursor preserves high ADC codes")
        print("Testing ZIP")

        let archive = try StreamExporter.export(prepared, name: "Uno", selection: selection, format: .zip, includeAnalyses: false)
        try CurveChecks.require(archive.pathExtension == "zip", "Exporter writes Uno CSV ZIP")
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        verify.arguments = ["-p", archive.path, "Main.md"]
        let output = Pipe()
        verify.standardOutput = output
        try verify.run()
        let description = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        verify.waitUntilExit()
        try CurveChecks.require(verify.terminationStatus == 0 && description.contains(board.title), "ZIP metadata preserves board identity")
        print("PASS: Uno PACK14 / raw faults / clocks / legacy reopen / 14-bit waveform and curve / ZIP board metadata")
    }

    private static func signalHealth(in store: StreamProjectStore) throws {
        let rate = 100_000
        let settings = StreamRunSettings(mode: .diagnosis, nominalRate: rate, wiring: "A0 synthetic", acquisitionBoard: .unoR4)
        var clock = Data()
        StreamWire.put(UInt32(48_000_000), into: &clock)
        StreamWire.put(UInt32(480), into: &clock)
        let start = StreamFrame(kind: .start, sequence: 0, stream: 4, boot: 5, index: 0, timeUS: 1_000,
                                count: 0, auxiliary: UInt32(rate), flags: 0, payload: clock)
        var words = Data()
        for index in 0..<1024 {
            let word: UInt16 = switch index {
            case 0: 0
            case 1: 0x3fff
            case 2: 0x8000
            default: index.isMultiple(of: 2) ? 9002 : 9000
            }
            StreamWire.put(word, into: &words)
        }
        let sum = UInt32(511 * 9000 + 510 * 9002)
        let squares = UInt64(511) * 9000 * 9000 + UInt64(510) * 9002 * 9002
        var body = Data()
        StreamWire.put(sum, into: &body)
        StreamWire.put(squares, into: &body)
        for value: UInt16 in [9000, 9002, 1, 1, 1, 0] { StreamWire.put(value, into: &body) }
        let rawStart = UInt64(97 * 1024)
        var summary = StreamFrame(kind: .health, sequence: 98, stream: 4, boot: 5, index: rawStart,
                                  timeUS: 1_004_520, count: 0, auxiliary: 1024, flags: 0, payload: body)
        var parser = StreamParser(board: .unoR4, health: true)
        var delivered: [StreamFrame] = []
        delivered += try parser.append(StreamWire.encode(start))
        let encoded = StreamWire.encode(summary)
        for byte in encoded { delivered += try parser.append(Data([byte])) }
        try CurveChecks.require(delivered.count == 2 && delivered.last?.index == rawStart, "Fragmentation preserves raw conversion index")
        var averagedParser = StreamParser(averaging: .eight, board: .unoR4, health: true)
        let averagedHealth = try averagedParser.append(encoded)
        try CurveChecks.require(averagedHealth.first?.index == rawStart,
                                "AVG14 telemetry continues to report original conversion positions")
        try reject(encoded, parser: .init(board: .unoR4))
        try reject(encoded, parser: .init(board: .picoW, health: true))
        var badCRC = encoded
        badCRC[badCRC.count - 1] ^= 1
        try reject(badCRC, parser: .init(board: .unoR4, health: true))
        var recovering = StreamParser(board: .unoR4, health: true)
        let raw = StreamFrame(kind: .samples, sequence: 99, stream: 4, boot: 5,
                              index: rawStart + 1024, timeUS: 1_014_760, count: 1024,
                              auxiliary: 0, flags: 0, payload: words)
        _ = try recovering.append(StreamWire.encode(start))
        let missing = try recovering.append(badCRC)
        let recovered = try recovering.append(StreamWire.encode(raw))
        try CurveChecks.require(missing.isEmpty && recovered.count == 1 && recovered[0].payload == words,
                                "Corrupt optional telemetry keeps the following raw frame intact")

        var outcomes: [String] = []
        for enabled in [false, true] {
            let run = try store.makeRun(name: enabled ? "Health on" : "Health off", description: "Synthetic signal health", settings: settings)
            let writer = try StreamRunWriter(store: store, run: run, stream: 4, firmware: enabled ? "1.2" : "1.1")
            var account = StreamAccounting(stream: 4, channel: 0, rate: rate, board: .unoR4, health: enabled)
            try account.accept(start)
            try writer.append(start)
            for block in 0..<196 {
                let frame = StreamFrame(kind: .samples, sequence: UInt32(1 + block), stream: 4, boot: 5,
                                        index: UInt64(block * 1024), timeUS: 1_000 + UInt64(10_240 * (1 + block)),
                                        count: 1024, auxiliary: 0, flags: 0, payload: words)
                try account.accept(frame)
                try writer.append(frame)
                if enabled && block == 97 {
                    var malformed = summary
                    malformed.payload[22] = 1
                    try account.accept(malformed)
                    try account.accept(summary)
                    try account.accept(summary)
                    try CurveChecks.require(account.healthReports == 1 && account.rejectedHealthReports == 2 &&
                                            account.health?.minimum == 9000 && account.health?.maximum == 9002 &&
                                            account.health?.low == 1 && account.health?.high == 1 && account.health?.errors == 1 &&
                                            abs((account.health?.noise ?? 0) - 1) < 0.001, "Validate moments, flags, and duplicates")
                }
            }
            if enabled {
                try CurveChecks.require(account.healthOpportunities == 2 && account.healthReports == 1,
                                        "One skipped scheduled snapshot does not count as lost samples")
            }
            var end = Data()
            StreamWire.put(account.received, into: &end)
            end.append(Data(count: 24))
            try account.accept(.init(kind: .end, sequence: account.nextSequence, stream: 4, boot: 5,
                                     index: account.received, timeUS: 2_100_000, count: 0, auxiliary: 0, flags: 0, payload: end))
            let saved = try writer.finish(accounting: account, issue: nil)
            try CurveChecks.require(account.knownLoss == 0 && saved.segments[0].savedSamples == 196 * 1024,
                                    "Optional reports do not change Stop or saved sample accounting")
            outcomes.append(contentsOf: try store.chunkSummaries(saved).map(\.sha256))
        }
        try CurveChecks.require(outcomes.count.isMultiple(of: 2) &&
                                Array(outcomes.prefix(outcomes.count / 2)) == Array(outcomes.suffix(outcomes.count / 2)),
                                "Health on and off have identical raw chunk hashes")
        summary.count = 1
        try CurveChecks.require(UnoSignalHealth(frame: summary) == nil, "A summary cannot claim sample payload")
        print("PASS: negotiated telemetry, fragmentation, missing reports, invalid moments and CRC, Stop, and identical raw hashes")
    }

    private static func averagedRun(in store: StreamProjectStore) throws {
        let board = AcquisitionBoard.unoR4
        let factor = ADCAveraging.eight
        let rawRate = 123_457
        let settings = StreamRunSettings(mode: .manual, nominalRate: rawRate, duration: 2, picoAveraging: factor, acquisitionBoard: board)
        let run = try store.makeRun(name: "Uno averages", description: "Synthetic AVG14 capture", settings: settings)
        let writer = try StreamRunWriter(store: store, run: run, stream: 4, firmware: "1.1")
        var accounting = StreamAccounting(stream: 4, channel: 0, rate: rawRate, averaging: factor, board: board)
        var parser = StreamParser(averaging: factor, board: board)
        func deliver(_ frame: StreamFrame) throws {
            for decoded in try parser.append(StreamWire.encode(frame)) {
                try accounting.accept(decoded)
                try writer.append(decoded)
            }
        }
        let groupCount = 128
        var configuration = Data()
        StreamWire.put(UInt32(48_000_000), into: &configuration)
        StreamWire.put(UInt32(389), into: &configuration)
        StreamWire.put(UInt32(8), into: &configuration)
        try deliver(.init(kind: .start, sequence: 0, stream: 4, boot: 5, index: 0,
                          timeUS: 11_000, count: 0, auxiliary: UInt32(rawRate), flags: 0, payload: configuration))
        var payload = Data()
        for index in 0..<groupCount {
            let packed = index == 0 ?
                UInt64(16383 + 5*9000) | (UInt64(1) << 17) | (UInt64(1) << 21) | (UInt64(1) << 25) :
                UInt64(8*9000 + 1)
            for offset in 0..<PicoAverage.stride(factor, board: board) { payload.append(UInt8(truncatingIfNeeded: packed >> (offset*8))) }
        }
        try deliver(.init(kind: .samples, sequence: 1, stream: 4, boot: 5, index: 0,
                          timeUS: 19_300, count: UInt32(groupCount), auxiliary: 0, flags: 16, payload: payload))
        var ending = Data()
        StreamWire.put(UInt64(groupCount), into: &ending)
        ending.append(Data(count: 24))
        try deliver(.init(kind: .end, sequence: 2, stream: 4, boot: 5, index: 1024, timeUS: 19_400,
                          count: 0, auxiliary: 0, flags: 0, payload: ending))
        let saved = try writer.finish(accounting: accounting, issue: nil)
        let reader = try StreamRangeReader(store: store, run: try store.openRun(saved.id)).prepared()
        let selection = try FixtureTemplateStudy.fullRange(reader)
        try CurveChecks.require(saved.status == .complete && saved.version == 5 && saved.settings.recordedRate == 48_000_000 / 389 / 8,
                                "Save Uno AVG14 with conversion timing")
        try CurveChecks.require(reader.index?.first?.averagingBoard == .unoR4, "Persist AVG14 coding in the chunk")
        try reader.visit(selection) { part in
            try CurveChecks.require(part.originalPayload == payload && part.groups?[1].mean == 9000.125 &&
                                    part.groups?.first?.highRail == 1 && part.groups?.first?.adcErrors == 1,
                                    "Reopen identical AVG14 bytes and exact values")
        }
        let curve = try CurveChecks.fit(reader, tolerance: 4)
        try CurveChecks.require(curve.manifest.stats.high == 1 && curve.manifest.stats.sourceErrors == 1,
                                "Curve fitting preserves Uno group faults")
        let folder = try StreamExporter.export(reader, name: "Uno AVG14", selection: selection, format: .binary, includeAnalyses: false)
        try CurveChecks.require(try Data(contentsOf: folder.appendingPathComponent("groups.avg14")) == payload,
                                "Binary export preserves original Uno average bytes")
        print("PASS AVG14 framed decode, timing, quality, immutable Project bytes, curve and binary export")
    }

    private static func liveQuality() throws {
        let pico = AcquisitionBoard.picoW
        let uno = AcquisitionBoard.unoR4
        func payload(_ readings: [UInt16]) -> Data {
            var result = Data()
            for reading in readings { StreamWire.put(reading, into: &result) }
            return result
        }
        for board in [pico, uno] {
            var preview = LiveStreamPreview()
            var raw = StreamFrame(kind: .samples, sequence: 1, stream: 1, boot: 1, index: 0, timeUS: 100,
                                  count: 4, auxiliary: 0, flags: 0, payload: payload([0, board.maxCode, 2900, 0x8000]))
            preview.accountQuality(raw, board: board)
            try CurveChecks.require(preview.clipped == 2 && preview.lowRail == 1 && preview.highRail == 1 && preview.adcErrors == 1,
                                    "Live raw counters use board rails and classify ADC error separately")
            raw.payload = payload([2000, 2950, 2100, 1999])
            preview.accountQuality(raw, board: board)
            try CurveChecks.require(preview.clipped == 0 && preview.lowRail == 1 && preview.highRail == 1 && preview.adcErrors == 1,
                                    "Only the last-block total resets while recording")
        }
        var average = LiveStreamPreview()
        let group = ADCAveraging.Group(first: 0, count: 8, sum: 10239, adcErrors: 1, lowRail: 1, highRail: 2)
        average.accountQuality(.init(kind: .samples, sequence: 1, stream: 1, boot: 1, index: 0, timeUS: 100,
                                     count: 1, auxiliary: 0, flags: 0, payload: Data(), groups: [group]), board: pico)
        try CurveChecks.require(average.lowRail == 1 && average.highRail == 2 && average.adcErrors == 1 && average.clipped == 1,
                                "Averaged conversion totals and clipped group count use different units")

        let first = payload([8000, 9000])
        let second = payload([4095, 16383, 0, 0x8000])
        let frozen = FrozenFlagWaveform(segment: UUID(), stream: 1, rate: 100_000, timelineStart: 0, click: .now,
                                       first: 20, end: 24, frames: [.init(first: 20, receivedAt: 1, words: second)], recordingBoard: uno)
        var overview = LiveWaveformOverview(samplesPerBin: 1)
        overview.append(.init(first, board: uno), first: 0, count: 2)
        overview.append(.init(second, board: uno), first: 20, count: 4)
        overview.append(.init(first, board: uno), first: 24, count: 2)
        let plot = try overview.through(frozen).plot(.init(lower: 0, upper: frozen.bounds.upper), start: 0, rate: frozen.rate)
        try CurveChecks.require(plot.stats.maximum == 16383 && plot.stats.highRail == 1 && plot.stats.lowRail == 1 &&
                                plot.stats.adcErrors == 1 && plot.stats.samples == 6, "Paused Uno overview rebuild preserves 14-bit values")
        print("PASS: raw and averaged live diagnostics and frozen Uno overview")
    }

    private static func reject(_ bytes: Data, parser input: StreamParser) throws {
        var parser = input
        do { _ = try parser.append(bytes) }
        catch StreamFailure.protocolError { return }
        throw StreamFailure.storage("Invalid test frame was accepted.")
    }
}
#endif
