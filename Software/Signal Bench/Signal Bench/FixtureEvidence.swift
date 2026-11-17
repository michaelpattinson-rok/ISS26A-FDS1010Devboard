import Foundation

nonisolated struct StreamFixtureReference: Codable, Sendable {
    var version: Int
    var stream: UInt64
    var source: String
    var clockAlignment: String
    var anchorReferenceUS: Double
    var anchorSampleIndex: UInt64
    var sampleRateHz: Double
    var uncertaintyUS: Double
    var pulsesUS: [Double]
    // Version 2 optionally supplies independently measured ADC0 peak heights
    // in code-equivalent units. Version 1 timing files still open unchanged.
    var amplitudesADC: [Double]? = nil

    var valid: Bool {
        (1...2).contains(version) && stream != 0 && anchorSampleIndex <= 3_600_000_000
        && anchorReferenceUS.isFinite && (156...500_001).contains(sampleRateHz)
        && (0.1...100_000).contains(uncertaintyUS) && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !clockAlignment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && source.utf8.count <= 512 && clockAlignment.utf8.count <= 2048
        && (1...20_000).contains(pulsesUS.count) && pulsesUS.allSatisfy(\.isFinite)
        && zip(pulsesUS, pulsesUS.dropFirst()).allSatisfy { $0 < $1 }
        && pulsesUS.allSatisfy { abs($0 - anchorReferenceUS) <= 86_400_000_000 }
        && (amplitudesADC.map { values in
            version == 2 && values.count == pulsesUS.count && values.allSatisfy { (0.01...4095).contains($0) }
        } ?? true)
    }

    func index(_ time: Double) -> Double {
        Double(anchorSampleIndex) + (time - anchorReferenceUS) * sampleRateHz / 1_000_000
    }

    var uncertaintySamples: Double { uncertaintyUS * sampleRateHz / 1_000_000 }
}

nonisolated struct FixtureTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var run: UUID
    var source: [StreamRangeReference]
    var referenceHash: String
    var range: ReviewRange
    var gain: String
    var polarity: ProfilePulseRules.Polarity
    var drift: Bool
    var notch60: Bool
    var notch120: Bool
    var peakOffset: Int
    var shape: [Double]
    var nominalRate: Int? = nil
    var picoAveraging: ADCAveraging? = nil
    var setup: CalibrationSetup? = nil
    var acquisitionBoard: AcquisitionBoard? = nil
    var board: AcquisitionBoard { acquisitionBoard ?? .picoW }
    var valid: Bool {
        StreamWire.customRates.contains(nominalRate ?? StreamWire.rate) && (16...2048).contains(shape.count) && shape.indices.contains(peakOffset) && shape.allSatisfy { $0.isFinite && abs($0) <= 1 }
        && shape.contains { abs($0) > 0 } && ["LOW", "HIGH"].contains(gain) && ProfileDigest.valid(referenceHash)
        && ((picoAveraging == nil && board == .picoW) || (setup?.valid == true && setup?.picoAveraging == picoAveraging &&
            setup?.acquisitionDevice == board && setup?.nominalHz == nominalRate && setup?.gain == gain))
        && range.count == shape.count && !source.isEmpty && source.count <= 512 && source.allSatisfy { ProfileDigest.valid($0.sha256) }
    }

    func score(_ values: [Double], center: Int, mask: [Bool]) -> Double? {
        let first = center - peakOffset
        guard first >= 0, first + shape.count <= values.count else { return nil }
        var sum = 0.0, square = 0.0, cross = 0.0
        for (offset, weight) in shape.enumerated() {
            let i = first + offset
            guard !mask[i], values[i].isFinite else { return nil }
            sum += values[i]
            square += values[i] * values[i]
            cross += values[i] * weight
        }
        let variance = square - sum * sum / Double(shape.count)
        return variance > 0 ? max(-1, min(1, cross / sqrt(variance))) : nil
    }
}

nonisolated struct FixtureComparison: Codable, Sendable {
    var matched = 0
    var missed = 0
    var missingCoverage = 0
    var ambiguous = 0
    var extraMatches = 0
}

nonisolated enum FixtureEvidence {
    static func reference(_ reader: StreamRangeReader) throws -> (StreamFixtureReference, String) {
        let run = try reader.store.runDirectory(reader.run.id)
        let bytes = try StreamFiles.read(run.appendingPathComponent("fixture-reference.json"), limit: 1_048_576)
        let value = try StreamFiles.decoder.decode(StreamFixtureReference.self, from: bytes)
        guard reader.run.settings.bench?.step == .fixture, value.valid,
              abs(value.sampleRateHz - reader.run.settings.recordedRate) <= reader.run.settings.recordedRate / 100,
              reader.run.segments.contains(where: { $0.stream == value.stream }) else {
            throw StreamFailure.storage("The independent timing reference does not match this fixture stream.")
        }
        return (value, StreamFiles.sha(bytes))
    }

    static func importReference(_ url: URL, reader: StreamRangeReader) throws {
        let bytes = try StreamFiles.read(url, limit: 1_048_576)
        let value = try StreamFiles.decoder.decode(StreamFixtureReference.self, from: bytes)
        guard reader.run.settings.bench?.step == .fixture, value.valid,
              abs(value.sampleRateHz - reader.run.settings.recordedRate) <= reader.run.settings.recordedRate / 100,
              reader.run.segments.contains(where: { $0.stream == value.stream }) else {
            throw StreamFailure.storage("Choose a version 1 or 2 timing reference for this fixture run and stream ID.")
        }
        let root = try reader.store.runDirectory(reader.run.id)
        try StreamFiles.publish(bytes, at: root.appendingPathComponent("fixture-reference.json"))
    }

    static func createTemplate(_ reader: StreamRangeReader, selection: StreamSelection, settings: ReviewSettings) throws -> FixtureTemplate {
        let (reference, hash) = try reference(reader)
        let input = try ReviewInput.load(reader, selection: selection)
        let rate = reader.run.settings.nominalRate
        let configured = reader.run.settings.recordedRate
        guard let span = input.spans.first(where: {
            guard $0.segment.stream == reference.stream else { return false }
            let bounds = ReviewInput.indices(selection, segment: $0.segment, rate: rate)
            return $0.first <= bounds.lowerBound && $0.end >= bounds.upperBound
        }) else {
            throw StreamFailure.storage("The selection must fit inside one contiguous span on the independently timed stream.")
        }
        let bound = ReviewInput.indices(selection, segment: span.segment, rate: rate)
        let start = Int(bound.lowerBound - span.first), end = Int(bound.upperBound - span.first)
        func clean(_ word: UInt16) -> Bool { word & 0x8000 == 0 && (1..<span.segment.board.maxCode).contains(span.segment.board.sampleCode(word)) }
        guard (16...2048).contains(bound.count), span.words[start..<end].allSatisfy(clean) else {
            throw StreamFailure.storage("Select 16 to 2,048 contiguous clean samples around one fixture pulse.")
        }
        var contextStart = start, contextEnd = end
        while contextStart > 0 && clean(span.words[contextStart - 1]) { contextStart -= 1 }
        while contextEnd < span.words.count && clean(span.words[contextEnd]) { contextEnd += 1 }
        if settings.notch60 || settings.notch120 {
            guard Double(start - contextStart) >= configured * 0.35,
                  (!settings.notch120 || configured > 240) && (!settings.notch60 || configured > 120) else {
                throw StreamFailure.storage("The template needs settled filter context before the pulse.")
            }
        }
        let uncertainty = reference.uncertaintySamples
        let inRange = reference.pulsesUS.map(reference.index).filter {
            $0 + uncertainty >= Double(bound.lowerBound) && $0 - uncertainty < Double(bound.upperBound)
        }
        guard inRange.count == 1, let timing = inRange.first,
              timing - uncertainty >= Double(bound.lowerBound), timing + uncertainty < Double(bound.upperBound) else {
            throw StreamFailure.storage("Exactly one independently timed pulse and its uncertainty must fit inside the selection.")
        }
        let trace = StudioReview.corrected((contextStart..<contextEnd).map(span.value),
                                           first: span.first + UInt64(contextStart), configuredRate: configured, settings: settings)
        let samples = Array(trace.processed[(start - contextStart)..<(end - contextStart)])
        let sign = settings.polarity.sign
        guard let peak = samples.indices.max(by: { samples[$0] * sign < samples[$1] * sign }),
              samples[peak] * sign >= settings.height, abs(Double(bound.lowerBound) + Double(peak) - timing) <= uncertainty,
              peak >= 2, peak + 2 < samples.count else {
            throw StreamFailure.storage("The measured peak does not match the declared fixture timing, polarity and height.")
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let norm = sqrt(samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) })
        guard norm.isFinite, norm > 0 else { throw StreamFailure.storage("The fixture waveform has no usable shape.") }
        let template = FixtureTemplate(run: reader.run.id, source: input.refs, referenceHash: hash,
                                       range: .init(segment: span.segment.id, first: bound.lowerBound, end: bound.upperBound),
                                       gain: reader.run.settings.gain, polarity: settings.polarity, drift: settings.drift,
                                       notch60: settings.notch60, notch120: settings.notch120, peakOffset: peak,
                                       shape: samples.map { ($0 - mean) / norm }, nominalRate: rate, picoAveraging: reader.run.settings.picoAveraging,
                                       setup: reader.run.settings.picoAveraging == nil && reader.run.settings.board == .picoW ? nil : reader.run.settings.bench?.setup,
                                       acquisitionBoard: reader.run.settings.acquisitionBoard)
        guard template.valid else { throw StreamFailure.storage("Confirm a physical gain and compatible fixture setup.") }
        let folder = try StreamFiles.directory("templates", in: reader.store.folder, create: true)
        try StreamFiles.publish(template, at: folder.appendingPathComponent(template.id.uuidString + ".json"))
        return template
    }

    static func templates(_ project: StreamProjectStore) throws -> [FixtureTemplate] {
        let folder = project.folder.appendingPathComponent("templates")
        guard StreamFiles.exists(folder) else { return [] }
        try StreamFiles.directory(folder)
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard entries.count <= 512 else { throw StreamFailure.storage("Too many fixture templates.") }
        return try entries.filter { $0.pathExtension == "json" }.map { file in
            let template = try StreamFiles.read(FixtureTemplate.self, file)
            guard template.valid, template.id.uuidString + ".json" == file.lastPathComponent else {
                throw StreamFailure.storage("A saved fixture template is invalid.")
            }
            return template
        }
    }

    static func compare(_ reference: StreamFixtureReference, input: ReviewInput, result: ReviewResult, processed: Bool) -> FixtureComparison {
        let rate = input.run.settings.nominalRate
        let candidates = (processed ? result.processed : result.raw).filter { $0.decision == "match" }
        let spans = input.spans.filter { $0.segment.stream == reference.stream }
        guard !result.overflow, let segment = input.run.segments.first(where: { $0.stream == reference.stream }) else {
            return .init(ambiguous: reference.pulsesUS.count)
        }
        let indices = ReviewInput.indices(input.selection, segment: segment, rate: rate)
        let uncertainty = reference.uncertaintySamples
        let times = reference.pulsesUS.map(reference.index).filter { $0 >= Double(indices.lowerBound) && $0 < Double(indices.upperBound) }
        let unavailable = result.intervals.filter {
            $0.range.segment == segment.id && ($0.action != .review || (processed && $0.reason == .edge))
        }
        var comparison = FixtureComparison(), used = Set<Int>()
        for (i, time) in times.enumerated() {
            let lo = time - uncertainty, hi = time + uncertainty
            if lo < Double(indices.lowerBound) || hi >= Double(indices.upperBound) ||
                (i > 0 && times[i - 1] + uncertainty >= lo) || (i + 1 < times.count && times[i + 1] - uncertainty <= hi) {
                comparison.ambiguous += 1
            } else if !spans.contains(where: { Double($0.first) <= lo && Double($0.end) > hi }) ||
                        unavailable.contains(where: { Double($0.range.first) <= hi && Double($0.range.end) > lo }) {
                comparison.missingCoverage += 1
            } else {
                let nearby = candidates.indices.filter {
                    candidates[$0].range.segment == segment.id && (lo...hi).contains(Double(candidates[$0].peakIndex))
                }
                if nearby.isEmpty { comparison.missed += 1 }
                else if nearby.count == 1, let index = nearby.first, used.insert(index).inserted { comparison.matched += 1 }
                else { comparison.ambiguous += 1; used.formUnion(nearby) }
            }
        }
        comparison.extraMatches = candidates.indices.filter { candidates[$0].range.segment == segment.id && !used.contains($0) }.count
        return comparison
    }
}
