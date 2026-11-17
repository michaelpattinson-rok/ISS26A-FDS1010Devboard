import CryptoKit
import Foundation

nonisolated struct ProfileInterval: Codable, Equatable, Sendable {
    var start: Int
    var end: Int
    var reason: String
    var omitFromCleaned: Bool
}

nonisolated struct ProfileCandidate: Codable, Equatable, Identifiable, Sendable {
    var start: Int
    var end: Int
    var peak: Int
    var height: Double
    var maximumSlope: Double
    var decision: String
    var review: Bool
    var id: Int { start }
}

nonisolated struct ProfileWindowResult: Codable, Equatable, Identifiable, Sendable {
    var algorithm = CalibrationProfile.algorithm
    var id: String
    var sampleHash: String
    var boot: String
    var elapsed: Double
    var deviceStartUS: UInt64?
    var gapBeforeUS: UInt64?
    var sampleHz: Int?
    var configuredHz: Double? = nil
    var samples: Int
    var usableSamples: Int
    var baseline: Double?
    var noise: Double?
    var drift: Double?
    var headroom: Double?
    var threshold: Double?
    var spectralPeakHz: Double?
    var adcErrors: Int
    var clipped: Int
    var firmwareQualityFlags: String?
    var outsideEnvelope: Bool
    var complete: Bool
    var reasons: [String]
    var intervals: [ProfileInterval]
    var candidates: [ProfileCandidate]

    var sampledSeconds: Double { (configuredHz ?? sampleHz.map(Double.init)).map { Double(samples) / $0 } ?? 0 }
    var usableSeconds: Double { (configuredHz ?? sampleHz.map(Double.init)).map { Double(usableSamples) / $0 } ?? 0 }
    var matchCount: Int { candidates.count { $0.decision == "match" } }
}

nonisolated struct ProfileManualExclusion: Codable, Equatable, Sendable {
    var recordID: String
    var start: Int
    var end: Int
    var reason: String
    var valid: Bool {
        CaptureIntent.validToken(recordID) && start >= 0 && end > start && end <= 32_768
        && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.utf8.count <= 400
    }
}

nonisolated struct ProfileBlock: Codable, Equatable, Identifiable, Sendable {
    var boot: String
    var minute: Int
    var coverage = ProfileCoverage()
    var medianBaseline: Double?
    var medianNoise: Double?
    var maximumDrift: Double?
    var minimumHeadroom: Double?
    var medianSpectralPeakHz: Double?
    var burstWindows = 0
    var id: String { "\(boot):\(minute)" }
}

nonisolated enum ProfileAnalyzer {
    static let sampleRate = 100_000
    static let maximumCandidates = 2048
    private static let blockSize = 2048

    static func digest(_ words: [UInt16]) -> String {
        let bytes = words.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
        return hash(Data(bytes))
    }

    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func sigma(_ values: [Double]) -> Double? {
        guard let center = median(values) else { return nil }
        return median(values.map { abs($0 - center) }).map { $0 * 1.4826 }
    }

    static func evaluate(_ record: CaptureRecord, rules: ProfilePulseRules, limits: ProfileLimits? = nil,
                         envelope: ProfileEnvelope? = nil, elapsed: Double = 0,
                         exclusions: [ProfileManualExclusion] = [], spectrum: Bool = false, streamingWindow: Bool = false) throws -> ProfileWindowResult {
        try Task.checkCancellation()
        guard rules.valid, limits?.valid ?? true, envelope?.valid ?? true else { throw StorageError.invalidSession }
        let words = record.samples
        let n = words.count
        let metadata = record.metadata
        let boot = metadata["boot_id"] ?? ""
        let start = metadata["start_us"].flatMap(UInt64.init)
        let end = metadata["end_us"].flatMap(UInt64.init)
        let board = metadata["acquisition_board"].flatMap(AcquisitionBoard.init(rawValue:)) ?? .picoW
        let adcMax = Double(board.maxCode)
        let sampleRate = metadata["sample_hz"].flatMap(Int.init) ?? 0
        let effective = metadata["configured_hz"].flatMap(Double.init)
        let frequency = effective ?? Double(sampleRate)
        let averaged = streamingWindow && metadata["pico_average"].flatMap(Int.init).flatMap(ADCAveraging.init(rawValue:)) != nil
        let means = averaged ? record.averagedCodes : nil
        let validTiming = (effective == nil || (streamingWindow && frequency.isFinite
            && frequency > 0 && abs(frequency - Double(sampleRate)) <= Double(sampleRate) / 100))
            && (streamingWindow ? (averaged ? (156...125_000).contains(sampleRate) : StreamWire.customRates.contains(sampleRate)) : sampleRate == Self.sampleRate)
            && start != nil && end != nil
            && (start ?? .max) < (end ?? 0) && boot.count == 16 && UInt64(boot, radix: 16) != nil
        var result = ProfileWindowResult(id: record.id, sampleHash: digest(words), boot: boot, elapsed: elapsed,
                                         deviceStartUS: start, gapBeforeUS: metadata["gap_before_us"].flatMap(UInt64.init),
                                         sampleHz: validTiming ? sampleRate : nil, configuredHz: validTiming ? effective : nil, samples: n, usableSamples: 0,
                                         adcErrors: 0, clipped: 0, firmwareQualityFlags: metadata["quality_flags"],
                                         outsideEnvelope: false, complete: false, reasons: [], intervals: [], candidates: [])
        guard record.complete, metadata["channel"] == "ADC0", metadata["observation_only"] == "1",
              metadata["acq_flags"] == "0", validTiming,
              !averaged || (means?.count == n && means?.allSatisfy({ (0...4095).contains($0) }) == true),
              (256...(streamingWindow ? max(256, StreamWire.samples(100_000, at: frequency)) : 32_768)).contains(n),
              metadata["n"].flatMap(Int.init) == n else {
            result.reasons = ["Unverified acquisition or timing"]
            if n > 0 { result.intervals = [.init(start: 0, end: n, reason: "Unverified acquisition or timing", omitFromCleaned: true)] }
            return result
        }
        let blockSize = max(32, StreamWire.samples(Self.blockSize, at: frequency))
        let faultPadding = StreamWire.samples(10, at: frequency)
        let codes = means ?? words.map { Double(board.sampleCode($0)) }
        var mask = [Bool](repeating: false, count: n)
        func maskRange(_ lo: Int, _ hi: Int, _ reason: String, cleaned: Bool = true) {
            let left = max(0, lo), right = min(n, hi)
            guard left < right else { return }
            result.intervals.append(.init(start: left, end: right, reason: reason, omitFromCleaned: cleaned))
            if cleaned { for i in left..<right { mask[i] = true } }
        }
        func faulty(_ i: Int) -> String? {
            if words[i] & 0x8000 != 0 {
                return averaged && words[i] & 0x4000 == 0 ? "ADC rail clipping" : "ADC error"
            }
            if codes[i] == 0 || codes[i] == adcMax { return "ADC rail clipping" }
            return nil
        }
        var i = 0
        while i < n {
            guard let reason = faulty(i) else { i += 1; continue }
            let first = i
            while i < n, faulty(i) == reason { i += 1 }
            if reason == "ADC error" { result.adcErrors += i - first } else { result.clipped += i - first }
            maskRange(first - max(faultPadding, rules.paddingBefore), i + max(faultPadding, rules.paddingAfter), reason)
        }
        for item in exclusions where item.recordID == record.id {
            guard item.valid, item.end <= n else { throw StorageError.invalidIdentifier }
            maskRange(item.start, item.end, "Operator: " + item.reason)
        }
        var centers: [(index: Int, value: Double, start: Int, end: Int)] = []
        for startIndex in stride(from: 0, to: n, by: blockSize) {
            let endIndex = min(n, startIndex + blockSize)
            let valid = (startIndex..<endIndex).compactMap { mask[$0] ? nil : codes[$0] }
            guard valid.count >= max(16, (endIndex - startIndex) / 2), let center = median(valid) else {
                maskRange(startIndex, endIndex, "Insufficient valid baseline")
                continue
            }
            centers.append(((startIndex + endIndex) / 2, center, startIndex, endIndex))
        }
        guard let first = centers.first, let last = centers.last else {
            result.reasons = ["No usable baseline"]
            return result
        }
        let baseline = median(centers.map(\.value))!
        let baselineLow = centers.map(\.value).min()!
        let baselineHigh = centers.map(\.value).max()!
        let drift = baselineHigh - baselineLow
        let headroom = min(baselineLow, adcMax - baselineHigh)
        var cursor = 0
        let residuals = codes.enumerated().map { index, code -> Double in
            while cursor + 1 < centers.count && centers[cursor + 1].index < index { cursor += 1 }
            if index <= first.index { return code - first.value }
            if index >= last.index { return code - last.value }
            let left = centers[cursor], right = centers[cursor + 1]
            let fraction = Double(index - left.index) / Double(right.index - left.index)
            return code - (left.value + fraction * (right.value - left.value))
        }
        let noise = sigma(residuals.indices.compactMap { mask[$0] ? nil : residuals[$0] }) ?? 0
        let threshold = rules.threshold == .adaptive ? max(rules.height, rules.sigmaMultiplier * noise) : rules.height
        result.baseline = baseline
        result.noise = noise
        result.drift = drift
        result.headroom = headroom
        result.threshold = threshold
        if let limits {
            if noise > limits.maximumNoise { result.reasons.append("Noise exceeds the locked limit") }
            if drift > limits.maximumDrift { result.reasons.append("Baseline drift exceeds the locked limit") }
            if headroom < limits.minimumHeadroom { result.reasons.append("Insufficient baseline headroom") }
        }
        if let envelope, !(envelope.baselineLow...envelope.baselineHigh).contains(baseline) {
            result.reasons.append("Baseline lies outside the fitted envelope")
        }
        result.outsideEnvelope = !result.reasons.isEmpty
        if result.outsideEnvelope {
            maskRange(0, n, "Outside the validated envelope", cleaned: false)
        }
        if spectrum {
            let bins = SignalAnalysis.spectrum(words, sampleRate: frequency).points
            result.spectralPeakHz = bins.dropFirst().max { $0.y < $1.y }?.x
        }
        let strict = rules.artifactMode == .strict
        let automatic = rules.artifactMode != .review
        if automatic {
            for center in centers {
                let local = (center.start..<center.end).compactMap { mask[$0] ? nil : residuals[$0] }
                if let spread = sigma(local), spread > rules.noisyBlockSigma * (strict ? 0.8 : 1) {
                    maskRange(center.start - rules.paddingBefore, center.end + rules.paddingAfter, "Noisy interval")
                }
            }
        }
        let signed = residuals.map { $0 * rules.polarity.sign }
        var separationEnd = 0
        i = 0
        while i < n {
            if mask[i] || signed[i] < threshold { i += 1; continue }
            let startIndex = i
            var peak = i, slope = 0.0
            while i < n, !mask[i], signed[i] >= threshold {
                if signed[i] > signed[peak] { peak = i }
                if i > 0 { slope = max(slope, abs(codes[i] - codes[i - 1])) }
                i += 1
            }
            if i < n { slope = max(slope, abs(codes[i] - codes[i - 1])) }
            guard result.candidates.count < maximumCandidates else {
                result.reasons.append("Candidate capacity exceeded")
                maskRange(0, n, "Candidate capacity exceeded", cleaned: false)
                return result
            }
            let width = i - startIndex
            let edge = startIndex == 0 || i == n || mask[startIndex - 1] || mask[i]
            let spike = width <= rules.spikeMaximumSamples + (strict ? 1 : 0)
                && slope >= rules.spikeMinimumSlope * (strict ? 0.8 : 1)
            let decision: String
            if edge {
                decision = "edge_or_gap"
                maskRange(startIndex, i, "Incomplete edge pulse", cleaned: false)
            } else if result.outsideEnvelope {
                decision = "outside_envelope"
            } else if automatic && spike {
                decision = "spike"
                maskRange(startIndex - rules.paddingBefore, i + rules.paddingAfter, "Short steep spike")
            } else if width < rules.minimumSamples || width > rules.maximumSamples {
                decision = "width"
            } else if startIndex < separationEnd {
                decision = "separation"
            } else {
                decision = "match"
                separationEnd = min(n, i + rules.separationSamples)
                maskRange(i, separationEnd, "Match recovery", cleaned: false)
            }
            result.candidates.append(.init(start: startIndex, end: i, peak: peak, height: signed[peak],
                                           maximumSlope: slope, decision: decision,
                                           review: signed[peak] >= rules.reviewHeight || spike))
        }
        // Retrospective padding from a later spike can overlap an earlier match.
        // Reconcile against the final cleaned mask before publishing any totals.
        for index in result.candidates.indices where result.candidates[index].decision == "match" {
            let candidate = result.candidates[index]
            if (candidate.start..<candidate.end).contains(where: { mask[$0] }) {
                result.candidates[index].decision = "masked_by_padding"
            }
        }
        if result.intervals.count > 4096 {
            result.reasons.append("Exclusion capacity exceeded")
            result.intervals = [.init(start: 0, end: n, reason: "Exclusion capacity exceeded", omitFromCleaned: false)]
            return result
        }
        var matchingMask = mask
        for interval in result.intervals where !interval.omitFromCleaned {
            for index in interval.start..<interval.end { matchingMask[index] = true }
        }
        result.usableSamples = matchingMask.count { !$0 }
        result.complete = true
        return result
    }

    static func blocks(_ results: [ProfileWindowResult]) -> [ProfileBlock] {
        Dictionary(grouping: results, by: { "\($0.boot):\(Int($0.elapsed / 60))" }).values.compactMap { windows in
            guard let first = windows.first else { return nil }
            var block = ProfileBlock(boot: first.boot, minute: Int(first.elapsed / 60))
            for item in windows { block.coverage.add(item) }
            block.medianBaseline = median(windows.compactMap(\.baseline))
            block.medianNoise = median(windows.compactMap(\.noise))
            block.maximumDrift = windows.compactMap(\.drift).max()
            block.minimumHeadroom = windows.compactMap(\.headroom).min()
            block.medianSpectralPeakHz = median(windows.compactMap(\.spectralPeakHz))
            block.burstWindows = windows.count { $0.matchCount > 1 }
            return block
        }.sorted { ($0.minute, $0.boot) < ($1.minute, $1.boot) }
    }
}
