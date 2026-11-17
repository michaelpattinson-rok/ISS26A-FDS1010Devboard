import Foundation

nonisolated struct WaveformDots: Sendable {
    static let liveLimit = 5_000_000
    static let savedLimit = 10_000_000
    static let canvasLimit = 12_000
    static let rawReadLimit = 15_000_000

    let id = UUID()
    // X is relative to the viewport. Y is the original 12-bit ADC code.
    let values: [SIMD2<Float>]
    var averaged = false

    static func averages(_ means: [Double?], percent: Double) -> Self {
        let selection = WaveformDotSelection(percent: percent, limit: means.count, possible: means.count)
        var values: [SIMD2<Float>] = means.enumerated().compactMap { i, mean in
            guard let mean, selection.includes(UInt64(i)) else { return nil }
            return .init((Float(i) + 0.5) / Float(means.count), Float(mean))
        }
        if values.isEmpty, let first = means.firstIndex(where: { $0 != nil }), let mean = means[first] {
            values.append(.init((Float(first) + 0.5) / Float(means.count), Float(mean)))
        }
        return .init(values: values, averaged: true)
    }
}

nonisolated struct WaveformDotSelection: Sendable {
    private static let scale: UInt64 = 1_000_000
    let limit: Int
    private let threshold: UInt64
    let capacity: Int

    init(percent: Double, limit: Int, possible: Int) {
        let fraction = Double(min(100, max(0.01, percent))) / 100
        let capped = min(fraction, Double(limit) / Double(max(1, possible)))
        threshold = UInt64((capped * Double(Self.scale)).rounded(.down))
        self.limit = limit
        capacity = min(limit, max(1, Int(Double(possible) * capped) + 1))
    }

    func includes(_ index: UInt64) -> Bool {
        guard threshold > 0 else { return false }
        if threshold == Self.scale { return true }
        // Partition the original indices into blocks of approximately 1 / density.
        // Select a stable offset in each block so periodic input does not lock to one phase.
        let block = ((index + 1) * threshold - 1) / Self.scale
        let lower = block * Self.scale / threshold
        let upper = (block + 1) * Self.scale / threshold
        var mixed = block &+ 0x9e3779b97f4a7c15
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58476d1ce4e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d049bb133111eb
        mixed ^= mixed >> 31
        return index == lower + mixed % (upper - lower)
    }
}
