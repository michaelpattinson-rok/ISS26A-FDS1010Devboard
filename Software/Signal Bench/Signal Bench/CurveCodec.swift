import Compression
import Foundation

nonisolated struct CurveReading: Sendable {
    var value: Double?
    var exact: Bool
    var adcErrors: Int
    var low: Int
    var high: Int
}

nonisolated enum CurveCodec {
    static let version = 1
    static let blockLimit = 4 * 1024 * 1024
    static let fault = StreamFailure.storage("The saved curve block failed verification.")

    // A leading byte selects original bytes or LZFSE. The verified expanded length is part of the block index.
    static func encode(_ data: Data) -> Data {
        guard data.count > 16 else { return Data([0]) + data }
        var output = Data(count: data.count - 1)
        let n = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard n > 0, n < data.count else { return Data([0]) + data }
        return Data([1]) + output.prefix(n)
    }

    static func decode(_ data: Data, length: Int) throws -> Data {
        guard (1...blockLimit).contains(length), let kind = data.first else { throw fault }
        if kind == 0, data.count == length + 1 { return Data(data.dropFirst()) }
        guard kind == 1, data.count > 1, data.count <= length else { throw fault }
        var output = Data(count: length + 1)
        let n = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    input.bindMemory(to: UInt8.self).baseAddress! + 1, input.count - 1, nil, COMPRESSION_LZFSE)
            }
        }
        guard n == length else { throw fault }
        output.removeLast()
        return output
    }

    static func reading(_ bytes: UnsafeRawBufferPointer, at offset: Int, factor: ADCAveraging?, board: AcquisitionBoard = .picoW) throws -> CurveReading {
        if let factor {
            guard let group = PicoAverage.group(bytes, offset: offset, first: 0, factor: factor, board: board) else { throw fault }
            return .init(value: group.mean, exact: true, adcErrors: group.adcErrors, low: group.lowRail, high: group.highRail)
        }
        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        let code = board.sampleCode(word)
        let invalid = word & 0x8000 != 0
        return .init(value: invalid || code == 0 || code == board.maxCode ? nil : Double(code), exact: true,
                     adcErrors: invalid ? 1 : 0, low: !invalid && code == 0 ? 1 : 0, high: !invalid && code == board.maxCode ? 1 : 0)
    }

    // Each command owns consecutive original indices within one contiguous run.
    // Zero high bit means literal payload. One high bit means an exact anchor sum and Float32 slope.
    static func fit(_ data: Data, spans: [Range<Int>], factor: ADCAveraging?, tolerance: Double,
                    preserve: [Range<Int>], board: AcquisitionBoard = .picoW) throws -> Data {
        let stride = PicoAverage.stride(factor, board: board)
        return try data.withUnsafeBytes { bytes in
            let values = try (0..<(bytes.count / stride)).map { try reading(bytes, at: $0 * stride, factor: factor, board: board).value }
            var output = Data()
            for span in spans {
                try Task.checkCancellation()
                var first = span.lowerBound
                var mask = 0
                while first < span.upperBound {
                    while mask < preserve.count && preserve[mask].upperBound <= first { mask += 1 }
                    let keep = mask < preserve.count && preserve[mask].contains(first)
                    let stop = min(span.upperBound, first + 32767, mask < preserve.count ?
                                   (keep ? preserve[mask].upperBound : preserve[mask].lowerBound) : span.upperBound)
                    var end = first + 1
                    if keep || values[first] == nil {
                        while end < stop && (keep || values[end] == nil) { end += 1 }
                        StreamWire.put(UInt16(end - first), into: &output)
                        output.append(data[(first * stride)..<(end * stride)])
                    } else {
                        let start = values[first]!
                        var lo = -Double.infinity
                        var hi = Double.infinity
                        // Reserve margin for the serialized slope and reconstruction arithmetic.
                        let fitLimit = tolerance - 0.0005
                        while end < stop, let value = values[end] {
                            let dx = Double(end - first)
                            let lower = max(lo, (value - start - fitLimit) / dx)
                            let upper = min(hi, (value - start + fitLimit) / dx)
                            guard lower <= upper else { break }
                            lo = lower
                            hi = upper
                            end += 1
                        }
                        let n = end - first
                        if n * stride <= 8 {
                            StreamWire.put(UInt16(n), into: &output)
                            output.append(data[(first * stride)..<(end * stride)])
                        } else {
                            let wanted = (values[end - 1]! - start) / Double(n - 1)
                            let slope = Float(min(hi, max(lo, wanted)))
                            StreamWire.put(UInt16(n) | 0x8000, into: &output)
                            StreamWire.put(UInt32((start * Double(factor?.count ?? 1)).rounded()), into: &output)
                            StreamWire.put(slope.bitPattern, into: &output)
                        }
                    }
                    first = end
                }
            }
            return output
        }
    }

    static func visit(_ bytes: Data, modeled: Bool, count: Int, spans: [Range<Int>], factor: ADCAveraging?, board: AcquisitionBoard = .picoW,
                      _ body: (Int, CurveReading) throws -> Void) throws {
        let stride = PicoAverage.stride(factor, board: board)
        try bytes.withUnsafeBytes { buffer in
            guard modeled || buffer.count == count * stride else { throw fault }
            var offset = 0
            for span in spans {
                var at = span.lowerBound
                while at < span.upperBound {
                    let n: Int
                    let linear: Bool
                    if modeled {
                        guard offset + 2 <= buffer.count else { throw fault }
                        let token = UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        offset += 2
                        n = Int(token & 0x7fff)
                        linear = token & 0x8000 != 0
                    } else {
                        n = span.count
                        linear = false
                    }
                    guard n > 0, n <= span.upperBound - at else { throw fault }
                    if linear {
                        guard offset + 8 <= buffer.count else { throw fault }
                        let sum = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        let start = Double(sum) / Double(factor?.count ?? 1)
                        let slope = Double(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))))
                        guard (1...Double(board.maxCode - 1)).contains(start), slope.isFinite, abs(slope) <= Double(board.maxCode) + 1 else { throw fault }
                        for i in 0..<n {
                            let value = min(Double(board.maxCode), max(0, start + slope * Double(i)))
                            try body(at + i, .init(value: value, exact: false, adcErrors: 0, low: 0, high: 0))
                        }
                        offset += 8
                    } else {
                        guard offset + n * stride <= buffer.count else { throw fault }
                        for i in 0..<n { try body(at + i, try reading(buffer, at: offset + i * stride, factor: factor, board: board)) }
                        offset += n * stride
                    }
                    at += n
                }
            }
            guard offset == buffer.count else { throw fault }
        }
    }
}
