import Foundation

nonisolated enum StreamFailure: LocalizedError {
    case protocolError(String), project(String), storage(String)
    var errorDescription: String? {
        switch self {
        case .protocolError(let text), .project(let text), .storage(let text): text
        }
    }
}

nonisolated enum StreamFrameKind: UInt8, Sendable { case start = 1, samples, gpio, end }

nonisolated struct StreamFrame: Sendable {
    var kind: StreamFrameKind
    var sequence: UInt32
    var stream: UInt64
    var boot: UInt64
    var index: UInt64
    var timeUS: UInt64
    var count: UInt32
    var auxiliary: UInt32
    var flags: UInt32
    var payload: Data
    var groups: [ADCAveraging.Group]? = nil

    var words: [UInt16] {
        guard kind == .samples else { return [] }
        if let groups { return groups.map(PicoAverage.projectedWord) }
        return payload.withUnsafeBytes { bytes in
            (0..<Int(count)).map { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self)) }
        }
    }
}

nonisolated enum StreamWire {
    static let headerSize = 64
    static let maxSamples = 2048
    static let rate = 100_000
    static let rates = [25_000, 50_000, 100_000, 125_000, 200_000, 250_000, 400_000, 500_000]
    static let customRates = 10_000...500_000
    static let adcClock: UInt32 = 48_000_000
    static func requiresPacking(_ rate: Int) -> Bool { rate > 250_000 }

    static func divider(for rate: Int, clock: UInt32 = adcClock) -> UInt32? {
        guard customRates.contains(rate), UInt64(clock) >= 96 * UInt64(rate) else { return nil }
        let period = (UInt64(clock) * 256 + UInt64(rate / 2)) / UInt64(rate)
        guard period <= 0x10000ff else { return nil }
        // A programmed 96-cycle interval skipped conversions on the Pico W.
        // Between 96 and 97 clocks choose the nearer of free running and 97.
        if period < 97 * 256 {
            let useFreeRunning = UInt64(rate) * (2 * 96 * 97) >= UInt64(clock) * (96 + 97)
            return useFreeRunning ? 0 : 96 * 256
        }
        return UInt32(period - 256)
    }

    static func configuredRate(clock: UInt32, divider: UInt32) -> Double {
        Double(clock) * 256 / Double(divider == 0 ? 96 * 256 : UInt64(divider) + 256)
    }

    static func configuredRate(for rate: Int) -> Double {
        divider(for: rate).map { configuredRate(clock: adcClock, divider: $0) } ?? Double(rate)
    }
    static func ordinaryRate(_ requested: Int, channel: Int) -> Bool {
        // The six minute hardware qualification covers GP26 (ADC0).
        requested == rate || (requested == 500_000 && channel == 0)
    }
    static let maxDuration = 7200.0
    static let stopReserveSeconds = 10.0

    static func samples(_ referenceSamples: Int, at rate: Int) -> Int {
        samples(referenceSamples, at: Double(rate))
    }

    static func samples(_ referenceSamples: Int, at rate: Double) -> Int {
        Int((Double(referenceSamples) * rate / Double(Self.rate)).rounded())
    }

    static func storageBytes(rate: Int, seconds: Double) -> Int64 {
        guard customRates.contains(rate), seconds.isFinite, seconds >= 0, seconds <= maxDuration else { return 0 }
        // Include per-frame timing metadata, filesystem overhead and room for Stop.
        return Int64(((seconds + stopReserveSeconds) * max(Double(rate), configuredRate(for: rate)) * 2.10).rounded(.up)) + 16 * 1024 * 1024
    }
    static let maxSampleBoundary: UInt64 = 3_605_000_000
    static let maxDeviceTimeUS = UInt64(Int64.max)
    static let protectedPinMask: UInt32 = 0x007f7fff

    static let crcTable: [UInt32] = (0..<256).map { entry in
        (0..<8).reduce(UInt32(entry)) { value, _ in
            (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320)
        }
    }

    static func crc(_ first: Data, _ second: Data = Data()) -> UInt32 {
        var crc = UInt32.max
        for byte in first { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        for byte in second { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ UInt32.max
    }

    static func read<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, at offset: Int) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    static func control(_ operation: UInt8, stream: UInt64, pin: UInt8 = 0) -> Data {
        var data = Data("SBC1".utf8)
        data.append(contentsOf: [1, operation, pin, 0])
        put(stream, into: &data)
        put(UInt32(0), into: &data)
        put(crc(data), into: &data)
        return data
    }

    static func encode(_ frame: StreamFrame) -> Data {
        var data = Data("SBS1".utf8)
        data.append(contentsOf: [1, frame.kind.rawValue])
        put(UInt16(headerSize), into: &data)
        put(UInt32(frame.payload.count), into: &data)
        put(frame.sequence, into: &data)
        put(frame.stream, into: &data)
        put(frame.boot, into: &data)
        put(frame.index, into: &data)
        put(frame.timeUS, into: &data)
        put(frame.count, into: &data)
        put(frame.auxiliary, into: &data)
        put(frame.flags, into: &data)
        put(crc(data, frame.payload), into: &data)
        data.append(frame.payload)
        return data
    }
}

nonisolated struct StreamParser {
    private var pending = Data()
    private var sawStart = false
    private let allowsPacked: Bool
    private let averaging: ADCAveraging?
    private let timing: Bool
    private let board: AcquisitionBoard

    init(allowsPacked: Bool = false, averaging: ADCAveraging? = nil, timing: Bool = false, board: AcquisitionBoard = .picoW) {
        self.board = board
        self.allowsPacked = allowsPacked
        self.averaging = averaging
        self.timing = timing || averaging != nil
    }

    private func unpackUno(_ packed: Data, count: Int) -> Data {
        var words = Data()
        words.reserveCapacity(count * 2)
        for byteOffset in stride(from: 0, to: packed.count, by: 7) {
            let i = packed.startIndex + byteOffset
            var bits: UInt64 = 0
            for j in 0..<7 { bits |= UInt64(packed[i + j]) << (8 * j) }
            for j in 0..<4 { StreamWire.put(UInt16((bits >> (14 * j)) & 0x3fff), into: &words) }
        }
        return words
    }

    // The wire uses two 12 bit codes per three bytes, followed by an
    // optional error bitmap. The writer always receives full ADC words.
    private func unpack(_ packed: Data, count: Int, hasErrors: Bool) -> Data {
        let errorOffset = count * 3 / 2
        var words = Data(count: count * 2)
        packed.withUnsafeBytes { input in
            words.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for i in stride(from: 0, to: count, by: 2) {
                    let offset = i * 3 / 2
                    let middle = input[offset + 1]
                    let errors: UInt8 = hasErrors ? input[errorOffset + i / 8] >> (i % 8) : 0
                    output[i * 2] = input[offset]
                    output[i * 2 + 1] = (middle & 15) | ((errors & 1) << 7)
                    output[i * 2 + 2] = (middle >> 4) | (input[offset + 2] << 4)
                    output[i * 2 + 3] = (input[offset + 2] >> 4) | ((errors & 2) << 6)
                }
            }
        }
        return words
    }

    mutating func append(_ incoming: Data) throws -> [StreamFrame] {
        var frames: [StreamFrame] = []
        try append(incoming) { frames.append($0) }
        return frames
    }

    mutating func append(_ incoming: Data, consume: (StreamFrame) throws -> Void) throws {
        guard incoming.count <= 32_768, pending.count + incoming.count <= 65_536 else {
            throw StreamFailure.protocolError("USB receive buffer exceeded its limit.")
        }
        pending.append(incoming)
        var offset = 0
        while pending.count - offset >= 4 {
            let magic = pending[offset..<(offset + 4)]
            if !sawStart && magic.elementsEqual("SB1 ".utf8) {
                guard let lineEnd = pending[offset...].firstIndex(of: 10) else {
                    if pending.count - offset > 256 { throw StreamFailure.protocolError("Invalid stream response.") }
                    break
                }
                let line = String(decoding: pending[offset..<lineEnd], as: UTF8.self)
                guard line.hasPrefix("SB1 ERROR ") else { throw StreamFailure.protocolError("Unexpected response before streaming.") }
                throw StreamFailure.protocolError(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard magic.elementsEqual("SBS1".utf8) else { throw StreamFailure.protocolError("The stream frame marker was damaged.") }
            guard pending.count - offset >= StreamWire.headerSize else { break }
            func field<T: FixedWidthInteger>(_ type: T.Type, _ relative: Int) -> T {
                StreamWire.read(type, pending, at: offset + relative)
            }
            guard pending[offset + 4] == 1, let kind = StreamFrameKind(rawValue: pending[offset + 5]),
                  field(UInt16.self, 6) == StreamWire.headerSize else {
                throw StreamFailure.protocolError("Unsupported stream frame.")
            }
            let bytes = Int(field(UInt32.self, 8))
            let count = field(UInt32.self, 48)
            let flags = field(UInt32.self, 56)
            let packed = kind == .samples && (flags == 1 || flags == 3)
            let hasErrors = packed && flags == 3
            let packedUno = kind == .samples && flags == 8
            let validSize: Bool
            switch kind {
            case .start: validSize = count == 0 && bytes == (averaging == nil ? 8 : 12)
            case .end: validSize = count == 0 && (timing || board == .unoR4 ? bytes == 32 : (bytes == 8 || bytes == 12))
            case .gpio: validSize = count == 0 && bytes == 16
            case .samples:
                if let averaging {
                    validSize = flags == PicoAverage.wireFlag && count == StreamWire.maxSamples / averaging.count
                        && bytes == Int(count) * PicoAverage.stride(averaging)
                } else if board == .unoR4 {
                    validSize = (1...UInt32(StreamWire.maxSamples)).contains(count) &&
                        (packedUno ? allowsPacked && count.isMultiple(of: 4) && bytes == Int(count) * 7 / 4 :
                            flags == 0 && bytes == Int(count) * 2)
                } else {
                    let expected = packed ? Int(count) * 3 / 2 + (hasErrors ? Int(count) / 8 : 0) : Int(count) * 2
                    validSize = (1...UInt32(StreamWire.maxSamples)).contains(count) && bytes == expected
                        && (packed ? allowsPacked && count.isMultiple(of: 8) : flags == 0)
                }
            }
            guard validSize else { throw StreamFailure.protocolError("Invalid stream payload length.") }
            let length = StreamWire.headerSize + bytes
            guard pending.count - offset >= length else { break }
            let payload = pending.subdata(in: (offset + StreamWire.headerSize)..<(offset + length))
            let calculated = StreamWire.crc(pending.subdata(in: offset..<(offset + 60)), payload)
            guard calculated == field(UInt32.self, 60) else {
                throw StreamFailure.protocolError("A stream checksum failed. The verified prefix is recoverable.")
            }
            let rawIndex = field(UInt64.self, 32)
            let factor = UInt64(averaging?.count ?? 1)
            guard rawIndex <= StreamWire.maxSampleBoundary, rawIndex.isMultiple(of: factor) else {
                throw StreamFailure.protocolError("The source conversion boundary is invalid.")
            }
            if kind == .samples && board == .unoR4 && !packedUno {
                guard payload.withUnsafeBytes({ bytes in
                    stride(from: 1, to: bytes.count, by: 2).allSatisfy { bytes[$0] & 0x40 == 0 }
                }) else { throw StreamFailure.protocolError("The Uno sample word has a reserved bit set.") }
            }
            let index = rawIndex / factor
            let groups = try averaging.flatMap { kind == .samples ? try PicoAverage.groups(payload, first: index, factor: $0) : nil }
            try consume(.init(kind: kind, sequence: field(UInt32.self, 12),
                              stream: field(UInt64.self, 16), boot: field(UInt64.self, 24),
                              index: index, timeUS: field(UInt64.self, 40),
                              count: count, auxiliary: field(UInt32.self, 52),
                              flags: packed || packedUno ? 0 : flags,
                              payload: packedUno ? unpackUno(payload, count: Int(count)) : packed ? unpack(payload, count: Int(count), hasErrors: hasErrors) : payload,
                              groups: groups))
            sawStart = true
            offset += length
        }
        // Data slices keep their backing bytes. Compact once per serial read
        // so bytes already delivered cannot accumulate for the run's duration.
        if offset == pending.count { pending.removeAll(keepingCapacity: true) }
        else if offset > 0 { pending = pending.subdata(in: offset..<pending.count) }
    }
}

nonisolated struct StreamAccounting {
    let stream: UInt64
    let channel: Int
    let rate: Int
    var boot: UInt64?
    var startTimeUS: UInt64?
    var configuredRate: Double?
    var nextSequence: UInt32 = 0
    var nextIndex: UInt64 = 0
    var received: UInt64 = 0
    var knownLoss: UInt64 = 0
    var lastDataTimeUS: UInt64 = 0
    var lastDataIndex: UInt64 = 0
    private var firstDMAAnchor: (index: UInt64, timeUS: UInt64)?
    var end: StreamFrame?
    var firmwareQueuePeak: UInt32?
    var maximumPackingUS: UInt32?
    var maximumUSBBackpressureUS: UInt64?
    var totalUSBBackpressureUS: UInt64?
    let averaging: ADCAveraging?
    let board: AcquisitionBoard
    var factor: UInt64 { UInt64(averaging?.count ?? 1) }
    var hostQueuePeak: Int?
    var maximumWriterUS: UInt64?

    init(stream: UInt64, channel: Int, rate: Int, averaging: ADCAveraging? = nil, board: AcquisitionBoard = .picoW) {
        self.board = board
        self.stream = stream
        self.channel = channel
        self.rate = rate
        self.averaging = averaging
    }

    var cadenceWindowUS: UInt64? {
        guard let firstDMAAnchor, lastDataTimeUS > firstDMAAnchor.timeUS else { return nil }
        let span = lastDataTimeUS - firstDMAAnchor.timeUS
        return span >= 250_000 ? span : nil
    }
    var sampleCadenceEstimate: Double? {
        guard let firstDMAAnchor, let cadenceWindowUS else { return nil }
        return Double(lastDataIndex - firstDMAAnchor.index) * 1_000_000 / Double(cadenceWindowUS)
    }

    mutating func accept(_ frame: StreamFrame) throws {
        guard end == nil, frame.stream == stream, frame.sequence == nextSequence, frame.boot != 0, (1...StreamWire.maxDeviceTimeUS).contains(frame.timeUS) else {
            throw StreamFailure.protocolError("Stream identity or sequence did not match.")
        }
        if let boot, frame.boot != boot { throw StreamFailure.protocolError("The recording device restarted during acquisition.") }
        switch frame.kind {
        case .start:
            guard frame.payload.count == (averaging == nil ? 8 : 12) else {
                throw StreamFailure.protocolError("Invalid stream start payload.")
            }
            let clock = StreamWire.read(UInt32.self, frame.payload, at: 0)
            let divider = StreamWire.read(UInt32.self, frame.payload, at: 4)
            guard boot == nil, frame.index == 0, frame.auxiliary == rate, frame.flags == channel,
                  board.accepts(clock, divider, rate: rate),
                  averaging.map({ StreamWire.read(UInt32.self, frame.payload, at: 8) == $0.count }) ?? true else {
                throw StreamFailure.protocolError("The device reported an unexpected sample configuration.")
            }
            configuredRate = board.measuredConfiguration(clock, counter: divider) / Double(factor)
            boot = frame.boot
            startTimeUS = frame.timeUS
            lastDataTimeUS = frame.timeUS
        case .samples:
            guard boot != nil, (1...UInt32(StreamWire.maxSamples)).contains(frame.count),
                  frame.index >= nextIndex, frame.timeUS >= lastDataTimeUS,
                  frame.index <= StreamWire.maxSampleBoundary / factor - UInt64(frame.count),
                  frame.flags == (averaging == nil ? 0 : PicoAverage.wireFlag), frame.auxiliary == 0,
                  averaging.map({ _ in frame.groups?.count == Int(frame.count) }) ?? true else {
                throw StreamFailure.protocolError("Sample ranges, timing or acquisition flags did not reconcile.")
            }
            knownLoss += frame.index - nextIndex
            nextIndex = frame.index + UInt64(frame.count)
            received += UInt64(frame.count)
            lastDataIndex = nextIndex
            lastDataTimeUS = frame.timeUS
            if firstDMAAnchor == nil { firstDMAAnchor = (nextIndex, frame.timeUS) }
        case .gpio:
            guard frame.payload.count == 16 else { throw StreamFailure.protocolError("Invalid GPIO payload.") }
            let directions = StreamWire.read(UInt32.self, frame.payload, at: 0)
            let levels = StreamWire.read(UInt32.self, frame.payload, at: 4)
            let outputs = StreamWire.read(UInt32.self, frame.payload, at: 8)
            let lease = StreamWire.read(UInt32.self, frame.payload, at: 12)
            guard let startTimeUS, frame.timeUS >= startTimeUS, frame.auxiliary == 0, frame.flags == 0,
                  frame.index <= StreamWire.maxSampleBoundary / factor, directions & ~board.gpioMask == 0,
                  levels & ~board.gpioMask == 0, outputs & ~directions == 0, lease <= 1,
                  lease == 1 || directions == 0 else { throw StreamFailure.protocolError("Invalid GPIO evidence.") }
        case .end:
            guard [8, 12, 32].contains(frame.payload.count), boot != nil, frame.timeUS >= lastDataTimeUS, frame.index >= nextIndex,
                  frame.index <= StreamWire.maxSampleBoundary / factor, frame.flags & ~1 == 0, frame.auxiliary <= 4,
                  StreamWire.read(UInt64.self, frame.payload, at: 0) == received else {
                throw StreamFailure.protocolError("The final sample counters did not reconcile.")
            }
            let peak = frame.payload.count >= 12 ? StreamWire.read(UInt32.self, frame.payload, at: 8) : nil
            guard peak.map({ $0 <= 12 }) ?? true else { throw StreamFailure.protocolError("Invalid firmware queue depth.") }
            if frame.payload.count == 32 {
                maximumPackingUS = StreamWire.read(UInt32.self, frame.payload, at: 12)
                let longest = StreamWire.read(UInt64.self, frame.payload, at: 16)
                let total = StreamWire.read(UInt64.self, frame.payload, at: 24)
                guard longest <= total, total <= frame.timeUS - (startTimeUS ?? 0) + 5_000_000 else {
                    throw StreamFailure.protocolError("Invalid USB backpressure counters.")
                }
                maximumUSBBackpressureUS = longest
                totalUSBBackpressureUS = total
            }
            knownLoss += frame.index - nextIndex
            nextIndex = frame.index
            firmwareQueuePeak = peak
            end = frame
        }
        nextSequence &+= 1
    }
}
