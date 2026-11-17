import CryptoKit
import Foundation

nonisolated struct WaveformSample: Sendable {
    let segment: UUID?
    let index: UInt64
    let time: Double
    let word: UInt16
    var group: ADCAveraging.Group? = nil
    var board: AcquisitionBoard = .picoW
    var sourceIndices: Range<UInt64> {
        if let group { return group.first..<(group.first + UInt64(group.count)) }
        return index..<(index + 1)
    }
    var value: Double { group?.mean ?? Double(code) }
    var error: Bool { group.map { $0.adcErrors > 0 } ?? invalid }
    var low: Bool { group.map { $0.lowRail > 0 } ?? (!invalid && code == 0) }
    var high: Bool { group.map { $0.highRail > 0 } ?? (!invalid && code == board.maxCode) }
    var readingLabel: String {
        if let group {
            if let mean = group.mean { return mean.formatted(.number.precision(.fractionLength(0...6))) + " ADC codes" }
            let flags = [(group.adcErrors, "ADC errors"), (group.lowRail, "low rail"), (group.highRail, "high rail")]
            return flags.filter { $0.0 != 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }
        return invalid ? "ADC error" : "\(code.formatted()) ADC codes"
    }
    var indexLabel: String {
        group == nil ? "Sample \(index.formatted())" :
            "Reading \(index.formatted()) · conversions \(sourceIndices.lowerBound.formatted()) to \((sourceIndices.upperBound - 1).formatted())"
    }
    var code: UInt16 { board.sampleCode(word) }
    var invalid: Bool { word & 0x8000 != 0 }
    var clipped: Bool { low || high }
}

nonisolated struct WaveformOverview: Codable, Sendable {
    static let fileName = "waveform-overview-v1.json"
    static let tileSeconds = 0.1
    static let maxFileBytes = 24 * 1024 * 1024
    static let maxGaps = 65_536

    struct Tile: Codable, Sendable {
        let bucket: Int
        var low: UInt16 = .max
        var high: UInt16 = 0
        var errors: Int = 0
        var clipped: Int = 0
        var lowRail: Int? = nil
        var highRail: Int? = nil
        var count: Int = 0
        var codeSum: UInt64? = nil
        var usableCount: Int? = nil
        var preciseSum: Double? = nil
        var range: ClosedRange<UInt16>? { low <= high ? low...high : nil }
    }

    struct Minute: Codable, Identifiable, Sendable {
        let id: Int
        let seconds: Double
        let sampled: Double
        let gaps: Int
        let samples: UInt64
        let errors: UInt64
        let clipped: UInt64
        let baseline: Double?
        let noise: Double?
        var unknown: Double { max(0, seconds - sampled) }
    }

    let version: Int
    let run: UUID
    let sourceHash: String
    let sourceChunks: [StreamChunkSummary]
    let duration: Double
    let minutes: [Minute]
    let tiles: [Tile]
    let gaps: [StreamSelection]
    let unknownBoundaries: [Double]
    let hasUnboundedUnknownTime: Bool

    private static func digest(_ reader: StreamRangeReader, _ chunks: [StreamChunkSummary]) throws -> String {
        var digest = SHA256()
        digest.update(data: try StreamFiles.encoder.encode([reader.run.settings.nominalRate, reader.run.settings.channel]))
        digest.update(data: try StreamFiles.encoder.encode(reader.run.segments))
        digest.update(data: try StreamFiles.encoder.encode(chunks))
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ reader: StreamRangeReader) throws -> Self? {
        let url = try reader.store.runDirectory(reader.run.id).appendingPathComponent(fileName)
        guard try StreamFiles.isPresent(url) else { return nil }
        let bytes = try StreamFiles.read(url, limit: maxFileBytes)
        let value = try StreamFiles.decoder.decode(Self.self, from: bytes)
        let chunks = try reader.prepared().index ?? []
        let lastBucket = Int((StreamWire.maxDuration + StreamWire.stopReserveSeconds) / tileSeconds)
        guard (1...2).contains(value.version), value.run == reader.run.id, value.sourceChunks == chunks,
              value.sourceHash == (try digest(reader, chunks)),
              value.duration.isFinite, value.duration > 0,
              value.duration <= StreamWire.maxDuration + StreamWire.stopReserveSeconds,
              value.tiles.count <= lastBucket + 1, value.gaps.count <= maxGaps,
              value.minutes.count <= 121, value.unknownBoundaries.count <= reader.run.segments.count,
              value.minutes.enumerated().allSatisfy({ index, minute in
                  index == minute.id && (0...60).contains(minute.seconds) && minute.seconds > 0
                    && (0...61).contains(minute.sampled) && minute.errors <= minute.samples && minute.clipped <= minute.samples
              }),
              zip(value.tiles, value.tiles.dropFirst()).allSatisfy({ $0.bucket < $1.bucket }),
              value.tiles.allSatisfy({ (0...lastBucket).contains($0.bucket) && (1...60_000).contains($0.count)
                  && (0...$0.count).contains($0.errors) && (0...$0.count).contains($0.clipped)
                  && ($0.usableCount.map { (0...60_000).contains($0) } ?? true)
                  && ($0.preciseSum.map { (0...Double(reader.run.settings.board.maxCode) * 60_000).contains($0) } ?? true)
                  && ($0.codeSum.map { $0 <= UInt64(reader.run.settings.board.maxCode) * 60_000 } ?? true)
                  && ($0.lowRail.map { (0...60_000).contains($0) } ?? true)
                  && ($0.highRail.map { (0...60_000).contains($0) } ?? true)
                  && (($0.lowRail == nil && $0.highRail == nil)
                      || ($0.lowRail != nil && $0.highRail != nil && ($0.lowRail ?? 0) + ($0.highRail ?? 0) >= $0.clipped)) }),
              value.gaps.allSatisfy(\.valid) else { return nil }
        return value
    }

    var hasAverages: Bool { tiles.allSatisfy { $0.codeSum != nil } }

    var hasRailBreakdown: Bool { tiles.allSatisfy { $0.lowRail != nil && $0.highRail != nil } }

    static func build(_ input: StreamRangeReader, publish: Bool = true, progress: (Double) -> Void = { _ in }) throws -> Self? {
        let reader = try input.prepared()
        let chunks = reader.index ?? []
        guard !chunks.isEmpty else { return nil }
        let duration = try reader.duration()
        guard duration > 0, duration <= StreamWire.maxDuration + StreamWire.stopReserveSeconds else {
            throw StreamFailure.storage("The overview exceeds the supported recording duration.")
        }
        let expected = chunks.reduce(0) { $0 + UInt64($1.readingCount) }
        var accumulator = Accumulator(duration: duration, board: reader.run.settings.board)
        var lastTime = 0.0
        var previous: UUID?
        var nextProgress = 0.025
        try reader.visit(.init(lower: 0, upper: duration)) { part in
            let first = part.firstSeconds
            if previous != part.segment.id, previous != nil { accumulator.boundaries.append(first) }
            try accumulator.addGap(from: lastTime, to: first)
            accumulator.append(part)
            lastTime = first + Double(part.reference.count) / part.configuredRate
            previous = part.segment.id
            let fraction = Double(accumulator.total) / Double(expected)
            if fraction >= nextProgress {
                progress(min(fraction, 1))
                nextProgress = fraction + 0.025
            }
        }
        guard accumulator.total == expected else {
            throw StreamFailure.storage("The quality summary could not account for every saved sample.")
        }
        try accumulator.addGap(from: lastTime, to: duration)
        while Double(accumulator.minute) * 60 < duration { accumulator.finishMinute() }
        let result = Self(version: 2, run: reader.run.id, sourceHash: try digest(reader, chunks),
                          sourceChunks: chunks, duration: duration, minutes: accumulator.minutes,
                          tiles: accumulator.tiles, gaps: accumulator.gaps,
                          unknownBoundaries: accumulator.boundaries, hasUnboundedUnknownTime: reader.run.hasUnknownCoverage)
        guard publish else { return result }
        let bytes = try StreamFiles.encoder.encode(result)
        guard bytes.count <= maxFileBytes else { throw StreamFailure.storage("The overview exceeds its file size limit.") }
        try Task.checkCancellation()
        try reader.store.verify()
        let folder = try reader.store.runDirectory(reader.run.id)
        let target = folder.appendingPathComponent(fileName)
        let lock = try StreamRunLock(folder)
        defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()
        let persisted = try reader.store.openRun(reader.run.id)
        let snapshot = try StreamRangeReader(store: reader.store, run: persisted).prepared()
        guard try digest(snapshot, snapshot.index ?? []) == result.sourceHash else {
            throw StreamFailure.storage("The run changed while the summary was being prepared. Reopen it and retry.")
        }
        try StreamFiles.publish(bytes, at: target, replace: try StreamFiles.isPresent(target))
        return result
    }

    private struct Accumulator {
        let duration: Double
        let board: AcquisitionBoard
        var total: UInt64 = 0
        var tiles: [Tile] = []
        var gaps: [StreamSelection] = []
        var boundaries: [Double] = []
        var minutes: [Minute] = []
        var minute = 0
        lazy var histogram = [UInt64](repeating: 0, count: Int(board.maxCode) + 1)
        var count: UInt64 = 0
        var errors: UInt64 = 0
        var clipped: UInt64 = 0
        var sampled = 0.0
        var valid: UInt64 = 0

        mutating func addGap(from: Double, to: Double) throws {
            guard to - from > 0.0000001 else { return }
            guard gaps.count < WaveformOverview.maxGaps else {
                throw StreamFailure.storage("The recording has too many gaps to build a compact overview.")
            }
            gaps.append(.init(lower: from, upper: to))
        }

        mutating func append(_ part: StreamRangeData) {
            let rate = part.configuredRate
            let start = part.firstSeconds
            part.words.withUnsafeBytes { bytes in
                var offset = 0
                while offset < part.reference.count {
                    let time = start + Double(offset) / rate
                    let bucket = Int(floor(time / WaveformOverview.tileSeconds + 0.0000001))
                    let nextMinute = bucket / 600
                    while minute < nextMinute { finishMinute() }
                    let upper = Double(bucket + 1) * WaveformOverview.tileSeconds
                    let limit = min(part.reference.count, max(offset + 1, Int(ceil((upper - start) * rate - 0.000001))))
                    var tile = tiles.last?.bucket == bucket ? tiles.removeLast() : Tile(bucket: bucket)
                    var low = tile.low, high = tile.high, bad = 0, lowRail = 0, highRail = 0
                    var codeSum: UInt64 = 0
                    var flagged = 0
                    var usableGroups = 0
                    var sumOfMeans = 0.0
                    for i in offset..<limit {
                        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        if let group = part.groups?[i] {
                            if group.adcErrors > 0 { bad += 1 }
                            if group.lowRail > 0 { lowRail += 1 }
                            if group.highRail > 0 { highRail += 1 }
                            if group.lowRail + group.highRail > 0 { flagged += 1 }
                            guard let mean = group.mean else { continue }
                            usableGroups += 1
                            sumOfMeans += mean
                        } else if word & 0x8000 != 0 { bad += 1; continue }
                        valid += 1
                        let code = part.segment.board.sampleCode(word)
                        histogram[Int(code)] += 1
                        codeSum += UInt64(code)
                        low = min(low, code)
                        high = max(high, code)
                        if part.groups == nil && code == 0 { lowRail += 1 }
                        if part.groups == nil && code == part.segment.board.maxCode { highRail += 1 }
                    }
                    let size = limit - offset
                    tile.count += size
                    tile.codeSum = (tile.codeSum ?? 0) + codeSum
                    if part.groups != nil {
                        tile.usableCount = (tile.usableCount ?? 0) + usableGroups
                        tile.preciseSum = (tile.preciseSum ?? 0) + sumOfMeans
                    }
                    tile.errors += bad
                    let railGroups = part.groups == nil ? lowRail + highRail : flagged
                    tile.clipped += railGroups
                    tile.lowRail = (tile.lowRail ?? 0) + lowRail
                    tile.highRail = (tile.highRail ?? 0) + highRail
                    tile.low = low
                    tile.high = high
                    tiles.append(tile)
                    count += UInt64(size)
                    errors += UInt64(bad)
                    clipped += UInt64(railGroups)
                    sampled += Double(size) / rate
                    offset = limit
                }
            }
            total += UInt64(part.reference.count)
        }

        mutating func finishMinute() {
            let start = Double(minute) * 60
            let end = min(start + 60, duration)
            guard end > start else { minute += 1; return }
            let baseline = StreamStudio.weightedMedian(histogram, total: valid)
            var noise: Double?
            if let baseline {
                var deviations = [UInt64](repeating: 0, count: 2 * histogram.count - 1)
                for (code, n) in histogram.enumerated() where n != 0 {
                    deviations[Int(abs(Double(code) - baseline) * 2)] += n
                }
                noise = StreamStudio.weightedMedian(deviations, total: valid).map { $0 * 0.7413 }
            }
            let gapCount = gaps.reversed().prefix { $0.upper > start }.filter { $0.lower < end }.count
            minutes.append(.init(id: minute, seconds: end - start, sampled: sampled, gaps: gapCount,
                                 samples: count, errors: errors, clipped: clipped, baseline: baseline, noise: noise))
            minute += 1
            histogram = [UInt64](repeating: 0, count: Int(board.maxCode) + 1)
            count = 0; errors = 0; clipped = 0; sampled = 0; valid = 0
        }
    }

    func plot(_ selection: StreamSelection, columns count: Int = 960) -> StudioPlot {
        var columns = [ClosedRange<UInt16>?](repeating: nil, count: count)
        var faults = [Bool](repeating: false, count: count)
        var sums = [Double](repeating: 0, count: count)
        var weights = sums
        var rails = faults, lowRails = faults, highRails = faults
        var samples: UInt64 = 0, errors: UInt64 = 0, clipped: UInt64 = 0
        var lowCount: UInt64? = 0, highCount: UInt64? = 0
        let width = selection.upper - selection.lower
        for tile in tiles {
            let start = Double(tile.bucket) * Self.tileSeconds
            let end = start + Self.tileSeconds
            guard end > selection.lower, start < selection.upper else { continue }
            let first = max(0, min(count - 1, Int(floor((start - selection.lower) / width * Double(count) + 1e-9))))
            let endColumn = max(first + 1, min(count, Int(ceil((end - selection.lower) / width * Double(count) - 1e-9))))
            if let range = tile.range {
                for x in first..<endColumn {
                    let existing = columns[x] ?? range
                    columns[x] = min(existing.lowerBound, range.lowerBound)...max(existing.upperBound, range.upperBound)
                    let validCount = tile.usableCount ?? tile.count - tile.errors
                    if let sum = tile.preciseSum ?? tile.codeSum.map(Double.init), validCount > 0 {
                        let binWidth = width / Double(count)
                        let left = selection.lower + Double(x) * binWidth
                        let overlap = max(0, min(end, left + binWidth) - max(start, left)) / Self.tileSeconds
                        sums[x] += sum * overlap
                        weights[x] += Double(validCount) * overlap
                    }
                }
            }
            rails[first] = rails[first] || tile.clipped > 0
            faults[first] = faults[first] || tile.errors > 0
            samples += UInt64(tile.count)
            errors += UInt64(tile.errors)
            clipped += UInt64(tile.clipped)
            lowRails[first] = lowRails[first] || (tile.lowRail.map { $0 > 0 } ?? (tile.low == 0))
            highRails[first] = highRails[first] || (tile.highRail.map { $0 > 0 } ?? (tile.high == 4095))
            let low = tile.lowRail ?? (tile.high == 4095 && tile.low == 0 ? nil : tile.low == 0 ? tile.clipped : 0)
            let high = tile.highRail ?? (tile.high == 4095 && tile.low == 0 ? nil : tile.high == 4095 ? tile.clipped : 0)
            lowCount = lowCount.flatMap { count in low.map { count + UInt64($0) } }
            highCount = highCount.flatMap { count in high.map { count + UInt64($0) } }
        }
        let nearby = minutes.filter { Double($0.id) * 60 < selection.upper && Double($0.id + 1) * 60 > selection.lower }
        let values = columns.compactMap { $0 }
        let visibleGaps = gaps.filter { $0.upper > selection.lower && $0.lower < selection.upper }
        let missing = visibleGaps.reduce(0.0) { sum, gap in
            sum + max(0, min(selection.upper, gap.upper) - max(selection.lower, gap.lower))
        }
        let stats = StreamStats(baseline: samples == 0 ? nil : ProfileAnalyzer.median(nearby.compactMap(\.baseline)),
                                robustNoise: samples == 0 ? nil : ProfileAnalyzer.median(nearby.compactMap(\.noise)),
                                minimum: values.map { Int($0.lowerBound) }.min(), maximum: values.map { Int($0.upperBound) }.max(),
                                samples: samples, adcErrors: errors, clipped: clipped,
                                nominalSampledSeconds: max(0, width - missing), selectionSeconds: width,
                                lowRail: lowCount, highRail: highCount)
        return .init(columns: columns, breaks: unknownBoundaries + visibleGaps.map(\.upper), stats: stats,
                     faults: faults, rails: rails, gaps: visibleGaps, indexed: true,
                     lowRails: lowRails, highRails: highRails,
                     means: zip(sums, weights).map { $1 > 0 ? $0 / $1 : nil })
    }
}
