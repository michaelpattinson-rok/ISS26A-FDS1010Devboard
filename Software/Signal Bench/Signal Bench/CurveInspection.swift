import Foundation

nonisolated struct CurveInspection: Sendable {
    nonisolated enum Trace: String, CaseIterable, Identifiable, Sendable {
        case curve = "Curve", overlay = "Overlay", error = "Error"
        var id: Self { self }
    }

    struct Bin: Sendable {
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var count: UInt64 = 0
        var sum = 0.0
        var clipped = false
        var invalid = false
        var lowRail = false
        var highRail = false
        mutating func add(_ value: Double) {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            count += 1
        }
        mutating func add(_ low: Double, _ high: Double, _ mean: Double, count: UInt64) {
            minimum = min(minimum, low)
            maximum = max(maximum, high)
            sum += mean * Double(count)
            self.count += count
        }
        var range: ClosedRange<Double>? { count > 0 ? minimum...maximum : nil }
    }

    struct Point: Sendable {
        var segment: UUID
        var index: UInt64
        var time: Double
        var reading: CurveReading
        var original: Double?
        var location: StreamMatchLocation { .init(segment: segment, sample: index) }
        var id: String { location.id }
    }

    var selection: StreamSelection
    var columns = [Bin](repeating: .init(), count: 800)
    var original = [Bin](repeating: .init(), count: 800)
    var points: [Point] = []
    var breaks: [Double] = []
    var verifiedDetail = false
    var count: UInt64 = 0
    var knownGap: Double?
    var valid: UInt64 = 0
    var modeled: UInt64 = 0
    var excluded: UInt64 = 0
    var mean: Double?
    var rmsVariation: Double?
    var selectedError: CurveErrorStats?
    var spectra: [Spectrum] = []

    struct Spectrum: Sendable {
        var rate: Double
        var windows: Int
        var points: [AnalysisPoint]
    }

    static func load(_ reader: CurveReader, source: StreamRangeReader?, selection: StreamSelection,
                     trace: Trace = .curve, diagnostics: Bool = false,
                     exclusions: [UUID: [Range<UInt64>]] = [:]) throws -> Self {
        var result = Self(selection: selection)
        let width = selection.upper - selection.lower
        let samples = width * reader.run.settings.recordedRate
        if samples > 2_000_000, trace != .curve || diagnostics {
            throw StreamFailure.storage("Choose a range of up to two million readings for this tool.")
        }
        func column(_ time: Double) -> Int {
            min(799, max(0, Int((time - selection.lower) * 800 / width)))
        }
        let segments = Dictionary(uniqueKeysWithValues: reader.run.segments.map { ($0.id, $0) })
        if samples > 2_000_000 {
            for item in reader.blocks {
                guard let segment = segments[item.source.segment] else { continue }
                let hz = segment.configuredRate(reader.run.settings.nominalRate)
                let first = segment.timelineStart + Double(item.first) / hz
                let last = segment.timelineStart + Double(item.end - 1) / hz
                guard first < selection.upper, last >= selection.lower else { continue }
                if let lo = item.minimum, let hi = item.maximum, let mean = item.mean {
                    for bin in column(first)...column(last) {
                        result.columns[bin].add(lo, hi, mean, count: item.quality.count)
                    }
                }
                result.columns[column(first)].invalid = item.quality.invalid > 0
                result.columns[column(first)].clipped = item.quality.clipped > 0
                result.columns[column(first)].lowRail = item.quality.low > 0
                result.columns[column(first)].highRail = item.quality.high > 0
            }
            return result
        }
        result.verifiedDetail = true
        let raw = try source?.prepared()
        var sourceBlock: StreamChunkSummary?
        var input = Data()
        var sourceFrames: [StreamSlice] = []
        var cursor = 0
        let owner = raw == nil ? [:] : Dictionary(grouping: reader.blocks, by: { $0.source.segment })
        let rawByID = Dictionary(uniqueKeysWithValues: (raw?.index ?? []).map { ($0.id, $0) })
        var blockIndex = 0
        var lastSegment: UUID?
        var next: UInt64?
        var noise = 0.0
        var total = 0.0
        var spectrumBuffer: [Double] = []
        var maskIndex = 0
        var masks: [Range<UInt64>] = []
        var averages: [Double: ADCSpectrumAverage] = [:]
        var sampled = 0.0
        var residual = CurveAccumulator(tolerance: reader.manifest.settings.tolerance)
        try reader.visit(selection) { segment, index, reading, _ in
            let hz = segment.configuredRate(reader.run.settings.nominalRate)
            let time = segment.timelineStart + Double(index) / hz
            if lastSegment != segment.id || next != index {
                result.breaks.append(time)
                spectrumBuffer.removeAll(keepingCapacity: true)
                if lastSegment != segment.id { blockIndex = 0 }
            }
            if lastSegment != segment.id {
                maskIndex = 0
                masks = exclusions[segment.id] ?? []
            }
            lastSegment = segment.id
            next = index + 1
            var original: Double?
            if trace != .curve, let raw {
                let blocks = owner[segment.id] ?? []
                while blockIndex < blocks.count, blocks[blockIndex].end <= index { blockIndex += 1 }
                guard blockIndex < blocks.count, let summary = rawByID[blocks[blockIndex].source.id],
                      summary == blocks[blockIndex].source else { throw ReviewWorkerError.stale }
                if sourceBlock != summary {
                    input = try raw.store.data(summary, run: raw.run)
                    sourceFrames = try raw.store.chunk(summary, run: raw.run).slices
                    sourceBlock = summary
                    cursor = 0
                }
                while cursor < sourceFrames.count, sourceFrames[cursor].first + UInt64(sourceFrames[cursor].count) <= index { cursor += 1 }
                guard cursor < sourceFrames.count, sourceFrames[cursor].first <= index else { throw CurveCodec.fault }
                let slice = sourceFrames[cursor]
                let offset = slice.byteOffset + Int(index - slice.first) * PicoAverage.stride(summary.picoAveraging)
                original = try input.withUnsafeBytes { try CurveCodec.reading($0, at: offset, factor: summary.picoAveraging, board: reader.run.settings.board).value }
            }
            let bin = column(time)
            sampled += 1 / hz
            result.count += 1
            while maskIndex < masks.count, masks[maskIndex].upperBound <= index { maskIndex += 1 }
            if diagnostics, maskIndex < masks.count, masks[maskIndex].contains(index) {
                result.excluded += 1
                spectrumBuffer.removeAll(keepingCapacity: true)
                return
            }
            if reading.adcErrors > 0 { result.columns[bin].invalid = true }
            if reading.low + reading.high > 0 { result.columns[bin].clipped = true }
            if reading.low > 0 { result.columns[bin].lowRail = true }
            if reading.high > 0 { result.columns[bin].highRail = true }
            if let value = reading.value {
                result.valid += 1
                if !reading.exact { result.modeled += 1 }
                let delta = value - total
                total += delta / Double(result.valid)
                noise += delta * (value - total)
                if trace == .error {
                    if let original { result.columns[bin].add(value - original) }
                } else {
                    result.columns[bin].add(value)
                    if let original { result.original[bin].add(original) }
                }
                if let original {
                    residual.add(reading, source: .init(value: original, exact: true, adcErrors: 0, low: 0, high: 0),
                                 at: .init(segment: segment.id, sample: index))
                }
                if diagnostics {
                    spectrumBuffer.append(value)
                    if spectrumBuffer.count == 1024 {
                        if averages[hz] == nil { averages[hz] = ADCSpectrumAverage(size: 1024, rate: hz) }
                        averages[hz]?.append(spectrumBuffer)
                        spectrumBuffer.removeFirst(512)
                    }
                }
            } else {
                spectrumBuffer.removeAll(keepingCapacity: true)
                if let next { result.breaks.append(segment.timelineStart + Double(next) / hz) }
            }
            if samples <= 1800 { result.points.append(.init(segment: segment.id, index: index, time: time, reading: reading, original: original)) }
        }
        result.knownGap = max(0, width - sampled)
        if residual.stats.count > 0 { result.selectedError = residual.result() }
        if result.valid > 0 {
            result.mean = total
            result.rmsVariation = sqrt(max(0, noise / Double(result.valid)))
        }
        result.spectra = averages.keys.sorted().compactMap { rate in
            guard let value = averages[rate] else { return nil }
            return .init(rate: rate, windows: value.windows, points: value.points)
        }
        return result
    }

    static func sample(_ reader: CurveReader, source: StreamRangeReader?, at time: Double) throws -> Point? {
        guard let segment = reader.run.segments.last(where: { $0.timelineStart <= time }) else { return nil }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let position = max(0, (time - segment.timelineStart) * rate)
        guard position <= Double(StreamWire.maxSampleBoundary) else { return nil }
        let index = UInt64((position + max(1e-7, 4 * position.ulp)).rounded(.down))
        let start = segment.timelineStart + Double(index) / rate
        let range = StreamSelection(lower: start, upper: start + 1 / rate)
        var point: Point?
        try reader.visit(range) { segment, index, reading, _ in
            point = .init(segment: segment.id, index: index, time: segment.timelineStart + Double(index) / rate, reading: reading)
        }
        if let found = point, let source {
            let original = try source.sample(at: found.location)
            if let original, !original.invalid, !original.clipped { point?.original = original.value }
        }
        return point
    }
}
