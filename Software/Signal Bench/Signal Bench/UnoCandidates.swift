import Foundation

nonisolated struct UnoCandidateSettings: Codable, Equatable, Sendable {
    var version = 1
    var threshold = 100
    var minWidthUS = 30
    var maxWidthUS = 3000
    var separationUS = 1000
    var driftLimit = 100
    var noiseLimit = 30

    private var minimum: Int { (minWidthUS + 9) / 10 }
    private var maximum: Int { maxWidthUS / 10 }
    var valid: Bool {
        version == 1 && (2...8192).contains(threshold) &&
        (20...20_480).contains(minWidthUS) && (20...20_480).contains(maxWidthUS) &&
        minimum <= maximum && (0...50_000).contains(separationUS) &&
        (1...4096).contains(driftLimit) && (1...4096).contains(noiseLimit)
    }
    var trailer: String {
        " PULSE1 \(threshold) \(minimum) \(maximum) \((separationUS + 9) / 10) \(driftLimit) \(noiseLimit)"
    }
}

nonisolated struct UnoCandidateBlock: Codable, Sendable {
    static let width: UInt64 = 1024
    enum Coverage: UInt8, Codable, CaseIterable, Sendable {
        case eligible, calibration, failedCalibration, fault, envelope, overflow, prolonged
        var title: String {
            switch self {
            case .eligible: "Eligible"; case .calibration: "Quiet reference"
            case .failedCalibration: "Quiet check failed"; case .fault: "ADC fault or rail"
            case .envelope: "Noise or drift"; case .overflow: "Candidate capacity"
            case .prolonged: "Overlong excursion"
            }
        }
    }
    enum Decision: UInt8, Codable, Sendable {
        case candidate, narrow, wide, separated, edge
        var title: String {
            switch self {
            case .candidate: "Candidate"; case .narrow: "Too narrow"; case .wide: "Too wide"
            case .separated: "Inside recovery"; case .edge: "Incomplete or invalid edge"
            }
        }
    }
    struct Pulse: Codable, Sendable {
        let first: UInt64
        let peak: UInt64
        let end: UInt64
        let height: UInt16
        let baseline: UInt16
        let decision: Decision
    }
    let first: UInt64
    let state: Coverage
    let workUS: UInt32
    let pulses: [Pulse]
    var end: UInt64 { first + Self.width }

    private init(first: UInt64, state: Coverage, workUS: UInt32, pulses: [Pulse]) {
        self.first = first
        self.state = state
        self.workUS = workUS
        self.pulses = pulses
    }

    func droppingPrefix(_ offset: UInt64) -> Self? {
        guard first >= offset else { return nil }
        return .init(first: first - offset, state: state, workUS: workUS, pulses: pulses.compactMap { pulse in
            guard pulse.first >= offset else { return nil }
            return .init(first: pulse.first - offset, peak: pulse.peak - offset, end: pulse.end - offset,
                         height: pulse.height, baseline: pulse.baseline, decision: pulse.decision)
        })
    }

    init?(frame: StreamFrame, lowerBound: UInt64) {
        let bytes = frame.payload
        guard bytes.count >= 8, frame.count == 0, frame.auxiliary == Self.width, frame.flags == 0,
              frame.index <= StreamWire.maxWireSampleBoundary - Self.width, frame.index.isMultiple(of: Self.width),
              let status = Coverage(rawValue: bytes[0]), bytes[1] <= 6,
              bytes.count == 8 + 20 * Int(bytes[1]), StreamWire.read(UInt16.self, bytes, at: 2) == 1 else { return nil }
        first = frame.index
        state = status
        workUS = StreamWire.read(UInt32.self, bytes, at: 4)
        let upper = frame.index + Self.width
        var decoded: [Pulse] = []
        for i in 0..<Int(bytes[1]) {
            let j = 8 + i * 20
            let start = UInt64(StreamWire.read(UInt32.self, bytes, at: j))
            let peak = UInt64(StreamWire.read(UInt32.self, bytes, at: j + 4))
            let end = UInt64(StreamWire.read(UInt32.self, bytes, at: j + 8))
            let height = StreamWire.read(UInt16.self, bytes, at: j + 12)
            let base = StreamWire.read(UInt16.self, bytes, at: j + 14)
            guard start <= peak, peak < end, end <= upper, end >= frame.index,
                  start >= lowerBound, height > 0, height < base, base < 16383,
                  let decision = Decision(rawValue: bytes[j + 16]),
                  bytes[(j + 17)..<(j + 20)].allSatisfy({ $0 == 0 }),
                  status == .eligible || decision != .candidate,
                  decoded.last.map({ $0.end <= start }) ?? true else { return nil }
            decoded.append(.init(first: start, peak: peak, end: end, height: height, baseline: base, decision: decision))
        }
        pulses = decoded
    }
}

nonisolated struct UnoCandidateArchive: Codable, Sendable {
    var version = 1
    var algorithmVersion = 1
    let segment: UUID
    let stream: UInt64
    let rawChunk: UUID
    let rawSHA256: String
    let settings: UnoCandidateSettings
    let blocks: [UnoCandidateBlock]
}
