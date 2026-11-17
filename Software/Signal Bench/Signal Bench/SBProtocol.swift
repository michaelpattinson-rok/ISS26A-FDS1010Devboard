import Foundation

enum SBProtocolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct SBRecordAssembler {
    let token: String
    private(set) var metadata: [String: String] = [:]
    private(set) var events: [[String: String]] = []
    private(set) var samples: [UInt16] = []
    private var expected: Int?
    private var bytes: [UInt8] = []
    private var metadataBytes: [UInt8] = []
    private var metadataVerified = false
    private var phase = 0

    nonisolated static func fields(_ strings: ArraySlice<Substring>) -> [String: String] {
        var values: [String: String] = [:]
        for s in strings { let p = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false); if p.count == 2 { values[String(p[0])] = String(p[1]) } }
        return values
    }
    mutating func accept(_ line: String) throws -> (complete: Bool, crc: UInt32?) {
        let p = line.split(separator: " ")
        guard p.count >= 3, p[0] == "SB1", p[2] == Substring(token) else { throw SBProtocolError.invalid("Record identity mismatch.") }
        switch p[1] {
        case "BEGIN":
            guard phase == 0, expected == nil else { throw SBProtocolError.invalid("Duplicate record header.") }
            metadata = Self.fields(p.dropFirst(3))
            guard let n = metadata["n"].flatMap(Int.init), (0...32768).contains(n) else { throw SBProtocolError.invalid("Invalid sample count.") }
            guard metadata.count == p.count - 3, ["tag", "sample_hz", "gain", "calibration_id", "calibrated", "acq_flags", "quality_flags", "baseline", "baseline_rms", "sigma", "threshold", "tail_baseline_shift", "adc_errors", "clipped_samples", "usable", "start_us", "end_us", "gap_before_us", "observation_samples", "dead_samples", "analysis_start", "analysis_end", "candidates", "stored", "rate_exposure_valid"].allSatisfy({ metadata[$0] != nil }), metadata["rate_exposure_valid"] == "0" else { throw SBProtocolError.invalid("Record metadata is missing or incompatible.") }
            guard ["CAL", "BACKGROUND", "SOURCE", "MANUAL", "STAGE"].contains(metadata["tag"] ?? ""), ["LOW", "HIGH"].contains(metadata["gain"] ?? ""), ["0", "1"].contains(metadata["calibrated"] ?? ""), ["0", "1"].contains(metadata["usable"] ?? ""), let hz = metadata["sample_hz"].flatMap(Double.init), hz.isFinite, hz > 0, ["baseline", "baseline_rms", "sigma", "threshold", "tail_baseline_shift"].allSatisfy({ key in metadata[key].flatMap(Double.init)?.isFinite == true }), ["calibration_id", "acq_flags", "quality_flags", "adc_errors", "clipped_samples", "start_us", "end_us", "gap_before_us", "observation_samples", "dead_samples", "analysis_start", "analysis_end", "candidates", "stored"].allSatisfy({ key in metadata[key].flatMap(UInt64.init) != nil }), let stored = metadata["stored"].flatMap(Int.init), stored <= 48, let candidates = metadata["candidates"].flatMap(Int.init), stored <= candidates, candidates <= n, let start = metadata["start_us"].flatMap(UInt64.init), let end = metadata["end_us"].flatMap(UInt64.init), end >= start, let observation = metadata["observation_samples"].flatMap(Int.init), observation <= n, let dead = metadata["dead_samples"].flatMap(Int.init), dead <= observation, let analysisStart = metadata["analysis_start"].flatMap(Int.init), let analysisEnd = metadata["analysis_end"].flatMap(Int.init), analysisStart <= analysisEnd, analysisEnd <= n, let adcErrors = metadata["adc_errors"].flatMap(Int.init), adcErrors <= n, let clipped = metadata["clipped_samples"].flatMap(Int.init), clipped <= n else { throw SBProtocolError.invalid("Record metadata values are invalid.") }
            if metadata["usable"] == "1" {
                guard metadata["tag"] != "CAL", metadata["calibrated"] == "1", metadata["acq_flags"].flatMap(UInt64.init) == 0, metadata["quality_flags"].flatMap(UInt64.init) == 0 else { throw SBProtocolError.invalid("Record qualification conflicts with its acquisition status.") }
            }
            metadataBytes.append(contentsOf: (line + "\n").utf8)
            expected = n; phase = 1
        case "EVENT":
            guard phase == 1, let count = expected, events.count < 48 else { throw SBProtocolError.invalid("Invalid event sequence.") }
            let event = Self.fields(p.dropFirst(3))
            guard event.count == p.count - 3, ["index", "start", "peak", "end", "delta_codes", "local_baseline", "local_offset", "local_slope", "local_sigma", "baseline_tolerance", "slope_tolerance", "negative_tail", "above", "contiguous", "flags", "qualified"].allSatisfy({ event[$0] != nil }), let index = event["index"].flatMap(Int.init), index == events.count, let start = event["start"].flatMap(Int.init), let peak = event["peak"].flatMap(Int.init), let end = event["end"].flatMap(Int.init), start >= 0, start <= peak, peak < count, end > peak, end <= count else { throw SBProtocolError.invalid("Invalid event metadata.") }
            guard ["delta_codes", "local_baseline", "local_offset", "local_slope", "local_sigma", "baseline_tolerance", "slope_tolerance", "negative_tail"].allSatisfy({ key in event[key].flatMap(Double.init)?.isFinite == true }), event["flags"].flatMap(UInt64.init) != nil, let above = event["above"].flatMap(Int.init), above >= 0, above <= end - start, let width = event["contiguous"].flatMap(Int.init), width >= 0, width <= above, ["0", "1"].contains(event["qualified"] ?? "") else { throw SBProtocolError.invalid("Invalid event values.") }
            if event["qualified"] == "1" {
                guard metadata["usable"] == "1", event["flags"].flatMap(UInt64.init) == 0 else { throw SBProtocolError.invalid("Candidate qualification conflicts with its record status.") }
            }
            metadataBytes.append(contentsOf: (line + "\n").utf8)
            events.append(event)
        case "DATA":
            guard (phase == 1 || phase == 2), let n = expected, p.count == 5, let offset = Int(p[3]), offset == samples.count else { throw SBProtocolError.invalid("Missing or out of order samples.") }
            phase = 2
            let hex = Array(p[4].utf8)
            guard !hex.isEmpty, hex.count <= 512, hex.count % 4 == 0, samples.count + hex.count / 4 <= n else { throw SBProtocolError.invalid("Invalid sample block.") }
            func nibble(_ x: UInt8) -> UInt8? { if x >= 48 && x <= 57 { return x-48 }; if x >= 97 && x <= 102 { return x-87 }; if x >= 65 && x <= 70 { return x-55 }; return nil }
            for i in stride(from: 0, to: hex.count, by: 4) {
                guard let a=nibble(hex[i]), let b=nibble(hex[i+1]), let c=nibble(hex[i+2]), let d=nibble(hex[i+3]) else { throw SBProtocolError.invalid("Invalid sample encoding.") }
                let lo=a*16+b, hi=c*16+d; bytes.append(contentsOf: [lo,hi]); samples.append(UInt16(lo) | (UInt16(hi)<<8))
            }
        case "META":
            guard (phase == 1 || phase == 2), samples.count == expected, p.count == 4, !metadataVerified, let checksum = UInt32(p[3], radix: 16), p[3].count == 8, checksum == Self.crc32(metadataBytes) else { throw SBProtocolError.invalid("Record metadata checksum does not match.") }
            metadataVerified = true; phase = 3
        case "END":
            guard phase == 3, metadataVerified, p.count == 5, let n = expected, let endN = Int(p[3]), endN == n, samples.count == n, let checksum = UInt32(p[4], radix: 16), p[4].count == 8, checksum == Self.crc32(bytes) else { throw SBProtocolError.invalid("Record is incomplete or its checksum does not match.") }
            guard let stored = metadata["stored"].flatMap(Int.init), stored == events.count else { throw SBProtocolError.invalid("Event count does not match.") }
            phase = 4; return (true, checksum)
        default: throw SBProtocolError.invalid("Unknown record message.")
        }
        return (false, nil)
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
        return crc ^ 0xffffffff
    }
}
