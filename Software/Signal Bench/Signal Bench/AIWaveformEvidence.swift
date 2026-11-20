import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct AIWaveformEvidence: Encodable, Sendable {
    struct Bin: Encodable, Sendable {
        var saved = 0
        var valid = 0
        var low: Double?
        var high: Double?
        var mean: Double?
        var lowRails = 0
        var highRails = 0
        var errors = 0

        mutating func ingest(_ reading: WaveformSample) {
            saved += 1
            if reading.error { errors += 1 }
            if reading.low { lowRails += 1 }
            if reading.high { highRails += 1 }
            guard !reading.error, !reading.clipped else { return }
            let value = reading.value
            valid += 1
            low = min(low ?? value, value)
            high = max(high ?? value, value)
            let previous = mean ?? value
            mean = previous + (value - previous) / Double(valid)
        }
    }

    let range: ReviewRange
    let readingsPerBin: UInt64
    let nominalSeconds: StreamSelection
    let recordedRate: Double
    let adcMaximum: UInt16
    let board: AcquisitionBoard
    let sourceHash: String
    let savedReadings: UInt64
    let missingReadings: UInt64
    let unknownTail: Bool
    let totalsCountGroups: Bool
    let displayLow: Double
    let displayHigh: Double
    let bins: [Bin]
    let gaps: Bool
    let evidence = "Fresh verified raw range. Bins show valid min, max and mean. Markers indicate faults. Empty bins and internal gaps are not drawn as a trace."

    static func make(_ reader: StreamRangeReader, range: ReviewRange, selection: StreamSelection) throws -> Self {
        guard let segment = reader.run.segments.first(where: { $0.id == range.segment }),
              selection.upper - selection.lower <= 30.0000001 else {
            throw ReviewWorkerError.invalid("Choose up to 30 seconds in one timing segment.")
        }
        var last = range.first
        var hash = SHA256()
        let binSize = (range.count + 95) / 96
        let count = Int((range.count + binSize - 1) / binSize)
        var bins = [Bin](repeating: .init(), count: count)
        var saved: UInt64 = 0
        var gaps = false
        try reader.visit(selection) { part in
            guard part.segment.id == range.segment else { return }
            let first = max(range.first, part.reference.first)
            let end = min(range.end, part.reference.first + UInt64(part.reference.count))
            guard first < end else { return }
            hash.update(data: try StreamFiles.encoder.encode(part.reference))
            hash.update(data: Data([10]))
            if last != first { gaps = true }
            last = end
            saved += end - first
            for index in first..<end {
                let bin = Int((index - range.first) / binSize)
                bins[bin].ingest(part.sample(at: Int(index - part.reference.first)))
            }
        }
        let unknownTail = segment.unknown && range.end > last
        let codeMaximum = reader.run.settings.board.maxCode
        let low = bins.compactMap(\.low).min() ?? 0
        let high = bins.compactMap(\.high).max() ?? Double(codeMaximum)
        let padding = max(1, (high - low) * 0.08)
        return .init(range: range, readingsPerBin: binSize, nominalSeconds: selection,
                     recordedRate: segment.configuredRate(reader.run.settings.nominalRate),
                     adcMaximum: codeMaximum, board: segment.board, sourceHash: hash.finalize().map { String(format: "%02x", $0) }.joined(), savedReadings: saved,
                     missingReadings: range.count - min(range.count, saved), unknownTail: unknownTail,
                     totalsCountGroups: segment.factor > 1, displayLow: low - padding, displayHigh: high + padding,
                     bins: bins, gaps: gaps || saved != range.count)
    }

    struct ImageSummary: Encodable {
        let range: ReviewRange
        let nominalSeconds: StreamSelection
        let recordedRate: Double
        let durationSeconds: Double
        let board: AcquisitionBoard
        let adcMaximum: UInt16
        let readingsPerBin: UInt64
        let sourceHash: String
        let minimumCode: Double?
        let maximumCode: Double?
        let savedReadings: UInt64
        let lowRails: Int
        let highRails: Int
        let errors: Int
        let missingReadings: UInt64
        let unknownTail: Bool
        let totalsCountGroups: Bool
        let evidence: String
    }

    var imageSummary: ImageSummary {
        .init(range: range, nominalSeconds: nominalSeconds, recordedRate: recordedRate,
              durationSeconds: Double(range.count) / recordedRate, board: board, adcMaximum: adcMaximum,
              readingsPerBin: readingsPerBin, sourceHash: sourceHash,
              minimumCode: bins.compactMap(\.low).min(), maximumCode: bins.compactMap(\.high).max(),
              savedReadings: savedReadings, lowRails: bins.reduce(0) { $0 + $1.lowRails },
              highRails: bins.reduce(0) { $0 + $1.highRails }, errors: bins.reduce(0) { $0 + $1.errors },
              missingReadings: missingReadings, unknownTail: unknownTail, totalsCountGroups: totalsCountGroups, evidence: evidence)
    }

    func png() throws -> Data {
        try Self.render { context in
            Self.label("ADC waveform    •    binned overview", x: 32, y: 305, on: context, size: 18)
            let left = 62.0, bottom = 60.0, width = 552.0, height = 215.0
            context.setStrokeColor(red: 0.80, green: 0.84, blue: 0.89, alpha: 1)
            for fraction in [0.0, 0.5, 1.0] {
                let y = bottom + fraction * height
                context.move(to: .init(x: left, y: y))
                context.addLine(to: .init(x: left + width, y: y))
                context.strokePath()
                Self.label(String(format: "%.1f", displayLow + fraction * (displayHigh - displayLow)),
                           x: 8, y: y - 4, on: context)
            }
            let stride = width * Double(readingsPerBin) / Double(range.count)
            func point(_ value: Double) -> Double {
                bottom + (value - displayLow) / (displayHigh - displayLow) * height
            }
            for (i, bin) in bins.enumerated() {
                let x = left + Double(i) * stride
                let w = min(stride, left + width - x)
                let expected = min(readingsPerBin, range.count - UInt64(i) * readingsPerBin)
                if bin.saved == 0 {
                    context.setFillColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1)
                    context.fill(.init(x: x, y: bottom, width: w, height: height))
                }
                if let low = bin.low, let high = bin.high, let mean = bin.mean {
                    context.setFillColor(red: 0.32, green: 0.57, blue: 0.91, alpha: 1)
                    context.fill(.init(x: x + w * 0.25, y: point(low), width: w * 0.5, height: max(1, point(high) - point(low))))
                    context.setFillColor(red: 0.04, green: 0.24, blue: 0.56, alpha: 1)
                    context.fill(.init(x: x + w * 0.15, y: point(mean), width: w * 0.7, height: 2))
                }
                context.setFillColor(red: 0.83, green: 0.30, blue: 0.08, alpha: 1)
                if bin.highRails > 0 { context.fill(.init(x: x, y: bottom + height + 5, width: w, height: 5)) }
                if bin.lowRails > 0 { context.fill(.init(x: x, y: bottom - 10, width: w, height: 5)) }
                if bin.errors > 0 {
                    context.setFillColor(red: 0.55, green: 0.12, blue: 0.57, alpha: 1)
                    context.fill(.init(x: x, y: bottom - 17, width: w, height: 5))
                }
                if UInt64(bin.saved) < expected {
                    context.setFillColor(red: 0.42, green: 0.45, blue: 0.52, alpha: 1)
                    context.fill(.init(x: x, y: bottom - 23, width: w, height: 2))
                }
            }
            Self.label(String(format: "Elapsed %.6f to %.6f s    |    readings %llu to %llu (exclusive)",
                              nominalSeconds.lower, nominalSeconds.upper, range.first, range.end), x: 32, y: 21, on: context)
            Self.label("Blue: min / mean / max   Orange: rails   Purple: ADC errors   Gray: coverage", x: 32, y: 5, on: context)
        }
    }

    static func probe(blueOnLeft: Bool) throws -> Data {
        try render { context in
            let blue = CGColor(red: 0.04, green: 0.30, blue: 0.95, alpha: 1)
            let orange = CGColor(red: 0.97, green: 0.40, blue: 0.04, alpha: 1)
            context.setFillColor(blueOnLeft ? blue : orange)
            context.fill(.init(x: 45, y: 50, width: 250, height: 240))
            context.setFillColor(blueOnLeft ? orange : blue)
            context.fill(.init(x: 345, y: 50, width: 250, height: 240))
        }
    }

    private static func render(_ draw: (CGContext) -> Void) throws -> Data {
        guard let context = CGContext(data: nil, width: 640, height: 336, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ReviewWorkerError.invalid("A waveform image could not be rendered.")
        }
        context.setFillColor(red: 0.97, green: 0.98, blue: 1, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 640, height: 336))
        draw(context)
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let sink = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw ReviewWorkerError.invalid("A waveform image could not be encoded.")
        }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink), bytes.length <= 48_000 else { throw ReviewWorkerError.limit }
        return bytes as Data
    }

    private static func label(_ text: String, x: Double, y: Double, on context: CGContext, size: Double = 11) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.12, green: 0.19, blue: 0.28, alpha: 1)
        ]))
        context.textPosition = .init(x: x, y: y)
        CTLineDraw(line, context)
    }
}
