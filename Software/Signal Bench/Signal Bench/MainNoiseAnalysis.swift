import Foundation

nonisolated struct MainPulseCriteria: Codable, Equatable, Sendable {
    enum ThresholdMode: String, Codable, CaseIterable, Sendable {
        case adaptive, fixed
    }

    static let codeRange = 1...4095
    static let sigmaRange = 3.0...30.0
    static let sampleRange = 1...1000

    var thresholdMode: ThresholdMode = .adaptive
    var minimumCodes = 24
    var sigmaMultiplier = 6.0
    var minimumSamples = 4

    var isValid: Bool {
        Self.codeRange.contains(minimumCodes) && sigmaMultiplier.isFinite &&
            Self.sigmaRange.contains(sigmaMultiplier) && Self.sampleRange.contains(minimumSamples)
    }
}

nonisolated enum MainDetectorCondition: String, Codable, CaseIterable, Sendable {
    case unspecified, disconnected, connectedDark

    var label: String {
        switch self {
        case .unspecified: "Unspecified"
        case .disconnected: "Detector disconnected"
        case .connectedDark: "Detector connected in darkness"
        }
    }
}

nonisolated struct MainObservationOptions: Codable, Equatable, Sendable {
    var schema = 1
    var criteria = MainPulseCriteria()
    var condition: MainDetectorCondition = .unspecified

    var isValid: Bool { schema == 1 && criteria.isValid }

    var metadata: [String: String] {
        [
            "host_main_criteria_version": String(schema),
            "host_detector_condition": condition.rawValue,
            "host_main_threshold_mode": criteria.thresholdMode.rawValue,
            "host_main_minimum_codes": String(criteria.minimumCodes),
            "host_main_sigma_multiplier": String(criteria.sigmaMultiplier),
            "host_main_minimum_samples": String(criteria.minimumSamples)
        ]
    }

    init(criteria: MainPulseCriteria = .init(), condition: MainDetectorCondition = .unspecified) {
        self.criteria = criteria
        self.condition = condition
    }

    init?(metadata: [String: String]) {
        guard metadata["host_main_criteria_version"] == "1",
              let condition = metadata["host_detector_condition"].flatMap(MainDetectorCondition.init(rawValue:)),
              let mode = metadata["host_main_threshold_mode"].flatMap(MainPulseCriteria.ThresholdMode.init(rawValue:)),
              let codes = metadata["host_main_minimum_codes"].flatMap(Int.init),
              let sigma = metadata["host_main_sigma_multiplier"].flatMap(Double.init),
              let samples = metadata["host_main_minimum_samples"].flatMap(Int.init) else { return nil }
        self.init(criteria: .init(thresholdMode: mode, minimumCodes: codes, sigmaMultiplier: sigma, minimumSamples: samples),
                  condition: condition)
        guard isValid else { return nil }
    }
}

nonisolated struct MainWindowAnalysis: Sendable {
    let estimatorVersion: UInt32
    let thresholdCodes: Double
    let candidateCount: Int
    let candidateDetailsTruncated: Bool
    let matchingPeakIndices: [Int]
    let baselineCodes: Double
    let noiseSigmaCodes: Double
    let tailShiftCodes: Double
    let clippedSamples: Int
    let adcErrors: Int
    let qualityFlags: UInt32
    let acquisitionFlags: UInt32?
    let firmwareQualityFlags: UInt32?

    var eligibleForMatches: Bool { acquisitionFlags == 0 && adcErrors == 0 && clippedSamples == 0 }
    var matchCount: Int { matchingPeakIndices.count }
}

nonisolated struct MainNoisePoint: Identifiable, Sendable {
    let id: String
    let elapsedSeconds: Double
    let capturedAt: Date
    let segment: Int
    let baselineCodes: Double?
    let noiseSigmaCodes: Double?
    let tailShiftCodes: Double?
    let thresholdCodes: Double?
    let clippedSamples: Int?
    let adcErrors: Int?
    let qualityFlags: UInt32?
    let acquisitionFlags: UInt32?
    let gapSeconds: Double?
}

nonisolated struct MainNoiseSummary: Sendable {
    let points: [MainNoisePoint]
    let medianNoiseCodes: Double?
    let percentile95NoiseCodes: Double?
    let noiseRangeCodes: ClosedRange<Double>?
    let baselineRangeCodes: ClosedRange<Double>?
    let tailShiftRangeCodes: ClosedRange<Double>?
    let clippedWindows: Int
    let adcErrorWindows: Int
    let flaggedWindows: Int
    let timingSegmentCount: Int
    let missingWindows: Int
}

nonisolated enum MainNoiseAnalysis {
    static func evaluate(_ record: CaptureRecord, criteria: MainPulseCriteria) throws -> MainWindowAnalysis {
        try Task.checkCancellation()
        guard criteria.isValid else { throw SBProtocolError.invalid("The pulse criteria are outside the supported ranges.") }
        guard record.complete, record.metadata["observation_only"] == "1",
              record.metadata["channel"] == "ADC0",
              !record.samples.isEmpty, record.samples.count <= 32_768,
              let rate = record.metadata["sample_hz"].flatMap(Double.init), abs(rate - 100_000) < 1,
              let polarity = record.metadata["profile"], ["NEGATIVE", "POSITIVE"].contains(polarity) else {
            throw SBProtocolError.invalid("Pulse criteria require a complete Main waveform from ADC0 at nominal 100 kS/s.")
        }

        var config = fds_default_config()
        config.minimum_above_threshold_samples = UInt32(criteria.minimumSamples)
        config.minimum_threshold_codes = Float(criteria.minimumCodes)
        if criteria.thresholdMode == .fixed {
            config.fixed_threshold_codes = Float(criteria.minimumCodes)
        } else {
            config.trigger_sigma = Float(criteria.sigmaMultiplier)
        }
        var workspace = fds_workspace()
        var result = fds_result()
        record.samples.withUnsafeBufferPointer { samples in
            fds_analyze_profile(samples.baseAddress, samples.count, &config, &workspace, &result,
                                polarity == "NEGATIVE" ? FDS_POLARITY_NEGATIVE : FDS_POLARITY_POSITIVE)
        }
        try Task.checkCancellation()
        guard (result.quality_flags & UInt32(FDS_BAD_ARGUMENT.rawValue)) == 0 else {
            throw SBProtocolError.invalid("This waveform has too few samples for the pulse estimator.")
        }
        let acquisitionFlags = record.metadata["acq_flags"].flatMap(UInt32.init)
        let firmwareQuality = record.metadata["quality_flags"].flatMap(UInt32.init)
        var matches: [Int] = []
        if acquisitionFlags == 0, result.adc_errors == 0, result.clipped_samples == 0 {
            let invalidShape = UInt32(FDS_PILEUP.rawValue) | UInt32(FDS_LONG_PULSE.rawValue) |
                UInt32(FDS_BOUNDARY_PULSE.rawValue)
            withUnsafePointer(to: result.events) { tuple in
                let events = UnsafeRawPointer(tuple).assumingMemoryBound(to: fds_event.self)
                for index in 0..<min(Int(result.stored), Int(FDS_MAX_EVENTS)) {
                    let event = events[index]
                    if event.flags & invalidShape == 0, event.peak_delta_codes >= result.threshold,
                       event.contiguous_above_samples >= config.minimum_above_threshold_samples {
                        matches.append(Int(event.peak))
                    }
                }
            }
        }
        return MainWindowAnalysis(estimatorVersion: fds_algorithm_version(), thresholdCodes: Double(result.threshold),
                                  candidateCount: Int(result.candidates), candidateDetailsTruncated: result.candidates > result.stored,
                                  matchingPeakIndices: matches,
                                  baselineCodes: Double(result.baseline), noiseSigmaCodes: Double(result.sigma),
                                  tailShiftCodes: Double(result.tail_baseline_shift), clippedSamples: Int(result.clipped_samples),
                                  adcErrors: Int(result.adc_errors), qualityFlags: result.quality_flags,
                                  acquisitionFlags: acquisitionFlags, firmwareQualityFlags: firmwareQuality)
    }

    /// The caller supplies acknowledged summaries in run order. A segment is
    /// independent of every other segment. Each point is one finite capture.
    static func summarize(_ summaries: [CaptureRecord]) -> MainNoiseSummary {
        guard let firstDate = summaries.first?.capturedAt else {
            return .init(points: [], medianNoiseCodes: nil, percentile95NoiseCodes: nil, noiseRangeCodes: nil, baselineRangeCodes: nil,
                         tailShiftRangeCodes: nil, clippedWindows: 0, adcErrorWindows: 0, flaggedWindows: 0,
                         timingSegmentCount: 0, missingWindows: 0)
        }
        var seen: Set<String> = []
        var segment = 0
        var segmentDeviceStart: UInt64?
        var segmentHostStart = firstDate
        var segmentElapsedStart = 0.0
        var previousDeviceStart: UInt64?
        var previousBoot: UInt64?
        var previousElapsed = 0.0
        var missing = 0
        var points: [MainNoisePoint] = []
        for record in summaries where seen.insert(record.id).inserted {
            let metadata = record.metadata
            guard record.complete, metadata["observation_only"] == "1", metadata["channel"] == "ADC0" else {
                missing += 1
                continue
            }
            let boot = metadata["boot_id"].flatMap { UInt64($0, radix: 16) }
            let start = boot == nil ? nil : metadata["start_us"].flatMap(UInt64.init)
            let deviceClockChanged: Bool
            if let start, let previousDeviceStart {
                deviceClockChanged = boot != previousBoot || start <= previousDeviceStart
            } else {
                deviceClockChanged = (start == nil) != (previousDeviceStart == nil)
            }
            if segment == 0 || deviceClockChanged {
                segment += 1
                segmentHostStart = record.capturedAt
                segmentDeviceStart = start
                segmentElapsedStart = max(previousElapsed, record.capturedAt.timeIntervalSince(firstDate))
            }
            let elapsed: Double
            if let start, let segmentDeviceStart {
                elapsed = segmentElapsedStart + Double(start - segmentDeviceStart) / 1_000_000
            } else {
                elapsed = max(previousElapsed, segmentElapsedStart + record.capturedAt.timeIntervalSince(segmentHostStart))
            }
            previousDeviceStart = start
            previousBoot = boot
            previousElapsed = elapsed
            let baseline = metric(metadata["baseline"], in: 0...4095)
            let sigma = metric(metadata["sigma"], in: 0...8192)
            let tail = metric(metadata["tail_baseline_shift"], in: -4095...4095)
            let clipping = count(metadata["clipped_samples"])
            let adcErrors = count(metadata["adc_errors"])
            let quality = metadata["quality_flags"].flatMap(UInt32.init)
            let acquisition = metadata["acq_flags"].flatMap(UInt32.init)
            if baseline == nil || sigma == nil || tail == nil || clipping == nil || adcErrors == nil ||
                quality == nil || acquisition == nil { missing += 1 }
            points.append(.init(id: record.id, elapsedSeconds: elapsed, capturedAt: record.capturedAt, segment: segment,
                                baselineCodes: baseline, noiseSigmaCodes: sigma, tailShiftCodes: tail,
                                thresholdCodes: metric(metadata["threshold"], in: 0...65_536),
                                clippedSamples: clipping, adcErrors: adcErrors, qualityFlags: quality,
                                acquisitionFlags: acquisition, gapSeconds: metadata["gap_before_us"].flatMap(UInt64.init)
                                    .map { Double($0) / 1_000_000 }))
        }
        // ADC faults, clipping and missing acquisition flags remain visible
        // in points and counts, and cannot shift the reported noise statistics.
        let validPoints = points.filter { $0.acquisitionFlags == 0 && $0.adcErrors == 0 && $0.clippedSamples == 0 }
        let noise = validPoints.compactMap(\.noiseSigmaCodes).sorted()
        let middle = noise.count / 2
        let median = noise.isEmpty ? nil : (noise.count.isMultiple(of: 2) ? (noise[middle - 1] + noise[middle]) / 2 : noise[middle])
        let percentile95 = noise.isEmpty ? nil : noise[Int((0.95 * Double(noise.count)).rounded(.up)) - 1]
        return .init(points: points, medianNoiseCodes: median, percentile95NoiseCodes: percentile95, noiseRangeCodes: range(noise),
                     baselineRangeCodes: range(validPoints.compactMap(\.baselineCodes)),
                     tailShiftRangeCodes: range(validPoints.compactMap(\.tailShiftCodes)),
                     clippedWindows: points.count { ($0.clippedSamples ?? 0) > 0 },
                     adcErrorWindows: points.count { ($0.adcErrors ?? 0) > 0 },
                     flaggedWindows: points.count { ($0.qualityFlags ?? 0) != 0 || ($0.acquisitionFlags ?? 0) != 0 },
                     timingSegmentCount: segment, missingWindows: missing)
    }

    static func comparisonWarnings(_ first: RunArchive, _ second: RunArchive) -> [String] {
        var warnings: [String] = []
        let conditions = Set([first.mainObservationOptions?.condition, second.mainObservationOptions?.condition].compactMap { $0 })
        if conditions != [.disconnected, .connectedDark] {
            warnings.append("Choose one run with the detector disconnected and one with the detector connected in darkness.")
        }
        if first.gainConfirmed != true || second.gainConfirmed != true || first.physicalGain == nil || second.physicalGain == nil {
            warnings.append("Physical gain was not confirmed for both runs. Confirm the same J4 position before comparing.")
        } else if first.physicalGain != second.physicalGain {
            warnings.append("The runs used different gain settings. Noise amplitudes may differ because of gain.")
        }
        if let firstProfile = first.processingProfile, let secondProfile = second.processingProfile, firstProfile != secondProfile {
            warnings.append("The runs used different pulse polarities. Compare noise values independently of pulse matches.")
        }
        return warnings
    }

    private static func metric(_ value: String?, in range: ClosedRange<Double>) -> Double? {
        guard let number = value.flatMap(Double.init), number.isFinite, range.contains(number) else { return nil }
        return number
    }

    private static func count(_ value: String?) -> Int? {
        guard let number = value.flatMap(Int.init), (0...32_768).contains(number) else { return nil }
        return number
    }

    private static func range(_ values: [Double]) -> ClosedRange<Double>? {
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        return minimum...maximum
    }
}
