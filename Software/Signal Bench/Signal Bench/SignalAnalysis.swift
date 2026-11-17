import Foundation
import Accelerate
import CryptoKit

nonisolated struct AnalysisPoint: Codable, Sendable {
    let x: Double
    let y: Double
}

nonisolated struct AnalysisCandidate: Codable, Sendable {
    let start: Int
    let peak: Int
    let end: Int
    let amplitudeCodes: Double
    let signedAmplitudeCodes: Double
    let flags: UInt32
    let qualified: Bool
}

/// An immutable interpretation of a particular raw record. Firmware results stay in the record.
nonisolated struct SignalAnalysisResult: Codable, Identifiable, Sendable {
    let schema: Int
    let id: UUID
    let recordID: String
    let createdAt: Date
    let inputSHA256: String
    let algorithmVersion: UInt32
    let polarity: String
    let calibrationRecordID: String?
    let calibrationID: String?
    let parameters: [String: Double]
    let sampleRateHz: Double
    let sampleCount: Int
    let validSamples: Int
    let adcErrors: Int
    let baselineCodes: Double
    let robustNoiseCodes: Double
    let baselineRMSCodes: Double
    let thresholdCodes: Double
    let qualityFlags: UInt32
    let qualificationAvailable: Bool
    let qualifiedPulses: Int
    let candidates: [AnalysisCandidate]
    let histogram: [AnalysisPoint]
    let baselineTrend: [AnalysisPoint]
    let spectrum: [AnalysisPoint]
    let spectrumWindowSamples: Int
    let spectrumWindows: Int
    let filterWidth: Int
    let warnings: [String]
}

nonisolated enum SignalAnalysis {
    static let filterWidths = [1, 5, 11, 21]

    static func compute(record: CaptureRecord, polarity: String, filterWidth: Int = 1) throws -> SignalAnalysisResult {
        try Task.checkCancellation()
        guard record.samples.count <= 32_768, !record.samples.isEmpty,
              ["NEGATIVE", "POSITIVE"].contains(polarity), filterWidths.contains(filterWidth),
              let rate = record.metadata["sample_hz"].flatMap(Double.init), rate.isFinite,
              rate > 0, rate <= 500_000 else {
            throw SBProtocolError.invalid("This record lacks supported samples or sampling information.")
        }
        // The shared pulse criteria are defined for nominal 100 kS/s.
        let supportedTiming = abs(rate - 100_000) < 1
        var config = fds_default_config()
        if let threshold = record.metadata["threshold"].flatMap(Float.init), threshold.isFinite, threshold > 0 {
            config.fixed_threshold_codes = threshold
        }
        var workspace = fds_workspace()
        var result = fds_result()
        record.samples.withUnsafeBufferPointer { samples in
            fds_analyze_profile(samples.baseAddress, samples.count, &config, &workspace, &result,
                                polarity == "NEGATIVE" ? FDS_POLARITY_NEGATIVE : FDS_POLARITY_POSITIVE)
        }
        let channelText = record.metadata["channel"] ?? "ADC0"
        let channel = ["ADC0": 0, "ADC1": 1, "ADC2": 2][channelText] ?? -1
        let storedProfile = record.metadata["profile"] ?? record.metadata["processing_profile"] ?? "POSITIVE"
        let matchedProfile = storedProfile == polarity
        let calibrated = record.metadata["calibrated"] == "1" && record.metadata["calibration_record_id"] != nil
        let mayQualify = record.metadata["observation_only"] != "1" && supportedTiming && record.complete && channel == 0 && matchedProfile && calibrated &&
            record.metadata["tag"] != "CAL" && record.metadata["acq_flags"] == "0"
        let qualified = mayQualify && result.valid_record
        var candidates: [AnalysisCandidate] = []
        withUnsafePointer(to: result.events) { tuple in
            let events = UnsafeRawPointer(tuple).assumingMemoryBound(to: fds_event.self)
            for index in 0..<min(Int(result.stored), Int(FDS_MAX_EVENTS)) {
                let event = events[index]
                candidates.append(.init(start: Int(event.start), peak: Int(event.peak), end: Int(event.end),
                                        amplitudeCodes: Double(event.peak_delta_codes),
                                        signedAmplitudeCodes: Double(event.peak_delta_codes) * (polarity == "NEGATIVE" ? -1 : 1),
                                        flags: event.flags, qualified: qualified && event.flags == 0))
            }
        }
        let valid = record.samples.filter { $0 & 0x8000 == 0 }.map { Double($0 & 0x0fff) }
        var rawBytes = Data(capacity: record.samples.count * 2)
        for value in record.samples { rawBytes.append(UInt8(value & 255)); rawBytes.append(UInt8(value >> 8)) }
        let digest = SHA256.hash(data: rawBytes).map { String(format: "%02x", $0) }.joined()
        let spectral = spectrum(record.samples, sampleRate: rate)
        try Task.checkCancellation()
        var warnings: [String] = []
        if !record.complete { warnings.append("The raw record is incomplete. Results are diagnostic.") }
        if channel != 0 { warnings.append("This stage has no qualified detector pulse profile. Pulse candidates are diagnostic.") }
        if !supportedTiming { warnings.append("Pulse criteria require nominal 100 kS/s. Results are diagnostic at this rate.") }
        if !calibrated { warnings.append("A linked quiet calibration is unavailable. Pulse candidates are diagnostic.") }
        if !matchedProfile { warnings.append("The selected polarity differs from the recorded profile. A matching quiet calibration is required for qualification.") }
        if result.adc_errors > 0 { warnings.append("ADC error samples are excluded from distributions and spectral windows.") }
        if result.clipped_samples > 0 { warnings.append("Clipping is present. The spectrum and pulse heights can be distorted.") }
        if !candidates.isEmpty { warnings.append("The spectrum includes signal pulses as well as noise.") }
        if spectral.points.isEmpty { warnings.append("The record has too few contiguous valid samples for a spectrum.") }
        let parameters: [String: Double] = [
            "trigger_sigma": Double(config.trigger_sigma), "minimum_threshold_codes": Double(config.minimum_threshold_codes),
            "maximum_sigma_codes": Double(config.maximum_sigma_codes), "fixed_threshold_codes": Double(config.fixed_threshold_codes),
            "recovery_samples": Double(config.recovery_samples), "end_guard_samples": Double(config.end_guard_samples),
            "local_baseline_samples": Double(config.local_baseline_samples),
            "minimum_above_threshold_samples": Double(config.minimum_above_threshold_samples),
            "maximum_pulse_samples": Double(config.max_positive_samples),
            "maximum_local_offset_codes": Double(config.maximum_local_offset_codes),
            "maximum_local_slope_codes": Double(config.maximum_local_slope_codes)
        ]
        return .init(schema: 1, id: UUID(), recordID: record.id, createdAt: Date(), inputSHA256: digest,
                     algorithmVersion: fds_algorithm_version(), polarity: polarity,
                     calibrationRecordID: record.metadata["calibration_record_id"], calibrationID: record.metadata["calibration_id"],
                     parameters: parameters, sampleRateHz: rate, sampleCount: record.samples.count,
                     validSamples: valid.count, adcErrors: record.samples.count - valid.count,
                     baselineCodes: Double(result.baseline), robustNoiseCodes: Double(result.sigma),
                     baselineRMSCodes: Double(result.baseline_rms), thresholdCodes: Double(result.threshold),
                     qualityFlags: result.quality_flags, qualificationAvailable: mayQualify,
                     qualifiedPulses: qualified ? Int(result.accepted) : 0, candidates: candidates,
                     histogram: histogram(valid), baselineTrend: baselineTrend(record.samples, sampleRate: rate),
                     spectrum: spectral.points, spectrumWindowSamples: spectral.size, spectrumWindows: spectral.windows,
                     filterWidth: filterWidth, warnings: warnings)
    }

    static func filteredSamples(_ samples: [UInt16], width: Int) -> [Double?] {
        guard filterWidths.contains(width) else { return [] }
        let radius = width / 2
        return samples.indices.map { index in
            let first = max(0, index - radius), end = min(samples.count, index + radius + 1)
            var sum = 0.0
            for j in first..<end {
                guard samples[j] & 0x8000 == 0 else { return nil }
                sum += Double(samples[j] & 0x0fff)
            }
            return sum / Double(end - first)
        }
    }

    private static func histogram(_ values: [Double]) -> [AnalysisPoint] {
        guard let low = values.min(), let high = values.max() else { return [] }
        let width = max(1, (high - low + 1) / 48)
        let count = min(48, Int((high - low) / width) + 1)
        var bins = [Double](repeating: 0, count: count)
        for value in values { bins[min(count - 1, Int((value - low) / width))] += 1 }
        return bins.indices.map { .init(x: low + (Double($0) + 0.5) * width, y: bins[$0]) }
    }

    private static func baselineTrend(_ words: [UInt16], sampleRate: Double) -> [AnalysisPoint] {
        stride(from: 0, to: words.count, by: 512).compactMap { start in
            let end = min(words.count, start + 512)
            guard end - start >= 64, !words[start..<end].contains(where: { $0 & 0x8000 != 0 }) else { return nil }
            let sorted = words[start..<end].map { Double($0 & 0x0fff) }.sorted()
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            return AnalysisPoint(x: Double(start + (end - start) / 2) / sampleRate, y: median)
        }
    }

    /// Hann Welch density in ADC codes squared per Hz, with one-sided doubling.
    /// Each window lies within one contiguous valid region. Error gaps are never joined.
    static func spectrum(_ words: [UInt16], sampleRate: Double) -> (points: [AnalysisPoint], size: Int, windows: Int) {
        guard sampleRate.isFinite, sampleRate > 0, words.count <= 32_768 * (StreamWire.rates.max() ?? StreamWire.rate) / StreamWire.rate else { return ([], 0, 0) }
        var regions: [Range<Int>] = []
        var start: Int?
        for index in words.indices {
            if words[index] & 0x8000 == 0 {
                if start == nil { start = index }
            } else if let first = start { regions.append(first..<index); start = nil }
        }
        if let first = start { regions.append(first..<words.count) }
        let longest = regions.map(\.count).max() ?? 0
        guard longest >= 128 else { return ([], 0, 0) }
        var size = 128
        let maxFFTSize = Int(4096 * min(sampleRate / Double(StreamWire.rate), 5))
        while size * 2 <= min(maxFFTSize, longest) { size *= 2 }
        guard let average = ADCSpectrumAverage(size: size, rate: sampleRate) else { return ([], 0, 0) }
        for region in regions where region.count >= size {
            for first in stride(from: region.lowerBound, through: region.upperBound - size, by: size / 2) {
                if Task.isCancelled { return ([], 0, 0) }
                average.append(words[first..<first + size])
            }
        }
        return (average.points, size, average.windows)
    }
}

nonisolated final class ADCSpectrumAverage {
    let size: Int
    let rate: Double
    private let setup: vDSP_DFT_SetupD
    private let window: [Double]
    private let normalization: Double
    private var density: [Double]
    private let imaginary: [Double]
    private var input: [Double]
    private var realOutput: [Double]
    private var imaginaryOutput: [Double]
    private(set) var windows = 0

    init?(size: Int, rate: Double) {
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), .FORWARD) else { return nil }
        self.size = size
        self.rate = rate
        self.setup = setup
        let window = (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)) }
        self.window = window
        normalization = 1 / (rate * window.reduce(0) { $0 + $1 * $1 })
        density = [Double](repeating: 0, count: size / 2 + 1)
        imaginary = [Double](repeating: 0, count: size)
        input = imaginary
        realOutput = imaginary
        imaginaryOutput = imaginary
    }

    deinit { vDSP_DFT_DestroySetupD(setup) }

    func append(_ words: ArraySlice<UInt16>) {
        let mean = Double(words.reduce(0) { $0 + Int($1 & 4095) }) / Double(size)
        for (index, word) in words.enumerated() { input[index] = (Double(word & 4095) - mean) * window[index] }
        accumulate()
    }

    func append(_ values: [Double]) {
        let mean = values.reduce(0, +) / Double(size)
        for (index, value) in values.enumerated() { input[index] = (value - mean) * window[index] }
        accumulate()
    }

    private func accumulate() {
        vDSP_DFT_ExecuteD(setup, input, imaginary, &realOutput, &imaginaryOutput)
        for bin in density.indices {
            let multiplier = (bin == 0 || bin == size / 2) ? 1.0 : 2.0
            density[bin] += multiplier * (realOutput[bin] * realOutput[bin] + imaginaryOutput[bin] * imaginaryOutput[bin]) * normalization
        }
        windows += 1
    }

    var points: [AnalysisPoint] {
        guard windows > 0 else { return [] }
        return density.indices.map { .init(x: Double($0) * rate / Double(size), y: density[$0] / Double(windows)) }
    }
}
