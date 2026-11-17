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
