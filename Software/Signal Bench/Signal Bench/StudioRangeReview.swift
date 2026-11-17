import CryptoKit
import Foundation

nonisolated struct StudioRangeQuality: Codable, Sendable {
    struct Minute: Codable, Identifiable, Sendable {
        let id: Int
        var sampledSeconds = 0.0
        var usableSeconds = 0.0
        var knownMissingSeconds = 0.0
        var baseline: Double?
        var noise: Double?
        var drift: Double?
        var clips: UInt64 = 0
        var errors: UInt64 = 0
    }
    struct Gap: Codable, Identifiable, Sendable {
        let start: Double
        let end: Double?
        let location: StreamMatchLocation?
        var id: Double { start }
    }
    var minutes: [Minute] = []
    var gaps: [Gap] = []
    var samples: UInt64 = 0
    var excluded: UInt64 = 0
    var settling: UInt64 = 0
    var rawMatches: UInt64 = 0
    var processedMatches: UInt64 = 0
    var decisionCount: UInt64 = 0
    var rate_exposure_valid = 0
}

nonisolated struct StudioRangeConfig: Codable, Equatable, Sendable {
    let selection: StreamSelection
    let settings: ReviewSettings
    let annotationRevision: UUID?
    let exclusions: [ReviewInterval]
    let profileRevision: UUID?
    var comparisonContext: ReviewSettings? = nil
}

nonisolated struct StudioRangeDecision: Codable, Identifiable, Sendable {
    let trace: String
    let pulse: ReviewPulse
    let widthUS: Double
    var id: String { "\(trace):\(pulse.range.segment):\(pulse.peakIndex)" }
}

nonisolated struct StudioRangeResult: Sendable {
    let config: StudioRangeConfig
    var trace: ReviewResult
    var quality = StudioRangeQuality()
    var decisions: [StudioRangeDecision] = []
    var intervals: [ReviewInterval] = []
    var spectra: [PostRunAnalysis.Spectrum] = []
    var pairedSpectra: [ReviewSpectralComparison] = []
}

nonisolated enum StudioRangeReview {
    static let analyzer = "signalbench.studio-range"
    static let version = 1
    static let comparisonVersion = 1
    private static let tileSize = 262_144

    static func config(_ reader: StreamRangeReader, selection: StreamSelection, settings: ReviewSettings) throws -> StudioRangeConfig {
        let annotation = try RunAnnotations.read(reader)
        return .init(selection: selection, settings: settings, annotationRevision: annotation?.id,
                     exclusions: annotation?.masks ?? [], profileRevision: reader.run.settings.profile?.id)
    }

    static func analyze(_ original: StreamRangeReader, config: StudioRangeConfig, includePulses: Bool = true,
                        expectedSourceHash: String? = nil, pairedSpectra: Bool = false,
                        contextSettings: ReviewSettings? = nil, referenceSettings: ReviewSettings? = nil,
                        change: ((ReviewDecisionChange) throws -> Void)? = nil,
                        source: ((StreamExportRange) throws -> Void)? = nil,
                        decision: ((StudioRangeDecision) throws -> Void)? = nil,
                        interval: ((ReviewInterval) throws -> Void)? = nil) throws -> StudioRangeResult {
        let reader = try original.prepared()
        let selection = config.selection
        let duration = try reader.duration()
        guard selection.valid, selection.upper <= duration + 1e-7, config.settings.valid,
              config.profileRevision == reader.run.settings.profile?.id else {
            throw StreamFailure.storage("Check the review range and settings.")
        }
        let requested = reader.run.settings.nominalRate
        let rates = reader.run.segments.map { $0.configuredRate(requested) }
        let reviewSettings = [config.settings, config.comparisonContext, contextSettings, referenceSettings].compactMap { $0 }
        guard reviewSettings.allSatisfy(\.valid) else { throw StreamFailure.storage("Invalid comparison settings.") }
        let support = reviewSettings.map { $0.padBefore + $0.padAfter + $0.maxWidth + $0.separation + 8192 }.max() ?? 0
        let halo = max(Int((rates.max() ?? Double(requested)) * 0.4), support)
        let collector = pairedSpectra ? ReviewSpectrumCollector(comparing: referenceSettings != nil) : nil
        let context = Double(tileSize + halo + 2) / (rates.min() ?? Double(requested))
        let expanded = StreamSelection(lower: max(0, selection.lower - context), upper: min(duration, selection.upper + context))
        var output = StudioRangeResult(config: config, trace: .init(selection: selection, settings: config.settings, rate: requested))
        let firstMinute = Int(selection.lower / 60), lastMinute = Int(ceil(selection.upper / 60)) - 1
        var quality = MinuteAccumulator(first: firstMinute, board: reader.run.settings.board)
        var sourceDigest = SHA256()
        var next: [UUID: UInt64] = [:]
        let masks = Dictionary(grouping: config.exclusions, by: \.range.segment)
        let segmentEnds = (reader.index ?? []).reduce(into: [UUID: UInt64]()) { ends, item in
            ends[item.segment] = max(ends[item.segment, default: 0], item.end)
        }
        func time(_ index: UInt64, _ segment: StreamRunSegment) -> Double {
            segment.timelineStart + Double(index) / segment.configuredRate(requested)
        }
        func column(_ seconds: Double) -> Int {
            min(719, max(0, Int((seconds - selection.lower) / (selection.upper - selection.lower) * 720)))
        }
        func knownGap(_ first: UInt64, _ end: UInt64, _ segment: StreamRunSegment, nextSample: Bool = false) throws {
            guard end > first else { return }
            guard output.quality.gaps.count < WaveformOverview.maxGaps else {
                throw StreamFailure.storage("Too many gaps to review together. Choose a shorter range.")
            }
            let start = time(first, segment), finish = time(end, segment)
            let location = nextSample ? StreamMatchLocation(segment: segment.id, sample: end) : nil
            output.quality.gaps.append(.init(start: start, end: finish, location: location))
        }
        try FixtureTiles.visit(reader, selection: expanded, halo: halo, tileSamples: tileSize, aligned: true, source: { part in
            let input = StreamExportRange(input: part.reference, firstNominalSeconds: part.firstSeconds, frame: part.frameAnchor)
            try source?(input)
            if expectedSourceHash != nil {
                sourceDigest.update(data: try StreamFiles.encoder.encode(input))
                sourceDigest.update(data: Data([10]))
            }
        }) { span, owned in
            let bounds = ReviewInput.indices(selection, segment: span.segment, rate: requested)
            let lo = max(owned.lowerBound, bounds.lowerBound), hi = min(owned.upperBound, bounds.upperBound)
            guard lo < hi else { return }
            let segment = span.segment
            let rate = segment.configuredRate(requested)
            let previous = next[segment.id] ?? bounds.lowerBound
            try knownGap(previous, lo, segment, nextSample: true)
            if next[segment.id] == nil || previous != lo { output.trace.breakBins.insert(column(time(lo, segment))) }
            next[segment.id] = hi
            let tile = StreamSelection(lower: time(owned.lowerBound, segment), upper: time(owned.upperBound, segment))
            let input = ReviewInput(run: reader.run, selection: tile, spans: [span], refs: [], gaps: [])
            let approved = masks[segment.id, default: []].filter { $0.range.first < span.end && $0.range.end > span.first }
            try collector?.register(rate: rate)
            var peerValues: [Double] = []
            var reference: ReviewResult?
            if let referenceSettings {
                if collector != nil { peerValues = Array(repeating: .nan, count: Int(hi - lo)) }
                reference = try StudioReview.analyze(input, settings: referenceSettings, manual: [], approved: approved,
                    decisionLimit: 2 * span.words.count, markSelectionEdges: false, includePulses: includePulses, ownedIndices: owned) { index, _, processed, _, _ in
                        guard !peerValues.isEmpty, lo <= index, index < hi, let processed else { return }
                        peerValues[Int(index - lo)] = processed
                    }
            }
            let reviewed = try StudioReview.analyze(input, settings: config.settings, manual: [], approved: approved,
                                                    decisionLimit: 2 * span.words.count, markSelectionEdges: false, includePulses: includePulses, ownedIndices: owned) { index, word, processed, excluded, settling in
                guard lo <= index, index < hi else { return }
                let seconds = time(index, segment)
                let b = column(seconds)
                let code = span.value(Int(index - span.first))
                let fault = word & 0x8000 != 0
                let error = fault && (span.means == nil || word & 0x4000 != 0)
                let clipped = span.means == nil ? !error && (code == 0 || code == Double(span.segment.board.maxCode)) : fault && word & 0x3000 != 0
                if let collector {
                    let peer = peerValues.isEmpty ? Double.nan : peerValues[Int(index - lo)]
                    collector.append(segment: segment.id, index: index, rate: rate, code: code,
                                     filtered: processed, peer: peer.isFinite ? peer : nil)
                }
                if !fault {
                    widen(&output.trace.bins[b].raw, code)
                    output.trace.bins[b].rawSum += code
                    output.trace.bins[b].rawCount += 1
                }
                if let processed {
                    widen(&output.trace.bins[b].processed, processed)
                    output.trace.bins[b].processedSum += processed
                    output.trace.bins[b].processedCount += 1
                }
                if excluded {
                    output.quality.excluded += 1
                    output.trace.bins[b].mask = true
                }
                if settling { output.quality.settling += 1 }
                quality.add(minute: max(firstMinute, min(lastMinute, Int(seconds / 60))), code: Int(code),
                            error: error, clipped: clipped, excluded: excluded, usable: !excluded && !settling, rate: rate)
            }
            if let reference, let change {
                try ReviewDecisionChange.compare(reference.processed, reviewed.processed, in: lo..<hi, rate: rate, emit: change)
            }
            output.quality.samples += hi - lo
            quality.finishDriftBlock()
            for item in reviewed.intervals {
                var clipped = item
                clipped.range.first = max(lo, item.range.first)
                clipped.range.end = min(hi, item.range.end)
                guard clipped.range.count > 0 else { continue }
                if output.intervals.count < 200 { output.intervals.append(clipped) }
                try interval?(clipped)
            }
            for (trace, pulses) in [("raw", reviewed.raw), ("processed", reviewed.processed)] {
                for pulse in pulses where lo <= pulse.peakIndex && pulse.peakIndex < hi {
                    let item = StudioRangeDecision(trace: trace, pulse: pulse, widthUS: Double(pulse.width) * 1_000_000 / rate)
                    output.quality.decisionCount += 1
                    if pulse.decision == "match" {
                        if trace == "raw" { output.quality.rawMatches += 1 } else { output.quality.processedMatches += 1 }
                    }
                    if output.decisions.count < 200 { output.decisions.append(item) }
                    try decision?(item)
                }
            }
        }
        if let expectedSourceHash, sourceDigest.finalize().map({ String(format: "%02x", $0) }).joined() != expectedSourceHash {
            throw StreamFailure.storage("The original input range or filter context changed. The saved analysis remains in the run folder.")
        }
        for (offset, segment) in reader.run.segments.enumerated() {
            let bounds = ReviewInput.indices(selection, segment: segment, rate: requested)
            let end = max(segment.accountedSamples, segmentEnds[segment.id, default: 0])
            try knownGap(next[segment.id] ?? bounds.lowerBound, min(end, bounds.upperBound), segment)
            let boundary = time(end, segment)
            let following = reader.run.segments.dropFirst(offset + 1).first?.timelineStart
            if (segment.unknown || following != nil), boundary <= selection.upper,
               (following ?? boundary) >= selection.lower {
                output.quality.gaps.append(.init(start: boundary, end: nil, location: nil))
            }
        }
        output.quality.gaps.sort { $0.start < $1.start }
        quality.finish(through: lastMinute)
        for gap in output.quality.gaps {
            guard let end = gap.end else { continue }
            for minute in Int(gap.start / 60)...Int(end / 60) {
                let offset = minute - firstMinute
                guard quality.rows.indices.contains(offset) else { continue }
                quality.rows[offset].knownMissingSeconds += max(0, min(end, Double(minute + 1) * 60) - max(gap.start, Double(minute) * 60))
            }
        }
        output.quality.minutes = quality.rows
        output.spectra = try PostRunAnalysis.spectra(reader, selection: selection, exclusions: config.exclusions)
        output.pairedSpectra = collector?.results() ?? []
        return output
    }

    static func save(_ reader: StreamRangeReader, config: StudioRangeConfig, proposal: ReviewProposal? = nil) throws -> StreamAnalysisManifest {
        var persisted = config
        persisted.comparisonContext = proposal?.reference ?? config.comparisonContext
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: true)
        var manifest = StreamAnalysisManifest(run: reader.run.id, selection: config.selection, streams: reader.run.segments.map(\.stream),
            analyzer: analyzer, analyzerVersion: version, profileRevision: config.profileRevision,
            rules: reader.run.settings.profile?.rules, annotationRevision: config.annotationRevision, outputs: [])
        _ = try ReviewFiles.publish(in: parent, name: manifest.id.uuidString) { stage in
            let source = try StreamOutput(stage.appendingPathComponent("input-context.jsonl"))
            let decisions = try StreamOutput(stage.appendingPathComponent("pulse-decisions.jsonl"))
            let intervals = try StreamOutput(stage.appendingPathComponent("exclusions.jsonl"))
            if let proposal { try proposal.checkCurrent(reader) }
            let changed = try proposal?.reference.map { _ in try StreamOutput(stage.appendingPathComponent("decision-changes.jsonl")) }
            let result = try analyze(reader, config: persisted, expectedSourceHash: proposal?.sourceHash,
                                     pairedSpectra: true, referenceSettings: proposal?.reference,
                                     change: { try changed?.item($0) }, source: { try source.item($0) },
                                     decision: { try decisions.item($0) }, interval: { try intervals.item($0) })
            guard result.quality.samples > 0 else { throw StreamFailure.storage("The range contains no saved samples.") }
            let quality = try StreamOutput(stage.appendingPathComponent("quality.json"))
            try quality.write(StreamFiles.encoder.encode(result.quality))
            let settings = try StreamOutput(stage.appendingPathComponent("settings.json"))
            try settings.write(StreamFiles.encoder.encode(persisted))
            let evidence = try StreamOutput(stage.appendingPathComponent("run-snapshot.json"))
            try evidence.write(StreamFiles.encoder.encode(reader.run))
            let spectrum = try StreamOutput(stage.appendingPathComponent("spectra.jsonl"))
            for item in result.spectra { try spectrum.item(item) }
            let paired = try StreamOutput(stage.appendingPathComponent("paired-spectra.jsonl"))
            for item in result.pairedSpectra { try paired.item(item) }
            let input = try source.finish(file: "input-context.jsonl", type: "signalbench.source-ranges")
            manifest.sourceHash = input.sha256
            manifest.outputs = [input,
                try decisions.finish(file: "pulse-decisions.jsonl", type: "signalbench.studio-pulse-decisions"),
                try intervals.finish(file: "exclusions.jsonl", type: "signalbench.exclusion-intervals"),
                try quality.finish(file: "quality.json", type: "signalbench.range-quality"),
                try settings.finish(file: "settings.json", type: "signalbench.range-settings"),
                try evidence.finish(file: "run-snapshot.json", type: "signalbench.run-snapshot"),
                try spectrum.finish(file: "spectra.jsonl", type: "signalbench.welch-spectra"),
                try paired.finish(file: "paired-spectra.jsonl", type: "signalbench.paired-spectra")]
            if let changed {
                manifest.outputs.append(try changed.finish(file: "decision-changes.jsonl", type: "signalbench.decision-changes"))
            }
            if let proposal {
                try proposal.checkCurrent(reader)
                let provenance = try StreamOutput(stage.appendingPathComponent("review-recipe.json"))
                try provenance.write(StreamFiles.encoder.encode(proposal))
                manifest.outputs.append(try provenance.finish(file: "review-recipe.json", type: "signalbench.review-recipe"))
            }
            try reader.store.verify()
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return manifest
    }

    static func load(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest) throws -> StudioRangeConfig {
        guard manifest.run == reader.run.id, manifest.analyzer == analyzer, manifest.analyzerVersion == version,
              let output = manifest.outputs.first(where: { $0.file == "settings.json" && $0.valid }) else {
            throw StreamFailure.storage("This range review uses unsupported settings.")
        }
        let root = try reader.store.runDirectory(reader.run.id)
        let parent = try StreamFiles.directory("analyses", in: root, create: false)
        let folder = try StreamFiles.directory(manifest.id.uuidString, in: parent, create: false)
        let bytes = try StreamFiles.read(folder.appendingPathComponent(output.file), limit: 16 * 1024 * 1024)
        guard UInt64(bytes.count) == output.bytes, StreamFiles.sha(bytes) == output.sha256 else {
            throw StreamFailure.storage("The saved review settings changed on disk.")
        }
        let config = try StreamFiles.decoder.decode(StudioRangeConfig.self, from: bytes)
        guard config.selection == manifest.selection, config.annotationRevision == manifest.annotationRevision,
              config.profileRevision == manifest.profileRevision, config.settings.valid, config.comparisonContext?.valid ?? true else {
            throw StreamFailure.storage("The saved review settings do not match the analysis.")
        }
        return config
    }

    private static func widen(_ range: inout ClosedRange<Double>?, _ value: Double) {
        range = min(range?.lowerBound ?? value, value)...max(range?.upperBound ?? value, value)
    }

    private struct MinuteAccumulator {
        var row: StudioRangeQuality.Minute
        var rows: [StudioRangeQuality.Minute] = []
        let binCount: Int
        var histogram: [UInt64]
        var driftHistogram: [UInt64]
        var good: UInt64 = 0
        var driftCount: UInt64 = 0
        var low = Double.infinity, high = -Double.infinity

        init(first: Int, board: AcquisitionBoard) {
            row = .init(id: first)
            binCount = Int(board.maxCode) + 1
            histogram = Array(repeating: 0, count: binCount)
            driftHistogram = histogram
        }

        mutating func add(minute: Int, code: Int, error: Bool, clipped: Bool, excluded: Bool, usable: Bool, rate: Double) {
            while row.id < minute { finishMinute() }
            row.sampledSeconds += 1 / rate
            if usable { row.usableSeconds += 1 / rate }
            if error { row.errors += 1 }
            if clipped { row.clips += 1 }
            if !error, !clipped, !excluded {
                histogram[code] += 1
                driftHistogram[code] += 1
                good += 1
                driftCount += 1
            }
        }

        mutating func finishDriftBlock() {
            if driftCount >= 64, let center = StreamStudio.weightedMedian(driftHistogram, total: driftCount) {
                low = min(low, center)
                high = max(high, center)
            }
            if driftCount > 0 { driftHistogram = Array(repeating: 0, count: binCount); driftCount = 0 }
        }

        mutating func finishMinute() {
            finishDriftBlock()
            row.baseline = StreamStudio.weightedMedian(histogram, total: good)
            if let center = row.baseline {
                var deviations = [UInt64](repeating: 0, count: 2 * histogram.count - 1)
                for (code, count) in histogram.enumerated() where count > 0 {
                    deviations[Int(abs(Double(code) - center) * 2)] += count
                }
                row.noise = StreamStudio.weightedMedian(deviations, total: good).map { $0 * 0.7413 }
            }
            if low.isFinite { row.drift = high - low }
            rows.append(row)
            row = .init(id: row.id + 1)
            histogram = Array(repeating: 0, count: binCount)
            good = 0
            low = .infinity
            high = -.infinity
        }

        mutating func finish(through last: Int) {
            while row.id <= last { finishMinute() }
        }
    }
}
