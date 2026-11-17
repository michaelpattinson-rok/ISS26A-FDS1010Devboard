import Foundation

nonisolated struct ReviewSettings: Codable, Equatable, Sendable {
    static let version = 2
    var algorithmVersion: Int? = nil
    var ruleVersion: Int { algorithmVersion ?? Self.version }
    var drift = true
    var notch60 = false
    var notch120 = false
    var template: FixtureTemplate?
    var correlation = 0.8
    var polarity = ProfilePulseRules.Polarity.negative
    var height = 24.0
    var minWidth = 4
    var maxWidth = 500
    var separation = 100
    var maskGlitches = false
    var maskNoise = false
    var spikeWidth = 2
    var spikeSlope = 250.0
    var noiseLimit = 80.0
    var reviewHeight = 1000.0
    var padBefore = 10
    var padAfter = 20
    var filterSummary: String {
        var filters: [String] = []
        if drift { filters.append("Baseline drift correction") }
        if notch60 { filters.append("60 Hz notch") }
        if notch120 { filters.append("120 Hz notch") }
        if maskGlitches { filters.append("Glitch exclusions") }
        if maskNoise { filters.append("Noise exclusions") }
        return filters.isEmpty ? "Filters off" : filters.joined(separator: " · ")
    }

    var valid: Bool {
        (1...Self.version).contains(ruleVersion) && (1...16383).contains(height) && (1...16_384).contains(minWidth) && (minWidth...16_384).contains(maxWidth)
        && (0...16_384).contains(separation) && (1...160).contains(spikeWidth) && (1...16383).contains(spikeSlope)
        && (0.1...16383).contains(noiseLimit) && (1...16383).contains(reviewHeight)
        && (0...10_000).contains(padBefore) && (0...10_000).contains(padAfter)
        && (0...1).contains(correlation) && (template?.valid ?? true)
    }

    init(profile: CalibrationProfile? = nil, sampleRate: Int = StreamWire.rate) {
        var rules = profile?.rules ?? ProfilePulseRules(spikeMinimumSlope: 250)
        if profile == nil { rules.rescaleTiming(from: StreamWire.rate, to: sampleRate) }
        polarity = rules.polarity
        height = rules.height
        minWidth = rules.minimumSamples
        maxWidth = rules.maximumSamples
        separation = rules.separationSamples
        spikeWidth = rules.spikeMaximumSamples
        spikeSlope = rules.spikeMinimumSlope
        noiseLimit = rules.noisyBlockSigma
        reviewHeight = rules.reviewHeight
        padBefore = rules.paddingBefore
        padAfter = rules.paddingAfter
    }
}

nonisolated struct ReviewRange: Codable, Equatable, Hashable, Sendable {
    var segment: UUID
    var first: UInt64
    var end: UInt64
    var count: UInt64 { end >= first ? end - first : 0 }
}

nonisolated struct ReviewInterval: Codable, Equatable, Identifiable, Sendable {
    enum Reason: String, Codable, Sendable {
        case error = "ADC error", clipping = "Clipping and recovery", gap = "Dropped or missing samples"
        case glitch = "Short steep glitch", noise = "Abnormal noise burst", tall = "High peak"
        case manual = "Operator exclusion", edge = "Filter settling"
    }
    enum Action: String, Codable, Sendable { case review, excluded, missing }
    var range: ReviewRange
    var reason: Reason
    var action: Action
    var note = ""
    var evidenceIndex: UInt64? = nil
    var id: String { "\(range.segment):\(range.first):\(range.end):\(reason.rawValue):\(action.rawValue):\(note)" }
}

nonisolated struct ReviewSpan: Sendable {
    var segment: StreamRunSegment
    var first: UInt64
    var words: [UInt16]
    var means: [Double]? = nil
    func value(_ index: Int) -> Double { means?[index] ?? Double(segment.board.sampleCode(words[index])) }
    var end: UInt64 { first + UInt64(words.count) }
}

nonisolated struct ReviewInput: Sendable {
    let run: StreamRun
    let selection: StreamSelection
    let spans: [ReviewSpan]
    let refs: [StreamRangeReference]
    let gaps: [ReviewInterval]

    static let maximumSeconds = 3.0

    static func load(_ reader: StreamRangeReader, selection: StreamSelection, context: Double = 0.4) throws -> Self {
        guard selection.valid, selection.upper - selection.lower <= maximumSeconds + 1e-8, (0...0.5).contains(context) else {
            throw StreamFailure.storage("Select up to three seconds for waveform review.")
        }
        let expanded = StreamSelection(lower: max(0, selection.lower - context), upper: min(86_400, selection.upper + context))
        var spans: [ReviewSpan] = [], refs: [StreamRangeReference] = [], gaps: [ReviewInterval] = []
        let rate = reader.run.settings.nominalRate
        var wordsRead = 0
        try reader.visit(expanded) { part in
            wordsRead += part.reference.count
            guard wordsRead <= Int((maximumSeconds + 1.01) * max(Double(rate), StreamWire.configuredRate(for: rate))) else {
                throw StreamFailure.storage("The waveform index overlaps or exceeds the review limit.")
            }
            refs.append(part.reference)
            let words = part.words.withUnsafeBytes { bytes in
                (0..<part.reference.count).map { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
            }
            let means = part.groups?.map { $0.mean ?? 0 }
            if let last = spans.last, last.segment.id == part.segment.id, last.end == part.reference.first {
                spans[spans.count - 1].words.append(contentsOf: words)
                if let means { spans[spans.count - 1].means?.append(contentsOf: means) }
            } else {
                spans.append(.init(segment: part.segment, first: part.reference.first, words: words, means: means))
            }
        }
        for segment in reader.run.segments {
            let bounds = indices(selection, segment: segment, rate: rate)
            let last = max(segment.accountedSamples, spans.last(where: { $0.segment.id == segment.id })?.end ?? 0)
            var cursor = min(bounds.lowerBound, last)
            let limit = min(bounds.upperBound, last)
            for span in spans where span.segment.id == segment.id {
                let lo = min(limit, max(cursor, span.first))
                if lo > cursor {
                    gaps.append(.init(range: .init(segment: segment.id, first: cursor, end: lo), reason: .gap, action: .missing))
                }
                cursor = min(limit, max(cursor, span.end))
            }
            if cursor < limit {
                gaps.append(.init(range: .init(segment: segment.id, first: cursor, end: limit), reason: .gap, action: .missing))
            }
        }
        return .init(run: reader.run, selection: selection, spans: spans, refs: refs, gaps: gaps)
    }

    static func indices(_ range: StreamSelection, segment: StreamRunSegment, rate: Int) -> Range<UInt64> {
        func index(_ time: Double) -> UInt64 {
            StreamRangeReader.sampleBoundary((time - segment.timelineStart) * segment.configuredRate(rate))
        }
        return index(range.lower)..<index(range.upper)
    }
}

nonisolated struct ReviewPulse: Codable, Equatable, Sendable {
    var range: ReviewRange
    var peakIndex: UInt64
    var peakTime: Double
    var height: Double
    var width: Int
    var correlation: Double?
    var decision: String
}

nonisolated struct ReviewTraceBin: Sendable {
    var raw: ClosedRange<Double>?
    var processed: ClosedRange<Double>?
    var mask = false
    var rawSum = 0.0
    var rawCount = 0
    var processedSum = 0.0
    var processedCount = 0
}

nonisolated struct ReviewResult: Sendable {
    let selection: StreamSelection
    let settings: ReviewSettings
    var manual: [ReviewInterval] = []
    var raw: [ReviewPulse] = []
    var processed: [ReviewPulse] = []
    var intervals: [ReviewInterval] = []
    var bins = Array(repeating: ReviewTraceBin(), count: 720)
    var breakBins: Set<Int> = []
    var sampled: UInt64 = 0
    var excluded: UInt64 = 0
    var filterSettling: UInt64 = 0
    var sampledSeconds = 0.0
    var excludedSeconds = 0.0
    var settlingSeconds = 0.0
    var processedUsableSeconds: Double { max(0, sampledSeconds - excludedSeconds - settlingSeconds) }
    var hasProcessedSamples: Bool { sampled > excluded + filterSettling }
    var overflow = false
    var rate: Int
    var rawCount: Int { raw.filter { $0.decision == "match" }.count }
    var processedCount: Int { processed.filter { $0.decision == "match" }.count }
}

nonisolated struct Notch {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    init(_ frequency: Double, rate: Double) {
        let omega = 2 * Double.pi * frequency / rate
        let alpha = sin(omega) / 16
        b0 = 1 / (1 + alpha)
        b1 = -2 * cos(omega) * b0
        b2 = b0
        a1 = b1
        a2 = (1 - alpha) * b0
    }
    mutating func next(_ sample: Double) -> Double {
        let output = sample * b0 + z1
        z1 = sample * b1 - output * a1 + z2
        z2 = sample * b2 - output * a2
        return output
    }
}

nonisolated enum StudioReview {
    static func corrected(_ words: [UInt16], first: UInt64, rate: Int, settings: ReviewSettings) -> (raw: [Double], processed: [Double], center: Double) {
        corrected(words.map { Double($0 & 4095) }, first: first, configuredRate: Double(rate), settings: settings)
    }

    static func corrected(_ values: [Double], first: UInt64, configuredRate: Double, settings: ReviewSettings) -> (raw: [Double], processed: [Double], center: Double) {
        let center = ProfileAnalyzer.median(values) ?? 0
        let raw = values.map { $0 - center }
        var corrected = raw
        if settings.drift {
            var anchors: [(Int, Double)] = []
            var i = 0
            while i < values.count {
                let block = max(4, StreamWire.samples(1024, at: configuredRate))
                let width = block - Int((first + UInt64(i)) % UInt64(block))
                let end = min(values.count, i + width)
                if let median = ProfileAnalyzer.median(Array(values[i..<end])) { anchors.append(((i + end - 1) / 2, median)) }
                i = end
            }
            if let firstAnchor = anchors.first, let lastAnchor = anchors.last {
                var j = 0
                for i in values.indices {
                    while j + 1 < anchors.count && i > anchors[j + 1].0 { j += 1 }
                    let baseline: Double
                    if i <= firstAnchor.0 { baseline = firstAnchor.1 }
                    else if i >= lastAnchor.0 { baseline = lastAnchor.1 }
                    else {
                        let left = anchors[j], right = anchors[j + 1]
                        baseline = left.1 + (right.1 - left.1) * Double(i - left.0) / Double(right.0 - left.0)
                    }
                    corrected[i] = values[i] - baseline
                }
            }
        }
        for frequency in [settings.notch60 ? 60.0 : nil, settings.notch120 ? 120.0 : nil].compactMap({ $0 }) {
            guard frequency < configuredRate / 2 else { continue }
            var filter = Notch(frequency, rate: configuredRate)
            for i in corrected.indices { corrected[i] = filter.next(corrected[i]) }
        }
        return (raw, corrected, center)
    }

    static func analyze(_ input: ReviewInput, settings: ReviewSettings, manual: [ReviewInterval],
                        approved: [ReviewInterval] = [], decisionLimit: Int = 4096, markSelectionEdges: Bool = true, includePulses: Bool = true, ownedIndices: Range<UInt64>? = nil,
                        trace: ((UInt64, UInt16, Double?, Bool, Bool) -> Void)? = nil) throws -> ReviewResult {
        guard settings.valid, manual.count <= 256, StreamWire.customRates.contains(input.run.settings.nominalRate) else {
            throw StreamFailure.storage("Check the filter, pulse and exclusion settings.")
        }
        if let template = settings.template {
            guard input.run.settings.channel == 0, input.run.settings.nominalRate == (template.nominalRate ?? StreamWire.rate),
                  input.run.settings.picoAveraging == template.picoAveraging, input.run.settings.board == template.board,
                  (template.picoAveraging == nil && template.board == .picoW) || (input.run.settings.bench?.setup ?? input.run.settings.profile?.setup)
                    .map({ template.setup?.matchesAcquisition($0) == true }) == true,
                  input.run.settings.gain == template.gain, settings.polarity == template.polarity,
                  settings.drift == template.drift, settings.notch60 == template.notch60, settings.notch120 == template.notch120 else {
                throw StreamFailure.storage("The template requires matching ADC0, gain, polarity and filter settings.")
            }
        }
        let rate = input.run.settings.nominalRate
        let displayRate = input.run.settings.picoAveraging == nil ? rate : Int(input.run.settings.recordedRate.rounded())
        let sign = settings.polarity.sign
        var result = ReviewResult(selection: input.selection, settings: settings, manual: manual, intervals: input.gaps, rate: displayRate)
        var pulseBudget = decisionLimit
        func bin(_ time: Double) -> Int {
            min(719, max(0, Int((time - input.selection.lower) / (input.selection.upper - input.selection.lower) * 720)))
        }
        for span in input.spans {
            try Task.checkCancellation()
            let selected = ownedIndices ?? ReviewInput.indices(input.selection, segment: span.segment, rate: rate)
            let lo = max(selected.lowerBound, span.first), hi = min(selected.upperBound, span.end)
            guard lo < hi else { continue }
            let selectedOffsets = Int(lo - span.first)..<Int(hi - span.first)
            let configured = span.segment.configuredRate(rate)
            guard (!settings.notch60 || configured > 120) && (!settings.notch120 || configured > 240) else {
                throw StreamFailure.storage("The selected notch frequency must be below half the recorded sample rate.")
            }
            result.sampledSeconds += Double(hi - lo) / configured
            var excludedSamples = 0
            var settlingSamples = 0
            let time: (UInt64) -> Double = { span.segment.timelineStart + Double($0) / configured }
            if span.first >= selected.lowerBound { result.breakBins.insert(bin(time(span.first))) }
            result.sampled += hi - lo
            var mask = Array(repeating: false, count: span.words.count)
            var maskChanges = Array(repeating: 0, count: span.words.count + 1)
            var processedMask = mask
            var intervals: [ReviewInterval] = []
            func record(_ offsets: Range<Int>, _ reason: ReviewInterval.Reason, _ action: ReviewInterval.Action,
                        note: String = "", evidenceIndex: UInt64? = nil) {
                let a = max(offsets.lowerBound, selectedOffsets.lowerBound), b = min(offsets.upperBound, selectedOffsets.upperBound)
                if a < b {
                    intervals.append(.init(range: .init(segment: span.segment.id, first: span.first + UInt64(a), end: span.first + UInt64(b)),
                                           reason: reason, action: action, note: note, evidenceIndex: evidenceIndex))
                }
                if action == .excluded, reason != .edge {
                    maskChanges[offsets.lowerBound] += 1
                    maskChanges[offsets.upperBound] -= 1
                }
            }
            func updateMask() {
                var depth = 0
                for i in mask.indices {
                    depth += maskChanges[i]
                    mask[i] = depth > 0
                }
            }
            func padded(_ a: Int, _ b: Int) -> Range<Int> {
                max(0, a - settings.padBefore)..<min(mask.count, b + settings.padAfter)
            }
            func fault(_ i: Int) -> ReviewInterval.Reason? {
                let word = span.words[i]
                if word & 0x8000 != 0 {
                    return span.means != nil && word & 0x4000 == 0 ? .clipping : .error
                }
                return (span.segment.board.sampleCode(word) == 0 || span.segment.board.sampleCode(word) == span.segment.board.maxCode) ? .clipping : nil
            }
            var i = 0
            while i < mask.count {
                guard let reason = fault(i) else { i += 1; continue }
                let start = i
                repeat { i += 1 } while i < mask.count && fault(i) == reason
                record(padded(start, i), reason, .excluded, evidenceIndex: span.first + UInt64(start))
            }
            for edit in manual + approved where edit.range.segment == span.segment.id && edit.action == .excluded {
                let start = max(span.first, edit.range.first), end = min(span.end, edit.range.end)
                if start < end { record(Int(start - span.first)..<Int(end - span.first), edit.reason, .excluded, note: edit.note, evidenceIndex: edit.evidenceIndex) }
            }
            updateMask()
            // Detect steep, short excursions independently of pulse polarity. A large
            // amplitude alone remains a review marker and cannot trigger exclusion.
            i = 1
            while i + 1 < span.words.count {
                let a = span.value(i - 1), b = span.value(i)
                guard !mask[i - 1], !mask[i], abs(b - a) >= settings.spikeSlope else { i += 1; continue }
                let end = min(i + settings.spikeWidth, mask.count - 1)
                if let recovery = (i + 1...end).first(where: {
                    !mask[$0] && abs(span.value($0) - a) <= settings.spikeSlope / 4
                    && abs(span.value($0 - 1) - span.value($0)) >= settings.spikeSlope
                }) {
                    record(settings.maskGlitches ? padded(i, recovery) : i..<recovery, .glitch,
                           settings.maskGlitches ? .excluded : .review, evidenceIndex: span.first + UInt64(i))
                    i = recovery + 1
                } else { i += 1 }
            }
            updateMask()
            var noiseStart = 0
            while noiseStart < mask.count {
                let first = noiseStart
                let block = max(16, StreamWire.samples(1024, at: configured))
                let width = settings.ruleVersion == 1 ? block : block - Int((span.first + UInt64(first)) % UInt64(block))
                let end = min(mask.count, first + width)
                noiseStart = end
                let values = (first..<end).compactMap { mask[$0] ? nil : span.value($0) }
                guard values.count >= 64, let median = ProfileAnalyzer.median(values),
                      let mad = ProfileAnalyzer.median(values.map({ abs($0 - median) })), mad * 1.4826 > settings.noiseLimit else { continue }
                record(settings.maskNoise ? padded(first, end) : first..<end, .noise, settings.maskNoise ? .excluded : .review, evidenceIndex: span.first + UInt64(first))
            }
            updateMask()
            processedMask = mask
            var raw = Array(repeating: Double.nan, count: mask.count)
            var filtered = raw
            var display = raw
            i = 0
            while i < mask.count {
                guard !mask[i] else { i += 1; continue }
                let start = i
                repeat { i += 1 } while i < mask.count && !mask[i]
                let trace = corrected((start..<i).map(span.value), first: span.first + UInt64(start), configuredRate: configured, settings: settings)
                for j in start..<i {
                    raw[j] = trace.raw[j - start]
                    filtered[j] = trace.processed[j - start]
                    display[j] = filtered[j] + trace.center
                }
                if settings.notch60 || settings.notch120 {
                    let settle = start..<min(i, start + Int(configured * 0.35))
                    for index in settle { processedMask[index] = true }
                    record(settle, .edge, .review)
                }
            }
            func pulses(_ values: [Double], mask validMask: [Bool], template: FixtureTemplate?) -> [ReviewPulse] {
                var found: [ReviewPulse] = [], i = 0, lastMatch: Int? = nil
                while i < values.count {
                    guard !validMask[i], values[i] * sign >= settings.height else { i += 1; continue }
                    let a = i
                    var peak = i
                    repeat {
                        if values[i] * sign > values[peak] * sign { peak = i }
                        i += 1
                    } while i < values.count && !validMask[i] && values[i] * sign >= settings.height
                    let inRange = selectedOffsets.contains(peak)
                    if settings.ruleVersion == 1 && !inRange { continue }
                    if peak >= selectedOffsets.upperBound { break }
                    let width = i - a
                    let height = values[peak] * sign
                    let rangeEdge = settings.ruleVersion == 1
                        ? a <= selectedOffsets.lowerBound || i >= selectedOffsets.upperBound
                        : a < selectedOffsets.lowerBound || i > selectedOffsets.upperBound
                    let signalEdge = a == 0 || i == values.count || validMask[a - 1] || validMask[i]
                    let score = template?.score(values, center: peak, mask: validMask)
                    let decision: String
                    if signalEdge || (settings.ruleVersion == 1 && rangeEdge) { decision = "edge" }
                    else if !(settings.minWidth...settings.maxWidth).contains(width) { decision = "width" }
                    else if let lastMatch, peak - lastMatch < settings.separation { decision = "separation" }
                    else if template != nil && (score ?? -1) < settings.correlation { decision = "template" }
                    else { decision = "match"; lastMatch = peak }
                    guard inRange else { continue }
                    guard pulseBudget > 0 else { result.overflow = true; break }
                    pulseBudget -= 1
                    found.append(.init(range: .init(segment: span.segment.id, first: span.first + UInt64(a), end: span.first + UInt64(i)),
                                       peakIndex: span.first + UInt64(peak), peakTime: time(span.first + UInt64(peak)),
                                       height: height, width: width, correlation: score, decision: markSelectionEdges && rangeEdge ? "edge" : decision))
                }
                return found
            }
            if includePulses {
                result.raw.append(contentsOf: pulses(raw, mask: mask, template: nil))
                result.processed.append(contentsOf: pulses(filtered, mask: processedMask, template: settings.template))
            }
            i = 0
            while i < raw.count {
                guard raw[i].isFinite, abs(raw[i]) >= settings.reviewHeight else { i += 1; continue }
                let start = i
                repeat { i += 1 } while i < raw.count && raw[i].isFinite && abs(raw[i]) >= settings.reviewHeight
                let peak = (start..<i).max { abs(raw[$0]) < abs(raw[$1]) } ?? start
                record(start..<i, .tall, .review, evidenceIndex: span.first + UInt64(peak))
            }
            result.intervals.append(contentsOf: intervals)
            for i in selectedOffsets {
                if let trace {
                    let processed = !processedMask[i] && display[i].isFinite ? display[i] : nil
                    trace(span.first + UInt64(i), span.words[i], processed, mask[i], !mask[i] && processedMask[i])
                    continue
                }
                let b = bin(time(span.first + UInt64(i)))
                let value = span.value(i)
                if mask[i] { excludedSamples += 1; result.bins[b].mask = true }
                else if processedMask[i] { settlingSamples += 1 }
                if span.means == nil ? fault(i) != .error : fault(i) == nil {
                    result.bins[b].raw = widen(result.bins[b].raw, value)
                    result.bins[b].rawSum += value
                    result.bins[b].rawCount += 1
                }
                if !processedMask[i] && display[i].isFinite {
                    result.bins[b].processed = widen(result.bins[b].processed, display[i])
                    result.bins[b].processedSum += display[i]
                    result.bins[b].processedCount += 1
                }
            }
            result.excluded += UInt64(excludedSamples)
            result.filterSettling += UInt64(settlingSamples)
            result.excludedSeconds += Double(excludedSamples) / configured
            result.settlingSeconds += Double(settlingSamples) / configured
        }
        return result
    }

    private static func widen(_ range: ClosedRange<Double>?, _ value: Double) -> ClosedRange<Double> {
        min(range?.lowerBound ?? value, value)...max(range?.upperBound ?? value, value)
    }
}
