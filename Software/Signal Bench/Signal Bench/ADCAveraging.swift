import Foundation

nonisolated enum ADCAveraging: Int, CaseIterable, Codable, Sendable {
    case four = 4, eight = 8, sixteen = 16, thirtyTwo = 32, sixtyFour = 64

    static let sourceRate = 500_000

    var count: Int { rawValue }
    var shift: Int { count.trailingZeroBitCount }
    var idealBitGain: Double { Double(shift) / 2 }

    func rate(from source: Double = Double(sourceRate)) -> Double { source / Double(count) }

    var title: String {
        "\(rate().formatted(.number.precision(.fractionLength(0...1)))) samples/s · Average \(count)"
    }

    struct Group: Encodable, Sendable {
        let first: UInt64
        let count: Int
        var sum: UInt64 = 0
        var adcErrors = 0
        var lowRail = 0
        var highRail = 0

        var mean: Double? {
            guard adcErrors == 0, lowRail == 0, highRail == 0 else { return nil }
            return Double(sum) / Double(count)
        }

        mutating func add(_ word: UInt16) {
            if word & 0x8000 != 0 {
                adcErrors += 1
                return
            }
            let code = word & 4095
            if code == 0 { lowRail += 1 }
            if code == 4095 { highRail += 1 }
            sum += UInt64(code)
        }
    }

    /// Returns the last complete, aligned group in this preview frame.
    func latest(in words: [UInt16], at first: UInt64) -> Group? {
        let end = first + UInt64(words.count)
        let boundary = end - end % UInt64(count)
        guard boundary >= first + UInt64(count) else { return nil }
        let start = boundary - UInt64(count)
        var group = Group(first: start, count: count)
        let offset = Int(start - first)
        for word in words[offset..<(offset + count)] { group.add(word) }
        return group
    }

    /// Aligns to the original sample grid. Incomplete groups at gaps, segment
    /// changes, and selection edges are omitted, never padded.
    struct Series {
        let preset: ADCAveraging
        private var segment: UUID?
        private var next: UInt64?
        private var group: Group?

        init(_ preset: ADCAveraging) { self.preset = preset }

        mutating func append(_ part: StreamRangeData, emit: (Group) throws -> Void) throws {
            let first = part.reference.first
            if segment != part.reference.segment || next != first { group = nil }
            segment = part.reference.segment
            next = first + UInt64(part.reference.count)

            try part.words.withUnsafeBytes { bytes in
                for offset in 0..<part.reference.count {
                    let index = first + UInt64(offset)
                    if index % UInt64(preset.count) == 0 {
                        group = Group(first: index, count: preset.count)
                    }
                    guard group != nil else { continue }
                    let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * offset, as: UInt16.self))
                    group?.add(word)
                    if let finished = group, index - finished.first == UInt64(preset.count - 1) {
                        try emit(finished)
                        group = nil
                    }
                }
            }
        }
    }
}

nonisolated struct ADCAveragedCSV {
    private(set) var groups = 0
    private var series: ADCAveraging.Series
    private var output: StreamOutput

    init(preset: ADCAveraging, output: StreamOutput) throws {
        series = .init(preset)
        self.output = output
        try header()
    }

    mutating func beginPart(_ output: StreamOutput) throws {
        self.output = output
        try header()
    }

    private func header() throws {
        try output.line("segment,stream_id,first_index,end_index_exclusive,center_nominal_time_s,effective_samples_per_second,raw_samples,mean_adc_code,adc_errors,low_rail,high_rail")
    }

    mutating func append(_ part: StreamRangeData) throws {
        let rate = part.configuredRate
        let effective = String(series.preset.rate(from: rate))
        let start = part.segment.timelineStart
        let prefix = "\(part.segment.id),\(part.segment.stream),"
        var rows = Data()
        var count = 0
        try series.append(part) { group in
            count += 1
            let center = start + (Double(group.first) + Double(group.count - 1) / 2) / rate
            let mean = group.mean.map { String($0) } ?? ""
            rows.append(contentsOf: "\(prefix)\(group.first),\(group.first + UInt64(group.count)),\(center),\(effective),\(group.count),\(mean),\(group.adcErrors),\(group.lowRail),\(group.highRail)\n".utf8)
        }
        if !rows.isEmpty { try output.write(rows) }
        groups += count
    }

    func finish(file: String = "averaged.csv") throws -> StreamAnalysisOutput {
        try output.finish(file: file, type: "signalbench.adc-block-means")
    }
}

/// AVG1 stores integer sums and source quality, never a rounded mean.
nonisolated enum PicoAverage {
    static let wireFlag: UInt32 = 4
    static let version = 1

    static func stride(_ factor: ADCAveraging?) -> Int {
        guard let factor else { return 2 }
        return (15 + 4 * factor.shift + 7) / 8
    }

    static func group(_ bytes: UnsafeRawBufferPointer, offset: Int, first: UInt64, factor: ADCAveraging) -> ADCAveraging.Group? {
        let n = factor.count, sumBits = 12 + factor.shift, countBits = 1 + factor.shift
        var packed: UInt64 = 0
        for i in 0..<stride(factor) { packed |= UInt64(bytes[offset + i]) << (8 * i) }
        let mask = (UInt64(1) << countBits) - 1
        let sum = packed & ((UInt64(1) << sumBits) - 1)
        let errors = Int((packed >> sumBits) & mask)
        let low = Int((packed >> (sumBits + countBits)) & mask)
        let high = Int((packed >> (sumBits + 2 * countBits)) & mask)
        let ordinary = n - errors - low - high
        guard packed >> (sumBits + 3 * countBits) == 0, ordinary >= 0,
              sum >= UInt64(high * 4095 + ordinary), sum <= UInt64(high * 4095 + ordinary * 4094) else { return nil }
        return .init(first: first, count: n, sum: sum, adcErrors: errors, lowRail: low, highRail: high)
    }

    static func groups(_ payload: Data, first: UInt64, factor: ADCAveraging) throws -> [ADCAveraging.Group] {
        let size = stride(factor)
        guard payload.count.isMultiple(of: size) else { throw StreamFailure.protocolError("An averaged reading was truncated.") }
        return try payload.withUnsafeBytes { bytes in
            try (0..<(bytes.count / size)).map { index in
                guard let value = group(bytes, offset: index * size, first: (first + UInt64(index)) * UInt64(factor.count), factor: factor) else {
                    throw StreamFailure.protocolError("An averaged reading has impossible sum or quality counts.")
                }
                return value
            }
        }
    }

    // Internal projection for legacy masks and integer envelope bins. The exact
    // group, including both rail counts, remains available beside this value.
    static func projectedWord(_ group: ADCAveraging.Group) -> UInt16 {
        if let mean = group.mean { return UInt16(mean.rounded()) }
        return 0x8000 | (group.lowRail > 0 ? 0x1000 : 0) | (group.highRail > 0 ? 0x2000 : 0) |
            (group.adcErrors > 0 ? 0x4000 : 0)
    }
}
