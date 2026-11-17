import CryptoKit
import Darwin
import Foundation

struct RangeCheckFailure: Error { let message: String }

func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw RangeCheckFailure(message: message) }
}

#if !REVIEW_WORKER_TESTING
@main
#endif
enum StudioRangeChecks {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try StreamProjectStore.create(named: "Range review validation", in: root)
        let rawA = try synthetic(project, stream: 12, rate: 100_000, count: 680_000, split: 2048)
        let rawB = try synthetic(project, stream: 13, rate: 100_000, count: 680_000, split: 887)
        let hashes = try rawHashes(rawA)
        var settings = ReviewSettings()
        settings.notch60 = true
        settings.height = 24
        settings.reviewHeight = 150
        let whole = StreamSelection(lower: 0, upper: try rawA.duration())
        let config = try StudioRangeReview.config(rawA, selection: whole, settings: settings)
        let first = try StudioRangeReview.analyze(rawA, config: config)
        let second = try StudioRangeReview.analyze(rawB, config: StudioRangeReview.config(rawB, selection: whole, settings: settings))
        try check(first.quality.samples == 679_900 && first.quality.minutes[0].clips == 3 && first.quality.minutes[0].errors == 1,
                  "Exact saved words, clipping and ADC error counts")
        try check(first.quality.gaps.count == 2 && abs(first.quality.minutes[0].knownMissingSeconds - 0.001) < 1e-9,
                  "Known gap and interrupted unknown tail")
        try check(first.trace.bins.map(\.processed) == second.trace.bins.map(\.processed) &&
                  first.spectra[0].points.map(\.density) == second.spectra[0].points.map(\.density),
                  "Same waveform with different disk chunks and USB slices")
        try check(first.intervals.contains { $0.reason == .tall && $0.action == .review } &&
                  !first.intervals.contains { $0.reason == .tall && $0.action == .excluded }, "Large peak stays review only")
        let narrow = StreamSelection(lower: 2.6214, upper: 2.622)
        let narrowResult = try StudioRangeReview.analyze(rawA, config: StudioRangeReview.config(rawA, selection: narrow, settings: settings))
        let atBoundary = first.decisions.filter { narrow.lower <= $0.pulse.peakTime && $0.pulse.peakTime < narrow.upper }
        try check(!atBoundary.isEmpty && narrowResult.decisions.map(\.pulse) == atBoundary.map(\.pulse), "Tile and selection boundary pulse ownership")
        let repeated = try StudioRangeReview.analyze(rawA, config: config)
        try check(repeated.trace.bins.map(\.processed) == first.trace.bins.map(\.processed) &&
                  repeated.decisions.map(\.pulse) == first.decisions.map(\.pulse), "Deterministic analysis")
        let manifest = try StudioRangeReview.save(rawA, config: config)
        let saved = try StudioRangeReview.load(rawA, manifest: manifest)
        let verified = try StudioRangeReview.analyze(rawA, config: saved, expectedSourceHash: manifest.sourceHash)
        try check(saved == config && verified.quality.decisionCount == first.quality.decisionCount &&
                  manifest.rate_exposure_valid == 0, "Saved inputs, decisions, and context verification")
        let segment = rawA.run.segments[0].id
        let mask = ReviewInterval(range: .init(segment: segment, first: 262_130, end: 262_190), reason: .manual,
                                  action: .excluded, note: "Operator disturbance")
        let revision = try RunAnnotations.save(.init(masks: [mask]), reader: rawA, replacing: nil)
        let masked = try StudioRangeReview.config(rawA, selection: narrow, settings: settings)
        let result = try StudioRangeReview.analyze(rawA, config: masked)
        try check(masked.annotationRevision == revision.id && result.quality.excluded == 50, "Original indices for an approved exclusion")
        let chosen = try StreamFiles.directory("Chosen exports", in: root, create: true)
        let cleaned = try StreamExporter.export(rawA, name: "Cleaned range", selection: narrow, format: .cleaned,
                                                includeAnalyses: true, destination: chosen)
        try check(cleaned.deletingLastPathComponent().path == chosen.path &&
                  !StreamFiles.exists(project.folder.appendingPathComponent("Exports")), "Write to the selected folder only")
        let rows = try String(contentsOf: cleaned.appendingPathComponent("cleaned.csv"), encoding: .utf8)
        let coverage = try String(contentsOf: cleaned.appendingPathComponent("selection-coverage.json"), encoding: .utf8)
        let table = try String(contentsOf: cleaned.appendingPathComponent("exclusions.csv"), encoding: .utf8)
        try check(rows.split(separator: "\n").count == 11 && rows.contains(",262190,") &&
                  table.contains(",262140,262190,") && coverage.contains("\"retainedSamples\":10"), "Cleaned export indexes, selected exclusions and coverage")
        try check(FileManager.default.fileExists(atPath: cleaned.appendingPathComponent("analyses/\(manifest.id.uuidString)/pulse-decisions.jsonl").path),
                  "Project export includes verified decision files")
        let raw = try StreamExporter.export(rawA, name: "Raw range", selection: narrow, format: .binary, includeAnalyses: false)
        try check(Data(contentsOf: raw.appendingPathComponent("raw.bin")).count == 120, "Original binary selected words")
        do {
            _ = try StreamExporter.export(rawA, name: "Cleaned range", selection: narrow, format: .binary,
                                          includeAnalyses: false, destination: chosen)
            throw RangeCheckFailure(message: "Existing export was replaced")
        } catch let error as POSIXError where error.code == .EEXIST {
            try check(String(contentsOf: cleaned.appendingPathComponent("cleaned.csv"), encoding: .utf8) == rows,
                      "Collision preserves the original export")
        }
        let cancelledExport = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StreamExporter.export(rawA, name: "Cancelled", selection: narrow, format: .csv,
                                             includeAnalyses: false, destination: chosen)
        }.result
        guard case .failure(is CancellationError) = cancelledExport else {
            throw RangeCheckFailure(message: "Cancelled export completed")
        }
        try check(FileManager.default.contentsOfDirectory(atPath: chosen.path) == ["Cleaned range"],
                  "Cancellation leaves no staging files in the selected folder")

        try zipExport(rawA, manifest: manifest, range: whole, folder: chosen)
        _ = try RunAnnotations.undo(rawA, revision: revision.id)
        try check(try RunAnnotations.read(rawA) == nil && rawHashes(rawA) == hashes, "Undo leaves raw SHA-256 unchanged")
        let cancelled = await Task.detached {
            do {
                var frames = 0
                _ = try StudioRangeReview.analyze(rawA, config: config, source: { _ in
                    frames += 1
                    if frames == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        let cancelledSave = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try StudioRangeReview.save(rawA, config: config); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try check(cancelled && cancelledSave && (try StreamStudio.analyses(rawA)).map(\.id) == [manifest.id], "Cancellation publishes no analysis")
        try checkRateBoundary(project)
        try checkAveraging(project, folder: chosen)
        let fast = try synthetic(project, stream: 17, rate: 500_000, count: 15_000_000, split: 2048, faults: false)
        let fastRange = StreamSelection(lower: 0, upper: try fast.duration())
        let fastConfig = try StudioRangeReview.config(fast, selection: fastRange, settings: ReviewSettings(sampleRate: 500_000))
        let start = Date()
        let fastResult = try StudioRangeReview.analyze(fast, config: fastConfig)
        let elapsed = Date().timeIntervalSince(start)
        try check(fastResult.quality.samples == 15_000_000 && fastResult.spectra.first?.sampleRate == 500_000, "30 seconds at 500 kS/s")
        let evidence = try electronics(project, history: URL(fileURLWithPath: arguments[2]))
        var usage = rusage()
        let residentBytes = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : 0
        let report: [String: Any] = ["synthetic500kSamples": fastResult.quality.samples, "synthetic500kAnalysisSeconds": elapsed,
                                     "syntheticRateExposureValid": fastResult.quality.rate_exposure_valid,
                                     "validationProcessPeakRSSBytes": residentBytes,
                                     "chunkIndependence": true, "knownAndUnknownGaps": true, "separateSegmentRates": true, "cancelledReadAndSave": true,
                                     "nearThresholdAndTileBoundary": true, "measuredElectronics": evidence]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: arguments[3]))
        print("PASS range, file boundaries, coverage, export, cancellation, raw hashes, 500 kS/s and measured electronics replay")
    }

    static func checkAveraging(_ project: StreamProjectStore, folder: URL) throws {
        let expectedRates = [125_000.0, 62_500, 31_250, 15_625, 7_812.5]
        for (preset, expectedRate) in zip(ADCAveraging.allCases, expectedRates) {
            let samples = (0..<preset.count).map { UInt16(100 + $0) }
            let average = preset.latest(in: samples, at: 0)
            try check(preset.rate() == expectedRate && average?.mean == 100 + Double(preset.count - 1) / 2,
                      "Exact nominal rate and fractional mean for each preset")
        }
        let preset = ADCAveraging.four
        let samples: [UInt16] = [100, 101, 102, 103, 200, 201, 202, 203, 300, 301, 302, 303,
                                 500, 0, 4095, 0x8800, 600, 601, 602, 603, 700]
        let run = try project.makeRun(name: "Averaged ADC0", description: "Synthetic ADC words",
                                      settings: .init(mode: .main, nominalRate: 500_000, duration: 1, adcAveraging: preset))
        var feeder = try Feed(project, run: run, stream: 55, rate: 500_000, start: 1_000_000)
        for range in [0..<3, 3..<6, 9..<15, 15..<samples.count] {
            var words = Data()
            for word in samples[range] { StreamWire.put(word, into: &words) }
            try feeder.append(words, at: UInt64(range.lowerBound))
        }
        let reader = try feeder.finish(project, interrupted: true)
        let before = try rawHashes(reader)
        try check(reader.run.settings.adcAveraging == .four, "Averaging preset reopens with the run")
        let selection = StreamSelection(lower: 0, upper: try reader.duration())
        let result = try StreamExporter.export(reader, name: "Averaging proof", selection: selection, format: .zip,
                                               includeAnalyses: false, destination: folder)
        let extracted = try StreamFiles.directory("Averaging proof extracted", in: folder, create: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", result.path, "-d", extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        try check(unzip.terminationStatus == 0, "ZIP with two CSV members opens")
        let averaged = try String(contentsOf: extracted.appendingPathComponent("averaged.csv"), encoding: .utf8)
        let rows = averaged.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        try check(rows.map { UInt64($0[2]) } == [0, 12, 16] && rows.allSatisfy { Double($0[5]) == 125_000 },
                  "Aligned groups survive frame boundaries and skip gaps and incomplete tails")
        try check(Double(rows[0][4]) == 0.000003 && Double(rows[0][7]) == 101.5 && Double(rows[2][7]) == 601.5,
                  "Fractional means and group center timing")
        try check(rows[1][7].isEmpty && Array(rows[1].suffix(3)) == ["1", "1", "1"],
                  "Both rails and ADC errors remain explicit")
        let raw = try String(contentsOf: extracted.appendingPathComponent("raw.csv"), encoding: .utf8)
        try check(raw.split(separator: "\n").dropFirst().count == samples.count - 3 && rawHashes(reader) == before,
                  "Original CSV words and raw hashes are preserved")
        let narrow = StreamSelection(lower: 1 / 500_000, upper: 19 / 500_000)
        let partial = try StreamExporter.export(reader, name: "Averaging partial range", selection: narrow, format: .csv,
                                                includeAnalyses: false, destination: folder)
        let partialCSV = try String(contentsOf: partial.appendingPathComponent("averaged.csv"), encoding: .utf8)
        try check(partialCSV.split(separator: "\n").dropFirst().count == 1 && partialCSV.contains(",12,16,"),
                  "Partial selection edges do not manufacture averages")
        print("PASS all five ADC averaging presets, gaps, rail flags, selection edges, and raw plus averaged ZIP")
    }

    static func zipExport(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest,
                          range: StreamSelection, folder: URL) throws {
        let zip = try StreamExporter.export(reader, name: "Recording.zip", selection: range, format: .zip,
                                            includeAnalyses: false, destination: folder)
        try check(zip.lastPathComponent == "Recording.zip", "ZIP extension is added once")
        let raw = try StreamExporter.export(reader, name: "Recording CSV", selection: range, format: .csv,
                                            includeAnalyses: true, destination: folder)
        let extracted = try StreamFiles.directory("Extracted", in: folder, create: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zip.path, "-d", extracted.path]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "macOS unzip validates the archive and CRCs")
        let files = ["raw.csv", "run.json", "ranges.jsonl", "annotations.json",
                     "analyses/\(manifest.id.uuidString)/pulse-decisions.jsonl"]
        for path in files {
            try check(FileManager.default.contentsEqual(atPath: raw.appendingPathComponent(path).path,
                                                        andPath: extracted.appendingPathComponent(path).path),
                      "ZIP matches folder export for \(path)")
        }
        func coverage(_ directory: URL, format: StreamExporter.Format) throws -> NSDictionary {
            let data = try Data(contentsOf: directory.appendingPathComponent("selection-coverage.json"))
            guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  manifest.removeValue(forKey: "format") as? String == format.rawValue else {
                throw RangeCheckFailure(message: "Export format missing from coverage")
            }
            return manifest as NSDictionary
        }
        try check(coverage(raw, format: .csv) == coverage(extracted, format: .zip),
                  "Archive and folder report the same selected coverage")
        let inventory = try StreamFiles.read([StreamAnalysisOutput].self, extracted.appendingPathComponent("files.json"))
        for entry in inventory {
            let bytes = try Data(contentsOf: extracted.appendingPathComponent(entry.file))
            try check(entry.bytes == UInt64(bytes.count) && entry.sha256 == StreamFiles.sha(bytes),
                      "Archive manifest verifies \(entry.file)")
        }
        let source = extracted.appendingPathComponent("raw.csv")
        let legacyFile = folder.appendingPathComponent("legacy.csv")
        let batchedFile = folder.appendingPathComponent("batched.csv")
        let reader = try reader.prepared()
        let clock = ContinuousClock()
        let old = try StreamOutput(legacyFile)
        let oldDuration = try clock.measure {
            try old.line("segment,stream_id,original_index,nominal_time_s,raw_word,adc_code,adc_error")
            try reader.visit(range) { part in
                try part.words.withUnsafeBytes { bytes in
                    for i in 0..<part.reference.count {
                        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                        let index = part.reference.first + UInt64(i)
                        let time = part.segment.timelineStart + Double(index) / part.configuredRate
                        try old.line("\(part.segment.id),\(part.segment.stream),\(index),\(time),\(word),\(word & 4095),\(word >> 15)")
                    }
                }
            }
            _ = try old.finish(file: "raw.csv", type: "signalbench.adc-csv")
        }
        let batched = try StreamOutput(batchedFile)
        let prefixes = Dictionary(uniqueKeysWithValues: reader.run.segments.map {
            ($0.id, Data("\($0.id.uuidString),\($0.stream),".utf8))
        })
        let batchDuration = try clock.measure {
            var csv = try RunSampleCSV(output: batched)
            try reader.visit(range) { part in
                let first = part.reference.first
                try csv.append(part, pieces: [first..<(first + UInt64(part.reference.count))], prefix: prefixes[part.segment.id]!)
            }
            try csv.flush()
            _ = try batched.finish(file: "raw.csv", type: "signalbench.adc-csv")
        }
        try check(FileManager.default.contentsEqual(atPath: source.path, andPath: legacyFile.path) &&
                  FileManager.default.contentsEqual(atPath: source.path, andPath: batchedFile.path),
                  "Batched CSV preserves bytes through gaps and ADC errors")
        let zipBytes = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("CSV benchmark (\(old.bytes) bytes): previous \(oldDuration), batched \(batchDuration). ZIP \(zipBytes) bytes.")
        do {
            _ = try StreamExporter.export(reader, name: "Recording", selection: range, format: .zip,
                                          includeAnalyses: false, destination: folder)
            throw RangeCheckFailure(message: "Existing ZIP was replaced")
        } catch let error as POSIXError where error.code == .EEXIST {}
    }

    static func synthetic(_ project: StreamProjectStore, stream: UInt64, rate: Int, count: Int, split: Int,
                          faults: Bool = true) throws -> StreamRangeReader {
        let run = try project.makeRun(name: "Offline test \(stream)", description: "Synthetic waveform",
                                      settings: .init(mode: .main, nominalRate: rate, duration: Double(count) / Double(rate)))
        var feeder = try Feed(project, run: run, stream: stream, rate: rate, start: 1_000_000)
        var i = 0, frames = 0
        while i < count {
            if faults && i == 320_000 { i += 100 }
            let gap = faults && i < 320_000 ? 320_000 : count
            let end = min(count, gap, i + split)
            var words = Data()
            for j in i..<end {
                var word = UInt16(2048 + Int((4 * sin(Double(j) * 2 * .pi * 60 / Double(rate))).rounded()))
                if faults {
                    if (262_141..<262_158).contains(j) { word -= UInt16(28 + max(0, 5 - abs(j - 262_146))) }
                    if (383_200..<383_221).contains(j) { word -= UInt16(210 - abs(j - 383_210) * 8) }
                    if (479_999..<480_002).contains(j) { word = 4095 }
                    if j == 500_001 { word |= 0x8000 }
                }
                StreamWire.put(word, into: &words)
            }
            try feeder.append(words, at: UInt64(i))
            frames += 1
            if split == 887 && frames.isMultiple(of: 40) { try feeder.writer.commit() }
            i = end
        }
        return try feeder.finish(project, interrupted: faults)
    }

    static func electronics(_ project: StreamProjectStore, history: URL,
                            review: (StreamRangeReader) throws -> Void = { _ in }) throws -> [String: Any] {
        struct Capture: Decodable {
            let metadata: [String: String]
            let sampleCount: Int
            let sampleSHA256: String
        }
        let folders = try FileManager.default.contentsOfDirectory(at: history.appendingPathComponent("records"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("record-") }
        let records = try folders.map { folder -> (UInt64, Capture, URL) in
            let item = try StreamFiles.decoder.decode(Capture.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
            guard let start = item.metadata["start_us"].flatMap(UInt64.init) else { throw RangeCheckFailure(message: "Missing capture clock") }
            return (start, item, folder.appendingPathComponent("samples.bin"))
        }.sorted { $0.0 < $1.0 }
        try check(records.count == 154, "Historical recording identity")
        let origin = records[0].0
        let run = try project.makeRun(name: "Electronics only replay", description: "Firmware 1.5 recording, nominal timing reconstructed from device window starts",
                                      settings: .init(mode: .main, duration: 301))
        var feeder = try Feed(project, run: run, stream: 21, rate: 100_000, start: origin)
        var expected = SHA256()
        for (start, record, file) in records {
            let words = try Data(contentsOf: file)
            try check(words.count == 2 * record.sampleCount && StreamFiles.sha(words) == record.sampleSHA256, "Original window SHA-256")
            expected.update(data: words)
            let index = (start - origin + 5) / 10
            for first in stride(from: 0, to: record.sampleCount, by: 2048) {
                let end = min(first + 2048, record.sampleCount)
                try feeder.append(words.subdata(in: 2 * first..<2 * end), at: index + UInt64(first))
            }
        }
        let reader = try feeder.finish(project, interrupted: false)
        let range = StreamSelection(lower: 0, upper: try reader.duration())
        let settings = ReviewSettings()
        let config = try StudioRangeReview.config(reader, selection: range, settings: settings)
        let result = try StudioRangeReview.analyze(reader, config: config)
        try review(reader)
        var actual = SHA256()
        try reader.visit(range) { actual.update(data: $0.words) }
        try check(expected.finalize() == actual.finalize() && result.quality.samples == 5_046_272 &&
                  result.quality.gaps.count == 153 && result.quality.minutes.allSatisfy { $0.errors == 0 && $0.clips == 0 },
                  "Historical samples, gaps and ADC quality")
        for (_, record, file) in records {
            try check(try StreamFiles.sha(Data(contentsOf: file)) == record.sampleSHA256, "Original SHA-256 unchanged after replay")
        }
        return ["windows": records.count, "samples": result.quality.samples, "knownGaps": result.quality.gaps.count,
                "sampledSeconds": result.quality.minutes.reduce(0) { $0 + $1.sampledSeconds },
                "spectrumSeconds": result.spectra.first?.analyzedSeconds ?? 0,
                "spectrumWindows": result.spectra.first?.windows ?? 0, "nominalSampleRate": 100_000,
                "minuteRobustNoiseADCCodes": result.quality.minutes.compactMap(\.noise),
                "physicalGainConfirmed": false, "rawSHA256Unchanged": true]
    }

    static func checkRateBoundary(_ project: StreamProjectStore) throws {
        let rate = 123_456
        let run = try project.makeRun(name: "Configured rate boundary", description: "Synthetic configured and fallback rate segments",
                                      settings: .init(mode: .main, nominalRate: rate, duration: 5))
        let words = Data([0, 8] + Array(repeating: [UInt8(1), 8], count: 2047).flatMap { $0 })
        var first = try Feed(project, run: run, stream: 25, rate: rate, start: 1_000_000)
        for i in 0..<32 { try first.append(words, at: UInt64(i * 2048)) }
        let interrupted = try first.finish(project, interrupted: true)
        var second = try Feed(project, run: project.openRun(interrupted.run.id), stream: 26, rate: rate, start: 3_000_000)
        for i in 0..<32 { try second.append(words, at: UInt64(i * 2048)) }
        var reopened = try second.finish(project, interrupted: false).run
        // Exercise a segment whose legacy index has no persisted clock fields.
        reopened.segments[1].adcClock = nil
        reopened.segments[1].divider256 = nil
        let reader = StreamRangeReader(store: project, run: reopened)
        let range = StreamSelection(lower: 0, upper: try reader.duration())
        let spectra = try PostRunAnalysis.spectra(reader, selection: range, exclusions: [])
        try check(spectra.count == 2 && spectra[0].sampleRate != spectra[1].sampleRate &&
                  spectra.allSatisfy { $0.windows > 0 && Set($0.ranges.map(\.segment)).count == 1 },
                  "Separate configured and fallback rate spectra")
    }

    static func rawHashes(_ reader: StreamRangeReader) throws -> [String] {
        try reader.store.chunkSummaries(reader.run).map { try StreamFiles.sha(reader.store.data($0, run: reader.run)) }
    }

    struct Feed {
        let writer: StreamRunWriter
        var account: StreamAccounting
        let stream: UInt64
        let rate: Int
        let start: UInt64

        init(_ project: StreamProjectStore, run: StreamRun, stream: UInt64, rate: Int, start: UInt64) throws {
            writer = try StreamRunWriter(store: project, run: run, stream: stream)
            account = StreamAccounting(stream: stream, channel: 0, rate: rate)
            self.stream = stream
            self.rate = rate
            self.start = start
            var clock = Data()
            StreamWire.put(StreamWire.adcClock, into: &clock)
            guard let divider = StreamWire.divider(for: rate, clock: StreamWire.adcClock) else {
                throw RangeCheckFailure(message: "Unsupported synthetic sample rate")
            }
            StreamWire.put(divider, into: &clock)
            let frame = StreamFrame(kind: .start, sequence: 0, stream: stream, boot: 17, index: 0,
                                    timeUS: start, count: 0, auxiliary: UInt32(rate), flags: 0, payload: clock)
            try account.accept(frame)
            try writer.append(frame)
        }

        mutating func append(_ bytes: Data, at index: UInt64) throws {
            let count = UInt64(bytes.count / 2)
            let frame = StreamFrame(kind: .samples, sequence: account.nextSequence, stream: stream, boot: 17, index: index,
                                    timeUS: start + (index + count) * 1_000_000 / UInt64(rate),
                                    count: UInt32(count), auxiliary: 0, flags: 0, payload: bytes)
            try account.accept(frame)
            try writer.append(frame)
        }

        mutating func finish(_ project: StreamProjectStore, interrupted: Bool) throws -> StreamRangeReader {
            if !interrupted {
                var totals = Data()
                StreamWire.put(account.received, into: &totals)
                try account.accept(.init(kind: .end, sequence: account.nextSequence, stream: stream, boot: 17,
                    index: account.nextIndex, timeUS: account.lastDataTimeUS, count: 0, auxiliary: 0, flags: 0, payload: totals))
            }
            return .init(store: project, run: try writer.finish(accounting: account, issue: interrupted ? "Interrupted test" : nil))
        }
    }
}
