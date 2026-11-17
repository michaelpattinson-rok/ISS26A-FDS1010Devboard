import Darwin
import Foundation

nonisolated struct FixtureReplayDecision: Codable, Sendable {
    var detector: String
    var segment: UUID
    var index: UInt64
    var peakIndex: UInt64
    var availableIndex: UInt64
    var amplitude: Double
    var score: Double?
    var residual: Double?
    var decision: String
    var blocker: UInt64?
    var fit: FixtureFit?
    var widthUS: Double? = nil
    var rejectionReason: String? = nil
    var alignment: Double { Double(index) + (fit?.fractionalOffset ?? 0) }
}

nonisolated struct FixtureReplayMetrics: Codable, Sendable {
    var matches = 0
    var totalMatches: Int? = nil
    var missedInCoverage = 0
    var outsideCoverage = 0
    var ambiguousTiming = 0
    var unassociated = 0
    var untimedDetections = 0
    var earlyTriggerHidLater = 0
    var rmsTimingErrorUS: Double?
    var rmsAmplitudeErrorCodes: Double?
    var amplitudeReferenceCount = 0
    var falseMatchesPerUsableMinute: Double?
}

nonisolated struct FixtureReplayReport: Codable, Sendable {
    var type = "signalbench.fixture-detector-replay"
    var version = 1
    var template: FixtureStudyTemplate
    var templateSHA256: String
    var weighted: Bool
    var source: FixtureStudySource
    var sampled: UInt64
    var usable: UInt64
    var sampledSeconds: Double? = nil
    var usableSeconds: Double? = nil
    var knownMissing: UInt64
    var adcErrorWords: UInt64
    var clippedWords: UInt64
    var unknownTime: Bool
    var heldAside: Bool
    var existing: FixtureReplayMetrics
    var matchedFilter: FixtureReplayMetrics
    var annotationRevision: UUID? = nil
    var decisionPreview: [FixtureReplayDecision]? = nil
    var countingEnabled = false
    var rate_exposure_valid = 0
}

nonisolated struct FixtureCoverage: Codable, Sendable {
    var segment: UUID
    var first: UInt64
    var end: UInt64
}

nonisolated enum FixtureReplay {
    static let analyzer = "signalbench.fixture-detector-replay"
    static let limit = 100_000

    static func eligible(_ reader: StreamRangeReader, template: FixtureStudyTemplate) -> Bool {
        let run = reader.run
        guard template.compatible(reader), let step = run.settings.bench?.step,
              [.fixture, .empty, .repeatEmpty].contains(step), run.status != .recording,
              template.noise?.run != run.id, !template.training.contains(where: { $0.run == run.id }) else { return false }
        return template.reservedValidationRuns.contains(run.id)
            || floor(run.created.timeIntervalSince1970) > template.created.timeIntervalSince1970
    }

    static func run(_ reader: StreamRangeReader, template: FixtureStudyTemplate, weighted: Bool) throws -> StreamAnalysisManifest {
        let selection = try FixtureTemplateStudy.fullRange(reader)
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: true)
        var manifest = StreamAnalysisManifest(run: reader.run.id, selection: selection,
            streams: reader.run.segments.map(\.stream), analyzer: analyzer, analyzerVersion: 2,
            profileRevision: reader.run.settings.profile?.id, outputs: [])
        _ = try ReviewFiles.publish(in: parent, name: manifest.id.uuidString) { stage in
            let result = try analyze(reader, template: template, weighted: weighted, writingTo: stage)
            manifest.annotationRevision = result.report.annotationRevision
            manifest.outputs = result.outputs
            try reader.store.verify()
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return manifest
    }

    static func preview(_ reader: StreamRangeReader, template: FixtureStudyTemplate, weighted: Bool, checkpoint: () throws -> Void = {},
                        decision: ((FixtureReplayDecision) throws -> Void)? = nil) throws -> FixtureReplayReport {
        try analyze(reader, template: template, weighted: weighted, checkpoint: checkpoint, decision: decision).report
    }

    private static func analyze(_ original: StreamRangeReader, template: FixtureStudyTemplate, weighted: Bool,
                                writingTo stage: URL? = nil, checkpoint: () throws -> Void = {}, decision: ((FixtureReplayDecision) throws -> Void)? = nil)
        throws -> (report: FixtureReplayReport, outputs: [StreamAnalysisOutput]) {
        try original.store.verify()
        let reader = try original.prepared()
        let selection = try FixtureTemplateStudy.fullRange(reader)
        let chunks = reader.index ?? []
        let prior = template.training + [template.noise].compactMap { $0 }
        guard eligible(reader, template: template),
              !prior.contains(where: { $0.run == reader.run.id || !Set($0.streams).isDisjoint(with: reader.run.segments.map(\.stream))
                  || !Set($0.chunks.values).isDisjoint(with: chunks.map(\.sha256)) }),
              let step = reader.run.settings.bench?.step else {
            throw StreamFailure.storage("Replay requires a separate saved fixture or empty-board run. Training and noise-fit data cannot be validation data.")
        }
        let annotation = try RunAnnotations.read(reader)
        let masks = Dictionary(grouping: annotation?.masks ?? [], by: \.range.segment)
        let kernel = try template.kernel(weighted: weighted)
        let bank = try FixtureFitBank(kernel)
        let limits = weighted ? template.weightedLimits! : template.limits
        let length = template.shape.count, before = template.before
        var baseline = template.baseline
        baseline.separation = 0
        let separation = template.baseline.separation
        let halo = max(length + separation + 2, baseline.maxWidth + baseline.padBefore + baseline.padAfter + 2048)
        guard halo <= 40_000 else { throw StreamFailure.storage("Reduce pulse support or separation to replay this profile.") }
        let decisions = try stage.map { try StreamOutput($0.appendingPathComponent("decisions.jsonl")) }
        let coverageFile = try stage.map { try StreamOutput($0.appendingPathComponent("coverage.jsonl")) }
        let sources = try stage.map { try StreamOutput($0.appendingPathComponent("source-ranges.jsonl")) }
        var sampled: UInt64 = 0, usable: UInt64 = 0, adcErrors: UInt64 = 0, clipped: UInt64 = 0
        var sampledSeconds = 0.0, usableSeconds = 0.0
        var observedEnds: [UUID: UInt64] = [:]
        var coverage: [FixtureCoverage] = []
        var found: [FixtureReplayDecision] = []
        var last: [String: (segment: UUID, available: UInt64, index: UInt64)] = [:]
        var previousEnd: UInt64?, previousSegment: UUID?
        func cover(_ range: FixtureCoverage) throws {
            if let prior = coverage.last, prior.segment == range.segment, prior.end == range.first {
                coverage[coverage.count - 1].end = range.end
            } else { coverage.append(range) }
        }
        func record(_ value: FixtureReplayDecision) throws {
            guard found.count < limit else {
                throw StreamFailure.storage("Replay reached its 100,000 decision limit. No complete result was published.")
            }
            found.append(value)
            try decisions?.item(value)
            try decision?(value)
        }
        try FixtureTiles.visit(reader, selection: selection, halo: halo, source: {
            try checkpoint()
            try sources?.item(StreamExportRange(input: $0.reference, firstNominalSeconds: $0.firstSeconds, frame: $0.frameAnchor))
        }) { span, owned in
            if span.segment.id != previousSegment || (previousEnd != nil && previousEnd != owned.lowerBound) { last.removeAll() }
            previousSegment = span.segment.id
            previousEnd = owned.upperBound
            sampled += UInt64(owned.count)
            observedEnds[span.segment.id] = owned.upperBound
            for word in span.words[Int(owned.lowerBound - span.first)..<Int(owned.upperBound - span.first)] {
                if span.means != nil {
                    if word & 0x4000 != 0 { adcErrors += 1 }
                    if word & 0x3000 != 0 { clipped += 1 }
                } else if word & 0x8000 != 0 { adcErrors += 1 }
                else if span.segment.board.sampleCode(word) == 0 || span.segment.board.sampleCode(word) == span.segment.board.maxCode { clipped += 1 }
            }
            let rate = span.segment.configuredRate(reader.run.settings.nominalRate)
            sampledSeconds += Double(owned.count) / rate
            let range = StreamSelection(lower: span.segment.timelineStart + Double(span.first) / rate,
                                        upper: span.segment.timelineStart + Double(span.end) / rate)
            let input = ReviewInput(run: reader.run, selection: range, spans: [span], refs: [], gaps: [])
            let approved = masks[span.segment.id, default: []].filter { $0.range.first < span.end && $0.range.end > span.first }
            let existing = try StudioReview.analyze(input, settings: baseline, manual: [], approved: approved,
                                                    markSelectionEdges: false, ownedIndices: span.first..<span.end)
            guard !existing.overflow else { throw StreamFailure.storage("The existing detector exceeded its candidate limit. The replay is incomplete.") }
            var maskedWords = span.words
            for excluded in existing.intervals where excluded.action == .excluded {
                let left = max(span.first, excluded.range.first), right = min(span.end, excluded.range.end)
                if left < right {
                    for i in left..<right { maskedWords[Int(i - span.first)] |= 0x8000 }
                }
            }
            let screen = kernel.screen(maskedWords, means: span.means, board: span.segment.board)
            let priorUsable = usable
            var open: UInt64?
            var lastEligible: UInt64?
            for i in screen.amplitudes.indices {
                let index = span.first + UInt64(i + before)
                guard owned.contains(index) else { continue }
                if screen.amplitudes[i].isFinite {
                    lastEligible = index; usable += 1
                    if open == nil { open = index }
                } else if let start = open {
                    try cover(.init(segment: span.segment.id, first: start, end: index))
                    open = nil
                }
            }
            if let start = open, let end = lastEligible {
                try cover(.init(segment: span.segment.id, first: start, end: end + 1))
            }
            usableSeconds += Double(usable - priorUsable) / rate
            guard coverage.count <= limit else { throw StreamFailure.storage("Too many fragmented coverage intervals.") }
            for item in existing.processed where owned.contains(item.peakIndex) {
                let marker = Int64(item.peakIndex) + Int64(before - template.peak)
                let screenIndex = Int(marker) - Int(span.first) - before
                guard marker >= 0 else { continue }
                let eligible = screen.amplitudes.indices.contains(screenIndex) && screen.amplitudes[screenIndex].isFinite
                let markerIndex = UInt64(marker)
                var decision = eligible ? item.decision : "outside_shared_coverage", blocker: UInt64?
                let key = "existing"
                // Enforce the saved separation across tile boundaries.
                // The first complete excursion acts before any truth lookup.
                if decision == "match" {
                    if let prior = last[key], prior.segment == span.segment.id,
                       markerIndex < prior.index + UInt64(separation) {
                        decision = "separation"; blocker = prior.index
                    } else {
                        last[key] = (span.segment.id, item.range.end, markerIndex)
                    }
                }
                try record(.init(detector: key, segment: span.segment.id, index: markerIndex, peakIndex: item.peakIndex,
                                 availableIndex: item.range.end, amplitude: item.height, decision: decision, blocker: blocker,
                                 widthUS: Double(item.width) * 1_000_000 / rate))
            }
            // Inspect local maxima over every available alignment. No
            // timing reference is loaded until the entire scan finishes.
            for i in screen.amplitudes.indices {
                    if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let index = span.first + UInt64(i + before)
                    guard owned.contains(index), screen.amplitudes[i] >= limits.minimumAmplitude,
                          (i == 0 || screen.amplitudes[i] >= screen.amplitudes[i - 1]),
                          (i + 1 == screen.amplitudes.count || screen.amplitudes[i] > screen.amplitudes[i + 1]) else { continue }
                    let raw = (i..<(i + length)).map(span.value)
                    let fitted = bank.fit(raw, first: span.first + UInt64(i))
                    let fit = fitted.estimate
                    let available = fit.first + UInt64(length) + (i + 1 < screen.amplitudes.count ? 1 : 0)
                    let rejection = limits.review(fit)
                    var decision = rejection == nil ? "match" : "shape_review"
                    var blocker: UInt64?
                    if decision == "match" {
                        if let prior = last["template"], prior.segment == span.segment.id,
                           available < prior.available + UInt64(separation) {
                            decision = "separation"; blocker = prior.index
                        } else {
                            last["template"] = (span.segment.id, available, index)
                        }
                    }
                    try record(.init(detector: "template", segment: span.segment.id, index: index, peakIndex: fit.peakIndex,
                                     availableIndex: available, amplitude: fit.amplitude, score: fit.score,
                                     residual: fit.residual, decision: decision, blocker: blocker, fit: fit,
                                     widthUS: Double(fitted.kernel.halfHeightWidth) * 1_000_000 / rate, rejectionReason: rejection))
            }
        }
        // Preserve the exact eligible center ranges for the shared
        // denominator, including support lost to clipping and real gaps.
        for interval in coverage {
            try Task.checkCancellation()
            try coverageFile?.item(interval)
        }
        // This is deliberately after detection, matching operational replay.
        let reference: (StreamFixtureReference, String)?
        if step == .fixture { reference = try FixtureEvidence.reference(reader) } else { reference = nil }
        let truth = try stage.map { try StreamOutput($0.appendingPathComponent("fixture-outcomes.jsonl")) }
        func boundary(_ count: Int, _ predicate: (Int) -> Bool) -> Int {
            var lo = 0, hi = count
            while lo < hi {
                let middle = lo + (hi - lo) / 2
                if predicate(middle) { hi = middle } else { lo = middle + 1 }
            }
            return lo
        }
        func evaluate(_ detector: String) throws -> FixtureReplayMetrics {
            let candidates = found.filter { $0.detector == detector }
            let accepted = candidates.filter { $0.decision == "match" }
            var result = FixtureReplayMetrics(totalMatches: accepted.count)
            var used = Set<Int>(), timing = 0.0, amplitude = 0.0
            if let (reference, _) = reference,
               let segment = reader.run.segments.first(where: { $0.stream == reference.stream }) {
                guard reader.run.segments.filter({ $0.stream == reference.stream }).count == 1 else {
                    throw StreamFailure.storage("The timing reference identifies more than one segment.")
                }
                let times = reference.pulsesUS.map(reference.index)
                let tolerance = reference.uncertaintySamples
                let available = coverage.filter { $0.segment == segment.id }
                let timed = accepted.filter { $0.segment == segment.id }.sorted { $0.index < $1.index }
                let blocked = candidates.filter { $0.segment == segment.id && $0.decision == "separation" }.sorted { $0.index < $1.index }
                for (i, time) in times.enumerated() {
                    try Task.checkCancellation()
                    var outcome = "missed_in_coverage"
                    let bounds = (time - tolerance)...(time + tolerance)
                    let coverIndex = boundary(available.count) { Double(available[$0].end) > bounds.upperBound }
                    let covered = coverIndex < available.count && Double(available[coverIndex].first) <= bounds.lowerBound
                    var associated: FixtureReplayDecision?, preempting: UInt64?
                    if (i > 0 && times[i - 1] + tolerance >= bounds.lowerBound) ||
                        (i + 1 < times.count && times[i + 1] - tolerance <= bounds.upperBound) {
                        result.ambiguousTiming += 1; outcome = "ambiguous"
                    } else if !covered {
                        result.outsideCoverage += 1; outcome = "outside_coverage"
                    } else {
                        let first = boundary(timed.count) { timed[$0].alignment >= bounds.lowerBound }
                        let end = boundary(timed.count) { timed[$0].alignment > bounds.upperBound }
                        let nearby = first..<end
                        if nearby.count == 1, let j = nearby.first, used.insert(j).inserted {
                            associated = timed[j]
                            result.matches += 1; outcome = "match"
                            timing += pow((timed[j].alignment - time) * 1_000_000 / reference.sampleRateHz, 2)
                            if let amplitudes = reference.amplitudesADC {
                                result.amplitudeReferenceCount += 1
                                amplitude += pow(timed[j].amplitude - amplitudes[i], 2)
                            }
                        } else if !nearby.isEmpty {
                            result.ambiguousTiming += 1; outcome = "ambiguous"; used.formUnion(nearby)
                        } else {
                            result.missedInCoverage += 1
                            let first = boundary(blocked.count) { blocked[$0].alignment >= bounds.lowerBound }
                            let end = boundary(blocked.count) { blocked[$0].alignment > bounds.upperBound }
                            if let item = blocked[first..<end].first(where: {
                                $0.blocker.map { Double($0) < bounds.lowerBound } == true
                            }) {
                                result.earlyTriggerHidLater += 1; outcome = "early_trigger_preempted"; preempting = item.blocker
                            }
                        }
                    }
                    try truth?.item(FixtureTruthOutcome(detector: detector, referenceUS: reference.pulsesUS[i],
                        expectedIndex: time, outcome: outcome, expectedAmplitude: reference.amplitudesADC?[i],
                        detectedIndex: associated?.alignment, detectedAmplitude: associated?.amplitude, blockingIndex: preempting))
                }
                result.unassociated = accepted.count - used.count
                result.untimedDetections = accepted.count - timed.count
                if result.matches > 0 { result.rmsTimingErrorUS = sqrt(timing / Double(result.matches)) }
                if result.amplitudeReferenceCount > 0 { result.rmsAmplitudeErrorCodes = sqrt(amplitude / Double(result.amplitudeReferenceCount)) }
            } else {
                result.unassociated = accepted.count
                if usableSeconds > 0 { result.falseMatchesPerUsableMinute = Double(accepted.count) * 60 / usableSeconds }
            }
            return result
        }
        let baselineMetrics = try evaluate("existing")
        let templateMetrics = try evaluate("template")
        let accounted = reader.run.segments.reduce(UInt64(0)) {
            $0 + max($1.accountedSamples, observedEnds[$1.id, default: 0])
        }
        var report = FixtureReplayReport(template: template, templateSHA256: StreamFiles.sha(try StreamFiles.encoder.encode(template)),
            weighted: weighted, source: .init(run: reader.run.id, streams: reader.run.segments.map(\.stream),
                chunks: Dictionary(uniqueKeysWithValues: chunks.map { ($0.id.uuidString, $0.sha256) })),
            sampled: sampled, usable: usable, sampledSeconds: sampledSeconds, usableSeconds: usableSeconds, knownMissing: accounted >= sampled ? accounted - sampled : 0,
            adcErrorWords: adcErrors, clippedWords: clipped, unknownTime: reader.run.hasUnknownCoverage,
            heldAside: true, existing: baselineMetrics, matchedFilter: templateMetrics)
        report.annotationRevision = annotation?.id
        report.decisionPreview = ["existing", "template"].flatMap { name in
            Array(found.lazy.filter { $0.detector == name }.prefix(30))
        }
        report.source.timingSHA256 = reference?.1
        report.source.timingSource = reference?.0.source
        report.source.clockAlignment = reference?.0.clockAlignment
        report.source.anchorReferenceUS = reference?.0.anchorReferenceUS
        report.source.anchorSampleIndex = reference?.0.anchorSampleIndex
        report.source.referenceRateHz = reference?.0.sampleRateHz
        report.source.uncertaintyUS = reference?.0.uncertaintyUS
        report.source.referencePulseCount = reference?.0.pulsesUS.count
        guard let stage, let decisions, let coverageFile, let sources, let truth else {
            try reader.store.verify()
            return (report, [])
        }
        let summary = try StreamOutput(stage.appendingPathComponent("replay.json"))
        let reportData = try StreamFiles.encoder.encode(report)
        guard reportData.count <= 16_777_216 else { throw StreamFailure.storage("The replay summary exceeds its 16 MiB limit.") }
        try summary.write(reportData)
        var outputs = [
            try decisions.finish(file: "decisions.jsonl", type: "signalbench.fixture-fit-decisions"),
            try coverageFile.finish(file: "coverage.jsonl", type: "signalbench.fixture-fit-coverage"),
            try sources.finish(file: "source-ranges.jsonl", type: "signalbench.source-ranges"),
            try truth.finish(file: "fixture-outcomes.jsonl", type: "signalbench.fixture-truth-outcomes"),
            try summary.finish(file: "replay.json", type: report.type)
        ]
        if let annotation {
            let annotations = try StreamOutput(stage.appendingPathComponent("annotations.json"))
            try annotations.write(StreamFiles.encoder.encode(annotation))
            outputs.append(try annotations.finish(file: "annotations.json", type: "signalbench.annotations"))
        }
        return (report, outputs)
    }

    static func load(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest) throws -> FixtureReplayReport {
        guard manifest.analyzer == analyzer, manifest.run == reader.run.id, (1...2).contains(manifest.analyzerVersion),
              let item = manifest.outputs.first(where: { $0.file == "replay.json" && $0.type == "signalbench.fixture-detector-replay" }) else {
            throw StreamFailure.storage("Choose a fixture replay analysis.")
        }
        let folder = try analysisFolder(reader, id: manifest.id)
        let bytes = try StreamFiles.read(folder.appendingPathComponent(item.file), limit: 16_777_216)
        guard bytes.count == item.bytes, StreamFiles.sha(bytes) == item.sha256 else { throw StreamFailure.storage("The fixture report failed its integrity check.") }
        let report = try StreamFiles.decoder.decode(FixtureReplayReport.self, from: bytes)
        let chunks = try reader.store.chunks(reader.run)
        guard report.version == 1, report.template.valid, report.source.run == reader.run.id,
              report.source.chunks == Dictionary(uniqueKeysWithValues: chunks.map { ($0.id.uuidString, $0.sha256) }),
              report.annotationRevision == manifest.annotationRevision,
              report.templateSHA256 == StreamFiles.sha(try StreamFiles.encoder.encode(report.template)), !report.countingEnabled else {
            throw StreamFailure.storage("The report or its raw source index has changed.")
        }
        return report
    }

    private static func analysisFolder(_ reader: StreamRangeReader, id: UUID) throws -> URL {
        let analyses = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: false)
        return try StreamFiles.directory(id.uuidString, in: analyses, create: false)
    }
}

nonisolated struct FixtureTruthOutcome: Codable, Sendable {
    var detector: String
    var referenceUS: Double
    var expectedIndex: Double
    var outcome: String
    var expectedAmplitude: Double?
    var detectedIndex: Double?
    var detectedAmplitude: Double?
    var blockingIndex: UInt64?
}

extension FixtureReplay {
    nonisolated static func export(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest, destination: URL? = nil) throws -> URL {
        _ = try load(reader, manifest: manifest)
        let root = try analysisFolder(reader, id: manifest.id)
        return try ReviewFiles.publish(in: destination ?? reader.store.exports(), name: "Fixture Replay " + UUID().uuidString) { stage in
            for file in manifest.outputs {
                guard file.valid else { throw StreamFailure.storage("Invalid analysis file reference.") }
                let source = root.appendingPathComponent(file.file)
                let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw StreamFiles.posix() }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_size >= 0, UInt64(info.st_size) == file.bytes else {
                    throw StreamFailure.storage("An analysis output has changed.")
                }
                let writer = try StreamOutput(stage.appendingPathComponent(file.file))
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation()
                    try writer.write(data)
                }
                let output = try writer.finish(file: file.file, type: file.type)
                guard output.bytes == file.bytes, output.sha256 == file.sha256 else {
                    throw StreamFailure.storage("An analysis output failed verification during export.")
                }
            }
            let csv = try StreamOutput(stage.appendingPathComponent("decisions.csv"))
            try csv.line("detector,segment,original_peak_index,alignment_index,available_index,amplitude_adc,width_us,template_score,residual_adc_rms,decision,rejection_reason,blocking_index")
            let handle = try FileHandle(forReadingFrom: stage.appendingPathComponent("decisions.jsonl"))
            defer { try? handle.close() }
            var buffer = Data()
            func row(_ data: Data) throws {
                let decision = try StreamFiles.decoder.decode(FixtureReplayDecision.self, from: data)
                let width = decision.widthUS.map { String($0) } ?? ""
                let score = decision.score.map { String($0) } ?? ""
                let residual = decision.residual.map { String($0) } ?? ""
                let blocker = decision.blocker.map { String($0) } ?? ""
                let columns = [ReviewFiles.csv(decision.detector), decision.segment.uuidString, String(decision.peakIndex),
                               String(decision.alignment), String(decision.availableIndex), String(decision.amplitude), width, score, residual,
                               ReviewFiles.csv(decision.decision), ReviewFiles.csv(decision.rejectionReason ?? ""), blocker]
                try csv.line(columns.joined(separator: ","))
            }
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                try Task.checkCancellation()
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    try row(buffer.subdata(in: 0..<newline))
                    buffer.removeSubrange(0...newline)
                }
                guard buffer.count <= 65_536 else { throw StreamFailure.storage("A decision row is too large.") }
            }
            guard buffer.isEmpty else { throw StreamFailure.storage("The decision output has an incomplete final row.") }
            _ = try csv.finish(file: "decisions.csv", type: "text/csv")
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
    }
}
