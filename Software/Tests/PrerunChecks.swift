import Darwin
import Foundation

#if !PRERUN_SCREENS && !CANONICAL_ZIP_CHECK
@main
#endif
enum PrerunChecks {
    private static let rate = 10_000

    static func profile(factor: ADCAveraging? = nil) -> CalibrationProfile {
        let setup = CalibrationSetup(board: "Rev E.1", detector: "FDS1010", cable: "Short", enclosure: "Dark",
                                     conditions: "Synthetic", firmware: CalibrationSetup.firmwareLabel("1.10"),
                                     nominalHz: rate, picoAveraging: factor)
        let fit = ProfileCoverage(elapsed: 120, sampled: 120, usable: 120, windows: 3, usableWindows: 3)
        let holdout = ProfileCoverage(elapsed: 60, sampled: 60, usable: 60, windows: 3, usableWindows: 3)
        let summaries = [CalibrationPhase.empty, .dark].map {
            ProfilePhaseSummary(phase: $0, fit: fit, holdout: holdout, fitBaselineMedian: 2048, fitNoiseMedian: 2,
                                holdoutBaselineMedian: 2048, holdoutNoiseMedian: 2,
                                evidenceSHA256: String(repeating: "0", count: 64), issues: [])
        }
        return CalibrationProfile(name: "Quiet dark", preset: .quick, setup: setup,
            rules: .init(minimumSamples: 2), limits: .init(minimumFitWindows: 2, minimumHoldoutWindows: 2,
                minimumUsableSecondsPerMinute: 40, maximumNoise: 30, maximumDrift: 50,
                minimumHeadroom: 100, baselineTolerance: 100, maximumEmptyMatchesPerBlock: 2, operatorApproved: true),
            envelope: .init(baselineLow: 2000, baselineHigh: 2100), phases: summaries)
    }

    static func plan(_ length: CalibratedPrerun.Length = .one, continuation: UUID? = nil) -> CalibratedPrerun.Plan {
        .init(length: length, measurementSeconds: 300, continuation: continuation, policy: .review)
    }

    static func capture(_ store: StreamProjectStore, settings: StreamRunSettings, duration: Double, deadline: Bool,
                        signal: (Int) -> UInt16 = { index in
        let hum = Int((sin(Double(index) * 2 * .pi * 60 / 10_000) * 5).rounded())
        let inPulse = (100...107).contains(index % 2000)
        return UInt16(2048 + hum - (inPulse ? 65 : 0))
    }, issue: String? = nil, continuing original: StreamRun? = nil,
                        link: CalibratedPrerun.Link? = nil) throws -> StreamRun {
        let run: StreamRun
        if let original { run = original }
        else {
            run = try store.makeRun(name: "Synthetic capture", description: "Baseline with known pulses and mains signal.", settings: settings)
        }
        let averaging = settings.picoAveraging
        let rate = settings.nominalRate
        let board = settings.board
        let firmware = board == .unoR4 ? "1.0" : "1.10"
        let factor = UInt64(averaging?.count ?? 1)
        let stream = UInt64(run.segments.count + 1)
        let writer = try StreamRunWriter(store: store, run: run, stream: stream, firmware: firmware, continuationPrerun: link)
        var accounting = StreamAccounting(stream: stream, channel: 0, rate: rate, averaging: averaging, board: board)
        var clock = Data()
        StreamWire.put(StreamWire.adcClock, into: &clock)
        let ticks = board == .unoR4 ? StreamWire.adcClock / UInt32(rate) : StreamWire.divider(for: rate)!
        StreamWire.put(ticks, into: &clock)
        if let averaging { StreamWire.put(UInt32(averaging.count), into: &clock) }
        let base: UInt64 = 1_000_000
        func frame(_ kind: StreamFrameKind, _ index: Int, _ count: Int, _ timeUS: UInt64, _ payload: Data,
                   flags: UInt32 = 0, aux: UInt32 = 0) throws {
            var value = StreamFrame(kind: kind, sequence: accounting.nextSequence, stream: stream, boot: stream,
                index: UInt64(index), timeUS: timeUS, count: UInt32(count), auxiliary: aux, flags: flags, payload: payload)
            if let averaging, kind == .samples { value.groups = try PicoAverage.groups(payload, first: UInt64(index), factor: averaging) }
            try accounting.accept(value)
            if kind != .end { try writer.append(value) }
        }
        try frame(.start, 0, 0, base, clock, aux: UInt32(rate))
        let effective = Double(rate) / Double(factor)
        let total = Int((duration * effective).rounded(.up))
        let block = (board == .unoR4 ? 1024 : StreamWire.maxSamples) / Int(factor)
        for first in stride(from: 0, to: total, by: block) {
            let count = min(block, total - first)
            var data = Data()
            for i in first..<(first + count) {
                let word = signal(i)
                if let averaging {
                    let raw = UInt64(word) * factor + 1
                    for j in 0..<PicoAverage.stride(averaging) {
                        data.append(UInt8(truncatingIfNeeded: raw >> (8*j)))
                    }
                } else {
                    StreamWire.put(word, into: &data)
                }
            }
            let time = base + UInt64((Double(first + count) * 1e6 / effective).rounded())
            try frame(.samples, first, count, time, data, flags: averaging == nil ? 0 : PicoAverage.wireFlag)
        }
        if issue == nil {
            var payload = Data()
            StreamWire.put(UInt64(total), into: &payload)
            if board == .unoR4 { payload.append(Data(count: 24)) }
            try frame(.end, total, 0, base + UInt64((Double(total) * 1e6 / effective).rounded()) + 1, payload)
        }
        return try writer.finish(accounting: accounting, issue: issue, deadlineReached: deadline)
    }

    static func checkSettings(_ profile: CalibrationProfile, plan: CalibratedPrerun.Plan) -> StreamRunSettings {
        .init(mode: .calibrated, nominalRate: rate, duration: plan.length.seconds, gain: profile.setup.gain,
              profile: profile, purpose: "localDarkCheck", picoAveraging: profile.setup.picoAveraging,
              acquisitionBoard: .picoW, prerunPlan: plan)
    }

    static func main() {
        setbuf(stdout, nil)
        do { try verify() }
        catch {
            FileHandle.standardError.write(Data("Prerun regression: \(error.localizedDescription) [\(error)]\n".utf8))
            exit(1)
        }
    }

    private static func verify() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "Prerun Validation", in: root)
        let profile = profile()
        try CurveChecks.require(profile.valid && profile.measurementReady, "Pico fixture-free synthetic profile")
        try CurveChecks.require(CalibratedPrerun.Length.allCases.map(\.seconds) == [60,300,900] &&
            CalibratedPrerun.Measurement.allCases.map(\.seconds) == [300,900,1800,3600,7200], "Exact approved presets")
        let check = try capture(store, settings: checkSettings(profile, plan: plan()), duration: 60, deadline: true)
        let result = try StreamingCalibration.assessPrerun(check.id, in: store)
        try CurveChecks.require(result.report.passed && result.report.quality.samples == 600_000, "Known fixture-shaped pulses over low hum pass: \(result.report.issues)")
        try CurveChecks.require(result.report.coverage.matches > 0, "Synthetic pulses remain visible over hum")

        for length in CalibratedPrerun.Length.allCases {
            let stopped = try capture(store, settings: checkSettings(profile, plan: plan(length)), duration: 0.5, deadline: false)
            let report = try StreamingCalibration.assessPrerun(stopped.id, in: store).report
            try CurveChecks.require(!report.passed && report.issues.contains(where: { $0.contains("timer finished") }) &&
                report.quality.samples == 5000, "Early stop preserves the raw prefix for \(length)")
        }
        let noisy = try capture(store, settings: checkSettings(profile, plan: plan()), duration: 5, deadline: false,
                                signal: { $0 % 11 == 0 ? 4095 : UInt16(2050 + 730 * sin(Double($0) * 2 * .pi * 60 / 10_000)) },
                                issue: "Simulated USB disconnect")
        let failed = try StreamingCalibration.assessPrerun(noisy.id, in: store)
        try CurveChecks.require(!failed.report.passed && failed.report.quality.railSamples > 0 &&
                                failed.report.coverage.uncertainInterruption, "Clipped noisy interrupted check")

        var settings = StreamRunSettings(mode: .calibrated, nominalRate: rate, duration: 300, gain: profile.setup.gain,
                                        profile: profile, noisePolicy: .review, acquisitionBoard: .picoW, prerun: result.link)
        try CalibratedPrerun.verifyForRecording(result.link, settings: settings, in: store)
        var changed = settings
        changed.duration = 900
        try rejects("Changed duration") { try CalibratedPrerun.verifyForRecording(result.link, settings: changed, in: store) }
        changed = settings
        changed.nominalRate = 50_000
        try rejects("Changed acquisition rate") { try CalibratedPrerun.verifyForRecording(result.link, settings: changed, in: store) }
        try rejects("Rejected approval") { try CalibratedPrerun.verifyForRecording(failed.link, settings: settings, in: store) }

        print("PASS: the raw 60 second check captured controlled synthetic pulses and rejected incomplete data")
        let run = try capture(store, settings: settings, duration: 0.6, deadline: false,
                              signal: { $0 == 9 ? 0x8800 : $0 == 11 ? 4095 : 2048 }, issue: "Simulated disk failure")
        let reader = StreamRangeReader(store: store, run: try store.openRun(run.id))
        try CurveChecks.require(reader.run.status == .interrupted && run.segments.first?.prerun == result.link, "Link stored before first frame")
        let check2 = try capture(store, settings: checkSettings(profile, plan: plan(continuation: run.id)), duration: 60, deadline: true)
        let again = try StreamingCalibration.assessPrerun(check2.id, in: store)
        try rejects("Continuation identity must match") { try CalibratedPrerun.verifyForRecording(again.link, settings: settings, in: store) }
        try CalibratedPrerun.verifyForRecording(again.link, settings: settings, in: store, continuing: run.id)
        let resumed = try capture(store, settings: settings, duration: 0.5, deadline: false,
                                  continuing: reader.run, link: again.link)
        try CurveChecks.require(resumed.status == .interrupted && resumed.linkedPreruns == [result.link, again.link] &&
                                resumed.segments.last?.timelineStart == 0.6, "Resume preserves both links and distinct timing")
        let resumedReader = StreamRangeReader(store: store, run: try store.openRun(resumed.id))
        let before = try CalibratedPrerun.snapshot(resumedReader, verifyPayload: true)
        let range = StreamSelection(lower: 0, upper: 0.002)
        let csv = try StreamExporter.export(resumedReader, name: "Evidence CSV", selection: range, format: .zip, includeAnalyses: false)
        let guide = String(decoding: try extract(csv, "Main.md"), as: UTF8.self)
        let sub = "calibration/\(check.id.uuidString)/"
        try CurveChecks.require(guide.contains(sub + "check.json") && guide.contains(sub + "ranges.jsonl"), "Root guide names all evidence")
        let report = try StreamFiles.decoder.decode(CalibratedPrerun.Report.self, from: extract(csv, sub + "check.json"))
        try CurveChecks.require(report == result.report, "ZIP exports the exact report")
        let raw = String(decoding: try extract(csv, "raw.csv"), as: UTF8.self)
        try CurveChecks.require(raw.contains(",34816,2048,1") && raw.contains(",4095,4095,0"), "Measurement raw word and rail preservation")
        let binary = try StreamExporter.export(resumedReader, name: "Evidence binary", selection: range, format: .binaryZIP, includeAnalyses: false)
        let bytes = try extract(binary, "raw.bin")
        let originalCheck = try extract(binary, sub + "raw.bin")
        try CurveChecks.require(bytes.count == 40 && StreamWire.read(UInt16.self, bytes, at: 18) == 0x8800 &&
                                originalCheck.count == 1_200_000, "Selected measurement and complete calibration words")
        let renewed = try extract(binary, "calibration/\(check2.id.uuidString)/raw.bin")
        try CurveChecks.require(renewed.count == originalCheck.count, "Resumed ZIP includes both preruns")
        try CurveChecks.require(try CalibratedPrerun.snapshot(resumedReader, verifyPayload: true) == before, "Raw hashes unchanged")

        settings.mode = .main
        settings.profile = nil
        settings.prerun = failed.link
        let rawFallback = try capture(store, settings: settings, duration: 0.1, deadline: false)
        let fallback = try StreamExporter.export(.init(store: store, run: rawFallback), name: "Raw fallback", selection: .init(lower: 0, upper: 0.1),
                                          format: .binaryZIP, includeAnalyses: false)
        _ = try extract(fallback, "calibration/\(noisy.id.uuidString)/check.json")
        try rejects("Cancelled export stays unpublished") {
            _ = try StreamExporter.export(resumedReader, name: "Cancelled", selection: range, format: .binaryZIP, includeAnalyses: false,
                                           checkpoint: { throw CancellationError() })
        }
        try CurveChecks.require(!(try store.exports()).appendingPathComponent("Cancelled.zip").exists, "No partial published ZIP")
        var exportChecks = 0
        try rejects("Disk-full export stays unpublished") {
            _ = try StreamExporter.export(resumedReader, name: "Disk Full", selection: range, format: .binaryZIP, includeAnalyses: false, checkpoint: {
                exportChecks += 1
                if exportChecks == 5 { throw POSIXError(.ENOSPC) }
            })
        }
        try CurveChecks.require(!(try store.exports()).appendingPathComponent("Disk Full.zip").exists, "Disk failure cannot publish a partial ZIP")
        let chunk = try store.chunkSummaries(check).first!
        let folder = try store.runDirectory(check.id).appendingPathComponent("chunks")
        let target = folder.appendingPathComponent(chunk.id.uuidString + ".bin")
        let original = try Data(contentsOf: target)
        defer { try? original.write(to: target, options: .atomic) }
        var corrupt = original
        corrupt[corrupt.startIndex] ^= 1
        try corrupt.write(to: target, options: .atomic)
        try rejects("Corrupt prerun blocks linked export") {
            _ = try StreamExporter.export(resumedReader, name: "Corrupt", selection: range, format: .binaryZIP, includeAnalyses: false)
        }
        try CurveChecks.require(!(try store.exports()).appendingPathComponent("Corrupt.zip").exists, "Corrupt archive unpublished")
        print("PASS: durations, early stop, hum and pulse replay, failed check, locked configuration, continuation, CSV and binary ZIP, raw errors, interruption, tampering and cancellation")
        try verifyAveraged(store)
    }

    private static func verifyAveraged(_ store: StreamProjectStore) throws {
        let factor = ADCAveraging(rawValue: 64)!
        let profile = profile(factor: factor)
        let middle = try capture(store, settings: checkSettings(profile, plan: plan(.five)), duration: 300, deadline: true,
                                  signal: { UInt16(2048 + $0 % 2) })
        let mid = try StreamingCalibration.assessPrerun(middle.id, in: store)
        try CurveChecks.require(mid.report.passed && mid.report.quality.samples == 46875, "Full five minute AVG1 check")
        let check = try capture(store, settings: checkSettings(profile, plan: plan(.fifteen)), duration: 900, deadline: true,
                                signal: { UInt16(2048 + $0 % 2) })
        let result = try StreamingCalibration.assessPrerun(check.id, in: store)
        try CurveChecks.require(result.report.passed && result.report.quality.samples == 140625, "Full 15 minute AVG1 check: \(result.report.issues)")
        let settings = StreamRunSettings(mode: .main, nominalRate: rate, duration: 300, picoAveraging: factor,
                                         acquisitionBoard: .picoW, prerun: result.link)
        let run = try capture(store, settings: settings, duration: 0.1, deadline: false, signal: { _ in 2048 })
        let reader = StreamRangeReader(store: store, run: run)
        let zip = try StreamExporter.export(reader, name: "AVG1 evidence", selection: .init(lower: 0, upper: try reader.duration()),
                                            format: .binaryZIP, includeAnalyses: false)
        let bytes = try extract(zip, "calibration/\(check.id.uuidString)/groups.avg1")
        let group = try PicoAverage.groups(Data(bytes.prefix(PicoAverage.stride(factor))), first: 0, factor: factor).first
        try CurveChecks.require(group?.sum == 131073 && group?.mean == 2048.015625, "Exact fractional ADC group")
        print("PASS: 15 minute prorated averaged capture and exact group data in ZIP")
    }

    static func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw StreamFailure.storage(name)
    }

    static func extract(_ zip: URL, _ path: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try CurveChecks.require(process.terminationStatus == 0, "Missing archive entry \(path)")
        return data
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
