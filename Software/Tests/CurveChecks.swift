import Darwin
import Foundation

#if !CURVE_SCREENS && !UNO_CHECKS
@main
#endif
enum CurveChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw StreamFailure.storage(message) }
    }

    static func fit(_ reader: StreamRangeReader, tolerance: Double, preserve: [ReviewRange] = []) throws -> CurveReader {
        let selection = try FixtureTemplateStudy.fullRange(reader)
        let input = try ProjectJob.Input.pin(reader, selection: selection)
        let id = UUID()
        let job = ProjectJob(project: reader.store.identity.id, kind: .waveformCurve, input: input,
            name: "Verified Curve", estimatedBytes: 0, curve: .init(action: .fit, curve: id, request: .init(tolerance: tolerance, preserve: preserve)))
        _ = try ProjectJobFiles.execute(job, store: reader.store, destination: nil, control: .init()) { _ in }
        return try CurveStore.open(reader.store, run: reader.run, id: id)
    }

    static func make(_ store: StreamProjectStore, count: Int, rate: Int, factor: ADCAveraging? = nil,
                     gapped: Bool = false, name: String = "Synthetic", board: AcquisitionBoard = .picoW) throws -> StreamRangeReader {
        let run = try store.makeRun(name: name, description: "Deterministic waveform for regression tests.",
            settings: .init(mode: .main, nominalRate: rate, duration: min(7200, Double(count + 2048) / Double(rate) + 1), picoAveraging: factor, acquisitionBoard: board == .picoW ? nil : board))
        let writer = try StreamRunWriter(store: store, run: run, stream: 8, firmware: board == .picoW ? "1.10" : "1.0")
        var accounting = StreamAccounting(stream: 8, channel: 0, rate: rate, averaging: factor, board: board)
        var clock = Data()
        StreamWire.put(StreamWire.adcClock, into: &clock)
        guard let divider = StreamWire.divider(for: rate, clock: StreamWire.adcClock) else { throw CurveCodec.fault }
        StreamWire.put(board == .picoW ? divider : StreamWire.adcClock / UInt32(rate), into: &clock)
        if let factor { StreamWire.put(UInt32(factor.count), into: &clock) }
        func send(_ frame: StreamFrame) throws {
            try accounting.accept(frame)
            try writer.append(frame)
        }
        try send(.init(kind: .start, sequence: 0, stream: 8, boot: 7, index: 0, timeUS: 1_000_000, count: 0,
                       auxiliary: UInt32(rate), flags: 0, payload: clock))
        let effective = Double(rate) / Double(factor?.count ?? 1)
        let frameCount = 2048 / (factor?.count ?? 1)
        for offset in stride(from: 0, to: count, by: frameCount) {
            if gapped && offset == frameCount { continue }
            let n = min(frameCount, count - offset)
            var payload = Data()
            for index in offset..<(offset + n) {
                let phase = index % 1024
                let pulse = phase >= 460 && phase <= 466 ? (4 - abs(phase - 463)) * 7 : 0
                let code = UInt16((board == .picoW ? 2000 : 8200) + (index / 16) % 64 - pulse)
                let fault: UInt16 = index == 13 && gapped ? 0x8421 : (index == 14 && gapped ? board.maxCode : code)
                if let factor {
                    let sums = UInt64(fault & 4095) * UInt64(factor.count) + 1
                    let valid = fault != 4095 && fault & 0x8000 == 0
                    let packed = valid ? sums : fault == 4095 ?
                        UInt64(4095 * factor.count) | (UInt64(factor.count) << (12 + factor.shift + 2 * (1 + factor.shift))) :
                        UInt64(factor.count) << (12 + factor.shift)
                    for i in 0..<PicoAverage.stride(factor) { payload.append(UInt8(truncatingIfNeeded: packed >> (8 * i))) }
                } else { StreamWire.put(fault, into: &payload) }
            }
            var frame = StreamFrame(kind: .samples, sequence: accounting.nextSequence, stream: 8, boot: 7,
                index: UInt64(offset), timeUS: 1_000_000 + UInt64((Double(offset + n) * 1e6 / effective).rounded()),
                count: UInt32(n), auxiliary: 0, flags: factor == nil ? 0 : PicoAverage.wireFlag, payload: payload)
            if let factor { frame.groups = try PicoAverage.groups(payload, first: UInt64(offset), factor: factor) }
            try send(frame)
        }
        let result = try writer.finish(accounting: accounting, issue: "Synthetic interrupted recording")
        return .init(store: store, run: try store.openRun(result.id))
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        let folder = URL(fileURLWithPath: arguments[1])
        let store = try StreamProjectStore.create(named: "Curve Validation", in: folder)
        if arguments.contains("--large") {
            let start = ContinuousClock.now
            let source = try make(store, count: 72_000_000, rate: 10_000, name: "Two Hour Synthetic")
            let prep = start.duration(to: .now)
            let fitting = ContinuousClock.now
            let curve = try fit(source, tolerance: 4)
            let fitTime = fitting.duration(to: .now)
            let navigate = ContinuousClock.now
            let range = StreamSelection(lower: 7180, upper: 7180.0064)
            let detail = try CurveInspection.load(curve, source: source, selection: range, trace: .overlay)
            try require(detail.count == 64, "Two-hour narrow navigation")
            let navigation = navigate.duration(to: .now)
            let exporting = ContinuousClock.now
            let zip = try CurveDelivery.export(curve, store: store, root: store.exports(), name: "Two Hour Curve",
                range: curve.manifest.selection, csv: false, checkpoint: {}, progress: { _ in }, validate: {})
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            print("Two-hour equivalent, 10,000 samples/s and 72,000,000 readings. Build \(prep); fit \(fitTime); range \(navigation); ZIP \(exporting.duration(to: .now)); peak RSS \(usage.ru_maxrss) B")
            print("Source samples \(curve.manifest.sourceBytes) B, curve \(curve.manifest.storedBytes) B, ZIP \((try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)) B")
            return
        }
        let source = try make(store, count: 300_000, rate: 100_000, gapped: true)
        let segment = source.run.segments[0].id
        let preserve = ReviewRange(segment: segment, first: 100, end: 500)
        let curve = try fit(source, tolerance: 4, preserve: [preserve])
        let stats = curve.manifest.stats
        try require(stats.maximum <= 4 && stats.maximum > 0 && stats.modeled > 0 && stats.exact > 0, "Bound and mixed representation")
        try require(stats.invalid == 1 && stats.clipped == 1 && stats.count == 300_000 - 2048 - 2, "Source fault counts")
        let gaps = try curve.gaps()
        try require(gaps.count == 1 && abs((gaps[0].upper - gaps[0].lower) - 0.02048) < 1e-8, "Exact missing sample range")
        try require(curve.manifest.unknownBoundaries.count == 1, "Unknown tail")
        let reading = try CurveInspection.sample(curve, source: source, at: 0.002)
        try require(reading?.reading.exact == true && reading?.reading.value == reading?.original, "Preserve exact sample")
        let diag = try CurveInspection.load(curve, source: nil, selection: .init(lower: 0, upper: 1), diagnostics: true)
        try require(!diag.spectra.isEmpty && diag.valid > 0, "Standalone diagnostic spectrum")
        let overview = try CurveInspection.load(curve, source: source, selection: .init(lower: 0, upper: 0.0005), trace: .error)
        try require(overview.points.count == 50, "High resolution original grid")
        try require(overview.selectedError?.count == 48, "Selected residual population")
        let pulse = try CurveInspection.load(curve, source: source, selection: .init(lower: 0.00455, upper: 0.00475), trace: .overlay)
        let rawPeak = pulse.points.filter { $0.original != nil }.min { $0.original! < $1.original! }
        let curvePeak = pulse.points.filter { $0.reading.value != nil }.min { $0.reading.value! < $1.reading.value! }
        try require(rawPeak?.index == 463 && curvePeak?.index == 463, "Narrow pulse peak stays on its verified source index")
        let entry = RunTimelineEntry(note: "Original note")
        _ = try RunTimeline.save(entry, replacing: nil, in: source, finished: true)
        _ = try RunAnnotations.save(.init(masks: [.init(range: preserve, reason: .manual, action: .excluded, note: "Synthetic annotation")]),
                                    reader: source, replacing: nil)
        let savedReport = try StudioRangeReview.save(source,
            config: StudioRangeReview.config(source, selection: .init(lower: 0, upper: 0.012), settings: .init()))
        let destination = try store.exports()
        let blocked = ProjectJobControl()
        blocked.cancel()
        do {
            _ = try CurveDelivery.copy(curve, store: store, id: UUID(), name: "Cancelled", checkpoint: blocked.checkpoint, progress: { _ in })
            throw StreamFailure.storage("Cancelled copy unexpectedly succeeded.")
        } catch is CancellationError {}
        let diskFailureID = UUID()
        var writes = 0
        do {
            _ = try CurveDelivery.copy(curve, store: store, id: diskFailureID, name: "Disk Failure", checkpoint: {
                writes += 1
                if writes == 2 { throw POSIXError(.ENOSPC) }
            }, progress: { _ in })
            throw StreamFailure.storage("Failed copy unexpectedly published.")
        } catch let error as POSIXError where error.code == .ENOSPC {}
        try require(!store.list().contains { $0.id == diskFailureID }, "Interrupted copy was not published")
        let copyID = UUID()
        let url = try CurveDelivery.copy(curve, store: store, id: copyID, name: "Standalone Curve", checkpoint: {}, progress: { _ in })
        try require(url.lastPathComponent == copyID.uuidString, "Independent run ID")
        let run = try store.openRun(copyID)
        do {
            try CurveDelivery.trashSource(for: run, in: store, typed: "Wrong name") { _ in
                throw POSIXError(.EIO)
            }
            throw POSIXError(.EIO)
        } catch is StreamFailure {}
        do {
            try CurveDelivery.trashSource(for: run, in: store, typed: source.run.name) { _ in
                throw POSIXError(.EPERM)
            }
            throw POSIXError(.EIO)
        } catch let error as POSIXError where error.code == .EPERM {}
        try require(try store.openRun(source.run.id).id == source.run.id, "Trash failure preserved original")
        let sourceRoot = try store.runDirectory(source.run.id)
        try FileManager.default.moveItem(at: sourceRoot, to: folder.appendingPathComponent("Original Held Aside"))
        let standalone = try CurveStore.open(store, run: run, id: curve.manifest.id)
        try standalone.verify()
        let standaloneInput = StreamRangeReader(store: store, run: run)
        try require(try RunTimeline.entries(standaloneInput, finished: true).first?.note == "Original note", "Copied notes")
        try require(try RunAnnotations.read(standaloneInput)?.masks.first?.note == "Synthetic annotation", "Copied exclusions")
        let reports = try StreamStudio.analyses(in: url.appendingPathComponent("source-analyses"), sourceRun: source.run.id)
        try require(reports.first?.id == savedReport.id && reports.first?.run == source.run.id, "Archived report retains source")
        let csv = try CurveDelivery.export(standalone, store: store, root: destination, name: "Standalone CSV",
            range: .init(lower: 0, upper: 0.001), csv: true, checkpoint: {}, progress: { _ in }, validate: {})
        let rows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        try require(rows.count == 101 && rows[14].contains(",13,13,14,") && rows[14].contains(",exact,1,0,0,"), "CSV indexing and exact fault")
        let zip = try CurveDelivery.export(standalone, store: store, root: destination, name: "Standalone ZIP",
            range: standalone.manifest.selection, csv: false, checkpoint: {}, progress: { _ in }, validate: {})
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tqq", zip.path]
        try unzip.run()
        unzip.waitUntilExit()
        try require(unzip.terminationStatus == 0, "Valid Curve ZIP")
        let chunk = standalone.blocks[0].source.id
        let corrupt = standalone.folder.appendingPathComponent(chunk.uuidString + ".curve")
        try Data([0, 0]).write(to: corrupt)
        do {
            try standalone.verify()
            throw POSIXError(.EIO)
        } catch let error as StreamFailure {
            try require(error.localizedDescription == CurveCodec.fault.localizedDescription, "Corrupt output rejected")
        }
        let averaged = try make(store, count: 128_000, rate: 500_000, factor: .eight, name: "Fractional Average")
        let avgCurve = try fit(averaged, tolerance: 0.125)
        try require(avgCurve.manifest.stats.maximum <= 0.125, "Fractional source tolerance")
        let avg = try CurveInspection.sample(avgCurve, source: averaged, at: 0)
        try require(avg?.reading.value == 2000.125 && avg?.original == 2000.125, "Fractional original and curve")
        if arguments.count > 2 {
            let result = try StudioRangeChecks.electronics(store, history: URL(fileURLWithPath: arguments[2])) { archived in
                let proof = try fit(archived, tolerance: 16)
                try require(proof.manifest.stats.count == 5_046_272 && proof.manifest.stats.maximum <= 16, "Historical fit bound")
                try require(try proof.gaps().count == 153, "Historical gap count")
                print("Historical curve \(proof.manifest.storedBytes) B, max error \(proof.manifest.stats.maximum), RMS \(proof.manifest.stats.rms ?? -1)")
            }
            print(result)
        }
        print("PASS curve quality, averaged fractions, protected ranges, faults, timing, standalone copy, Trash confirmation, cancellation, injected storage failure, reports, corrupt data, and exports")
    }
}
