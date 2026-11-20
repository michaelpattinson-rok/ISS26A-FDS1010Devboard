import CryptoKit
import Foundation

nonisolated enum ReviewWorkerError: LocalizedError {
    case invalid(String), stale, limit, unsupported, cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .stale: return "The saved samples, setup or approved exclusions changed. Run a fresh review."
        case .limit: return "The review exceeds its configured size limit."
        case .unsupported: return "This review recipe or analyzer version is unsupported."
        case .cancelled: return "Review cancelled."
        }
    }
}

nonisolated struct ReviewDecisionChange: Codable, Identifiable, Sendable {
    let location: StreamMatchLocation
    let before: ReviewPulse?
    let after: ReviewPulse?
    let sampleRate: Double
    var id: String { "\(location.segment):\(location.sample)" }

    static func compare(_ before: [ReviewPulse], _ after: [ReviewPulse], in owned: Range<UInt64>, rate: Double,
                        emit: (Self) throws -> Void) throws {
        let left = before.filter { owned.contains($0.peakIndex) }
        let right = after.filter { owned.contains($0.peakIndex) }
        var a = 0, b = 0
        while a < left.count || b < right.count {
            if (a + b).isMultiple(of: 4096) { try Task.checkCancellation() }
            let i = min(a < left.count ? left[a].peakIndex : .max, b < right.count ? right[b].peakIndex : .max)
            let old = a < left.count && left[a].peakIndex == i ? left[a] : nil
            let new = b < right.count && right[b].peakIndex == i ? right[b] : nil
            if old != nil { a += 1 }
            if new != nil { b += 1 }
            guard let segment = (old ?? new)?.range.segment, old != new else { continue }
            try emit(.init(location: .init(segment: segment, sample: i), before: old, after: new, sampleRate: rate))
        }
    }
}

nonisolated struct ReviewWorkerSettings: Codable, Sendable {
    var drift: Bool?
    var notch60: Bool?
    var notch120: Bool?
    var maskGlitches: Bool?
    var maskNoise: Bool?
    var height: Double?

    func resolved(_ run: StreamRun) throws -> ReviewSettings {
        var value = ReviewSettings(profile: run.settings.profile, sampleRate: Int(run.settings.recordedRate.rounded()))
        value.algorithmVersion = ReviewSettings.version
        value.drift = drift ?? value.drift
        value.notch60 = notch60 ?? value.notch60
        value.notch120 = notch120 ?? value.notch120
        value.maskGlitches = maskGlitches ?? false
        value.maskNoise = maskNoise ?? false
        value.height = height ?? value.height
        guard height.map({ (1...Double(run.settings.board.maxCode)).contains($0) }) ?? true,
              value.valid else { throw ReviewWorkerError.invalid("Invalid filter or pulse settings.") }
        return value
    }
}

nonisolated struct ReviewRecipe: Codable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let requests: [ReviewRequest]
}

nonisolated struct ReviewRequest: Codable, Sendable {
    enum Operation: String, CaseIterable, Codable, Sendable {
        case list_runs, metadata, flags, quality, waveform, preview, compare, pulse_decisions, fixture_templates, fixture_replay
        case read_review_guide, batch_quality, batch_compare
        case interruption, find_clipping, find_gaps, spectra, export_estimate, draft_jobs
        case waveform_overview, waveform_image, device_candidates, averaging_replay

        var batchOnly: Bool { self == .read_review_guide || self == .batch_quality || self == .batch_compare }
    }

    let operation: Operation
    var run: UUID?
    var range: ReviewRange?
    var settings: ReviewWorkerSettings?
    var reference: ReviewWorkerSettings?
    var template: UUID?
    var weighted: Bool?
    var offset: Int?
    var limit: Int?
    var runs: [UUID]?
    var jobKind: ProjectJob.Kind?
    // Host supplied range, persisted for exact replay across timing segments.
    var visibleSelection: StreamSelection?

    var page: Range<Int> { (offset ?? 0)..<((offset ?? 0) + (limit ?? 20)) }

    static func decode(_ data: Data, operation: Operation? = nil, saved: Bool = false) throws -> Self {
        guard data.count <= 16_384,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReviewWorkerError.invalid("Expected a bounded JSON object.")
        }
        if let operation {
            guard object["operation"] == nil else { throw ReviewWorkerError.invalid("Unexpected operation argument.") }
            object["operation"] = operation.rawValue
        }
        guard let name = object["operation"] as? String, let op = Operation(rawValue: name) else {
            throw ReviewWorkerError.invalid("Unknown review operation.")
        }
        try keys(object, allowed: ["operation"] + op.fields + (saved ? ["visibleSelection"] : []), required: op.required + ["operation"])
        if let raw = object["range"] {
            guard let range = raw as? [String: Any] else { throw ReviewWorkerError.invalid("Invalid sample range.") }
            try keys(range, allowed: ["segment", "first", "end"], required: ["segment", "first", "end"])
        }
        for field in ["settings", "reference"] {
            if let raw = object[field] {
                guard let settings = raw as? [String: Any] else { throw ReviewWorkerError.invalid("Invalid filter settings.") }
                try keys(settings, allowed: ["drift", "notch60", "notch120", "maskGlitches", "maskNoise", "height"], required: [])
            }
        }
        let result = try StreamFiles.decoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        guard (0...100_000_000).contains(result.offset ?? 0), (1...50).contains(result.limit ?? 20),
              result.range.map({ $0.count > 0 && $0.end <= StreamWire.maxSampleBoundary }) ?? true,
              result.visibleSelection?.valid ?? true,
              result.runs.map({ (1...ProjectReview.batchLimit).contains($0.count) && Set($0).count == $0.count }) ?? true else {
            throw ReviewWorkerError.invalid("Sample range or page is outside the allowed bounds.")
        }
        return result
    }

    static func keys(_ object: [String: Any], allowed: [String], required: [String]) throws {
        guard Set(object.keys).isSubset(of: Set(allowed)), required.allSatisfy({ object[$0] != nil }),
              !object.values.contains(where: { $0 is NSNull }) else {
            throw ReviewWorkerError.invalid("Unexpected or missing review fields.")
        }
    }

    static func recipe(_ data: Data) throws -> [Self] {
        guard data.count <= 262_144,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["requests"] as? [[String: Any]], (1...12).contains(values.count) else {
            throw ReviewWorkerError.invalid("Expected a recipe with 1 to 12 requests.")
        }
        try keys(root, allowed: ["version", "requests"], required: ["version", "requests"])
        guard try StreamFiles.decoder.decode(ReviewRecipe.self, from: data).version == ReviewRecipe.schemaVersion else {
            throw ReviewWorkerError.unsupported
        }
        return try values.map { try decode(JSONSerialization.data(withJSONObject: $0)) }
    }
}

nonisolated extension ReviewRequest.Operation {
    var required: [String] {
        switch self {
        case .list_runs, .fixture_templates, .read_review_guide, .batch_quality: return []
        case .batch_compare: return ["runs", "settings", "reference"]
        case .draft_jobs: return ["jobKind"]
        case .waveform, .waveform_overview, .waveform_image, .device_candidates, .averaging_replay: return ["run", "range"]
        case .compare: return ["run", "settings", "reference"]
        case .fixture_replay: return ["run", "template", "weighted"]
        default: return ["run"]
        }
    }
    var fields: [String] {
        switch self {
        case .list_runs, .fixture_templates: return ["offset", "limit"]
        case .read_review_guide: return []
        case .batch_quality: return ["runs", "offset", "limit"]
        case .batch_compare: return required
        case .metadata: return ["run"]
        case .flags: return ["run", "offset", "limit"]
        case .quality: return ["run", "range", "offset", "limit"]
        case .waveform, .waveform_overview, .waveform_image: return required
        case .device_candidates, .averaging_replay: return required + ["offset", "limit"]
        case .preview, .pulse_decisions: return ["run", "range", "settings", "offset", "limit"]
        case .compare: return required + ["range", "offset", "limit"]
        case .fixture_replay: return required + ["offset", "limit"]
        case .interruption: return ["run", "offset", "limit"]
        case .find_clipping, .find_gaps: return ["run", "range", "offset", "limit"]
        case .export_estimate: return ["run", "range"]
        case .spectra: return ["run", "range", "settings"]
        case .draft_jobs: return ["run", "runs", "range", "jobKind", "settings", "reference", "template", "weighted"]
        }
    }
}

nonisolated struct ReviewProposal: Codable, Identifiable, Sendable {
    var version = 1
    var id = UUID()
    let project: UUID
    let run: UUID
    let request: ReviewRequest
    let config: StudioRangeConfig
    let reference: ReviewSettings?
    let runHash: String
    let sourceHash: String
    let analyzerVersion: Int
    let comparisonVersion: Int
    var rate_exposure_valid = 0

    static func hash(_ run: StreamRun) throws -> String {
        try StreamFiles.sha(StreamFiles.encoder.encode(run))
    }

    func checkCurrent(_ reader: StreamRangeReader) throws {
        try reader.store.verify()
        let current = try reader.store.openRun(run)
        let annotation = try RunAnnotations.read(reader)
        guard version == 1, rate_exposure_valid == 0, analyzerVersion == StudioRangeReview.version,
              comparisonVersion == StudioRangeReview.comparisonVersion,
              [.preview, .compare].contains(request.operation), request.run == run,
              project == reader.store.identity.id, run == reader.run.id, sourceHash.count == 64,
              sourceHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              try Self.hash(current) == runHash, try Self.hash(reader.run) == runHash,
              config.annotationRevision == annotation?.id, config.exclusions == (annotation?.masks ?? []),
              config.profileRevision == current.settings.profile?.id,
              config.settings.valid, reference?.valid ?? true else { throw ReviewWorkerError.stale }
        let validated = try ReviewRequest.decode(StreamFiles.encoder.encode(request), saved: true)
        guard try ReviewWorker.selection(validated, reader: reader) == config.selection,
              config.contextLimit == nil || config.contextLimit == validated.visibleSelection,
              try (validated.settings ?? ReviewWorkerSettings()).resolved(current) == config.settings,
              try validated.reference?.resolved(current) == reference else { throw ReviewWorkerError.stale }
    }

    func stage(_ reader: StreamRangeReader) throws {
        try checkCurrent(reader)
        let folder = try StreamFiles.directory("proposed-reviews", in: reader.store.runDirectory(run), create: true)
        _ = try ReviewFiles.publish(in: folder, name: id.uuidString) { pending in
            try checkCurrent(reader)
            let decisions = try StreamOutput(pending.appendingPathComponent("decision-changes.jsonl"))
            let result = try review(reader) { try decisions.item($0) }
            let changes = try decisions.finish(file: "decision-changes.jsonl", type: "signalbench.decision-changes")
            let evidence = StageEvidence(primary: result.primary.quality, reference: result.reference?.quality, changes: changes)
            try StreamFiles.publish(evidence, at: pending.appendingPathComponent("coverage.json"))
            let bytes = try StreamFiles.encoder.encode(self)
            guard bytes.count <= 16_777_216 else { throw ReviewWorkerError.limit }
            try StreamFiles.publish(bytes, at: pending.appendingPathComponent("proposal.json"))
        }
    }

    private struct StageEvidence: Encodable {
        let primary: StudioRangeQuality
        let reference: StudioRangeQuality?
        let changes: StreamAnalysisOutput
    }

    static func list(_ reader: StreamRangeReader) throws -> [UUID] {
        let root = try reader.store.runDirectory(reader.run.id)
        guard try StreamFiles.isPresent(root.appendingPathComponent("proposed-reviews")) else { return [] }
        let parent = try StreamFiles.directory("proposed-reviews", in: root, create: false)
        let files = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        guard files.count <= 10_000 else { throw ReviewWorkerError.limit }
        return files.compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
    }

    struct ListItem: Identifiable, Sendable {
        let id: UUID
        let created: Date?
        let selection: StreamSelection?
        let filters: String?
        let isComparison: Bool
    }

    static func summaries(_ reader: StreamRangeReader) throws -> [ListItem] {
        let ids = try list(reader)
        let root = try reader.store.runDirectory(reader.run.id)
        let parent = root.appendingPathComponent("proposed-reviews")
        return try ids.map { id in
            try Task.checkCancellation()
            return autoreleasepool {
                let folder = parent.appendingPathComponent(id.uuidString)
                let item = try? load(id, reader: reader)
                let date = item == nil ? nil : (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return .init(id: id, created: date, selection: item?.config.selection,
                             filters: item?.config.settings.filterSummary, isComparison: item?.reference != nil)
            }
        }.sorted { ($0.created ?? .distantPast, $0.id.uuidString) > ($1.created ?? .distantPast, $1.id.uuidString) }
    }

    static func load(_ id: UUID, reader: StreamRangeReader) throws -> Self {
        let root = try reader.store.runDirectory(reader.run.id)
        let parent = try StreamFiles.directory("proposed-reviews", in: root, create: false)
        let folder = try StreamFiles.directory(id.uuidString, in: parent, create: false)
        let data = try StreamFiles.read(folder.appendingPathComponent("proposal.json"), limit: 16_777_216)
        let result = try StreamFiles.decoder.decode(Self.self, from: data)
        guard result.id == id else { throw ReviewWorkerError.stale }
        return result
    }

    func review(_ reader: StreamRangeReader, emit: @escaping (ReviewDecisionChange) throws -> Void) throws
        -> (primary: StudioRangeResult, reference: StudioRangeResult?) {
        try checkCurrent(reader)
        let input = try reader.prepared()
        let main = try StudioRangeReview.analyze(input, config: config, expectedSourceHash: sourceHash,
            pairedSpectra: true, referenceSettings: reference, change: emit)
        let baseline = try reference.map { settings in
            let cfg = StudioRangeConfig(selection: config.selection, settings: settings,
                annotationRevision: config.annotationRevision, exclusions: config.exclusions, profileRevision: config.profileRevision, contextLimit: config.contextLimit)
            return try StudioRangeReview.analyze(input, config: cfg, expectedSourceHash: sourceHash, contextSettings: config.settings)
        }
        try checkCurrent(reader)
        return (main, baseline)
    }
}

nonisolated struct ReviewWorker {
    let store: StreamProjectStore

    typealias Output = (String, any Encodable) throws -> Void

    private struct RunInfo: Encodable {
        let id: UUID
        let name: String?
        let status: String?
        let issue: String?
    }
    private struct Span: Encodable {
        let source: StreamExportRange
        let words: [UInt16]?
        let groups: [ADCAveraging.Group]?
    }
    private struct Missing: Encodable {
        let range: ReviewRange
        let status: String
    }
    private struct SpectrumSummary: Encodable {
        let sampleRate: Double
        let windows: Int
        let seconds: Double
        let raw60: Double?
        let processed60: Double?
        let reference60: Double?
        let raw120: Double?
        let processed120: Double?
        let reference120: Double?
    }
    private struct Comparison: Encodable {
        let selection: StreamSelection
        let sourceHash: String
        let evidence = "Fresh Verified Scan"
        let contextLimited: Bool
        let primary: Totals
        let reference: Totals?
        let changedDecisions: Int
        let spectra: [SpectrumSummary]
        let findings: [Finding]
        let pageOffset: Int
        let itemsAvailable: Int
        let rate_exposure_valid = 0

    }
    private enum Finding: Encodable {
        case decision(StudioRangeDecision), change(ReviewDecisionChange), minute(StudioRangeQuality.Minute)
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .decision(let item): try value.encode(item)
            case .change(let item): try value.encode(item)
            case .minute(let item): try value.encode(item)
            }
        }
    }
    private struct Totals: Encodable {
        let samples: UInt64
        let sampledSeconds: Double
        let usableSeconds: Double
        let knownMissingSeconds: Double
        let unknownGaps: Int
        let baselineNoiseCodes: Double?
        let clips: UInt64
        let errors: UInt64
        let excluded: UInt64
        let settling: UInt64
        let rawMatches: UInt64
        let processedMatches: UInt64
        let decisions: UInt64

        init(_ value: StudioRangeQuality) {
            samples = value.samples
            sampledSeconds = value.minutes.reduce(0) { $0 + $1.sampledSeconds }
            usableSeconds = value.minutes.reduce(0) { $0 + $1.usableSeconds }
            knownMissingSeconds = value.minutes.reduce(0) { $0 + $1.knownMissingSeconds }
            unknownGaps = value.gaps.filter { $0.end == nil }.count
            baselineNoiseCodes = ProfileAnalyzer.median(value.minutes.compactMap(\.noise))
            clips = value.minutes.reduce(0) { $0 + $1.clips }
            errors = value.minutes.reduce(0) { $0 + $1.errors }
            excluded = value.excluded
            settling = value.settling
            rawMatches = value.rawMatches
            processedMatches = value.processedMatches
            decisions = value.decisionCount
        }
    }

    func reader(_ id: UUID) throws -> StreamRangeReader {
        try store.verify()
        let run = try store.openRun(id)
        return .init(store: store, run: run)
    }

    static func selection(_ request: ReviewRequest, reader: StreamRangeReader) throws -> StreamSelection {
        guard let scope = request.visibleSelection else { return try selection(request.range, reader: reader) }
        guard scope.valid, scope.upper <= (try reader.duration()) + 1e-9 else {
            throw ReviewWorkerError.invalid("The review range is outside the recording.")
        }
        guard let range = request.range else { return scope }
        let requested = try selection(range, reader: reader)
        guard let segment = reader.run.segments.first(where: { $0.id == range.segment }) else {
            throw ReviewWorkerError.invalid("The requested segment is unavailable.")
        }
        let allowed = ReviewInput.indices(scope, segment: segment, rate: reader.run.settings.nominalRate)
        guard range.first >= allowed.lowerBound, range.end <= allowed.upperBound else {
            throw ReviewWorkerError.invalid("The sample range is outside the selected interval.")
        }
        return requested
    }

    static func selection(_ range: ReviewRange?, reader: StreamRangeReader) throws -> StreamSelection {
        let reader = try reader.prepared()
        let duration = try reader.duration()
        guard let range else {
            let full = StreamSelection(lower: 0, upper: duration)
            guard full.valid else { throw ReviewWorkerError.invalid("The run has no usable timeline.") }
            return full
        }
        guard let segment = reader.run.segments.first(where: { $0.id == range.segment }),
              range.count > 0, range.end <= StreamWire.maxSampleBoundary else {
            throw ReviewWorkerError.invalid("The sample range does not identify a segment in this run.")
        }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let maxIndex = (reader.index ?? []).lazy.filter { $0.segment == segment.id }.map(\.end).max() ?? 0
        guard range.end <= max(maxIndex, segment.accountedSamples) else {
            throw ReviewWorkerError.invalid("The sample range extends past the saved coverage boundary.")
        }
        let selection = StreamSelection(lower: segment.timelineStart + Double(range.first) / rate,
                                        upper: segment.timelineStart + Double(range.end) / rate)
        guard selection.valid, selection.upper <= duration + 1e-7 else {
            throw ReviewWorkerError.invalid("Invalid sample selection.")
        }
        return selection
    }

    func execute(_ request: ReviewRequest, checkpoint: @escaping () throws -> Void = {}, output: @escaping Output) throws -> any Encodable {
        try Task.checkCancellation()
        try store.verify()
        try checkpoint()
        switch request.operation {
        case .list_runs:
            let list = try store.list()
            return list.dropFirst(request.page.lowerBound).prefix(request.page.count).map {
                RunInfo(id: $0.id, name: $0.run?.name, status: $0.run?.status.rawValue, issue: $0.issue)
            }
        case .fixture_templates:
            return try FixtureTemplateStudy.templates(store).dropFirst(request.page.lowerBound).prefix(request.page.count).map(\.id)
        default: break
        }
        guard let id = request.run else { throw ReviewWorkerError.invalid("A run ID is required.") }
        let input = try reader(id)
        switch request.operation {
        case .metadata:
            if request.visibleSelection != nil {
                struct ScopedMetadata: Encodable {
                    let id: UUID
                    let mode: RecordingMode
                    let rate: Int
                    let selection: StreamSelection
                    let board: AcquisitionBoard
                    let adcBits: Int
                    let adcMaximum: UInt16
                    let channel: Int
                    let averagingFactor: Int
                    let selectedSegments: [Segment]
                    let moreSegments: Bool
                    let evidence = "Recorded Metadata"

                    struct Segment: Encodable {
                        let id: UUID
                        let firmware: String?
                        let timelineStart: Double
                        let configuredRawRate: Double
                        let recordedRate: Double
                    }
                }
                let settings = input.run.settings
                let prepared = try input.prepared()
                let selected = try Self.selection(request, reader: prepared)
                let ends = (prepared.index ?? []).reduce(into: [UUID: UInt64]()) { result, chunk in
                    result[chunk.segment] = max(result[chunk.segment, default: 0], chunk.end)
                }
                let segments = input.run.segments.filter { segment in
                    guard request.range.map({ $0.segment == segment.id }) ?? true else { return false }
                    let end = ends[segment.id, default: 0]
                    let last = max(segment.accountedSamples, end)
                    let bounds = ReviewInput.indices(selected, segment: segment, rate: settings.nominalRate)
                    return last > bounds.lowerBound && bounds.upperBound > 0
                }
                return ScopedMetadata(id: id, mode: settings.mode, rate: settings.nominalRate,
                    selection: selected, board: settings.board, adcBits: settings.board.bits, adcMaximum: settings.board.maxCode,
                    channel: settings.channel, averagingFactor: settings.factor,
                    selectedSegments: segments.prefix(16).map { segment in
                        .init(id: segment.id, firmware: segment.firmware, timelineStart: segment.timelineStart,
                              configuredRawRate: segment.rawConfiguredRate(settings.nominalRate),
                              recordedRate: segment.configuredRate(settings.nominalRate))
                    }, moreSegments: segments.count > 16)
            }
            return input.run
        case .interruption: return try ProjectReviewTools.interruption(input, request: request)
        case .find_clipping, .find_gaps:
            return try ProjectReviewTools.qualitySearch(input, request: request, clipping: request.operation == .find_clipping)
        case .export_estimate: return try ProjectReviewTools.exportEstimate(input, request: request)
        case .draft_jobs:
            guard request.runs == nil else { throw ReviewWorkerError.invalid("Use the selected Studio run.") }
            let draft = try ReviewJobDraft.make(request, readers: [input], approved: [id])
            try output("job_draft", draft)
            return draft
        case .flags:
            let values = try RunTimeline.entries(input, finished: true, resolving: false).filter { entry in
                guard let scope = request.visibleSelection else { return true }
                guard let position = entry.position else { return false }
                guard let time = RunTimeline.time(of: position, in: input.run) else { return false }
                return time >= scope.lower && time < scope.upper
            }
            return Array(values.dropFirst(request.page.lowerBound).prefix(request.page.count))
        case .waveform:
            guard let range = request.range, range.count <= 512 else {
                throw ReviewWorkerError.invalid("A waveform snippet can contain up to 512 original samples.")
            }
            let input = try input.prepared()
            let selected = try Self.selection(request, reader: input)
            var next = range.first
            var records: [Span] = []
            var gaps: [Missing] = []
            func markMissing(until end: UInt64) {
                if end > next { gaps.append(.init(range: .init(segment: range.segment, first: next, end: end), status: "missing")) }
            }
            try input.visit(selected) { part in
                guard part.segment.id == range.segment else { return }
                let first = max(range.first, part.reference.first)
                let end = min(range.end, part.reference.first + UInt64(part.reference.count))
                guard first < end else { return }
                markMissing(until: first)
                var ref = part.reference
                ref.first = first
                ref.count = Int(end - first)
                let words = (first..<end).map { StreamWire.read(UInt16.self, part.words, at: 2 * Int($0 - part.reference.first)) }
                let seconds = part.segment.timelineStart + Double(first) / part.configuredRate
                let groups = part.groups.map { Array($0[Int(first - part.reference.first)..<Int(end - part.reference.first)]) }
                records.append(.init(source: .init(input: ref, firstNominalSeconds: seconds, frame: part.frameAnchor),
                                     words: groups == nil ? words : nil, groups: groups))
                next = end
            }
            markMissing(until: range.end)
            struct Snippet: Encodable { let ranges: [Span]; let gaps: [Missing] }
            return Snippet(ranges: records, gaps: gaps)
        case .waveform_overview, .waveform_image, .device_candidates, .averaging_replay:
            let reader = try input.prepared()
            guard let range = request.range else { throw ReviewWorkerError.invalid("Choose a sample range.") }
            let selection = try Self.selection(request, reader: reader)
            switch request.operation {
            case .waveform_image, .waveform_overview:
                let evidence = try AIWaveformEvidence.make(reader, range: range, selection: selection)
                if request.operation == .waveform_image {
                    try output("waveform_image", evidence.png())
                    return evidence.imageSummary
                }
                return evidence
            case .device_candidates:
                return try UnoCandidateAnalysis.review(reader, range: range, selection: selection, page: request.page)
            default:
                return try UnoAveragingReplay.review(reader, range: range, selection: selection, page: request.page)
            }
        case .fixture_replay:
            guard let templateID = request.template, let weighted = request.weighted,
                  let template = try FixtureTemplateStudy.templates(store).first(where: { $0.id == templateID }) else {
                throw ReviewWorkerError.invalid("Choose a saved fixture template revision in this Project.")
            }
            var page: [FixtureReplayDecision] = []
            var count = 0
            let report = try FixtureReplay.preview(input, template: template, weighted: weighted, checkpoint: checkpoint) { value in
                if request.page.contains(count) { page.append(value) }
                count += 1
                try output("fixture_decision", value)
            }
            try output("fixture_evidence", report)
            struct ReplaySummary: Encodable {
                let weighted: Bool
                let existing: FixtureReplayMetrics
                let matchedFilter: FixtureReplayMetrics
                let sampledSeconds: Double?
                let usableSeconds: Double?
                let knownMissing: UInt64
                let unknownTime: Bool
                let templateSHA256: String
                let timingSHA256: String?
                let annotationRevision: UUID?
                let decisions: [FixtureReplayDecision]
                let totalDecisions: Int
                let rate_exposure_valid = 0
            }
            return ReplaySummary(weighted: report.weighted, existing: report.existing, matchedFilter: report.matchedFilter,
                sampledSeconds: report.sampledSeconds, usableSeconds: report.usableSeconds,
                knownMissing: report.knownMissing, unknownTime: report.unknownTime, templateSHA256: report.templateSHA256,
                timingSHA256: report.source.timingSHA256, annotationRevision: report.annotationRevision,
                decisions: page, totalDecisions: count)
        case .quality, .preview, .compare, .pulse_decisions, .spectra:
            return try analyze(request, reader: input, checkpoint: checkpoint, output: output)
        default: throw ReviewWorkerError.invalid("Unsupported review operation.")
        }
    }

    private func analyze(_ request: ReviewRequest, reader input: StreamRangeReader, checkpoint: @escaping () throws -> Void, output: @escaping Output) throws -> any Encodable {
        let reader = try input.prepared()
        let selection = try Self.selection(request, reader: reader)
        let settings = try (request.settings ?? ReviewWorkerSettings()).resolved(reader.run)
        let reference = try request.reference?.resolved(reader.run)
        var config = try StudioRangeReview.config(reader, selection: selection, settings: settings)
        config.contextLimit = request.visibleSelection
        let fullPulseReview = request.operation != .quality && request.operation != .spectra
        var digest = SHA256()
        var page: [Finding] = []
        var count = 0
        var changes = 0
        func retain(_ item: Finding) {
            if request.page.contains(count) { page.append(item) }
            count += 1
        }
        let primary = try StudioRangeReview.analyze(reader, config: config, includePulses: fullPulseReview,
            pairedSpectra: fullPulseReview || request.operation == .spectra, referenceSettings: reference,
            change: { value in
                changes += 1
                retain(.change(value))
                try output("decision_change", value)
            },
            source: { part in
                try checkpoint()
                digest.update(data: try StreamFiles.encoder.encode(part))
                digest.update(data: Data([10]))
                try output("source", part)
            },
            decision: { value in
                if reference == nil { retain(.decision(value)) }
                try output("decision", value)
            },
            interval: { value in try output("interval", value) })
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let peer = try reference.map { settings in
            let cfg = StudioRangeConfig(selection: selection, settings: settings, annotationRevision: config.annotationRevision,
                                        exclusions: config.exclusions, profileRevision: config.profileRevision, contextLimit: config.contextLimit)
            return try StudioRangeReview.analyze(reader, config: cfg, expectedSourceHash: hash,
                contextSettings: config.settings, source: { _ in try checkpoint() },
                decision: { try output("reference_decision", $0) },
                interval: { try output("reference_interval", $0) })
        }
        try output("quality", primary.quality)
        if let peer { try output("reference_quality", peer.quality) }
        if request.operation == .quality {
            for row in primary.quality.minutes { retain(.minute(row)) }
        }
        for value in primary.spectra { try output("raw_spectrum", value) }
        for value in primary.pairedSpectra { try output("paired_spectrum", value) }
        let recipe = ReviewProposal(project: store.identity.id, run: reader.run.id, request: request, config: config,
            reference: reference, runHash: try ReviewProposal.hash(reader.run), sourceHash: hash,
            analyzerVersion: StudioRangeReview.version, comparisonVersion: StudioRangeReview.comparisonVersion)
        if [.preview, .compare].contains(request.operation) {
            try recipe.checkCurrent(reader)
            try output("proposal", recipe)
        } else {
            try store.verify()
            struct Input: Encodable {
                let request: ReviewRequest
                let config: StudioRangeConfig
                let sourceHash: String
                let analyzerVersion: Int
                let comparisonVersion: Int
            }
            try output("recipe", Input(request: request, config: config, sourceHash: hash,
                analyzerVersion: StudioRangeReview.version, comparisonVersion: StudioRangeReview.comparisonVersion))
        }
        let spectra = primary.pairedSpectra.map { spectrum in
            SpectrumSummary(sampleRate: spectrum.sampleRate, windows: spectrum.windows, seconds: spectrum.analyzedSeconds,
                raw60: spectrum.bandPower(spectrum.raw, around: 60), processed60: spectrum.bandPower(spectrum.processed, around: 60),
                reference60: spectrum.reference.flatMap { spectrum.bandPower($0, around: 60) },
                raw120: spectrum.bandPower(spectrum.raw, around: 120), processed120: spectrum.bandPower(spectrum.processed, around: 120),
                reference120: spectrum.reference.flatMap { spectrum.bandPower($0, around: 120) })
        }
        return Comparison(selection: selection, sourceHash: hash, contextLimited: config.contextLimit != nil, primary: Totals(primary.quality), reference: peer.map { Totals($0.quality) },
            changedDecisions: changes, spectra: spectra, findings: page, pageOffset: request.page.lowerBound, itemsAvailable: count)
    }
}
