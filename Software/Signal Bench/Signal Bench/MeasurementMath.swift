import Foundation

/// Horizontal position for a sample in an inclusive displayed interval.
enum WaveformProjection {
    static func columnCount(sampleCount: Int, pixelWidth: Int) -> Int {
        max(1, min(sampleCount, pixelWidth))
    }

    static func fraction(index: Int, first: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return Double(index - first) / Double(count - 1)
    }
}

/// Statistics over a selected inclusive sample interval. Samples marked with
/// the ADC FIFO error bit are counted separately and excluded from statistics.
struct SampleStatistics {
    let count: Int
    let errorCount: Int
    let minimum: Int?
    let maximum: Int?
    let mean: Double?
    let deviation: Double?

    static func calculate(_ samples: [UInt16], from first: Int, to last: Int) -> SampleStatistics {
        guard !samples.isEmpty else { return SampleStatistics(count: 0, errorCount: 0, minimum: nil, maximum: nil, mean: nil, deviation: nil) }
        let start = max(0, min(samples.count - 1, min(first, last)))
        let end = max(0, min(samples.count - 1, max(first, last)))
        var count = 0, errors = 0, lo = 4095, hi = 0
        var mean = 0.0, m2 = 0.0
        for i in start...end {
            let word = samples[i]
            if word & 0x8000 != 0 { errors += 1; continue }
            let v = Int(word & 0x0fff)
            count += 1; lo = min(lo, v); hi = max(hi, v)
            let delta = Double(v) - mean
            mean += delta / Double(count)
            m2 += delta * (Double(v) - mean)
        }
        return SampleStatistics(count: count, errorCount: errors,
                                minimum: count > 0 ? lo : nil, maximum: count > 0 ? hi : nil,
                                mean: count > 0 ? mean : nil,
                                deviation: count > 0 ? sqrt(max(0, m2 / Double(count))) : nil)
    }

    static func nominalMicroseconds(index: Int, sampleRate: String?) -> Double? {
        guard index >= 0, let text = sampleRate, let hz = Double(text), hz.isFinite, hz > 0 else { return nil }
        let value = Double(index) * 1_000_000 / hz
        return value.isFinite ? value : nil
    }
}
