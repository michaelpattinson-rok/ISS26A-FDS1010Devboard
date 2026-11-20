import Foundation

nonisolated struct FlagFrame: Sendable {
    let first: UInt64
    let receivedAt: UInt64
    let words: Data
    var averaging: ADCAveraging? = nil
    var board: AcquisitionBoard = .picoW
    var count: Int { words.count / PicoAverage.stride(averaging, board: board) }
    var end: UInt64 { first + UInt64(count) }
}

nonisolated struct FrozenFlagWaveform: Sendable {
    let segment: UUID
    let stream: UInt64
    let rate: Double
    let timelineStart: Double
    let click: Date
    let first: UInt64
    let end: UInt64
    let frames: [FlagFrame]
    var recordingBoard: AcquisitionBoard = .picoW

    func time(_ index: UInt64) -> Double { timelineStart + Double(index) / rate }
    var bounds: StreamSelection { .init(lower: time(first), upper: time(end)) }

    func sample(at time: Double) -> WaveformSample? {
        let coordinate = (time - timelineStart) * rate
        guard coordinate.isFinite, coordinate >= Double(first), coordinate <= Double(end) else { return nil }
        let floorIndex = min(end - 1, UInt64((coordinate + 1e-6).rounded(.down)))
        guard let frame = frames.first(where: { $0.first <= floorIndex && floorIndex < $0.end }) else { return nil }
        return sample(atIndex: min(frame.end - 1, UInt64(coordinate.rounded())), in: frame)
    }

    func sample(atIndex index: UInt64) -> WaveformSample? {
        guard first <= index, index < end,
              let frame = frames.first(where: { $0.first <= index && index < $0.end }) else { return nil }
        return sample(atIndex: index, in: frame)
    }

    private func sample(atIndex index: UInt64, in frame: FlagFrame) -> WaveformSample? {
        let offset = Int(index - frame.first) * PicoAverage.stride(frame.averaging, board: recordingBoard)
        if let factor = frame.averaging {
            guard let group = frame.words.withUnsafeBytes({ PicoAverage.group($0, offset: offset, first: index * UInt64(factor.count), factor: factor, board: recordingBoard) }) else { return nil }
            return .init(segment: segment, index: index, time: self.time(index), word: PicoAverage.projectedWord(group), group: group, board: recordingBoard)
        }
        return .init(segment: segment, index: index, time: self.time(index), word: StreamWire.read(UInt16.self, frame.words, at: offset), board: recordingBoard)
    }

    func plot(_ selection: StreamSelection, dotPercent: Double? = nil, dotLimit: Int = WaveformDots.liveLimit) throws -> StudioPlot {
        try StreamStudio.reduceWaveform(selection, rate: rate, dotPercent: dotPercent, dotLimit: dotLimit, board: recordingBoard) { accept in
            try visit(selection, accept)
        }
    }

    func visit(_ selection: StreamSelection, _ accept: (UUID, UInt64, Double, Double, Data, [ADCAveraging.Group]?) throws -> Void) throws {
        let lower = max(first, UInt64(max(0, ceil((selection.lower - timelineStart) * rate - 1e-6))))
        let upper = min(end, UInt64(max(0, ceil((selection.upper - timelineStart) * rate - 1e-6))))
        for frame in frames where frame.end > lower && frame.first < upper {
            try Task.checkCancellation()
            let start = max(frame.first, lower), stop = min(frame.end, upper)
            guard stop > start else { continue }
            let size = PicoAverage.stride(frame.averaging, board: recordingBoard)
            let offset = Int(start - frame.first) * size
            let payload = start == frame.first && stop == frame.end ? frame.words :
                frame.words.subdata(in: offset..<(offset + Int(stop - start) * size))
            if let factor = frame.averaging {
                let groups = try PicoAverage.groups(payload, first: start, factor: factor, board: recordingBoard)
                var words = Data(capacity: 2 * groups.count)
                for group in groups { StreamWire.put(PicoAverage.projectedWord(group), into: &words) }
                try accept(segment, start, time(start), rate, words, groups)
            } else {
                try accept(segment, start, time(start), rate, payload, nil)
            }
        }
    }
}

/// Retains the decoded frame buffers already passed to the writer. All deque
/// mutations happen on the transport queue and never wait on the editor.
nonisolated struct LiveFlagHistory {
    static let seconds = 30.0
    static let byteLimit = 30_000_000
    private let rate: Double
    private let averaging: ADCAveraging?
    private let board: AcquisitionBoard
    private var frames = [FlagFrame?](repeating: nil, count: 8192)
    private var head = 0
    private var count = 0
    private(set) var bytes = 0

    init(rate: Double, averaging: ADCAveraging? = nil, board: AcquisitionBoard = .picoW) {
        self.rate = rate
        self.averaging = averaging
        self.board = board
    }

    mutating func append(first: UInt64, at receivedAt: UInt64, words: Data) {
        let frame = FlagFrame(first: first, receivedAt: receivedAt, words: words, averaging: averaging, board: board)
        let window = UInt64((rate * Self.seconds).rounded(.down))
        let boundary = frame.end - min(frame.end, window)
        while count > 0, let oldest = frames[head],
              count == frames.count || bytes + words.count > Self.byteLimit || oldest.end <= boundary {
            bytes -= oldest.words.count
            frames[head] = nil
            head = (head + 1) % frames.count
            count -= 1
        }
        frames[(head + count) % frames.count] = frame
        count += 1
        bytes += words.count
    }

    func freeze(at instant: UInt64, date: Date, segment: StreamRunSegment, seconds: Double = Self.seconds) -> FrozenFlagWaveform? {
        let recent = (0..<count).reversed().lazy.compactMap { frames[(head + $0) % frames.count] }
            .drop(while: { $0.receivedAt > instant })
        guard let last = recent.first else { return nil }
        let window = UInt64((rate * min(Self.seconds, max(0.001, seconds))).rounded(.down))
        let lower = last.end - min(last.end, window)
        let retained = Array(recent.prefix(while: { $0.end > lower }).reversed())
        guard let earliest = retained.first else { return nil }
        return .init(segment: segment.id, stream: segment.stream, rate: rate, timelineStart: segment.timelineStart,
                     click: date, first: max(earliest.first, lower), end: last.end, frames: retained, recordingBoard: segment.board)
    }
}
