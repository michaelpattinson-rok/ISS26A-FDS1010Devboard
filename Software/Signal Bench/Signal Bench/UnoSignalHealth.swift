import Foundation

nonisolated struct UnoSignalHealth: Sendable {
    static let block: UInt64 = 1024
    static let payloadSize = 24
    let firstConversion: UInt64
    let deviceEndUS: UInt64
    let baseline: Double?
    let noise: Double?
    let minimum: UInt16?
    let maximum: UInt16?
    let low: UInt16
    let high: UInt16
    let errors: UInt16

    init?(frame: StreamFrame) {
        let bytes = frame.payload
        guard bytes.count == Self.payloadSize, frame.count == 0, frame.flags == 0,
              frame.auxiliary == Self.block, StreamWire.read(UInt16.self, bytes, at: 22) == 0 else { return nil }
        let sum = UInt64(StreamWire.read(UInt32.self, bytes, at: 0))
        let squares = StreamWire.read(UInt64.self, bytes, at: 4)
        let min = StreamWire.read(UInt16.self, bytes, at: 12)
        let max = StreamWire.read(UInt16.self, bytes, at: 14)
        low = StreamWire.read(UInt16.self, bytes, at: 16)
        high = StreamWire.read(UInt16.self, bytes, at: 18)
        errors = StreamWire.read(UInt16.self, bytes, at: 20)
        let excluded = UInt64(low) + UInt64(high) + UInt64(errors)
        guard excluded <= Self.block else { return nil }
        let valid = Self.block - excluded
        if valid == 0 {
            guard min == 0, max == 0, sum == 0, squares == 0 else { return nil }
            baseline = nil; noise = nil; minimum = nil; maximum = nil
        } else {
            let lower = UInt64(min), upper = UInt64(max)
            guard lower > 0, upper < 0x3fff, lower <= upper,
                  sum >= valid * lower, sum <= valid * upper,
                  squares <= sum * upper, squares >= sum * lower,
                  squares * valid >= sum * sum else { return nil }
            baseline = Double(sum) / Double(valid)
            noise = sqrt(Double(squares * valid - sum * sum)) / Double(valid)
            minimum = min; maximum = max
        }
        firstConversion = frame.index
        deviceEndUS = frame.timeUS
    }
}
