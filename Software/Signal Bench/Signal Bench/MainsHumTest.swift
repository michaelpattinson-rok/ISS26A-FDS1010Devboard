import Foundation

nonisolated struct MainsHumCapture: Codable, Equatable, Sendable {
    enum Step: String, CaseIterable, Identifiable, Codable, Sendable {
        case battery100, battery500, plugged100, plugged500
        var id: Self { self }
        var battery: Bool { self == .battery100 || self == .battery500 }
        var rate: Int { self == .battery100 || self == .plugged100 ? 100_000 : 500_000 }
        var power: String { battery ? "On Battery" : "Charger Connected" }
        var title: String { "\(power) · \(rate.formatted()) samples/s" }
    }

    static let seconds: Double = 20
    let test: UUID
    let step: Step

    var runName: String { "60 Hz Test · \(step.power) · \(step.rate.formatted()) samples per second" }

    var settings: StreamRunSettings {
        .init(mode: .diagnosis, nominalRate: step.rate, duration: Self.seconds,
              wiring: "Standard J2, GP26 / ADC0, J1 empty, optional probes disconnected",
              gain: "LOW", acquisitionBoard: .picoW, mainsHum: self)
    }

    func matches(_ settings: StreamRunSettings) -> Bool {
        settings.mode == .diagnosis && settings.board == .picoW && settings.channel == 0 &&
        settings.nominalRate == step.rate && settings.duration == Self.seconds && settings.gain == "LOW" &&
        settings.adcAveraging == nil && settings.picoAveraging == nil
    }

    struct Reading: Sendable {
        var samples: UInt64 = 0
        var low: UInt64 = 0
        var high: UInt64 = 0
        var errors: UInt64 = 0
        var usableSeconds: Double = 0
        var humRMS: Double?
        var comparisonIssue: String?
        var sampledSeconds: Double = 0
        var cadence: Double = 0
        var selection: StreamSelection?
        var railed: UInt64 { low + high }
    }

    static func analyze(_ original: StreamRangeReader) throws -> Reading {
        let reader = try original.prepared()
        let run = reader.run
        var result = Reading()
        guard let capture = run.settings.mainsHum, capture.matches(run.settings) else {
            throw StreamFailure.storage("This run is not a 60 Hz test capture.")
        }
        let duration = try reader.duration()
        guard duration > 0, run.segments.count == 1, let segment = run.segments.first else {
            result.comparisonIssue = "No single saved capture is available."
            return result
        }
        guard duration <= Self.seconds + 10 else {
            result.comparisonIssue = "The capture exceeds the expected duration."
            return result
        }
        result = try analyzeRange(reader, segment: segment, selection: .init(lower: 0, upper: duration))
        if run.status != .complete || segment.deadlineReached != true {
            result.comparisonIssue = "Capture ended early. Repeat this step."
        } else if segment.unknown || segment.knownLoss > 0 || run.hasCadenceMismatch ||
                    result.samples != segment.savedSamples || segment.accountedSamples != result.samples {
            result.comparisonIssue = "Sample coverage or cadence did not reconcile."
        } else if result.railed > 0 {
            result.comparisonIssue = "Clipping limits this reading. Check the analog path."
        } else if result.errors > 0 {
            result.comparisonIssue = "ADC errors were saved. Repeat this step."
        } else if result.usableSeconds < 18 {
            result.comparisonIssue = "Less than 18 seconds of usable data."
        }
        return result
    }
    static func compare(_ original: StreamRangeReader, segmentID: UUID, start: Double) throws -> Reading {
        let reader = try original.prepared()
        let run = reader.run
        guard run.status != .recording, run.curveSource == nil,
              let segment = run.segments.first(where: { $0.id == segmentID }) else {
            throw StreamFailure.storage("Choose a saved recording segment with original ADC readings.")
        }
        guard run.settings.adcAveraging == nil, segment.picoAveraging == nil,
              run.settings.picoAveraging == nil else {
            throw StreamFailure.storage("The 60 Hz comparison requires original readings recorded at 1×.")
        }
        let configured = segment.configuredRate(run.settings.nominalRate)
        let summaries = reader.index ?? []
        guard let end = summaries.lazy.filter({ $0.segment == segment.id }).map(\.end).max(),
              start.isFinite, start >= 0, start < Double(end) / configured else {
            throw StreamFailure.storage("The start is outside the saved part of this segment.")
        }
        let lower = segment.timelineStart + start
        let upper = min(segment.timelineStart + Double(end) / configured, lower + seconds)
        var result = try analyzeRange(reader, segment: segment, selection: .init(lower: lower, upper: upper))
        if run.status == .interrupted || segment.unknown {
            result.comparisonIssue = "Verified saved prefix. Some recording coverage is unknown."
        } else if result.railed > 0 || result.errors > 0 {
            result.comparisonIssue = "Windows with clipping or ADC errors were excluded."
        } else if result.humRMS == nil {
            result.comparisonIssue = "No intact one second window is available."
        }
        return result
    }

    private static func analyzeRange(_ reader: StreamRangeReader, segment: StreamRunSegment,
                                     selection: StreamSelection) throws -> Reading {
        let run = reader.run
        // A device cadence is preferable. Use the verified ADC configuration if
        // this firmware did not report a timer measurement.
        let configured = segment.configuredRate(run.settings.nominalRate)
        let measured = segment.measuredByPicoTimer
        let rate = measured.flatMap { (configured * 0.99...configured * 1.01).contains($0) ? $0 : nil } ?? configured
        var result = Reading(selection: selection)
        result.cadence = rate
        var tone = HumProjection(rate: rate)
        var next: UInt64?
        try reader.visit(selection) { part in
            guard part.reference.segment == segment.id else { return }
            if next != part.reference.first { tone.resetWindow() }
            next = part.reference.first + UInt64(part.reference.count)
            part.words.withUnsafeBytes { bytes in
                for offset in 0..<part.reference.count {
                    let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset * 2, as: UInt16.self))
                    let code = segment.board.sampleCode(word)
                    let invalid = word & 0x8000 != 0
                    result.samples += 1
                    if invalid { result.errors += 1 }
                    else if code == 0 { result.low += 1 }
                    else if code == segment.board.maxCode { result.high += 1 }
                    tone.append(Double(code), usable: !invalid && code != 0 && code != segment.board.maxCode)
                }
            }
        }
        result.sampledSeconds = Double(result.samples) / rate
        let levels = tone.levels.sorted()
        result.usableSeconds = Double(levels.count * tone.length) / rate
        if !levels.isEmpty {
            result.humRMS = (levels[(levels.count - 1) / 2] + levels[levels.count / 2]) / 2
        }
        return result
    }

}

/// Fits a DC offset and a 60 Hz sinusoid in each contiguous one second
/// interval. A gap, ADC fault or rail prevents that window from contributing.
nonisolated struct HumProjection {
    let length: Int
    private let rotation: (Double, Double)
    private var up: Double = 1
    private var down: Double = 0
    private var n = 0
    private var usable = true
    private var y = 0.0, c = 0.0, s = 0.0, cc = 0.0, ss = 0.0, cs = 0.0, yc = 0.0, ys = 0.0
    private(set) var levels: [Double] = []

    init(rate: Double) {
        length = Int(rate.rounded())
        let phase = 2 * Double.pi * 60 / rate
        rotation = (cos(phase), sin(phase))
    }

    mutating func append(_ code: Double, usable: Bool) {
        self.usable = self.usable && usable
        y += code
        c += up; s += down
        cc += up * up; ss += down * down; cs += up * down
        yc += code * up; ys += code * down
        (up, down) = (up * rotation.0 - down * rotation.1, up * rotation.1 + down * rotation.0)
        n += 1
        if n == length {
            if self.usable {
                let count = Double(n)
                let a = cc - c * c / count
                let b = cs - c * s / count
                let d = ss - s * s / count
                let u = yc - y * c / count
                let v = ys - y * s / count
                let determinant = a * d - b * b
                levels.append(hypot((d * u - b * v) / determinant, (a * v - b * u) / determinant) / sqrt(2))
            }
            resetWindow()
        }
    }

    mutating func resetWindow() {
        n = 0
        usable = true
        up = 1; down = 0
        y = 0; c = 0; s = 0; cc = 0; ss = 0; cs = 0; yc = 0; ys = 0
    }
}
