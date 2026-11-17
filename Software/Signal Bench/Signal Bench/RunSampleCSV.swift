import Foundation

/// Encodes the same columns as the original exporter in bounded UTF-8 batches.
nonisolated struct RunSampleCSV {
    private let output: StreamOutput
    private let picoAveraged: Bool
    private var buffer = Data()

    init(output: StreamOutput, picoAveraged: Bool = false) throws {
        self.output = output
        self.picoAveraged = picoAveraged
        buffer.reserveCapacity(262_144)
        try output.line(picoAveraged ?
            "segment,stream_id,reading_index,first_conversion,end_conversion_exclusive,center_nominal_time_s,exact_sum,mean_adc_code,adc_errors,low_rail,high_rail" :
            "segment,stream_id,original_index,nominal_time_s,raw_word,adc_code,adc_error")
    }

    mutating func append(_ part: StreamRangeData, pieces: [Range<UInt64>], prefix: Data) throws {
        let first = part.reference.first
        let rate = part.configuredRate
        let start = part.segment.timelineStart
        if picoAveraged {
            guard let groups = part.groups else { throw StreamFailure.storage("Averaged readings are missing from the verified range.") }
            for piece in pieces {
                try Task.checkCancellation()
                for index in piece {
                    let group = groups[Int(index - first)]
                    buffer.append(prefix)
                    integer(index, separator: 44)
                    integer(group.first, separator: 44)
                    integer(group.first + UInt64(group.count), separator: 44)
                    let center = start + (Double(index) + Double(group.count - 1) / (2 * Double(group.count))) / rate
                    buffer.append(contentsOf: String(center).utf8)
                    buffer.append(44)
                    integer(group.sum, separator: 44)
                    if let mean = group.mean { buffer.append(contentsOf: String(mean).utf8) }
                    buffer.append(44)
                    integer(UInt64(group.adcErrors), separator: 44)
                    integer(UInt64(group.lowRail), separator: 44)
                    integer(UInt64(group.highRail), separator: 10)
                    if buffer.count >= 262_144 { try flush() }
                }
            }
            return
        }
        try part.words.withUnsafeBytes { bytes in
            for piece in pieces {
                try Task.checkCancellation()
                for index in piece {
                    let i = Int(index - first)
                    let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                    buffer.append(prefix)
                    integer(index, separator: 44)
                    buffer.append(contentsOf: String(start + Double(index) / rate).utf8)
                    buffer.append(44)
                    integer(UInt64(word), separator: 44)
                    integer(UInt64(part.segment.board.sampleCode(word)), separator: 44)
                    buffer.append(word & 0x8000 == 0 ? 48 : 49)
                    buffer.append(10)
                    if buffer.count >= 262_144 { try flush() }
                }
            }
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try Task.checkCancellation()
        try output.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func integer(_ value: UInt64, separator: UInt8) {
        // Emit ASCII digits in order without an intermediate String per field.
        var divisor: UInt64 = 1
        while divisor <= value / 10 { divisor *= 10 }
        var remaining = value
        while divisor > 0 {
            buffer.append(UInt8(remaining / divisor) + 48)
            remaining %= divisor
            divisor /= 10
        }
        buffer.append(separator)
    }
}
