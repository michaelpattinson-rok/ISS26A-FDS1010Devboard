import Foundation

/// Decodes bounded mixed text/raw USB frames before any text normalization.
struct BinaryTransferDecoder {
    private var buffer = Data()
    private var frame: (token: String, offset: UInt32, count: UInt16, crc: UInt32)?
    private var token: String?
    private var offset: UInt32 = 0
    var allowBinary = false

    mutating func append(_ data: Data) throws -> [String] {
        guard buffer.count + data.count <= 16_384 else { throw SBProtocolError.invalid("USB input exceeded its buffer limit.") }
        buffer.append(data)
        var lines: [String] = []
        while true {
            if let f = frame {
                let size = Int(f.count) * 2
                guard buffer.count >= size + 1 else { break }
                let bytes = Array(buffer.prefix(size))
                guard buffer[buffer.startIndex + size] == 10 else { throw SBProtocolError.invalid("Invalid binary frame terminator.") }
                var checked = Array(f.token.utf8)
                checked += (0..<4).map { UInt8(truncatingIfNeeded: f.offset >> ($0 * 8)) }
                checked += [UInt8(truncatingIfNeeded: f.count), UInt8(truncatingIfNeeded: f.count >> 8)]
                checked += bytes
                guard SBRecordAssembler.crc32(checked) == f.crc else { throw SBProtocolError.invalid("Binary sample checksum failed.") }
                buffer.removeFirst(size + 1)
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                lines.append("SB1 DATA \(f.token) \(f.offset) \(hex)")
                offset += UInt32(f.count); frame = nil
                continue
            }
            guard let end = buffer.firstIndex(of: 10) else {
                guard buffer.count <= 2048 else { throw SBProtocolError.invalid("Device line exceeded its limit.") }
                break
            }
            let bytes = buffer.prefix(upTo: end)
            guard bytes.count <= 2048, let raw = String(data: bytes, encoding: .utf8) else { throw SBProtocolError.invalid("Invalid device text.") }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            buffer.removeSubrange(...end)
            let fields = line.split(separator: " ")
            if fields.starts(with: ["SB1", "BINARY"]) {
                guard allowBinary, fields.count == 6, String(fields[2]) == token,
                      let start = UInt32(fields[3]), start == offset,
                      let count = UInt16(fields[4]), (1...128).contains(count),
                      start + UInt32(count) <= 32768,
                      fields[5].count == 8, let crc = UInt32(fields[5], radix: 16) else {
                    throw SBProtocolError.invalid("Invalid binary sample frame.")
                }
                frame = (String(fields[2]), start, count, crc)
            } else {
                if fields.starts(with: ["SB1", "BEGIN"]), fields.count >= 3 {
                    token = String(fields[2]); offset = 0
                }
                if fields.starts(with: ["SB1", "END"]) { token = nil; offset = 0 }
                lines.append(line)
            }
        }
        return lines
    }
}
