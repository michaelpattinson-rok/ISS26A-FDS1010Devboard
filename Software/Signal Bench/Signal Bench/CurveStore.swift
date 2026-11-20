import Darwin
import Foundation

nonisolated struct CurveErrorStats: Codable, Sendable {
    var exact: UInt64 = 0
    var modeled: UInt64 = 0
    var invalid: UInt64 = 0
    var clipped: UInt64 = 0
    var sourceErrors: UInt64 = 0
    var low: UInt64 = 0
    var high: UInt64 = 0
    var sum = 0.0
    var squares = 0.0
    var maximum = 0.0
    var worst: StreamMatchLocation?
    var p95: Double?
    var p99: Double?
    var count: UInt64 { exact + modeled }
    var rms: Double? { count > 0 ? sqrt(squares / Double(count)) : nil }
    var bias: Double? { count > 0 ? sum / Double(count) : nil }
}

nonisolated struct CurveAccumulator {
    var stats = CurveErrorStats()
    private var histogram: [UInt64]

    init(tolerance: Double) {
        histogram = [UInt64](repeating: 0, count: Int(ceil(tolerance * 256)) + 1)
    }

    mutating func add(_ reading: CurveReading, source: CurveReading, at location: @autoclosure () -> StreamMatchLocation) {
        stats.sourceErrors += UInt64(source.adcErrors)
        stats.low += UInt64(source.low)
        stats.high += UInt64(source.high)
        if source.adcErrors > 0 { stats.invalid += 1 }
        if source.low + source.high > 0 { stats.clipped += 1 }
        guard let value = source.value, let output = reading.value else { return }
        if reading.exact { stats.exact += 1 } else { stats.modeled += 1 }
        let error = output - value
        let absolute = abs(error)
        stats.sum += error
        stats.squares += error * error
        if absolute > stats.maximum || stats.worst == nil {
            stats.maximum = absolute
            stats.worst = location()
        }
        histogram[min(histogram.count - 1, Int(ceil(absolute * 256)))] += 1
    }

    func result() -> CurveErrorStats {
        var result = stats
        guard stats.count > 0 else { return result }
        let p95 = (stats.count * 95 + 99) / 100
        let p99 = (stats.count * 99 + 99) / 100
        var total: UInt64 = 0
        for (bin, count) in histogram.enumerated() where count > 0 {
            total += count
            if total >= p95 && result.p95 == nil { result.p95 = Double(bin) / 256 }
            if total >= p99 { result.p99 = Double(bin) / 256; break }
        }
        return result
    }
}

nonisolated struct CurveRequest: Codable, Sendable {
    var tolerance = 1.0
    var preserve: [ReviewRange] = []
    var valid: Bool {
        (0.125...64).contains(tolerance) && preserve.count <= 256
            && preserve.allSatisfy { $0.first < $0.end && $0.end <= StreamWire.maxSampleBoundary }
    }
}

nonisolated struct CurveSpan: Codable, Sendable, Equatable {
    var first: UInt64
    var count: Int
    var byteOffset: Int
    var anchor: StreamFrameAnchor
    var end: UInt64 { first + UInt64(count) }
}

nonisolated struct CurveBlock: Codable, Sendable {
    var source: StreamChunkSummary
    var first: UInt64
    var end: UInt64
    var count: Int
    var expanded: Int
    var stored: Int
    var modeled: Bool
    var sha256: String
    var frameSHA256: String
    var frameBytes: Int
    var frameExpanded: Int
    var internalGaps: [StreamSelection]
    var minimum: Double?
    var maximum: Double?
    var mean: Double?
    var quality: CurveErrorStats
}

nonisolated struct CurveManifest: Codable, Sendable, Identifiable {
    var type = "signalbench.waveform-curve"
    var version = 1
    var algorithm = CurveCodec.version
    var id: UUID
    var name: String
    var project: UUID
    var source: UUID
    var sourceFingerprint: String
    var selection: StreamSelection
    var wholeRun: Bool
    var settings: CurveRequest
    var count: Int
    var indexHash: String
    var storedBytes: Int64
    var sourceBytes: Int64
    var sourceIndexBytes: Int64
    var losslessBytes: Int64
    var missingSeconds: Double
    var capturedSeconds: Double
    var missingReadings: UInt64
    var unknownBoundaries: [Double]
    var stats: CurveErrorStats
    var minutes: [Minute]
    var created = Date()

    struct Minute: Codable, Sendable, Identifiable {
        var id: Int
        var stats: CurveErrorStats
    }
}

nonisolated struct CurveReader: Sendable {
    let folder: URL
    let manifest: CurveManifest
    let run: StreamRun
    let blocks: [CurveBlock]

    init(folder: URL, run: StreamRun) throws {
        try StreamFiles.directory(folder)
        let m = try StreamFiles.read(CurveManifest.self, folder.appendingPathComponent("curve.json"))
        guard m.version == 1, m.algorithm == CurveCodec.version, m.type == "signalbench.waveform-curve",
              m.project == run.project, m.source == (run.curveSource ?? run.id), m.settings.valid,
              m.selection.valid, (1...16_000).contains(m.count), ProfileDigest.valid(m.sourceFingerprint),
              (try? SessionStore.projectName(m.name)) == m.name else { throw CurveCodec.fault }
        let index = try StreamFiles.read(folder.appendingPathComponent("index.json"), limit: 32 * 1024 * 1024)
        guard StreamFiles.sha(index) == m.indexHash else { throw CurveCodec.fault }
        let loaded = try StreamFiles.decoder.decode([CurveBlock].self, from: index)
        let segments = Dictionary(uniqueKeysWithValues: run.segments.enumerated().map { ($1.id, $0) })
        var previous: (position: Int, end: UInt64)?
        var previousTime = -Double.infinity
        var total: UInt64 = 0
        guard loaded.count == m.count, Set(loaded.map { $0.source.id }).count == m.count else { throw CurveCodec.fault }
        for item in loaded {
            guard let position = segments[item.source.segment], item.source.valid,
                  item.source.picoAveraging == run.settings.picoAveraging,
                  (1...item.source.readingCount).contains(item.count), item.first >= item.source.first,
                  item.end <= item.source.end, item.end > item.first, UInt64(item.count) <= item.end - item.first,
                  (1...CurveCodec.blockLimit).contains(item.expanded), (2...(item.expanded + 1)).contains(item.stored),
                  (1...1_048_575).contains(item.frameExpanded), (2...(item.frameExpanded + 1)).contains(item.frameBytes),
                  item.internalGaps.count <= 255, item.internalGaps.allSatisfy(\.valid),
                  ProfileDigest.valid(item.sha256), ProfileDigest.valid(item.frameSHA256),
                  item.quality.count <= UInt64(item.count),
                  previous.map({ position > $0.position || (position == $0.position && item.first >= $0.end) }) ?? true else {
                throw CurveCodec.fault
            }
            previous = (position, item.end)
            let segment = run.segments[position]
            let rate = segment.configuredRate(run.settings.nominalRate)
            let time = segment.timelineStart + Double(item.first) / rate
            guard time >= previousTime - 1e-8 else { throw CurveCodec.fault }
            previousTime = segment.timelineStart + Double(item.end) / rate
            total += item.quality.count
        }
        guard total == m.stats.count, m.minutes.count <= 1440,
              (0...m.settings.tolerance).contains(m.stats.maximum),
              m.capturedSeconds.isFinite, m.capturedSeconds >= 0,
              m.missingSeconds.isFinite, m.missingSeconds >= 0,
              m.unknownBoundaries.allSatisfy({ $0.isFinite && m.selection.lower <= $0 && $0 <= m.selection.upper }) else { throw CurveCodec.fault }
        self.folder = folder
        manifest = m
        self.run = run
        blocks = loaded
    }

    func frameData(_ item: CurveBlock) throws -> Data {
        let url = folder.appendingPathComponent(item.source.id.uuidString + ".frames")
        let data = try StreamFiles.read(url, limit: item.frameBytes)
        guard data.count == item.frameBytes, StreamFiles.sha(data) == item.frameSHA256 else { throw CurveCodec.fault }
        return data
    }

    func data(_ item: CurveBlock) throws -> Data {
        let data = try storedBlock(item)
        return try CurveCodec.decode(data, length: item.expanded)
    }

    func storedBlock(_ item: CurveBlock) throws -> Data {
        let url = folder.appendingPathComponent(item.source.id.uuidString + ".curve")
        let data = try StreamFiles.read(url, limit: item.stored)
        guard data.count == item.stored, StreamFiles.sha(data) == item.sha256 else { throw CurveCodec.fault }
        return data
    }

    func layout(_ item: CurveBlock) throws -> [CurveSpan] {
        let spans = try StreamFiles.decoder.decode([CurveSpan].self,
            from: CurveCodec.decode(frameData(item), length: item.frameExpanded))
        let stride = PicoAverage.stride(item.source.picoAveraging, board: item.source.board)
        var end = item.first
        var count = 0
        guard (1...256).contains(spans.count), spans.first?.first == item.first else { throw CurveCodec.fault }
        for span in spans {
            guard (1...StreamWire.maxSamples).contains(span.count), span.first >= end,
                  span.first <= item.end, UInt64(span.count) <= item.end - span.first, span.byteOffset == count * stride,
                  (1...StreamWire.maxSamples).contains(span.anchor.frameSampleCount),
                  span.anchor.frameFirstIndex <= span.first, span.anchor.frameFirstIndex <= StreamWire.maxSampleBoundary,
                  span.end <= span.anchor.frameFirstIndex + UInt64(span.anchor.frameSampleCount),
                  (1...StreamWire.maxDeviceTimeUS).contains(span.anchor.deviceFrameEndUS) else { throw CurveCodec.fault }
            end = span.end
            count += span.count
        }
        guard end == item.end, count == item.count else { throw CurveCodec.fault }
        return spans
    }

    static func contiguous(_ frames: [CurveSpan], stride: Int) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var next: UInt64?
        for frame in frames {
            let offset = frame.byteOffset / stride
            if next == frame.first, let last = spans.last {
                spans[spans.count - 1] = last.lowerBound..<(offset + frame.count)
            } else {
                spans.append(offset..<(offset + frame.count))
            }
            next = frame.end
        }
        return spans
    }

    func visit(_ selection: StreamSelection, checkpoint: () throws -> Void = {},
               _ body: (StreamRunSegment, UInt64, CurveReading, StreamFrameAnchor) throws -> Void) throws {
        guard selection.valid else { throw CurveCodec.fault }
        let segments = Dictionary(uniqueKeysWithValues: run.segments.map { ($0.id, $0) })
        let first = blocks.partitioningIndex { item in
            guard let segment = segments[item.source.segment] else { return true }
            let rate = segment.configuredRate(run.settings.nominalRate)
            return segment.timelineStart + Double(item.end) / rate > selection.lower - 1e-8
        }
        for block in blocks.dropFirst(first) {
            guard let segment = segments[block.source.segment] else { throw CurveCodec.fault }
            let limits = ReviewInput.indices(selection, segment: segment, rate: run.settings.nominalRate)
            if segment.timelineStart + Double(block.first) / segment.configuredRate(run.settings.nominalRate) >= selection.upper + 1e-8 { break }
            guard limits.lowerBound < block.end, block.first < limits.upperBound else { continue }
            try Task.checkCancellation()
            try checkpoint()
            try autoreleasepool {
                let frames = try layout(block)
                let factor = block.source.picoAveraging
                let stride = PicoAverage.stride(factor, board: run.settings.board)
                var frame = 0
                try CurveCodec.visit(data(block), modeled: block.modeled, count: block.count,
                                     spans: Self.contiguous(frames, stride: stride), factor: factor, board: run.settings.board) { offset, reading in
                    while offset >= frames[frame].byteOffset / stride + frames[frame].count { frame += 1 }
                    let anchor = frames[frame]
                    let index = anchor.first + UInt64(offset - anchor.byteOffset / stride)
                    if limits.contains(index) { try body(segment, index, reading, anchor.anchor) }
                }
            }
        }
    }

    func verify(checkpoint: () throws -> Void = {}) throws {
        for block in blocks {
            try Task.checkCancellation()
            try checkpoint()
            try autoreleasepool {
                let factor = block.source.picoAveraging
                try CurveCodec.visit(data(block), modeled: block.modeled, count: block.count,
                    spans: Self.contiguous(layout(block), stride: PicoAverage.stride(factor, board: run.settings.board)), factor: factor, board: run.settings.board) { _, _ in }
            }
        }
    }

    func verifySourceGrid(_ source: StreamRangeReader) throws {
        let source = try source.prepared()
        let entries = source.index ?? []
        guard entries.count == blocks.count, manifest.wholeRun else { throw CurveCodec.fault }
        for (original, block) in zip(entries, blocks) {
            try Task.checkCancellation()
            guard original == block.source, block.first == original.first, block.end == original.end,
                  block.count == original.readingCount else { throw CurveCodec.fault }
            let expected = try source.store.chunk(original, run: source.run).slices
            let actual = try layout(block)
            guard actual.count == expected.count else { throw CurveCodec.fault }
            for (s, f) in zip(expected, actual) {
                guard s.first == f.first, s.count == f.count, s.byteOffset == f.byteOffset,
                      s.sequence == f.anchor.sequence, s.first == f.anchor.frameFirstIndex,
                      s.count == f.anchor.frameSampleCount, s.deviceEndUS == f.anchor.deviceFrameEndUS else { throw CurveCodec.fault }
            }
        }
    }

    func seconds(_ location: StreamMatchLocation) -> Double? {
        run.segments.first(where: { $0.id == location.segment }).map {
            $0.timelineStart + Double(location.sample) / $0.configuredRate(run.settings.nominalRate)
        }
    }

    func gaps() throws -> [StreamSelection] {
        var result: [StreamSelection] = []
        var end = manifest.selection.lower
        let segments = Dictionary(uniqueKeysWithValues: run.segments.map { ($0.id, $0) })
        func addGap(until time: Double) throws {
            guard time - end > 1e-8 else { return }
            guard result.count < WaveformOverview.maxGaps else {
                throw StreamFailure.storage("The run has too many gaps to show at once.")
            }
            result.append(.init(lower: end, upper: time))
        }
        for item in blocks {
            try Task.checkCancellation()
            guard let segment = segments[item.source.segment] else { throw CurveCodec.fault }
            let rate = segment.configuredRate(run.settings.nominalRate)
            try addGap(until: segment.timelineStart + Double(item.first) / rate)
            guard result.count + item.internalGaps.count <= WaveformOverview.maxGaps else { throw CurveCodec.fault }
            result.append(contentsOf: item.internalGaps)
            end = max(end, segment.timelineStart + Double(item.end) / rate)
        }
        try addGap(until: manifest.selection.upper)
        return result
    }
}

nonisolated enum CurveStore {
    static func root(_ store: StreamProjectStore, _ run: StreamRun, create: Bool) throws -> URL {
        try StreamFiles.directory("curves", in: store.runDirectory(run.id), create: create)
    }

    static func open(_ store: StreamProjectStore, run: StreamRun, id: UUID) throws -> CurveReader {
        let result = try CurveReader(folder: StreamFiles.directory(id.uuidString, in: root(store, run, create: false), create: false), run: run)
        guard result.manifest.id == id else { throw CurveCodec.fault }
        return result
    }

    static func list(_ store: StreamProjectStore, _ run: StreamRun) throws -> [CurveManifest] {
        let dir = try store.runDirectory(run.id)
        guard try StreamFiles.isPresent(dir.appendingPathComponent("curves")) else { return [] }
        let folder = try root(store, run, create: false)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard entries.count <= 512 else { throw CurveCodec.fault }
        return try entries.compactMap { name in
            guard let id = UUID(uuidString: name) else { return nil }
            let dir = try StreamFiles.directory(id.uuidString, in: folder, create: false)
            let item = try StreamFiles.read(CurveManifest.self, dir.appendingPathComponent("curve.json"))
            guard item.id == id, item.project == run.project, item.source == (run.curveSource ?? run.id), item.version == 1 else {
                throw CurveCodec.fault
            }
            return item
        }.sorted { $0.created > $1.created }
    }

    static func fit(_ original: StreamRangeReader, id: UUID, name: String, selection: StreamSelection, request: CurveRequest,
                    fingerprint: String, stage: URL, checkpoint: () throws -> Void,
                    progress: (Double) -> Void) throws -> CurveManifest {
        guard request.valid, selection.valid, original.run.curveSource == nil else { throw CurveCodec.fault }
        let reader = try original.prepared()
        let run = reader.run
        let duration = try reader.duration()
        let summaries = reader.index ?? []
        let segments = Dictionary(uniqueKeysWithValues: run.segments.map { ($0.id, $0) })
        let preserved = Dictionary(grouping: request.preserve, by: \.segment)
        var blocks: [CurveBlock] = []
        var all = CurveAccumulator(tolerance: request.tolerance)
        var minutes: [CurveManifest.Minute] = []
        var activeMinute: Int?
        var minute = CurveAccumulator(tolerance: request.tolerance)
        var lossless: Int64 = 0
        var sourceBytes: Int64 = 0
        var sourceIndexBytes: Int64 = 0
        var sampled = 0.0
        var represented: UInt64 = 0
        let factor = run.settings.picoAveraging
        let stride = PicoAverage.stride(factor, board: run.settings.board)
        let sourceFolder = try StreamFiles.directory("chunks", in: reader.store.runDirectory(run.id), create: false)
        let volume = try stage.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard volume.map({ $0 > 1_048_576 }) ?? true else { throw POSIXError(.ENOSPC) }

        for (position, summary) in summaries.enumerated() {
            guard let segment = segments[summary.segment] else { throw CurveCodec.fault }
            let selected = ReviewInput.indices(selection, segment: segment, rate: run.settings.nominalRate)
            guard selected.lowerBound < summary.end, summary.first < selected.upperBound else { continue }
            try Task.checkCancellation()
            try checkpoint()
            try autoreleasepool {
                let chunk = try reader.store.chunk(summary, run: run)
                let original = try reader.store.data(summary, run: run)
                var bytes = Data()
                var frames: [CurveSpan] = []
                var mask: [Range<Int>] = []
                for slice in chunk.slices {
                    let lo = max(selected.lowerBound, slice.first)
                    let hi = min(selected.upperBound, slice.first + UInt64(slice.count))
                    guard lo < hi else { continue }
                    let first = slice.byteOffset + Int(lo - slice.first) * stride
                    let count = Int(hi - lo)
                    let offset = bytes.count
                    frames.append(.init(first: lo, count: count, byteOffset: offset,
                        anchor: .init(sequence: slice.sequence, frameFirstIndex: slice.first,
                                      frameSampleCount: slice.count, deviceFrameEndUS: slice.deviceEndUS)))
                    for range in preserved[segment.id] ?? [] {
                        let start = max(lo, range.first), end = min(hi, range.end)
                        if start < end { mask.append((offset / stride + Int(start - lo))..<(offset / stride + Int(end - lo))) }
                    }
                    bytes.append(original[first..<(first + count * stride)])
                }
                guard let first = frames.first, let last = frames.last else { return }
                var merged: [Range<Int>] = []
                for span in mask.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    if let last = merged.last, span.lowerBound <= last.upperBound {
                        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                    } else { merged.append(span) }
                }
                let count = bytes.count / stride
                let spans = CurveReader.contiguous(frames, stride: stride)
                let exact = CurveCodec.encode(bytes)
                let candidate = try CurveCodec.fit(bytes, spans: spans, factor: factor, tolerance: request.tolerance, preserve: merged, board: run.settings.board)
                let fitted = CurveCodec.encode(candidate)
                var modeled = fitted.count < exact.count
                let output = stage.appendingPathComponent(summary.id.uuidString + ".curve")
                let frameFile = stage.appendingPathComponent(summary.id.uuidString + ".frames")
                let expandedFrames = try StreamFiles.encoder.encode(frames)
                let frameBytes = CurveCodec.encode(expandedFrames)
                try StreamFiles.publish(frameBytes, at: frameFile)
                let readFrames = try StreamFiles.read(frameFile, limit: 1_048_576)
                guard readFrames == frameBytes,
                      try CurveCodec.decode(readFrames, length: expandedFrames.count) == expandedFrames else { throw CurveCodec.fault }

                func publish(_ data: Data, length: Int, replace: Bool) throws -> Data {
                    try StreamFiles.publish(data, at: output, replace: replace)
                    let saved = try StreamFiles.read(output, limit: data.count)
                    guard saved == data else { throw CurveCodec.fault }
                    return try CurveCodec.decode(saved, length: length)
                }

                var stored = modeled ? fitted : exact
                var expanded = modeled ? candidate.count : bytes.count
                var decoded = try publish(stored, length: expanded, replace: false)
                if modeled {
                    let bounded = try bytes.withUnsafeBytes { input in
                        var bounded = true
                        try CurveCodec.visit(decoded, modeled: true, count: count, spans: spans, factor: factor, board: run.settings.board) { i, value in
                            let source = try CurveCodec.reading(input, at: i * stride, factor: factor, board: run.settings.board)
                            if let v = value.value, let s = source.value {
                                if abs(v - s) > request.tolerance { bounded = false }
                            } else if value.value != source.value || !value.exact || value.adcErrors != source.adcErrors ||
                                        value.low != source.low || value.high != source.high { bounded = false }
                        }
                        return bounded
                    }
                    if !bounded {
                        modeled = false
                        stored = exact
                        expanded = bytes.count
                        decoded = try publish(stored, length: expanded, replace: true)
                    }
                }

                var block = CurveAccumulator(tolerance: request.tolerance)
                var minimum = Double.infinity, maximum = -Double.infinity, sum = 0.0
                let rate = segment.configuredRate(run.settings.nominalRate)
                var frame = 0
                try bytes.withUnsafeBytes { input in
                    try CurveCodec.visit(decoded, modeled: modeled, count: count, spans: spans, factor: factor, board: run.settings.board) { i, reading in
                        while i >= frames[frame].byteOffset / stride + frames[frame].count { frame += 1 }
                        let index = frames[frame].first + UInt64(i - frames[frame].byteOffset / stride)
                        let source = try CurveCodec.reading(input, at: i * stride, factor: factor, board: run.settings.board)
                        let location = StreamMatchLocation(segment: segment.id, sample: index)
                        let m = Int((segment.timelineStart + Double(index) / rate) / 60)
                        if activeMinute != m {
                            if let activeMinute { minutes.append(.init(id: activeMinute, stats: minute.result())) }
                            activeMinute = m
                            minute = .init(tolerance: request.tolerance)
                        }
                        all.add(reading, source: source, at: location)
                        block.add(reading, source: source, at: location)
                        minute.add(reading, source: source, at: location)
                        if let value = reading.value {
                            minimum = min(minimum, value)
                            maximum = max(maximum, value)
                            sum += value
                        }
                    }
                }
                let quality = block.result()
                let internalGaps = zip(frames, frames.dropFirst()).compactMap { previous, following -> StreamSelection? in
                    guard previous.end < following.first else { return nil }
                    return .init(lower: segment.timelineStart + Double(previous.end) / rate,
                                 upper: segment.timelineStart + Double(following.first) / rate)
                }
                blocks.append(.init(source: summary, first: first.first, end: last.end, count: count, expanded: expanded,
                    stored: stored.count, modeled: modeled, sha256: StreamFiles.sha(stored), frameSHA256: StreamFiles.sha(frameBytes),
                    frameBytes: frameBytes.count, frameExpanded: expandedFrames.count, internalGaps: internalGaps,
                    minimum: minimum.isFinite ? minimum : nil, maximum: maximum.isFinite ? maximum : nil,
                    mean: quality.count > 0 ? sum / Double(quality.count) : nil, quality: quality))
                sampled += Double(count) / rate
                represented += UInt64(count)
                let file = sourceFolder.appendingPathComponent(summary.id.uuidString + ".bin")
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? summary.bytes
                sourceBytes += Int64(size)
                for suffix in [".json", ".frames"] {
                    let originalIndex = sourceFolder.appendingPathComponent(summary.id.uuidString + suffix)
                    if try StreamFiles.isPresent(originalIndex) {
                        sourceIndexBytes += Int64(try originalIndex.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    }
                }
                // Compare both encodings with the same bounded index and framing overhead.
                lossless += Int64(exact.count + frameBytes.count)
            }
            if position.isMultiple(of: 16) { progress(Double(position + 1) / Double(max(1, summaries.count)) * 0.98) }
        }
        guard !blocks.isEmpty else { throw StreamFailure.storage("This range has no saved readings.") }
        if let activeMinute { minutes.append(.init(id: activeMinute, stats: minute.result())) }
        let index = try StreamFiles.encoder.encode(blocks)
        guard index.count <= 32 * 1024 * 1024 else { throw CurveCodec.fault }
        try StreamFiles.publish(index, at: stage.appendingPathComponent("index.json"))
        let frameSizes = try blocks.reduce(Int64(0)) { sum, block in
            let url = stage.appendingPathComponent(block.source.id.uuidString + ".frames")
            return sum + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let stored = blocks.reduce(frameSizes + Int64(index.count)) { $0 + Int64($1.stored) }
        let unknown = run.segments.enumerated().compactMap { offset, segment -> Double? in
            let end = max(segment.accountedSamples, summaries.last(where: { $0.segment == segment.id })?.end ?? 0)
            let time = segment.timelineStart + Double(end) / segment.configuredRate(run.settings.nominalRate)
            return (segment.unknown || offset + 1 < run.segments.count) && selection.lower <= time && time <= selection.upper ? time : nil
        }
        let accounted = run.segments.reduce((readings: UInt64(0), seconds: 0.0)) { total, segment in
            let selection = ReviewInput.indices(selection, segment: segment, rate: run.settings.nominalRate)
            let end = max(segment.accountedSamples, summaries.last(where: { $0.segment == segment.id })?.end ?? 0)
            let count = max(selection.lowerBound, min(selection.upperBound, end)) - selection.lowerBound
            return (total.readings + count, total.seconds + Double(count) / segment.configuredRate(run.settings.nominalRate))
        }
        var manifest = CurveManifest(id: id, name: name, project: run.project, source: run.id, sourceFingerprint: fingerprint,
            selection: selection, wholeRun: selection.lower == 0 && abs(selection.upper - duration) <= 1e-8, settings: request,
            count: blocks.count, indexHash: StreamFiles.sha(index), storedBytes: stored, sourceBytes: sourceBytes, sourceIndexBytes: sourceIndexBytes,
            losslessBytes: lossless + Int64(index.count), missingSeconds: max(0, accounted.seconds - sampled),
            capturedSeconds: sampled, missingReadings: accounted.readings - min(accounted.readings, represented),
            unknownBoundaries: unknown, stats: all.result(), minutes: minutes)
        let losslessWithoutManifest = manifest.losslessBytes
        for _ in 0..<4 {
            let size = Int64(try StreamFiles.encoder.encode(manifest).count)
            if manifest.storedBytes == stored + size && manifest.losslessBytes == losslessWithoutManifest + size { break }
            manifest.storedBytes = stored + size
            manifest.losslessBytes = losslessWithoutManifest + size
        }
        try StreamFiles.publish(manifest, at: stage.appendingPathComponent("curve.json"))
        _ = try CurveReader(folder: stage, run: run)
        return manifest
    }
}

private extension Array {
    nonisolated func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle }
            else { low = middle + 1 }
        }
        return low
    }
}
