import Foundation

nonisolated struct LiveWaveformOverview: Sendable {
    private static let maximumBins = 2_048
    private(set) var step: UInt64
    private var bins: [UInt64: LiveWaveformBin] = [:]
    private var gaps: [Range<UInt64>] = []
    private(set) var end: UInt64 = 0

    init(samplesPerBin: UInt64) { step = samplesPerBin * 20 }

    mutating func append(_ bin: LiveWaveformBin, first: UInt64, count: UInt64) {
        while (first + count - 1) / step >= UInt64(Self.maximumBins) {
            var compact: [UInt64: LiveWaveformBin] = [:]
            for (index, value) in bins { compact[index / 2, default: .init()].merge(value) }
            bins = compact
            step *= 2
        }
        if first > end {
            if gaps.count == 4_096, let last = gaps.popLast() { gaps.append(last.lowerBound..<first) }
            else { gaps.append(end..<first) }
        }
        bins[first / step, default: .init()].merge(bin)
        end = first + count
    }

    func through(_ frozen: FrozenFlagWaveform) throws -> Self {
        guard end > frozen.end else { return self }
        var result = self
        let boundary = frozen.end / step * step
        result.bins = bins.filter { $0.key < boundary / step }
        result.gaps = gaps.compactMap { gap in
            gap.lowerBound < boundary ? gap.lowerBound..<min(gap.upperBound, boundary) : nil
        }
        result.end = boundary
        if boundary < frozen.end {
            let range = StreamSelection(lower: frozen.time(boundary), upper: frozen.time(frozen.end))
            try frozen.visit(range) { _, index, _, _, words, groups in
                var bin = LiveWaveformBin()
                if let groups { bin.append(groups[...]) }
                else { bin = LiveWaveformBin(words, board: frozen.recordingBoard) }
                result.append(bin, first: index, count: UInt64(bin.count))
            }
        }
        result.end = frozen.end
        return result
    }

    func plot(_ range: StreamSelection, start: Double, rate: Double, columns count: Int = 960) -> StudioPlot {
        var accumulator = LivePlotBins(range: range, columns: count)
        for (index, bin) in bins {
            accumulator.add(bin, lower: start + Double(index * step) / rate,
                            upper: start + Double(min(end, (index + 1) * step)) / rate)
        }
        var visibleGaps = gaps.map {
            StreamSelection(lower: start + Double($0.lowerBound) / rate, upper: start + Double($0.upperBound) / rate)
        }
        if range.upper > start + Double(end) / rate {
            visibleGaps.append(.init(lower: start + Double(end) / rate, upper: range.upper))
        }
        return accumulator.plot(gaps: visibleGaps, rate: rate)
    }
}

nonisolated struct LivePlotBins {
    let range: StreamSelection
    private var columns: [ClosedRange<UInt16>?]
    private var sums: [Double]
    private var weights: [Double]
    private var faults: [Bool]
    private var low: [Bool]
    private var high: [Bool]
    private var totals = LiveWaveformBin()

    init(range: StreamSelection, columns count: Int) {
        self.range = range
        columns = .init(repeating: nil, count: count)
        sums = .init(repeating: 0, count: count)
        weights = sums
        faults = .init(repeating: false, count: count)
        low = faults
        high = faults
    }

    mutating func add(_ bin: LiveWaveformBin, lower: Double, upper: Double) {
        guard upper > range.lower, lower < range.upper else { return }
        let factor = Double(columns.count) / (range.upper - range.lower)
        let first = max(0, min(columns.count - 1, Int(floor((lower - range.lower) * factor + 1e-9))))
        let end = max(first + 1, min(columns.count, Int(ceil((upper - range.lower) * factor - 1e-9))))
        if let values = bin.range {
            for i in first..<end {
                let existing = columns[i] ?? values
                columns[i] = min(existing.lowerBound, values.lowerBound)...max(existing.upperBound, values.upperBound)
                let left = range.lower + Double(i) / factor
                let overlap = max(0, min(upper, left + 1 / factor) - max(lower, left)) / (upper - lower)
                sums[i] += bin.codeSum * overlap
                weights[i] += Double(bin.usable) * overlap
            }
        }
        if bin.errors > 0 || bin.clipped > 0 {
            for i in first..<end {
                faults[i] = faults[i] || bin.errors > 0
                low[i] = low[i] || bin.lowRail > 0
                high[i] = high[i] || bin.highRail > 0
            }
        }
        totals.merge(bin)
    }

    func plot(gaps: [StreamSelection], rate: Double) -> StudioPlot {
        let visible = gaps.filter { $0.upper > range.lower && $0.lower < range.upper }
        let stats = StreamStats(minimum: totals.range.map { Int($0.lowerBound) },
                                maximum: totals.range.map { Int($0.upperBound) }, samples: UInt64(totals.count),
                                adcErrors: UInt64(totals.errors), clipped: UInt64(totals.clipped),
                                nominalSampledSeconds: Double(totals.count) / rate,
                                selectionSeconds: range.upper - range.lower,
                                lowRail: UInt64(totals.lowRail), highRail: UInt64(totals.highRail))
        return .init(columns: columns, breaks: visible.map(\.upper), stats: stats, faults: faults,
                     rails: zip(low, high).map { $0 || $1 }, gaps: visible, indexed: true, lowRails: low, highRails: high,
                     means: zip(sums, weights).map { $1 > 0 ? $0 / $1 : nil })
    }
}

nonisolated struct LiveWaveformCapture: Sendable {
    let raw: FrozenFlagWaveform
    let overview: LiveWaveformOverview?

    func plot(_ selection: StreamSelection, dotPercent: Double?, limit: Int) throws -> StudioPlot {
        if selection.lower >= raw.bounds.lower - 1e-9 && selection.upper <= raw.bounds.upper + 1e-9 {
            return try raw.plot(selection, dotPercent: dotPercent, dotLimit: limit)
        }
        guard let overview else { return try raw.plot(selection, dotPercent: nil) }
        return try overview.through(raw).plot(selection, start: raw.timelineStart, rate: raw.rate)
    }
}
