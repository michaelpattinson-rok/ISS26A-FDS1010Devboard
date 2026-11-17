import Darwin
import CryptoKit
import Foundation

nonisolated struct StreamSelection: Codable, Equatable, Sendable {
    var lower: Double
    var upper: Double
    var valid: Bool { (0...86_400).contains(lower) && (lower...86_400).contains(upper) && upper > lower }
}

nonisolated struct StreamRangeReference: Codable, Equatable, Sendable {
    var segment: UUID
    var stream: UInt64
    var chunk: UUID
    var sha256: String
    var first: UInt64
    var count: Int
}

nonisolated struct StreamRangeData: Sendable {
    var segment: StreamRunSegment
    var rate: Int
    var reference: StreamRangeReference
    var words: Data
    var frameAnchor: StreamFrameAnchor? = nil
    var averagedPayload: Data? = nil
    var groups: [ADCAveraging.Group]? = nil
    var recordedNominal: Int { Int(configuredRate.rounded()) }
    var originalPayload: Data { averagedPayload ?? words }

    func sample(at offset: Int) -> WaveformSample {
        let index = reference.first + UInt64(offset)
        return .init(segment: segment.id, index: index,
                     time: segment.timelineStart + Double(index) / configuredRate,
                     word: StreamWire.read(UInt16.self, words, at: offset * 2), group: groups?[offset], board: segment.board)
    }

    var configuredRate: Double { segment.configuredRate(rate) }
    var firstSeconds: Double { segment.timelineStart + Double(reference.first) / configuredRate }
}

nonisolated struct StreamFrameAnchor: Codable, Equatable, Sendable {
    var sequence: UInt32
    var frameFirstIndex: UInt64
    var frameSampleCount: Int
    var deviceFrameEndUS: UInt64
}

nonisolated struct StreamExportRange: Codable, Sendable {
    var input: StreamRangeReference
    var outputSampleOffset: UInt64? = nil
    var firstNominalSeconds: Double
    var frame: StreamFrameAnchor?
}

nonisolated struct StreamRangeReader: Sendable {
    let store: StreamProjectStore
    let run: StreamRun
    var index: [StreamChunkSummary]? = nil

    func prepared() throws -> Self {
        var reader = self
        if reader.index == nil { reader.index = try store.chunkSummaries(run) }
        return reader
    }

    static func sampleBoundary(_ value: Double) -> UInt64 {
        UInt64(max(0, ceil(value - max(1e-7, 4 * value.ulp))))
    }

    func duration() throws -> Double {
        let ends = try (index ?? store.chunkSummaries(run)).reduce(into: [UUID: UInt64]()) { result, chunk in
            result[chunk.segment] = chunk.end
        }
        return run.segments.map {
            $0.timelineStart + Double(max(ends[$0.id, default: 0], $0.accountedSamples)) / $0.configuredRate(run.settings.nominalRate)
        }.max() ?? 0
    }

    func sample(at location: StreamMatchLocation) throws -> WaveformSample? {
        guard let segment = run.segments.first(where: { $0.id == location.segment }),
              location.sample < StreamWire.maxSampleBoundary else { return nil }
        let rate = segment.configuredRate(run.settings.nominalRate)
        let lower = segment.timelineStart + Double(location.sample) / rate
        let upper = segment.timelineStart + Double(location.sample + 1) / rate
        var sample: WaveformSample?
        try visit(.init(lower: lower, upper: upper)) { part in
            guard part.reference.segment == location.segment, part.reference.first == location.sample else { return }
            sample = part.sample(at: 0)
        }
        return sample
    }

    func visit(_ selection: StreamSelection, cancelled: () -> Bool = { false },
               _ body: (StreamRangeData) throws -> Void) throws {
        guard run.curveSource == nil else { throw StreamFailure.storage("This tool needs original ADC data. Open the curve in the waveform workspace.") }
        guard selection.valid else { throw StreamFailure.storage("Choose a nonempty time range.") }
        let byID = Dictionary(uniqueKeysWithValues: run.segments.map { ($0.id, $0) })
        for summary in try (index ?? store.chunkSummaries(run)) {
            guard !cancelled(), !Task.isCancelled else { throw CancellationError() }
            guard let segment = byID[summary.segment] else {
                throw StreamFailure.storage("The raw index is missing its timing segment.")
            }
            let sampleRate = segment.configuredRate(run.settings.nominalRate)
            let lower = max(0, (selection.lower - segment.timelineStart) * sampleRate)
            let upper = max(0, (selection.upper - segment.timelineStart) * sampleRate)
            guard lower < Double(summary.end), Double(summary.first) < upper else { continue }
            let lo = Self.sampleBoundary(lower)
            let hi = Self.sampleBoundary(upper)
            try autoreleasepool {
                let chunk = try store.chunk(summary, run: run)
                let data = try store.data(summary, run: run)
                for slice in chunk.slices {
                    let left = max(lo, slice.first)
                    let right = min(hi, slice.first + UInt64(slice.count))
                    guard right > left else { continue }
                    let size = PicoAverage.stride(segment.picoAveraging)
                    let start = slice.byteOffset + size * Int(left - slice.first)
                    let count = Int(right - left)
                    let payload = data.subdata(in: start..<(start + size * count))
                    let groups = try segment.picoAveraging.map { try PicoAverage.groups(payload, first: left, factor: $0) }
                    let words = groups.map { groups in
                        var projected = Data(capacity: count * 2)
                        for group in groups { StreamWire.put(PicoAverage.projectedWord(group), into: &projected) }
                        return projected
                    } ?? payload
                    try body(.init(segment: segment, rate: run.settings.nominalRate,
                                   reference: .init(segment: segment.id, stream: segment.stream, chunk: chunk.id,
                                                    sha256: chunk.sha256, first: left, count: count),
                                   words: words,
                                   frameAnchor: .init(sequence: slice.sequence, frameFirstIndex: slice.first,
                                                      frameSampleCount: slice.count, deviceFrameEndUS: slice.deviceEndUS),
                                   averagedPayload: groups == nil ? nil : payload, groups: groups))
                }
            }
        }
    }
}

nonisolated struct StreamStats: Codable, Equatable, Sendable {
    var baseline: Double?
    var robustNoise: Double?
    var minimum: Int?
    var maximum: Int?
    var samples: UInt64
    var adcErrors: UInt64
    var clipped: UInt64
    var nominalSampledSeconds: Double
    var selectionSeconds: Double
    var lowRail: UInt64? = nil
    var highRail: UInt64? = nil
}

nonisolated struct StudioPlot: Sendable {
    var columns: [ClosedRange<UInt16>?]
    var breaks: [Double]
    var stats: StreamStats
    var faults: [Bool] = []
    var rails: [Bool] = []
    var gaps: [StreamSelection] = []
    var samples: [WaveformSample] = []
    var indexed = false
    var lowRails: [Bool] = []
    var highRails: [Bool] = []
    var dots: WaveformDots? = nil
    var means: [Double?] = []
}

nonisolated struct StreamAnalysisOutput: Codable, Sendable {
    var file: String
    var type: String
    var version: Int
    var bytes: UInt64
    var sha256: String
    var valid: Bool {
        !file.isEmpty && file.utf8.count <= 120 && !file.hasPrefix(".") && !file.contains("/") && !file.contains("\\")
        && ProfileDigest.valid(sha256) && (1...1_000_000).contains(version) && type.utf8.count <= 120
    }
}

nonisolated struct StreamPulseSummary: Codable, Sendable {
    var matches: UInt64 = 0
    var evaluatedWindows: UInt64 = 0
    var incompleteWindows: UInt64 = 0
    var outsideEnvelope: UInt64 = 0
    var usableSamples: UInt64? = nil
    var operatorExcludedSamples: UInt64? = nil
    var candidates: UInt64? = nil

    mutating func add(_ result: ProfileWindowResult, usable: Int? = nil) {
        evaluatedWindows += 1
        candidates = (candidates ?? 0) + UInt64(result.candidates.count)
        if result.complete && !result.outsideEnvelope { usableSamples = (usableSamples ?? 0) + UInt64(usable ?? result.usableSamples) }
        if !result.complete { incompleteWindows += 1 }
        if result.outsideEnvelope { outsideEnvelope += 1 }
        if result.complete && !result.outsideEnvelope { matches += UInt64(result.matchCount) }
    }
}

nonisolated private struct StreamQualityExport: Encodable {
    var type = "signalbench.quality-summary"
    var version = 1
    let sourceHash: String
    let minutes: [WaveformOverview.Minute]
    let gaps: [StreamSelection]
    let unknownBoundaries: [Double]
    let hasUnboundedUnknownTime: Bool
}

nonisolated private struct StreamExportSelection: Encodable {
    struct Segment: Encodable {
        let id: UUID
        let stream: UInt64
        let sampleRate: Double
        let input: ReviewRange
        let unknownBoundary: Bool
        var quality = ManualSampleQuality()
        var retainedSamples: UInt64 = 0
        var knownMissing: UInt64 = 0
    }
    var type = "signalbench.export-selection"
    var version = 1
    let run: UUID
    let selection: StreamSelection
    let annotationRevision: UUID?
    let format: StreamExporter.Format.RawValue
    var segments: [Segment]
    var rate_exposure_valid = 0
}

nonisolated struct StreamMatchLocation: Codable, Identifiable, Sendable {
    let segment: UUID
    let sample: UInt64
    var id: String { segment.uuidString + ":" + String(sample) }
}

nonisolated struct StreamAnalysisManifest: Codable, Identifiable, Sendable {
    var type = "com.issa26.signal-bench-analysis"
    var version = 1
    var id = UUID()
    var run: UUID
    var created = Date()
    var selection: StreamSelection
    var streams: [UInt64]
    var analyzer: String
    var analyzerVersion: Int
    var profileRevision: UUID?
    var rules: ProfilePulseRules?
    var statistics: StreamStats? = nil
    var pulseSummary: StreamPulseSummary? = nil
    var annotationRevision: UUID? = nil
    var status = "complete"
    var rate_exposure_valid = 0
    var sourceHash: String? = nil
    var matchLocations: [StreamMatchLocation]? = nil
    var outputs: [StreamAnalysisOutput]
}

nonisolated final class StreamOutput: @unchecked Sendable {
    private enum Sink {
        case file(FileHandle)
        case archive(RunExportZIP.Member)
    }
    private let sink: Sink
    private var buffer = Data()
    private var digest = SHA256()
    private(set) var bytes: UInt64 = 0

    init(_ url: URL) throws {
        try StreamFiles.directory(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StreamFiles.posix() }
        sink = .file(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    init(member: RunExportZIP.Member) {
        sink = .archive(member)
    }

    func write(_ data: Data) throws {
        digest.update(data: data)
        bytes += UInt64(data.count)
        buffer.append(data)
        if buffer.count >= 65_536 { try flush() }
    }
    func line(_ text: String) throws { try write(Data((text + "\n").utf8)) }
    func item<T: Encodable>(_ value: T) throws {
        try write(StreamFiles.encoder.encode(value))
        try write(Data([10]))
    }
    private func flush() throws {
        guard !buffer.isEmpty else { return }
        switch sink {
        case .file(let handle): try handle.write(contentsOf: buffer)
        case .archive(let member): try member.write(buffer)
        }
        buffer.removeAll(keepingCapacity: true)
    }
    func finish(file: String, type: String) throws -> StreamAnalysisOutput {
        try flush()
        switch sink {
        case .file(let handle):
            try handle.synchronize()
            try handle.close()
        case .archive(let member): try member.finish()
        }
        return .init(file: file, type: type, version: 1, bytes: bytes,
                     sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

nonisolated enum StreamStudio {
    static func plot(_ reader: StreamRangeReader, selection: StreamSelection, columns count: Int = 960,
                     dotPercent: Double? = nil, dotLimit: Int = WaveformDots.savedLimit) throws -> StudioPlot {
        try reduceWaveform(selection, rate: reader.run.settings.recordedRate, columns: count,
                           dotPercent: dotPercent, dotLimit: dotLimit, board: reader.run.settings.board) { accept in
            try reader.visit(selection) { part in
                try accept(part.segment.id, part.reference.first, part.firstSeconds, part.configuredRate, part.words, part.groups)
            }
        }
    }

    static func reduceWaveform(_ selection: StreamSelection, rate: Double, columns count: Int = 960,
                               dotPercent: Double? = nil, dotLimit: Int = WaveformDots.savedLimit,
                               board: AcquisitionBoard = .picoW, visit: ((UUID, UInt64, Double, Double, Data, [ADCAveraging.Group]?) throws -> Void) throws -> Void) throws -> StudioPlot {
        guard (1...4096).contains(count), selection.valid else { throw StreamFailure.storage("Invalid waveform preview size.") }
        var minima = Array(repeating: UInt16.max, count: count), maxima = Array(repeating: UInt16(0), count: count)
        var sums = Array(repeating: 0.0, count: count)
        var counts = Array(repeating: UInt64(0), count: count)
        var bins = Array(repeating: UInt64(0), count: Int(board.maxCode) + 1)
        var total: UInt64 = 0, bad: UInt64 = 0, clipped: UInt64 = 0, unavailable: UInt64 = 0
        var lowCount: UInt64 = 0, highCount: UInt64 = 0
        var sampledSeconds = 0.0
        var breaks: [Double] = []
        var gaps: [StreamSelection] = []
        var faults = Array(repeating: false, count: count)
        var rails = faults, lowRails = faults, highRails = faults
        var exact: [WaveformSample] = []
        let showSamples = (selection.upper - selection.lower) * rate <= Double(count - 4)
        var lastTime = selection.lower
        var previous: (segment: UUID, next: UInt64)?
        let span = selection.upper - selection.lower
        let dotSelection = dotPercent.map {
            WaveformDotSelection(percent: $0, limit: dotLimit, possible: Int((span * rate).rounded(.up)))
        }
        var dots: [SIMD2<Float>] = []
        var firstDot: SIMD2<Float>?
        if let dotSelection { dots.reserveCapacity(dotSelection.capacity) }
        try visit { segment, index, first, rate, words, groups in
            try Task.checkCancellation()
            let length = words.count / 2
            if let previous, previous.segment != segment || previous.next != index { breaks.append(first) }
            if first > lastTime + (previous == nil ? 1 / rate : 0.0000001) { gaps.append(.init(lower: lastTime, upper: first)) }
            previous = (segment, index + UInt64(length))
            sampledSeconds += Double(length) / rate
            lastTime = first + Double(length) / rate
            words.withUnsafeBytes { bytes in
                for i in 0..<length {
                    let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                    total += 1
                    let time = first + Double(i) / rate
                    let position = (time - selection.lower) / span
                    let x = min(count - 1, max(0, Int(position * Double(count))))
                    let group = groups?[i]
                    if showSamples {
                        exact.append(.init(segment: segment, index: index + UInt64(i), time: time, word: word, group: group, board: board))
                    }
                    if let group {
                        if group.adcErrors > 0 { bad += 1; faults[x] = true }
                        if group.lowRail > 0 { lowCount += 1; lowRails[x] = true }
                        if group.highRail > 0 { highCount += 1; highRails[x] = true }
                        if group.lowRail + group.highRail > 0 { clipped += 1; rails[x] = true }
                        if group.mean == nil { unavailable += 1; continue }
                    } else if word & 0x8000 != 0 { bad += 1; unavailable += 1; faults[x] = true; continue }
                    let value = board.sampleCode(word)
                    let precise = group?.mean ?? Double(value)
                    if let dotSelection, dots.count < dotSelection.limit {
                        if dotSelection.includes(index + UInt64(i)) {
                            dots.append(.init(Float(position), Float(precise)))
                        } else if dots.isEmpty && firstDot == nil {
                            firstDot = .init(Float(position), Float(precise))
                        }
                    }
                    sums[x] += precise
                    counts[x] += 1
                    bins[Int(value)] += 1
                    if group == nil && (value == 0 || value == board.maxCode) {
                        clipped += 1
                        rails[x] = true
                        if value == 0 { lowRails[x] = true; lowCount += 1 }
                        else { highRails[x] = true; highCount += 1 }
                    }
                    minima[x] = min(minima[x], value)
                    maxima[x] = max(maxima[x], value)
                }
            }
        }
        if selection.upper > lastTime + 0.0000001 { gaps.append(.init(lower: lastTime, upper: selection.upper)) }
        if dots.isEmpty, let firstDot { dots.append(firstDot) }
        let valid = total - unavailable
        let median = weightedMedian(bins, total: valid)
        var mad: Double?
        if let median {
            var deviations = Array(repeating: UInt64(0), count: 2 * bins.count - 1)
            for (value, n) in bins.enumerated() where n > 0 { deviations[Int(abs(Double(value) - median) * 2)] += n }
            mad = weightedMedian(deviations, total: valid).map { $0 * 0.7413 }
        }
        let stats = StreamStats(baseline: median, robustNoise: mad, minimum: bins.firstIndex { $0 > 0 },
                                maximum: bins.lastIndex { $0 > 0 }, samples: total, adcErrors: bad, clipped: clipped,
                                nominalSampledSeconds: sampledSeconds, selectionSeconds: span,
                                lowRail: lowCount, highRail: highCount)
        return .init(columns: minima.indices.map { minima[$0] == .max ? nil : minima[$0]...maxima[$0] }, breaks: breaks, stats: stats, faults: faults, rails: rails, gaps: gaps, samples: exact,
                     lowRails: lowRails, highRails: highRails, dots: dotSelection == nil ? nil : .init(values: dots),
                     means: zip(sums, counts).map { $1 == 0 ? nil : Double($0) / Double($1) })
    }

    static func weightedMedian(_ bins: [UInt64], total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        let lo = (total - 1) / 2, hi = total / 2
        var count: UInt64 = 0
        var low: Int?
        for (i, n) in bins.enumerated() {
            count += n
            if low == nil && count > lo { low = i }
            if count > hi { return Double((low ?? i) + i) / 2 }
        }
        return nil
    }

    static func save(_ reader: StreamRangeReader, selection: StreamSelection, rules: ProfilePulseRules? = nil,
                     sourceHash: String? = nil) throws -> StreamAnalysisManifest {
        let reader = try reader.prepared()
        let profile = reader.run.settings.profile
        let annotations = try RunAnnotations.read(reader)
        let exclusions = RunAnnotations.merged(annotations?.masks ?? [])
        if rules != nil {
            guard reader.run.settings.channel == 0, !reader.run.hasCadenceMismatch, let profile, profile.valid,
                  profile.measurementReady, profile.setup.nominalHz == reader.run.settings.nominalRate,
                  profile.setup.acquisitionDevice == reader.run.settings.board,
                  profile.setup.picoAveraging == reader.run.settings.picoAveraging,
                  profile.setup.gain == reader.run.settings.gain, rules?.valid == true else {
                throw StreamFailure.storage("Pulse analysis needs a compatible, saved ADC0 profile.")
            }
            try ProfileFixtureValidation.verify(profile, in: reader.store)
        }
        let runDir = try reader.store.runDirectory(reader.run.id)
        let analyses = try StreamFiles.directory("analyses", in: runDir, create: true)
        let id = UUID()
        let stage = try StreamFiles.directory(".analysis-" + id.uuidString, in: analyses, create: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }
        let sources = try StreamOutput(stage.appendingPathComponent("input-ranges.jsonl"))
        let results = rules == nil ? nil : try StreamOutput(stage.appendingPathComponent("pulse-windows.jsonl"))
        var streams = Set<UInt64>()
        var summary = StreamPulseSummary()
        var matchLocations: [StreamMatchLocation] = []
        var excludedSamples: UInt64 = 0
        let stats = try plot(reader, selection: selection).stats
        func source(_ part: StreamRangeData) throws {
            try sources.item(part.reference)
            streams.insert(part.reference.stream)
            if results != nil {
                let first = part.reference.first
                let pieces = RunAnnotations.retained(first..<(first + UInt64(part.reference.count)), excluding: exclusions[part.segment.id] ?? [])
                excludedSamples += UInt64(part.reference.count - pieces.reduce(0) { $0 + $1.count })
            }
        }
        if let rules, let profile, let results {
            try ContinuousPulseScan.scan(reader, selection: selection, profile: profile, rules: rules,
                                         excluding: exclusions, source: source) { window in
                summary.add(window.result, usable: window.usable)
                if window.result.complete && !window.result.outsideEnvelope && matchLocations.count < 128 {
                    for item in window.result.candidates.lazy.filter({ $0.decision == "match" }).prefix(128 - matchLocations.count) {
                        matchLocations.append(.init(segment: window.segment, sample: window.contextFirst + UInt64(item.peak)))
                    }
                }
                try results.item(window)
            }
        } else {
            try reader.visit(selection, source)
        }
        guard stats.samples > 0 else { throw StreamFailure.storage("The selected range contains no verified samples.") }
        let statOutput = try StreamOutput(stage.appendingPathComponent("statistics.json"))
        try statOutput.write(StreamFiles.encoder.encode(stats))
        var outputs = [try sources.finish(file: "input-ranges.jsonl", type: "signalbench.raw-ranges"),
                       try statOutput.finish(file: "statistics.json", type: "signalbench.raw-statistics")]
        if let results { outputs.append(try results.finish(file: "pulse-windows.jsonl", type: "signalbench.owned-pulse-windows")) }
        summary.operatorExcludedSamples = excludedSamples
        let manifest = StreamAnalysisManifest(id: id, run: reader.run.id, selection: selection, streams: streams.sorted(),
                                              analyzer: rules == nil ? "signalbench.histogram" : "signalbench.profile-pulses",
                                              analyzerVersion: rules == nil ? 1 : ContinuousPulseScan.algorithmVersion,
                                              profileRevision: profile?.id, rules: rules, statistics: stats,
                                              pulseSummary: results == nil ? nil : summary,
                                              annotationRevision: annotations?.id,
                                              status: summary.incompleteWindows > 0 ? "partial" : "complete", sourceHash: sourceHash, matchLocations: matchLocations.isEmpty ? nil : matchLocations, outputs: outputs)
        try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        try Task.checkCancellation()
        let target = analyses.appendingPathComponent(id.uuidString)
        guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        published = true
        try StreamFiles.sync(analyses)
        return manifest
    }

    static func analyses(_ reader: StreamRangeReader) throws -> [StreamAnalysisManifest] {
        let parent = try reader.store.runDirectory(reader.run.id).appendingPathComponent("analyses")
        return try analyses(in: parent, sourceRun: reader.run.id)
    }

    static func analyses(in parent: URL, sourceRun: UUID) throws -> [StreamAnalysisManifest] {
        guard StreamFiles.exists(parent) else { return [] }
        try StreamFiles.directory(parent)
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            let manifest = try StreamFiles.read(StreamAnalysisManifest.self, dir.appendingPathComponent("analysis.json"))
            guard id == manifest.id, manifest.run == sourceRun, manifest.selection.valid,
                  manifest.outputs.count <= 64, manifest.outputs.allSatisfy(\.valid) else {
                throw StreamFailure.storage("A saved analysis reference is invalid.")
            }
            return manifest
        }.sorted { $0.created > $1.created }
    }
}

nonisolated struct StreamPulseBlocks {
    private var anchor: StreamRangeData?
    private var samples: [UInt16] = []
    private var means: [Double] = []
    private var nextIndex: UInt64 = 0

    mutating func append(_ part: StreamRangeData, output: (CaptureRecord) throws -> Void) throws {
        if let anchor, anchor.segment.id != part.segment.id || nextIndex != part.reference.first {
            try finish(output)
        }
        try part.words.withUnsafeBytes { bytes in
            for i in 0..<part.reference.count {
                if anchor == nil {
                    var adjusted = part
                    adjusted.reference.first += UInt64(i)
                    adjusted.words = Data()
                    adjusted.averagedPayload = nil
                    adjusted.groups = nil
                    anchor = adjusted
                }
                samples.append(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                if let group = part.groups?[i] { means.append(group.mean ?? 0) }
                nextIndex = part.reference.first + UInt64(i + 1)
                if samples.count == max(256, StreamWire.samples(32_768, at: part.configuredRate)) { try finish(output) }
            }
        }
    }

    mutating func finish(_ output: (CaptureRecord) throws -> Void) throws {
        guard let anchor, !samples.isEmpty else { return }
        let start = (anchor.segment.firstDeviceUS ?? 0) + UInt64(Double(anchor.reference.first) * 1_000_000 / anchor.configuredRate)
        let count = samples.count
        var metadata: [String: String] = ["boot_id": String(format: "%016llx", anchor.segment.boot ?? 0),
            "sample_hz": String(anchor.segment.picoAveraging == nil ? anchor.rate : anchor.recordedNominal), "configured_hz": String(anchor.configuredRate), "start_us": String(start),
            "end_us": String(start + UInt64(Double(count) * 1_000_000 / anchor.configuredRate)),
            "n": String(count), "observation_only": "1", "acquisition_board": anchor.segment.board.rawValue, "channel": "ADC0", "acq_flags": "0",
            "host_stream_id": String(anchor.segment.stream), "host_stream_first": String(anchor.reference.first),
            "host_stream_segment": anchor.segment.id.uuidString, "host_stream_elapsed": String(anchor.firstSeconds)]
        if let factor = anchor.segment.picoAveraging { metadata["pico_average"] = String(factor.count) }
        try output(.init(id: "\(anchor.segment.id.uuidString):\(anchor.reference.first)", metadata: metadata,
                         events: [], samples: samples, complete: true, averagedCodes: means.isEmpty ? nil : means))
        samples.removeAll(keepingCapacity: true)
        means.removeAll(keepingCapacity: true)
        self.anchor = nil
    }
}

nonisolated enum StreamExporter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case binary = "Original Binary", csv = "Raw CSV", cleaned = "Cleaned CSV"
        case zip = "Full Run ZIP", binaryZIP = "Original Binary + Run Info (ZIP)"
        case averaged = "Averaged CSV"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .binary: "Creates a folder with the original ADC words, run details and timing."
            case .csv: "Creates a folder with the sample CSV, run details and timing. Large CSVs need more disk space."
            case .cleaned: "Creates a CSV that omits samples covered by the Project’s approved exclusions. Original sample indices are preserved."
            case .zip: "Includes Main.md, sample CSVs, timing, quality, flags, notes and saved analyses."
            case .binaryZIP: "Packages the original ADC words and run information in one ZIP. Choose this for full resolution without CSV conversion."
            case .averaged: "Exports only the saved averaging preset’s complete groups. Groups with ADC errors or rail hits retain their flags and have no mean."
            }
        }

        var includesRunInfo: Bool { self == .zip || self == .binaryZIP }
        var writesBinary: Bool { self == .binary || self == .binaryZIP }

        // Used only to present an order of magnitude before reading raw data.
        func estimatedBytes(samples: UInt64, averaging: ADCAveraging?, pico: ADCAveraging? = nil,
                            hasExclusions: Bool = false) -> Double {
            if let pico {
                if writesBinary { return Double(samples) * Double(PicoAverage.stride(pico)) }
                return Double(samples) * (self == .zip && hasExclusions ? 300 : 150)
            }
            return switch self {
            case .binary, .binaryZIP: Double(samples) * 2
            case .averaged: Double(samples) / Double(averaging?.count ?? 1) * 120
            case .csv, .cleaned, .zip:
                Double(samples) * (85 * (self == .zip && hasExclusions ? 2 : 1) + (averaging.map { 120 / Double($0.count) } ?? 0))
            }
        }
    }

    static func export(_ reader: StreamRangeReader, name: String, selection: StreamSelection,
                       format: Format, includeAnalyses: Bool, destination: URL? = nil,
                       progress: (Double) -> Void = { _ in }, checkpoint: () throws -> Void = {},
                       beforePublish: () throws -> Void = {}) throws -> URL {
        guard selection.valid else { throw StreamFailure.storage("Choose a nonempty time range.") }
        let name = try SessionStore.projectName(name)
        let title = format.includesRunInfo && name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)) : name
        let root = try destination ?? reader.store.exports()
        try StreamFiles.directory(root)
        let target = root.appendingPathComponent(format.includesRunInfo ? try SessionStore.projectName(title) + ".zip" : title,
                                                 isDirectory: !format.includesRunInfo)
        if try StreamFiles.isPresent(target) { throw POSIXError(.EEXIST) }
        try Task.checkCancellation()
        let stage = try StreamFiles.directory(".export-" + UUID().uuidString, in: root, create: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let reader = try reader.prepared()
        let includeAnalyses = includeAnalyses || format.includesRunInfo
        let archiveFile = stage.appendingPathComponent(".run.zip")
        let archive = try format.includesRunInfo ? RunExportZIP(archiveFile, date: reader.run.created) : nil
        if format == .averaged, reader.run.settings.adcAveraging == nil, reader.run.settings.picoAveraging == nil {
            throw StreamFailure.storage("This run has no averaging preset.")
        }
        let annotations = try RunAnnotations.read(reader)
        let exclusions = RunAnnotations.merged(annotations?.masks ?? [])
        let ends = (reader.index ?? []).reduce(into: [UUID: UInt64]()) { $0[$1.segment] = max($0[$1.segment, default: 0], $1.end) }
        let nominal = reader.run.settings.nominalRate
        var coverage = StreamExportSelection(run: reader.run.id, selection: selection, annotationRevision: annotations?.id,
            format: format.rawValue, segments: reader.run.segments.enumerated().compactMap { offset, segment in
                let bounds = ReviewInput.indices(selection, segment: segment, rate: nominal)
                let end = max(segment.accountedSamples, ends[segment.id, default: 0])
                let rate = segment.configuredRate(nominal)
                let stop = segment.timelineStart + Double(end) / rate
                let following = reader.run.segments.dropFirst(offset + 1).first?.timelineStart
                let unknown = (segment.unknown || following != nil) && stop <= selection.upper && (following ?? stop) >= selection.lower
                let limit = max(bounds.lowerBound, min(end, bounds.upperBound))
                guard bounds.lowerBound < limit || unknown else { return nil }
                return .init(id: segment.id, stream: segment.stream, sampleRate: rate,
                             input: .init(segment: segment.id, first: bounds.lowerBound, end: limit), unknownBoundary: unknown)
            })
        let byID = Dictionary(uniqueKeysWithValues: coverage.segments.enumerated().map { ($0.element.id, $0.offset) })
        var outputs: [StreamAnalysisOutput] = []
        if let annotations {
            let file = try StreamOutput(stage.appendingPathComponent("annotations.json"))
            try file.write(StreamFiles.encoder.encode(annotations))
            outputs.append(try file.finish(file: "annotations.json", type: "signalbench.annotations"))
        }
        if format == .cleaned || format == .zip && !exclusions.isEmpty {
            let table = try StreamOutput(stage.appendingPathComponent("exclusions.csv"))
            try table.line("segment,first_index,end_index_exclusive,reason,note")
            for mask in annotations?.masks ?? [] {
                guard let i = byID[mask.range.segment] else { continue }
                let input = coverage.segments[i].input
                let first = max(input.first, mask.range.first), end = min(input.end, mask.range.end)
                if first < end {
                    try table.line("\(mask.range.segment),\(first),\(end),\(ReviewFiles.csv(mask.reason.rawValue)),\(ReviewFiles.csv(mask.note))")
                }
            }
            outputs.append(try table.finish(file: "exclusions.csv", type: "signalbench.exclusions"))
        }
        let index = try StreamOutput(stage.appendingPathComponent("ranges.jsonl"))
        let samples = try RunExportSamples(root: stage, archive: archive, format: format, settings: reader.run.settings,
                                           hasExclusions: !exclusions.isEmpty)
        let prefixes = Dictionary(uniqueKeysWithValues: reader.run.segments.map {
            ($0.id, Data("\($0.id.uuidString),\($0.stream),".utf8))
        })
        try StreamFiles.publish(reader.run, at: stage.appendingPathComponent("run.json"))
        var total: UInt64 = 0
        var visited: UInt64 = 0
        var reported = 0
        let expected = max(1, coverage.segments.reduce(0) { $0 + $1.input.count })
        try reader.visit(selection) { part in
            let first = part.reference.first
            let range = first..<(first + UInt64(part.reference.count))
            guard let i = byID[part.segment.id] else { throw StreamFailure.storage("Export coverage is missing its timing segment.") }
            try checkpoint()
            try coverage.segments[i].quality.append(part.originalPayload, averaging: part.segment.picoAveraging, board: part.segment.board)
            let retained = RunAnnotations.retained(range, excluding: exclusions[part.segment.id] ?? [])
            let pieces = format == .cleaned ? retained : [range]
            for piece in pieces {
                var ref = part.reference
                ref.first = piece.lowerBound
                ref.count = piece.count
                let time = part.segment.timelineStart + Double(ref.first) / part.configuredRate
                try index.item(StreamExportRange(input: ref, outputSampleOffset: samples.hasPrimary ? total : nil,
                                                 firstNominalSeconds: time, frame: part.frameAnchor))
                if samples.hasPrimary {
                    total += UInt64(piece.count)
                    coverage.segments[i].retainedSamples += UInt64(piece.count)
                }
            }
            try samples.append(part, range: range, retained: retained, prefix: prefixes[part.segment.id] ?? Data(), checkpoint: checkpoint)
            visited += UInt64(part.reference.count)
            let percent = min(90, Int(Double(visited) * 90 / Double(expected)))
            if percent > reported { reported = percent; progress(Double(percent) / 100) }
        }
        guard coverage.segments.contains(where: { $0.quality.samples > 0 }) else {
            throw StreamFailure.storage("The selected range contains no verified samples.")
        }
        for i in coverage.segments.indices {
            let row = coverage.segments[i]
            coverage.segments[i].knownMissing = row.input.count > row.quality.samples ? row.input.count - row.quality.samples : 0
        }
        let selected = try StreamOutput(stage.appendingPathComponent("selection-coverage.json"))
        try selected.write(StreamFiles.encoder.encode(coverage))
        outputs.append(try selected.finish(file: "selection-coverage.json", type: coverage.type))
        outputs.append(try index.finish(file: "ranges.jsonl", type: "signalbench.raw-ranges"))
        outputs.append(contentsOf: try samples.finish(checkpoint: checkpoint))
        progress(0.9)
        let timeline = try RunTimeline.entries(reader, finished: true)
        if !timeline.isEmpty {
            let events = try StreamOutput(stage.appendingPathComponent("timeline.jsonl"))
            for entry in timeline { try events.item(entry) }
            outputs.append(try events.finish(file: "timeline.jsonl", type: "signalbench.run-timeline"))
        }
        if includeAnalyses, let overview = try WaveformOverview.read(reader) {
            let summary = try StreamOutput(stage.appendingPathComponent("quality-summary.json"))
            let report = StreamQualityExport(sourceHash: overview.sourceHash, minutes: overview.minutes,
                gaps: overview.gaps, unknownBoundaries: overview.unknownBoundaries,
                hasUnboundedUnknownTime: overview.hasUnboundedUnknownTime)
            try summary.write(StreamFiles.encoder.encode(report))
            outputs.append(try summary.finish(file: "quality-summary.json", type: report.type))
        }
        try StreamFiles.publish(outputs, at: stage.appendingPathComponent("files.json"))
        let runFolder = try reader.store.runDirectory(reader.run.id)
        if format.includesRunInfo {
            let moments = try BenchStudy.moments(reader)
            if !moments.isEmpty {
                let file = try StreamOutput(stage.appendingPathComponent("bench-moments.jsonl"))
                for moment in moments { try file.item(moment) }
                _ = try file.finish(file: "bench-moments.jsonl", type: "signalbench.bench-moments")
            }
            let fixture = runFolder.appendingPathComponent("fixture-reference.json")
            if try StreamFiles.isPresent(fixture) {
                _ = try FixtureEvidence.reference(reader)
                try StreamFiles.publish(StreamFiles.read(fixture, limit: 1_048_576),
                                        at: stage.appendingPathComponent("fixture-reference.json"))
            }
            let labels = try TrainingLabels.list(reader.store).filter { $0.run == reader.run.id }
            if !labels.isEmpty {
                let file = try StreamOutput(stage.appendingPathComponent("training-labels.jsonl"))
                for label in labels {
                    try Task.checkCancellation()
                    try file.item(label)
                }
                _ = try file.finish(file: "training-labels.jsonl", type: "signalbench.training-labels")
            }
        }
        let gpio = runFolder.appendingPathComponent("gpio")
        if StreamFiles.exists(gpio) {
            try StreamFiles.directory(gpio)
            let destination = try StreamFiles.directory("gpio", in: stage, create: true)
            for file in try FileManager.default.contentsOfDirectory(at: gpio, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                try Task.checkCancellation()
                let data = try StreamFiles.read(file, limit: 4096)
                _ = try StreamFiles.decoder.decode(StreamGPIO.self, from: data)
                try StreamFiles.publish(data, at: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
        if includeAnalyses {
            let manifests = try StreamStudio.analyses(reader)
            let analysisDir = archive == nil ? try StreamFiles.directory("analyses", in: stage, create: true) : nil
            for manifest in manifests {
                let source = runFolder.appendingPathComponent("analyses").appendingPathComponent(manifest.id.uuidString)
                let destination = try analysisDir.map { try StreamFiles.directory(manifest.id.uuidString, in: $0, create: true) }
                let path = "analyses/\(manifest.id.uuidString)/"
                for file in manifest.outputs {
                    let input = source.appendingPathComponent(file.file)
                    try StreamFiles.directory(source)
                    let fd = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw StreamFiles.posix() }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          info.st_size >= 0, UInt64(info.st_size) == file.bytes else {
                        throw StreamFailure.storage("A saved analysis file changed.")
                    }
                    let writer: StreamOutput
                    if let archive { writer = try StreamOutput(member: archive.entry(path + file.file)) }
                    else if let destination { writer = try StreamOutput(destination.appendingPathComponent(file.file)) }
                    else { throw StreamFailure.storage("The export destination is unavailable.") }
                    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                        try Task.checkCancellation()
                        try checkpoint()
                        try writer.write(data)
                    }
                    let copied = try writer.finish(file: archive == nil ? file.file : path + file.file, type: file.type)
                    guard copied.bytes == file.bytes, copied.sha256 == file.sha256 else {
                        throw StreamFailure.storage("A saved analysis output failed its integrity check.")
                    }
                    if archive != nil { outputs.append(copied) }
                }
                if let archive {
                    let output = try StreamOutput(member: archive.entry(path + "analysis.json"))
                    try output.write(StreamFiles.encoder.encode(manifest))
                    outputs.append(try output.finish(file: path + "analysis.json", type: manifest.type))
                } else if let destination {
                    try StreamFiles.publish(manifest, at: destination.appendingPathComponent("analysis.json"))
                }
            }
        }
        if let archive {
            let linked = reader.run.linkedPreruns
            let leases = try linked.map { link in
                do { return try ProjectReview.ReadLease(reader.store.runDirectory(link.run)) }
                catch { throw StreamFailure.storage("Prerun \(link.run.uuidString) is unavailable. " + error.localizedDescription) }
            }
            defer { withExtendedLifetime(leases) {} }
            for (index, link) in linked.enumerated() {
                try checkpoint()
                outputs += try CalibratedPrerun.export(link, in: reader.store, archive: archive,
                    format: format, staging: stage, checkpoint: checkpoint) { fraction in
                    progress(0.9 + 0.08 * (Double(index) + fraction) / Double(linked.count))
                }
            }
            try addZipTables(stage: stage, reader: reader, coverage: coverage, timeline: timeline, annotations: annotations)
            let stagedFiles = try addSidecars(to: archive, in: stage, excluding: archiveFile, checkpoint: checkpoint)
            let alreadyListed = Set(stagedFiles.map(\.file))
            outputs.removeAll { alreadyListed.contains($0.file) }
            outputs.append(contentsOf: stagedFiles)
            let guide = try StreamOutput(member: archive.entry("Main.md"))
            try guide.write(Data(exportGuide(reader.run, coverage: coverage, files: outputs).utf8))
            outputs.append(try guide.finish(file: "Main.md", type: "signalbench.export-guide"))
            let manifest = try StreamOutput(member: archive.entry("manifest.json"))
            try manifest.write(StreamFiles.encoder.encode(ZipManifest(run: reader.run.id, files: outputs.sorted { $0.file < $1.file })))
            _ = try manifest.finish(file: "manifest.json", type: "signalbench.zip-manifest")
            try checkpoint()
            try archive.finish()
        }
        try Task.checkCancellation()
        try reader.store.verify()
        try StreamFiles.sync(stage)
        try beforePublish()
        let completed = archive == nil ? stage : archiveFile
        guard renamex_np(completed.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        do { try StreamFiles.sync(root) }
        catch { throw StreamFailure.storage("The export was written as \(target.lastPathComponent), but the destination could not confirm it was saved. Check the folder before retrying.") }
        progress(1)
        return target
    }

    private struct ZipManifest: Encodable {
        let type = "signalbench.run-zip"
        let version = 1
        let run: UUID
        let files: [StreamAnalysisOutput]
    }

    private static func addSidecars(to archive: RunExportZIP, in folder: URL, excluding archiveFile: URL,
                                    prefix: String = "", checkpoint: () throws -> Void) throws -> [StreamAnalysisOutput] {
        try StreamFiles.directory(folder)
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var results: [StreamAnalysisOutput] = []
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.path != archiveFile.path {
            try Task.checkCancellation()
            try checkpoint()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw StreamFiles.posix() }
            let entry = prefix + url.lastPathComponent
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                results.append(contentsOf: try addSidecars(to: archive, in: url, excluding: archiveFile,
                                                            prefix: entry + "/", checkpoint: checkpoint))
            } else {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw StreamFiles.posix() }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                    throw StreamFailure.storage("An export file is unavailable.")
                }
                let output = try StreamOutput(member: archive.entry(entry))
                while let bytes = try file.read(upToCount: 262_144), !bytes.isEmpty {
                    try Task.checkCancellation()
                    try checkpoint()
                    try output.write(bytes)
                }
                results.append(try output.finish(file: entry, type: "signalbench.export-file"))
            }
        }
        return results
    }

    private static func exportGuide(_ run: StreamRun, coverage: StreamExportSelection, files: [StreamAnalysisOutput]) -> String {
        let settings = run.settings
        let factor = settings.factor
        let raw = run.segments.first?.rawConfiguredRate(settings.nominalRate) ?? settings.rawConfiguredRate
        let saved = coverage.segments.reduce(UInt64(0)) { $0 + $1.quality.samples }
        let lost = coverage.segments.reduce(UInt64(0)) { $0 + $1.knownMissing }
        let errors = coverage.segments.reduce(UInt64(0)) { $0 + $1.quality.adcErrors }
        let clipped = coverage.segments.reduce(UInt64(0)) { $0 + $1.quality.railSamples }
        let sampled = coverage.segments.reduce(0.0) { $0 + Double($1.quality.samples) / $1.sampleRate }
        let unknown = coverage.segments.contains(where: \.unknownBoundary)
        let readingKind = factor == 1 ? "Original ADC words" : "AVG1 groups with exact sums and quality counts"
        let description = run.description.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        var lines = ["# " + run.name, "", description, "", "## Recording", "",
            "- Run ID: \(run.id)", "- Board: \(run.boardLabel)", "- ADC: \(settings.board.bits) bits, nominal \(settings.board.nominalReferenceMV) mV reference", "- Mode: \(settings.mode.rawValue)", "- Channel: \(settings.board.analogPin(settings.channel))",
            "- Status: \(run.status.rawValue)", "- Stop: \(run.displayMessage ?? "See timing.csv")",
            "- Raw requested: \(settings.nominalRate) samples/s", "- Raw configured: \(raw) samples/s",
            "- Average: \(factor)×", "- Recorded: \(raw / Double(factor)) readings/s",
            "- Data: \(readingKind)", "- Gain: \(settings.gain)", "- Wiring: \(settings.wiring)",
            "- Selected elapsed interval: \(coverage.selection.lower) to \(coverage.selection.upper) s",
            "- Sampled time: \(sampled) s", "- Verified readings: \(saved)",
            "- Known missing readings: \(lost)", "- Readings with clipping: \(clipped)",
            "- Readings with ADC errors: \(errors)", "- Unknown boundary in selection: \(unknown ? "yes" : "no")",
            "- Count rate exposure: invalid", "", "## Files", "",
            "- Sample CSV parts begin with the unnumbered file, then continue in ascending part number.",
            "- timing.csv and ranges.jsonl give segment, sample indices, nominal time and Pico DMA anchors.",
            "- quality.csv gives saved, missing, clipped and error readings by segment.",
            "- exclusions.csv describes approved masks when a cleaned CSV is included.",
            "- manifest.json records SHA-256 and uncompressed size for the other archive members.", ""]
        if factor > 1 {
            lines.append("Averaged reading indices map to original conversion ranges by multiplying by \(factor). Individual conversions inside an averaged group are unavailable. A flagged group has no usable mean.")
        } else if let legacy = settings.adcAveraging {
            lines.append("This recording includes a legacy Mac averaging preset of \(legacy.count)×. The original raw words are retained.")
        }
        lines.append(contentsOf: ["", "### Included files", ""])
        let names = files.map(\.file).sorted()
        lines.append(contentsOf: names.prefix(200).map { "- `" + $0 + "`" })
        if names.count > 200 { lines.append("- The manifest lists all \(names.count) files.") }
        if !run.linkedPreruns.isEmpty {
            lines += ["", "## Dark prerun evidence", "", "Each linked directory contains the full prerun, including for a measurement range export."]
            for link in run.linkedPreruns { lines.append("- `calibration/\(link.run.uuidString)/`") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func addZipTables(stage: URL, reader: StreamRangeReader, coverage: StreamExportSelection,
                                     timeline: [RunTimelineEntry], annotations: RunAnnotationRevision?) throws {
        func table(_ name: String, _ header: String, write: (StreamOutput) throws -> Void) throws {
            let output = try StreamOutput(stage.appendingPathComponent(name))
            try output.line(header)
            try write(output)
            _ = try output.finish(file: name, type: "signalbench.export-csv")
        }
        let segments = Dictionary(uniqueKeysWithValues: reader.run.segments.map { ($0.id, $0) })
        try table("timing.csv", "segment,stream,first_reading,end_reading_exclusive,raw_configured_hz,recorded_hz,average_factor,first_device_us,final_device_us,unknown_boundary,pico_stop_code,reason") { output in
            for row in coverage.segments {
                guard let segment = segments[row.id] else { continue }
                let raw = segment.rawConfiguredRate(reader.run.settings.nominalRate)
                try output.line("\(row.id),\(row.stream),\(row.input.first),\(row.input.end),\(raw),\(row.sampleRate),\(segment.factor),\(segment.firstDeviceUS.map(String.init) ?? ""),\(segment.finalDeviceUS.map(String.init) ?? ""),\(row.unknownBoundary),\(segment.firmwareStopCode.map(String.init) ?? ""),\(ReviewFiles.csv(segment.displayEndReason ?? ""))")
            }
        }
        try table("quality.csv", "segment,saved_readings,missing_readings,readings_with_adc_error,readings_with_clipping,source_adc_errors,source_low_rails,source_high_rails,sampled_seconds,unknown_boundary") { output in
            for row in coverage.segments {
                let q = row.quality
                try output.line("\(row.id),\(q.samples),\(row.knownMissing),\(q.adcErrors),\(q.railSamples),\(q.sourceADCErrors.map(String.init) ?? ""),\(q.sourceLowRails.map(String.init) ?? ""),\(q.sourceHighRails.map(String.init) ?? ""),\(Double(q.samples) / row.sampleRate),\(row.unknownBoundary)")
            }
        }
        let flags = timeline.filter { $0.position != nil }
        if !flags.isEmpty || !(annotations?.flags.isEmpty ?? true) {
            try table("flags.csv", "id,segment,reading_index,first_conversion,elapsed_s,state,label,note") { output in
                for flag in flags {
                    guard let pos = flag.position, let segment = segments[pos.segment] else { continue }
                    let time = RunTimeline.time(of: pos, in: reader.run).map { String($0) } ?? ""
                    try output.line("\(flag.id),\(pos.segment),\(pos.index),\(pos.index * segment.factor),\(time),\(flag.state.rawValue),\(ReviewFiles.csv(flag.label)),\(ReviewFiles.csv(flag.note))")
                }
                for flag in annotations?.flags ?? [] {
                    guard let segment = segments[flag.segment] else { continue }
                    let time = segment.timelineStart + Double(flag.sample) / segment.configuredRate(reader.run.settings.nominalRate)
                    try output.line("\(flag.id),\(flag.segment),\(flag.sample),\(flag.sample * segment.factor),\(time),placed,\(ReviewFiles.csv(flag.description)),")
                }
            }
        }
        let notes = timeline.filter { $0.state == .note }
        if !notes.isEmpty {
            try table("notes.csv", "id,host_time,note") { output in
                for note in notes { try output.line("\(note.id),\((note.click ?? note.created).ISO8601Format()),\(ReviewFiles.csv(note.note))") }
            }
        }
        let gpio = stage.appendingPathComponent("gpio", isDirectory: true)
        if try StreamFiles.isPresent(gpio) {
            try table("gpio.csv", "segment,device_us,completed_readings,completed_conversions,directions,levels,latches,lease_active") { output in
                let records = try FileManager.default.contentsOfDirectory(at: gpio, includingPropertiesForKeys: nil)
                    .map { try StreamFiles.read(StreamGPIO.self, $0) }
                    .sorted { ($0.segment.uuidString, $0.deviceUS) < ($1.segment.uuidString, $1.deviceUS) }
                for row in records {
                    try Task.checkCancellation()
                    guard let segment = segments[row.segment] else { continue }
                    try output.line("\(row.segment),\(row.deviceUS),\(row.completedSampleBoundary),\(row.completedSampleBoundary * segment.factor),\(row.directions),\(row.levels),\(row.latches),\(row.leaseActive)")
                }
            }
        }
    }
}
