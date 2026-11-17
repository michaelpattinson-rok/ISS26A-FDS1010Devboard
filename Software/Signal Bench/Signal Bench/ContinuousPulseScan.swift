import Foundation

nonisolated struct OwnedPulseWindow: Codable, Sendable {
    var segment: UUID
    var first: UInt64
    var count: Int
    var contextFirst: UInt64
    var result: ProfileWindowResult
    var usable: Int
    var usableRanges: [Range<UInt64>]
}

nonisolated enum ContinuousPulseScan {
    static let algorithmVersion = 4

    static func scan(_ reader: StreamRangeReader, selection: StreamSelection, profile: CalibrationProfile,
                     rules: ProfilePulseRules, excluding: [UUID: [Range<UInt64>]],
                     source: (StreamRangeData) throws -> Void = { _ in },
                     output: (OwnedPulseWindow) throws -> Void) throws {
        var localRules = rules
        // Recovery is applied once on the original indices across all tiles.
        localRules.separationSamples = 0
        let rate = reader.run.settings.nominalRate
        guard reader.run.settings.channel == 0, profile.setup.nominalHz == rate, profile.setup.acquisitionDevice == reader.run.settings.board, profile.setup.picoAveraging == reader.run.settings.picoAveraging else {
            throw StreamFailure.storage("Pulse analysis requires a profile for this ADC channel and sample rate.")
        }
        let frequency = reader.run.settings.recordedRate
        let grid = max(32, StreamWire.samples(2048, at: frequency))
        let halo = ((max(rules.maximumSamples, rules.paddingAfter + rules.paddingBefore) + 3 * grid - 1) / grid) * grid
        var previousSegment: UUID?
        var previousEnd: UInt64?
        var recovery: Range<UInt64>?
        try FixtureTiles.visit(reader, selection: selection, halo: halo, tileSamples: max(256, StreamWire.samples(16_384, at: frequency)),
                               excluding: excluding, source: source) { span, owned in
            if previousSegment != span.segment.id || previousEnd != owned.lowerBound { recovery = nil }
            previousSegment = span.segment.id
            previousEnd = owned.upperBound
            let clockStart = span.segment.firstDeviceUS ?? 0
            let configured = span.segment.configuredRate(rate)
            let start = clockStart + UInt64(Double(span.first) * 1_000_000 / configured)
            let end = clockStart + UInt64(Double(span.end) * 1_000_000 / configured)
            var record = CaptureRecord(id: "\(span.segment.id):\(span.first)",
                metadata: ["boot_id": String(format: "%016llx", span.segment.boot ?? 0),
                           "sample_hz": String(rate), "configured_hz": String(configured), "start_us": String(start), "end_us": String(end),
                           "n": String(span.words.count), "observation_only": "1", "acquisition_board": span.segment.board.rawValue, "channel": "ADC0", "acq_flags": "0"],
                events: [], samples: span.words, complete: true, averagedCodes: span.means)
            if let factor = span.segment.picoAveraging {
                record.metadata["pico_average"] = String(factor.count)
                record.metadata["sample_hz"] = String(Int(configured.rounded()))
            }
            let elapsed = span.segment.timelineStart + Double(owned.lowerBound) / configured
            var result = try ProfileAnalyzer.evaluate(record, rules: localRules, limits: profile.limits, envelope: profile.envelope,
                                                     elapsed: elapsed, streamingWindow: true)
            var blocked = result.intervals.filter(\.omitFromCleaned).compactMap { item -> ReviewInterval? in
                let first = max(owned.lowerBound, span.first + UInt64(item.start))
                let end = min(owned.upperBound, span.first + UInt64(item.end))
                guard end > first else { return nil }
                return .init(range: .init(segment: span.segment.id, first: first, end: end), reason: .manual, action: .excluded)
            }
            func addRecovery(_ range: Range<UInt64>) {
                let first = max(owned.lowerBound, range.lowerBound)
                let end = min(owned.upperBound, range.upperBound)
                if first < end {
                    blocked.append(.init(range: .init(segment: span.segment.id, first: first, end: end), reason: .edge, action: .excluded))
                }
            }
            if let recovery { addRecovery(recovery) }
            // The crossing start owns the event. Context can extend across a
            // storage or analysis boundary without counting the event twice.
            result.candidates = result.candidates.filter { owned.contains(span.first + UInt64($0.start)) }
            if result.complete && !result.outsideEnvelope {
                for index in result.candidates.indices where result.candidates[index].decision == "match" {
                    let candidate = result.candidates[index]
                    if let recovery, span.first + UInt64(candidate.start) < recovery.upperBound {
                        result.candidates[index].decision = "separation"
                    } else {
                        let stop = span.first + UInt64(candidate.end)
                        let interval = stop..<(stop + UInt64(rules.separationSamples))
                        recovery = interval
                        addRecovery(interval)
                    }
                }
            }
            let usable = result.complete && !result.outsideEnvelope
                ? RunAnnotations.retained(owned, excluding: RunAnnotations.merged(blocked)[span.segment.id] ?? []) : []
            try output(.init(segment: span.segment.id, first: owned.lowerBound, count: owned.count,
                             contextFirst: span.first, result: result, usable: usable.reduce(0) { $0 + $1.count },
                             usableRanges: usable))
        }
    }
}
