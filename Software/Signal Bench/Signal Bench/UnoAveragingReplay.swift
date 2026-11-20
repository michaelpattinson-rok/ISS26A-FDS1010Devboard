import CryptoKit
import Foundation

nonisolated enum UnoAveragingReplay {
    struct Hit: Codable, Sendable {
        let rawPeak: Double
        let first: UInt64
        let end: UInt64
        let height: Double
        let widthUS: Double
    }
    struct Outcome: Codable, Sendable {
        let referenceUS: Double
        let result: String
        let hit: Hit?
        let timingErrorUS: Double?
        let heightLossCodes: Double?
        let widthChangeUS: Double?
    }
    struct Row: Codable, Identifiable, Sendable {
        let factor: Int
        let recordedRate: Double
        let usableSeconds: Double
        let matched: Int
        let missed: Int
        let outsideCoverage: Int
        let ambiguous: Int
        let unassociated: Int
        let falseMatchesPerUsableMinute: Double?
        let averageHeightLoss: Double?
        let averageWidthChangeUS: Double?
        let rmsTimingErrorUS: Double?
        let outcomes: [Outcome]
        var id: Int { factor }
    }
    struct Report: Codable, Sendable {
        var version = 1
        let training: UUID
        let heldOut: UUID
        let emptyControl: UUID?
        let trainingHash: String
        let heldOutHash: String
        let controlHash: String?
        let trainingTimingHash: String
        let heldOutTimingHash: String
        let trainingBiasUS: Double
        let settings: ReviewSettings
        let rows: [Row]
        var rate_exposure_valid = 0
    }
    struct Scan {
        let segment: UUID
        let stream: UInt64
        let rate: Double
        let factor: Int
        let eligible: [Range<UInt64>]
        let hits: [Hit]
    }
    private static let candidateLimit = 20_000

    static func run(training originalTraining: StreamRangeReader, heldOut originalHeld: StreamRangeReader,
                    empty originalEmpty: StreamRangeReader?) throws -> Report {
        let training = try originalTraining.prepared(), held = try originalHeld.prepared()
        let empty = try originalEmpty?.prepared()
        guard training.store.identity.id == held.store.identity.id, training.run.id != held.run.id,
              training.run.settings.bench?.step == .fixture, held.run.settings.bench?.step == .fixture,
              let setup = training.run.settings.bench?.setup,
              held.run.settings.bench?.setup.matchesAcquisition(setup) == true,
              setup.gain == held.run.settings.gain,
              empty.map({ $0.store.identity.id == held.store.identity.id && $0.run.id != training.run.id &&
                  $0.run.id != held.run.id && [.empty, .repeatEmpty].contains($0.run.settings.bench?.step) &&
                  $0.run.settings.bench?.setup.matchesAcquisition(setup) == true && $0.run.settings.gain == setup.gain }) ?? true else {
            throw StreamFailure.storage("Choose different timed training and validation runs, with matching Uno settings. Any empty control must match the same setup.")
        }
        let leases = try [training, held].map { try ProjectReview.ReadLease($0.store.runDirectory($0.run.id)) } +
            (try empty.map { [try ProjectReview.ReadLease($0.store.runDirectory($0.run.id))] } ?? [])
        defer { withExtendedLifetime(leases) {} }
        let pinTraining = try pin(training), pinHeld = try pin(held), pinEmpty = try empty.map(pin)
        var settings = ReviewSettings(profile: training.run.settings.profile, sampleRate: training.run.settings.nominalRate)
        settings.polarity = .negative
        settings.template = nil
        let trainingScan = try scan(training, factor: 1, settings: settings)
        let (trainRef, trainHash) = try FixtureEvidence.reference(training)
        guard trainRef.stream == trainingScan.stream,
              let bias = ProfileAnalyzer.median(associate(trainingScan, reference: trainRef, biasUS: 0)
                .compactMap(\.timingErrorUS)) else {
            throw StreamFailure.storage("The training recording has no unambiguous pulse matches for the frozen settings.")
        }
        // The entire held-out signal is processed at every factor before its
        // independent reference is opened.
        var validations: [Scan] = [], controls: [Scan?] = []
        for factor in [1] + ADCAveraging.allCases.map(\.count) {
            try Task.checkCancellation()
            validations.append(try scan(held, factor: factor, settings: settings))
            controls.append(try empty.map { try scan($0, factor: factor, settings: settings) })
        }
        let (heldRef, heldHash) = try FixtureEvidence.reference(held)
        guard validations.first?.stream == heldRef.stream else {
            throw StreamFailure.storage("The held-out reference identifies a different timing segment.")
        }
        let original = associate(validations[0], reference: heldRef, biasUS: bias)
        let rows = zip(validations, controls).map { scan, control in
            let assessed = associate(scan, reference: heldRef, biasUS: bias)
            let outcomes = zip(assessed, original).map { value, raw in
                Outcome(referenceUS: value.referenceUS, result: value.result, hit: value.hit, timingErrorUS: value.timingErrorUS,
                        heightLossCodes: value.hit.flatMap { hit in raw.hit.map { $0.height - hit.height } },
                        widthChangeUS: value.hit.flatMap { hit in raw.hit.map { hit.widthUS - $0.widthUS } })
            }
            let errors = outcomes.compactMap(\.timingErrorUS)
            let matches = outcomes.filter { $0.result == "Matched" }.count
            let controlSeconds = control.map { Double($0.eligible.reduce(0) { $0 + $1.count }) / $0.rate }
            return Row(factor: scan.factor, recordedRate: scan.rate / Double(scan.factor),
                usableSeconds: Double(scan.eligible.reduce(0) { $0 + $1.count }) / scan.rate, matched: matches,
                missed: outcomes.filter { $0.result == "Missed in coverage" }.count,
                outsideCoverage: outcomes.filter { $0.result == "Outside coverage" }.count,
                ambiguous: outcomes.filter { $0.result == "Ambiguous" }.count,
                unassociated: scan.hits.count - matches,
                falseMatchesPerUsableMinute: control.flatMap { value in
                    controlSeconds.flatMap { $0 > 0 ? Double(value.hits.count) * 60 / $0 : nil }
                }, averageHeightLoss: mean(outcomes.compactMap(\.heightLossCodes)),
                averageWidthChangeUS: mean(outcomes.compactMap(\.widthChangeUS)),
                rmsTimingErrorUS: mean(errors.map { $0 * $0 }).map(sqrt), outcomes: outcomes)
        }
        try pinTraining.verify(.init(store: training.store, run: training.store.openRun(training.run.id)))
        try pinHeld.verify(.init(store: held.store, run: held.store.openRun(held.run.id)))
        if let empty, let pinEmpty { try pinEmpty.verify(.init(store: empty.store, run: empty.store.openRun(empty.run.id))) }
        guard try FixtureEvidence.reference(training).1 == trainHash,
              try FixtureEvidence.reference(held).1 == heldHash else { throw ReviewWorkerError.stale }
        return .init(training: training.run.id, heldOut: held.run.id, emptyControl: empty?.run.id,
                     trainingHash: pinTraining.source, heldOutHash: pinHeld.source, controlHash: pinEmpty?.source,
                     trainingTimingHash: trainHash, heldOutTimingHash: heldHash, trainingBiasUS: bias,
                     settings: settings, rows: rows)
    }

    private static func pin(_ reader: StreamRangeReader) throws -> ProjectJob.Input {
        try ProjectJob.Input.pin(reader, selection: FixtureTemplateStudy.fullRange(reader))
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func group(_ words: ArraySlice<UInt16>, first: UInt64) -> ADCAveraging.Group {
        var group = ADCAveraging.Group(first: first, count: words.count)
        for word in words {
            if word & 0xc000 != 0 { group.adcErrors += 1; continue }
            group.sum += UInt64(word)
            if word == 0 { group.lowRail += 1 }
            if word == 16383 { group.highRail += 1 }
        }
        return group
    }

    struct RangeReplay: Encodable {
        struct Row: Encodable {
            let factor: Int
            let recordedRate: Double
            let usableSeconds: Double
            let matches: Int
            let meanHeightCodes: Double?
            let meanWidthUS: Double?
            let findings: [Hit]
        }
        struct Location: Encodable {
            let range: ReviewRange
            let location: StreamMatchLocation
        }
        let range: ReviewRange
        let selection: StreamSelection
        let sourceSHA256: [String]
        let annotationRevision: UUID?
        let settings: ReviewSettings
        let pageOffset: Int
        let rows: [Row]
        let findings: [Location]
        let rate_exposure_valid = 0
        let evidence = "Diagnostic averaging of identical original Uno readings. These are Mac Pulse Matches without independent fixture timing."
    }

    static func review(_ reader: StreamRangeReader, range: ReviewRange,
                       selection: StreamSelection, page: Range<Int>) throws -> RangeReplay {
        guard selection.upper - selection.lower <= 30.0000001 else {
            throw ReviewWorkerError.invalid("Choose up to 30 seconds of an original Uno A0 recording.")
        }
        let pinned = try ProjectJob.Input.pin(reader, selection: selection)
        var settings = ReviewSettings(profile: reader.run.settings.profile, sampleRate: reader.run.settings.nominalRate)
        settings.polarity = .negative
        settings.template = nil
        let rows = try ([1] + ADCAveraging.allCases.map(\.count)).map { factor in
            let scan = try scan(reader, factor: factor, settings: settings, selection: selection, segmentID: range.segment)
            let duration = Double(scan.eligible.reduce(0) { $0 + $1.count }) / scan.rate
            return RangeReplay.Row(factor: factor, recordedRate: scan.rate / Double(factor), usableSeconds: duration,
                matches: scan.hits.count, meanHeightCodes: mean(scan.hits.map(\.height)),
                meanWidthUS: mean(scan.hits.map(\.widthUS)),
                findings: Array(scan.hits.dropFirst(page.lowerBound).prefix(min(6, page.count))))
        }
        let hashes = (reader.index ?? []).filter { $0.segment == range.segment && $0.first < range.end && $0.end > range.first }
            .map(\.sha256)
        var source = SHA256()
        for digest in hashes { source.update(data: Data(digest.utf8)) }
        try pinned.verify(.init(store: reader.store, run: reader.store.openRun(reader.run.id)))
        return .init(range: range, selection: selection,
                     sourceSHA256: [source.finalize().map { String(format: "%02x", $0) }.joined()],
                     annotationRevision: pinned.annotations, settings: settings, pageOffset: page.lowerBound, rows: rows,
                     findings: (rows.first?.findings ?? []).map {
                        .init(range: .init(segment: range.segment, first: $0.first, end: $0.end),
                              location: .init(segment: range.segment, sample: UInt64($0.rawPeak)))
                     })
    }

    static func scan(_ reader: StreamRangeReader, factor: Int, settings: ReviewSettings,
                     selection scope: StreamSelection? = nil, segmentID: UUID? = nil) throws -> Scan {
        let target = segmentID.flatMap { id in reader.run.segments.first { $0.id == id } } ??
            (segmentID == nil && reader.run.segments.count == 1 ? reader.run.segments.first : nil)
        guard reader.run.status != .recording, reader.run.curveSource == nil, reader.run.settings.board == .unoR4,
              reader.run.settings.channel == 0, reader.run.settings.picoAveraging == nil,
              reader.run.settings.adcAveraging == nil,
              let segment = target, factor == 1 || ADCAveraging(rawValue: factor) != nil else {
            throw StreamFailure.storage("Replay requires an original Uno A0 recording with one timing segment.")
        }
        let originalRate = segment.configuredRate(reader.run.settings.nominalRate)
        let rate = originalRate / Double(factor)
        let step = UInt64(factor)
        var scaled = settings
        scaled.minWidth = max(1, (settings.minWidth + factor - 1) / factor)
        scaled.maxWidth = max(scaled.minWidth, settings.maxWidth / factor)
        scaled.separation = 0
        scaled.spikeWidth = max(1, (settings.spikeWidth + factor - 1) / factor)
        scaled.padBefore = (settings.padBefore + factor - 1) / factor
        scaled.padAfter = (settings.padAfter + factor - 1) / factor
        var run = reader.run, transformed = segment
        transformed.picoAveraging = ADCAveraging(rawValue: factor)
        run.settings.picoAveraging = transformed.picoAveraging
        run.segments = [transformed]
        let masks = RunAnnotations.merged(try RunAnnotations.read(reader)?.masks ?? [])[segment.id] ?? []
        var coverage: [Range<UInt64>] = [], hits: [Hit] = []
        var separationEnd: UInt64 = 0, previousEnd: UInt64?
        let selection = try scope ?? FixtureTemplateStudy.fullRange(reader)
        // Align tiles in the original domain; a gap never forms a group with
        // samples on both sides. The nonowned context is for filtering only.
        let halo = max(8192, Int(originalRate * 0.4) + settings.maxWidth + settings.padBefore + settings.padAfter)
        try FixtureTiles.visit(reader, selection: selection, halo: halo, tileSamples: 65_536) { span, owned in
            guard span.segment.id == segment.id else { return }
            if previousEnd != owned.lowerBound { separationEnd = 0 }
            previousEnd = owned.upperBound
            let first = (span.first + step - 1) / step * step
            let end = span.end / step * step
            guard first < end else { return }
            var words: [UInt16] = [], means: [Double] = []
            var maskIndex = masks.partitioningIndex { $0.upperBound > first }
            for index in stride(from: Int(first - span.first), to: Int(end - span.first), by: factor) {
                let source = span.first + UInt64(index)
                while maskIndex < masks.count && masks[maskIndex].upperBound <= source { maskIndex += 1 }
                let masked = maskIndex < masks.count && masks[maskIndex].lowerBound < source + step
                if factor == 1 {
                    words.append(span.words[index] | (masked ? 0x8000 : 0))
                } else {
                    let value = group(span.words[index..<(index + factor)], first: source)
                    words.append(PicoAverage.projectedWord(value) | (masked ? 0x8000 : 0))
                    means.append(value.mean ?? 0)
                }
            }
            let lo = max(first / step, (owned.lowerBound + step - 1) / step)
            let hi = min(end / step, (owned.upperBound + step - 1) / step)
            guard lo < hi else { return }
            let interval = StreamSelection(lower: segment.timelineStart + Double(lo) / rate,
                                           upper: segment.timelineStart + Double(hi) / rate)
            let input = ReviewInput(run: run, selection: interval, spans: [
                .init(segment: transformed, first: first / step, words: words, means: factor == 1 ? nil : means)
            ], refs: [], gaps: [])
            let output = try StudioReview.analyze(input, settings: scaled, manual: [], markSelectionEdges: false,
                                                    ownedIndices: lo..<hi) { index, _, _, masked, settling in
                guard !masked, !settling else { return }
                let first = index * step
                if let last = coverage.last, last.upperBound == first {
                    coverage[coverage.count - 1] = last.lowerBound..<(first + step)
                } else { coverage.append(first..<(first + step)) }
            }
            guard !output.overflow, coverage.count < candidateLimit else {
                throw StreamFailure.storage("Replay exceeded its decision or fragmented coverage limit.")
            }
            for pulse in output.processed where pulse.decision == "match" && (lo..<hi).contains(pulse.peakIndex) {
                let first = pulse.range.first * step, end = pulse.range.end * step
                guard pulse.peakIndex * step >= separationEnd, (settings.minWidth...settings.maxWidth).contains(pulse.width * factor) else { continue }
                hits.append(.init(rawPeak: Double(pulse.peakIndex * step) + Double(factor - 1) / 2,
                                  first: first, end: end, height: pulse.height, widthUS: Double(pulse.width) / rate * 1e6))
                separationEnd = pulse.peakIndex * step + UInt64(settings.separation)
                guard hits.count <= candidateLimit else { throw StreamFailure.storage("Replay exceeded its candidate limit.") }
            }
        }
        return .init(segment: segment.id, stream: segment.stream, rate: originalRate, factor: factor,
                     eligible: coverage, hits: hits.sorted { $0.rawPeak < $1.rawPeak })
    }

    private static func associate(_ scan: Scan, reference: StreamFixtureReference, biasUS: Double) -> [Outcome] {
        let bounds = reference.pulsesUS.map { reference.index($0) + biasUS * scan.rate / 1e6 }
        let tolerance = reference.uncertaintySamples
        return bounds.enumerated().map { i, index in
            let lo = index - tolerance, hi = index + tolerance
            var outcome = "Outside coverage"
            var hit: Hit?
            if (i > 0 && bounds[i - 1] + tolerance >= lo) || (i + 1 < bounds.count && bounds[i + 1] - tolerance <= hi) {
                outcome = "Ambiguous"
            } else {
                let index = scan.eligible.partitioningIndex { Double($0.upperBound) > hi }
                guard lo >= 0, scan.eligible.indices.contains(index), Double(scan.eligible[index].lowerBound) <= lo else {
                    return .init(referenceUS: reference.pulsesUS[i], result: outcome, hit: nil, timingErrorUS: nil,
                                 heightLossCodes: nil, widthChangeUS: nil)
                }
                let span = scan.eligible[index]
                let start = scan.hits.partitioningIndex { $0.rawPeak >= lo }
                let end = scan.hits.partitioningIndex { $0.rawPeak > hi }
                if end - start == 1, span.lowerBound <= scan.hits[start].first, span.upperBound >= scan.hits[start].end {
                    outcome = "Matched"; hit = scan.hits[start]
                } else { outcome = end > start ? "Ambiguous" : "Missed in coverage" }
            }
            return .init(referenceUS: reference.pulsesUS[i], result: outcome, hit: hit,
                         timingErrorUS: hit.map { ($0.rawPeak - index) / scan.rate * 1e6 },
                         heightLossCodes: nil, widthChangeUS: nil)
        }
    }
}

private extension Array {
    nonisolated func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
