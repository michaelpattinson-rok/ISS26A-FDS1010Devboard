import Foundation

#if !MAINS_SCREEN_CHECK
@main
#endif
enum MainsHumChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "Hum Check", in: root)
        let test = UUID()
        let start = ContinuousClock.now
        for step in MainsHumCapture.Step.allCases {
            let capture = MainsHumCapture(test: test, step: step)
            let settings = capture.settings
            try CurveChecks.require(settings.valid && settings.recordedRate == Double(step.rate), "Raw ADC0 configuration for each condition")
            let amplitude = step.battery ? 20.0 : 80.0
            let run = try record(store, capture, amplitude: amplitude)
            let before = try store.chunkSummaries(run)
            let result = try MainsHumCapture.analyze(.init(store: store, run: run))
            try CurveChecks.require(run.settings.mainsHum == capture && result.comparisonIssue == nil, "Reopen tagged capture and admit complete coverage")
            try CurveChecks.require(result.samples == UInt64(step.rate * 20) && result.usableSeconds == 20, "Full twenty second coverage")
            try CurveChecks.require(abs((result.humRMS ?? 0) - amplitude / sqrt(2)) < 0.05, "60 Hz RMS despite DC offset, phase change across captures and a stronger 120 Hz tone")
            try CurveChecks.require(try store.chunkSummaries(run) == before, "Raw sample hashes stay unchanged")
            print("\(step.title): \(result.samples) samples, \(result.humRMS ?? 0) codes RMS")
        }
        let fault = try record(store, .init(test: test, step: .battery100), amplitude: 20, fault: true)
        let stats = try MainsHumCapture.analyze(.init(store: store, run: fault))
        try CurveChecks.require(stats.low == 1 && stats.high == 1 && stats.errors == 1 &&
                                stats.usableSeconds == 19 && stats.comparisonIssue != nil, "Rail and error counts, rejected second and excluded pair")
        let gap = try record(store, .init(test: test, step: .battery100), amplitude: 20, gap: true)
        let coverage = try MainsHumCapture.analyze(.init(store: store, run: gap))
        try CurveChecks.require(coverage.usableSeconds < 20 && coverage.comparisonIssue != nil, "Known loss prevents comparison")
        let early = try record(store, .init(test: test, step: .battery100), amplitude: 20, interrupted: true)
        let prefix = try MainsHumCapture.analyze(.init(store: store, run: early))
        try CurveChecks.require(prefix.usableSeconds == 2 && prefix.comparisonIssue != nil, "Interrupted prefix remains visible")
        let uno = try record(store, .init(test: test, step: .battery100), amplitude: 40, fault: true,
                             interrupted: true, board: .unoR4)
        let unoHashes = try store.chunkSummaries(uno)
        let unoReader = StreamRangeReader(store: store, run: uno)
        let selected = try MainsHumCapture.compare(unoReader, segmentID: uno.segments[0].id, start: 0)
        try CurveChecks.require(selected.railed == 2 && selected.errors == 1 && selected.usableSeconds == 1 &&
                                abs((selected.humRMS ?? 0) - 40 / sqrt(2)) < 0.05 && selected.comparisonIssue != nil,
                                "Saved Uno 14-bit interrupted comparison respects faults")
        let inset = try MainsHumCapture.compare(unoReader, segmentID: uno.segments[0].id, start: 1)
        try CurveChecks.require(inset.selection == .init(lower: 1, upper: 2) && inset.samples == 100_000 &&
                                inset.railed == 0 && inset.errors == 0, "Use exact selected source range")
        var averaged = uno
        averaged.settings.adcAveraging = .eight
        do {
            _ = try MainsHumCapture.compare(.init(store: store, run: averaged, index: unoHashes),
                                            segmentID: uno.segments[0].id, start: 0)
            throw StreamFailure.project("Averaged input was incorrectly accepted")
        } catch StreamFailure.storage {}
        try CurveChecks.require(try store.chunkSummaries(uno) == unoHashes, "Comparisons leave raw hashes unchanged")
        let untagged = try CurveChecks.make(store, count: 2048, rate: 100_000)
        try CurveChecks.require(untagged.run.settings.mainsHum == nil, "Older runs require no metadata")
        var mismatched = MainsHumCapture(test: test, step: .battery500).settings
        mismatched.channel = 1
        try CurveChecks.require(!mismatched.valid, "Diagnostic labels reject mismatched channels")
        print("PASS 60 Hz captures, ordinary run compatibility, rates, faults, gaps, interrupted prefix and raw hashes. Test wall time \(start.duration(to: .now)).")
    }

    static func record(_ store: StreamProjectStore, _ capture: MainsHumCapture, amplitude: Double,
                               fault: Bool = false, gap: Bool = false, interrupted: Bool = false,
                               board: AcquisitionBoard = .picoW) throws -> StreamRun {
        let rate = capture.step.rate
        let total = (interrupted ? 2 : 20) * rate
        let settings = board == .picoW ? capture.settings :
            StreamRunSettings(mode: .diagnosis, nominalRate: rate, duration: 20, wiring: "A0 synthetic", acquisitionBoard: board)
        let run = try store.makeRun(name: capture.runName, description: "Synthetic mains pickup comparison", settings: settings)
        let writer = try StreamRunWriter(store: store, run: run, stream: 8, firmware: "1.10")
        var accounting = StreamAccounting(stream: 8, channel: 0, rate: rate, board: board)
        func send(_ frame: StreamFrame) throws {
            try accounting.accept(frame)
            try writer.append(frame)
        }
        var clock = Data()
        StreamWire.put(board == .picoW ? StreamWire.adcClock : UInt32(48_000_000), into: &clock)
        StreamWire.put(board == .picoW ? StreamWire.divider(for: rate)! : UInt32(48_000_000 / rate), into: &clock)
        try send(.init(kind: .start, sequence: 0, stream: 8, boot: 7, index: 0, timeUS: 1_000_000, count: 0,
                       auxiliary: UInt32(rate), flags: 0, payload: clock))
        let samples: [UInt16] = (0..<rate).map { index in
            let angle = 2 * Double.pi * 60 * Double(index) / Double(rate)
            let baseline = board == .picoW ? 2100.0 : 12_000.0
            return UInt16((baseline + amplitude * cos(angle + Double(rate) / 400_000) + 150 * sin(angle * 2)).rounded())
        }
        for first in stride(from: 0, to: total, by: 2048) {
            if gap && first == 2048 { continue }
            let count = min(2048, total - first)
            var data = Data(capacity: count * 2)
            for index in first..<first + count {
                let word: UInt16
                switch index {
                case 5 where fault: word = 0
                case 6 where fault: word = board.maxCode
                case 7 where fault: word = 0x8000
                default: word = samples[index % rate]
                }
                StreamWire.put(word, into: &data)
            }
            try send(.init(kind: .samples, sequence: accounting.nextSequence, stream: 8, boot: 7,
                           index: UInt64(first), timeUS: 1_000_000 + UInt64((first + count) * 1_000_000 / rate),
                           count: UInt32(count), auxiliary: 0, flags: 0, payload: data))
        }
        if !interrupted {
            var end = Data()
            StreamWire.put(accounting.received, into: &end)
            try send(.init(kind: .end, sequence: accounting.nextSequence, stream: 8, boot: 7,
                           index: UInt64(total), timeUS: 21_000_000, count: 0, auxiliary: 0, flags: 0, payload: end))
        }
        let saved = try writer.finish(accounting: accounting, issue: interrupted ? "Synthetic USB disconnect" : nil, deadlineReached: !interrupted)
        return try store.openRun(saved.id)
    }
}
