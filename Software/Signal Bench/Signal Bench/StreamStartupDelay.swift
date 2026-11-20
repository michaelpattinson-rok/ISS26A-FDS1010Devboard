import Foundation

nonisolated struct StreamStartupEvidence: Codable, Equatable, Sendable {
    let originalReadingOffset: UInt64
    let discardedReadings: UInt64

    func valid(factor: UInt64) -> Bool {
        discardedReadings <= originalReadingOffset &&
            originalReadingOffset <= StreamWire.maxWireSampleBoundary / factor
    }
}

/// Apply only after the original wire frame and its counters have been validated.
nonisolated struct StreamStartupDelay {
    static let supported = 0...30
    static let defaultSeconds = 5

    let seconds: Int
    private(set) var cutoff: UInt64 = 0
    private(set) var discarded: UInt64 = 0

    mutating func configure(rate: Double, candidates: Bool) {
        let samples = UInt64((Double(seconds) * rate).rounded(.up))
        let block = candidates ? UnoCandidateBlock.width : 1
        cutoff = (samples + block - 1) / block * block
    }

    mutating func retain(_ frame: StreamFrame, board: AcquisitionBoard, averaging: ADCAveraging?) -> StreamFrame? {
        guard cutoff > 0 else { return frame }
        var saved = frame
        if frame.kind == .samples {
            let skip = min(cutoff - min(cutoff, frame.index), UInt64(frame.count))
            discarded += skip
            guard skip < UInt64(frame.count) else { return nil }
            if skip > 0 {
                let stride = PicoAverage.stride(averaging, board: board)
                saved.payload = Data(frame.payload.dropFirst(Int(skip) * stride))
                saved.count -= UInt32(skip)
            }
            saved.index = max(frame.index, cutoff) - cutoff
            if let averaging, let groups = frame.groups {
                let origin = cutoff * UInt64(averaging.count)
                saved.groups = groups.dropFirst(Int(skip)).map {
                    .init(first: $0.first - origin, count: $0.count, sum: $0.sum,
                          adcErrors: $0.adcErrors, lowRail: $0.lowRail, highRail: $0.highRail)
                }
            }
        } else if frame.kind == .gpio {
            saved.index -= min(saved.index, cutoff)
        }
        return saved
    }

    func evidence(_ wire: StreamAccounting, logged: Bool) -> StreamStartupEvidence? {
        guard seconds > 0 else { return nil }
        return logged ? .init(originalReadingOffset: cutoff, discardedReadings: discarded)
            : .init(originalReadingOffset: wire.nextIndex, discardedReadings: wire.received)
    }

    func savedAccounting(_ wire: StreamAccounting, logged: Bool) -> StreamAccounting {
        guard let evidence = evidence(wire, logged: logged) else { return wire }
        var result = wire
        result.nextIndex -= evidence.originalReadingOffset
        result.received -= evidence.discardedReadings
        result.knownLoss = result.nextIndex - result.received
        return result
    }
}
