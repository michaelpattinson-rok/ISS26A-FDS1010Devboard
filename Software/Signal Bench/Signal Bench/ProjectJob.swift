import CryptoKit
import Foundation

nonisolated struct ProjectJob: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case quality, comparison, fixture, exclusions, zip, binaryZIP, csv, cleaned, averaged, binary, waveformCurve

        var title: String {
            switch self {
            case .quality: "Quality report"
            case .comparison: "Analysis comparison"
            case .fixture: "Fixture replay"
            case .exclusions: "Exclusion proposal"
            case .zip: "Full Run ZIP"
            case .binaryZIP: "Original Binary ZIP"
            case .csv: "Raw CSV"
            case .cleaned: "Cleaned CSV"
            case .averaged: "Averaged CSV"
            case .binary: "Original Binary"
            case .waveformCurve: "Waveform Curve"
            }
        }

        var format: StreamExporter.Format? {
            switch self {
            case .zip: .zip
            case .binaryZIP: .binaryZIP
            case .csv: .csv
            case .cleaned: .cleaned
            case .averaged: .averaged
            case .binary: .binary
            default: nil
            }
        }
    }

    enum State: String, Codable, Sendable {
        case queued, running, paused, completed, failed, interrupted, cancelled
        var unfinished: Bool { self == .queued || self == .running || self == .paused }
        var retryable: Bool { self == .failed || self == .interrupted || self == .cancelled }
    }

    struct Input: Codable, Sendable {
        let run: UUID
        let selection: StreamSelection
        let source: String
        let profile: UUID?
        let annotations: UUID?
        let recordedReadings: UInt64
        var ranges: [ReviewRange]? = nil

        static func pin(_ original: StreamRangeReader, selection: StreamSelection, validateCoverage: Bool = true) throws -> Self {
            let reader = try original.prepared()
            let run = reader.run
            if validateCoverage {
                guard selection.valid, selection.upper <= (try reader.duration()) + 1e-7 else {
                    throw StreamFailure.storage("Choose a range inside the saved recording.")
                }
            }
            let index = reader.index ?? []
            let annotations = try RunAnnotations.read(reader)?.id
            var digest = SHA256()
            digest.update(data: try StreamFiles.encoder.encode(run))
            digest.update(data: try StreamFiles.encoder.encode(index))
            var count: UInt64 = 0
            let segments = Dictionary(uniqueKeysWithValues: run.segments.map { ($0.id, $0) })
            var selected: [UUID: ReviewRange] = [:]
            for summary in index {
                try Task.checkCancellation()
                guard let segment = segments[summary.segment] else { continue }
                let bounds = ReviewInput.indices(selection, segment: segment, rate: run.settings.nominalRate)
                let lo = max(bounds.lowerBound, summary.first), hi = min(bounds.upperBound, summary.end)
                if hi > lo {
                    count += min(UInt64(summary.readingCount), hi - lo)
                    selected[segment.id] = .init(segment: segment.id, first: min(lo, selected[segment.id]?.first ?? lo),
                                                 end: max(hi, selected[segment.id]?.end ?? hi))
                }
            }
            guard count > 0 else { throw StreamFailure.storage("The selected range contains no saved readings.") }
            let source = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return .init(run: run.id, selection: selection, source: source, profile: run.settings.profile?.id,
                         annotations: annotations, recordedReadings: count, ranges: run.segments.compactMap { selected[$0.id] })
        }

        func verify(_ reader: StreamRangeReader) throws {
            let current = try Self.pin(reader, selection: selection)
            guard current.source == source, current.annotations == annotations, current.profile == profile,
                  ranges == nil || current.ranges == ranges else {
                throw ReviewWorkerError.stale
            }
        }
    }

    struct ModelProvenance: Codable, Sendable {
        let model: String
        let reasoning: LMStudioClient.Reasoning
        var analyzer = StudioRangeReview.version
        var comparison = StudioRangeReview.comparisonVersion
        var processing = ReviewSettings.version

        var current: Bool {
            analyzer == StudioRangeReview.version && comparison == StudioRangeReview.comparisonVersion &&
                processing == ReviewSettings.version
        }
    }

    var model: ModelProvenance? = nil
    var fixtureProofs: [Input]? = nil

    var version = 1
    var id = UUID()
    let project: UUID
    let kind: Kind
    let input: Input
    var name: String
    let estimatedBytes: Int64
    var settings: ReviewWorkerSettings? = nil
    var reference: ReviewWorkerSettings? = nil
    var template: UUID? = nil
    var templateHash: String? = nil
    var fixtureInputs: [UUID]? = nil
    var weighted: Bool? = nil
    var includeAnalyses = true
    var needsDestination = false
    var approved = Date()
    var state = State.queued
    var progress = 0.0
    var message: String?
    // This is a single file or directory name in a known Project directory.
    var output: String?
    var timingHash: String? = nil
    var curve: CurveJobSpec? = nil

    var picksDestination: Bool { kind.format != nil || curve?.action == .zip || curve?.action == .csv }
    var title: String { model != nil && kind == .zip ? "Selected Range ZIP" : (curve?.action.title ?? kind.title) }

    var valid: Bool {
        version == 1 && (model.map { (1...512).contains($0.model.utf8.count) } ?? true) && (try? SessionStore.projectName(name)) == name && input.selection.valid && ProfileDigest.valid(input.source)
            && input.recordedReadings > 0 && input.recordedReadings <= StreamWire.maxSampleBoundary * 1000
            && (0...Int64(10_000_000_000_000)).contains(estimatedBytes) && (0...1).contains(progress)
            && (message?.utf8.count ?? 0) <= 8192
            && (output.map { file in
                let base = (kind.format?.includesRunInfo == true || curve?.action == .zip || curve?.action == .csv) &&
                    (file.lowercased().hasSuffix(".zip") || file.lowercased().hasSuffix(".csv")) ? String(file.dropLast(4)) : file
                return (try? SessionStore.projectName(base)) == base
            } ?? true)
            && (kind == .fixture ? template != nil && templateHash.map(ProfileDigest.valid) == true &&
                (1...17).contains(fixtureInputs?.count ?? 0) && (timingHash.map(ProfileDigest.valid) ?? true) :
                template == nil && fixtureInputs == nil && timingHash == nil)
            && (kind == .comparison ? settings != nil && reference != nil : reference == nil)
            && (!needsDestination || picksDestination)
            && (kind == .waveformCurve ? curve?.valid == true : curve == nil)
    }

    static func export(_ reader: StreamRangeReader, name: String, selection: StreamSelection, format: StreamExporter.Format,
                       includeAnalyses: Bool, external: Bool) throws -> Self {
        let input = try Input.pin(reader, selection: selection)
        let settings = reader.run.settings
        let kind = Kind.allCases.first { $0.format == format }!
        let bytes = format.estimatedBytes(samples: input.recordedReadings, averaging: settings.adcAveraging,
            pico: settings.picoAveraging, hasExclusions: !(try RunAnnotations.read(reader)?.masks.isEmpty ?? true), board: settings.board)
        return .init(project: reader.store.identity.id, kind: kind, input: input,
                     name: try SessionStore.projectName(name), estimatedBytes: Int64(bytes.rounded(.up)),
                     includeAnalyses: includeAnalyses, needsDestination: external)
    }
}

nonisolated enum ProjectJobFiles {
    static let folderName = "jobs"

    static func load(_ store: StreamProjectStore, reconcile: Bool = true) throws -> [ProjectJob] {
        let root = store.folder.appendingPathComponent(folderName)
        guard try StreamFiles.isPresent(root) else { return [] }
        try StreamFiles.directory(root)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard entries.count <= 10_000 else { throw StreamFailure.storage("The Project job history exceeds its limit.") }
        return try entries.compactMap { url -> ProjectJob? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            var job = try StreamFiles.decoder.decode(ProjectJob.self, from: StreamFiles.read(url, limit: 32_768))
            guard job.valid, job.project == store.identity.id, job.id == id else {
                throw StreamFailure.storage("A job in this Project cannot be read.")
            }
            if reconcile && job.state.unfinished {
                job.state = .interrupted
                job.message = "The Project closed before this job completed. Retry to run it again."
            }
            return job
        }.sorted { $0.approved > $1.approved }
    }

    static func save(_ job: ProjectJob, in store: StreamProjectStore) throws {
        try store.verify()
        guard job.valid, job.project == store.identity.id else { throw ReviewWorkerError.invalid("Invalid Project job.") }
        let root = try StreamFiles.directory(folderName, in: store.folder, create: true)
        let url = root.appendingPathComponent(job.id.uuidString + ".json")
        try StreamFiles.publish(job, at: url, replace: try StreamFiles.isPresent(url))
    }

    static func resultFolder(_ store: StreamProjectStore, create: Bool) throws -> URL {
        let root = try StreamFiles.directory(folderName, in: store.folder, create: create)
        return try StreamFiles.directory("results", in: root, create: create)
    }

    static func exclusionProposal(_ job: ProjectJob, reader: StreamRangeReader) throws -> JobExclusionProposal {
        guard job.kind == .exclusions, job.project == reader.store.identity.id, job.input.run == reader.run.id,
              job.state == .completed, job.output == job.id.uuidString else { throw ReviewWorkerError.stale }
        try job.input.verify(reader)
        let folder = try StreamFiles.directory(job.id.uuidString, in: resultFolder(reader.store, create: false), create: false)
        let data = try StreamFiles.read(folder.appendingPathComponent("exclusion-proposal.json"), limit: 16 * 1024 * 1024)
        let value = try StreamFiles.decoder.decode(JobExclusionProposal.self, from: data)
        guard value.version == 1, value.input.source == job.input.source, value.input.selection == job.input.selection,
              value.input.annotations == job.input.annotations, value.input.run == job.input.run,
              value.intervals.count <= 20_000, value.intervals.allSatisfy({ interval in
                  guard interval.action == .excluded, interval.range.count > 0, interval.note.utf8.count <= 400,
                        let segment = reader.run.segments.first(where: { $0.id == interval.range.segment }) else { return false }
                  let limits = ReviewInput.indices(job.input.selection, segment: segment, rate: reader.run.settings.nominalRate)
                  return interval.range.first >= limits.lowerBound && interval.range.end <= limits.upperBound
              }) else { throw ReviewWorkerError.stale }
        return value
    }

    static func execute(_ job: ProjectJob, store: StreamProjectStore, destination: URL?, control: ProjectJobControl,
                        progress: @escaping (Double) -> Void) throws -> URL {
        guard job.valid, job.project == store.identity.id else { throw ReviewWorkerError.stale }
        if job.kind == .waveformCurve {
            return try CurveDelivery.execute(job, store: store, destination: destination, control: control, progress: progress)
        }
        let run = try store.openRun(job.input.run)
        let reader = try StreamRangeReader(store: store, run: run).prepared()
        let leases = try Set([run.id] + (job.fixtureInputs ?? [])).map { try ProjectReview.ReadLease(store.runDirectory($0)) }
        defer { withExtendedLifetime(leases) {} }
        func verifyInputs() throws {
            guard job.model?.current != false else { throw ReviewWorkerError.stale }
            try job.input.verify(.init(store: store, run: store.openRun(run.id)))
            for proof in job.fixtureProofs ?? [] {
                try proof.verify(.init(store: store, run: store.openRun(proof.run)))
            }
        }
        try verifyInputs()
        try control.checkpoint()
        if let format = job.kind.format {
            guard !job.needsDestination || destination != nil else { throw StreamFailure.storage("Choose an export location to retry this job.") }
            let folder = try destination ?? store.exports()
            if let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                let minimum = format.writesBinary ? Int64(job.input.recordedReadings) * Int64(PicoAverage.stride(run.settings.picoAveraging, board: run.settings.board)) :
                    min(job.estimatedBytes, 64 * 1024 * 1024)
                guard Int64(available) >= minimum else { throw StreamFailure.storage("The selected export volume is short on free space.") }
            }
            return try StreamExporter.export(reader, name: job.name, selection: job.input.selection, format: format,
                includeAnalyses: job.includeAnalyses, destination: folder, scoped: job.model != nil, progress: progress,
                checkpoint: control.checkpoint, beforePublish: {
                    try verifyInputs()
                    try control.checkpoint()
                })
        }
        let parent = try resultFolder(store, create: true)
        let url = try ReviewFiles.publish(in: parent, name: job.id.uuidString) { stage in
            let writer = try StreamOutput(stage.appendingPathComponent("findings.jsonl"))
            var recipe = ReviewRequest(operation: .quality, run: run.id, visibleSelection: job.input.selection)
            switch job.kind {
            case .quality: break
            case .comparison:
                recipe = .init(operation: .compare, run: run.id, settings: job.settings, reference: job.reference,
                               visibleSelection: job.input.selection)
            case .exclusions:
                let settings = try (job.settings ?? ReviewWorkerSettings()).resolved(run)
                let masks = try RunAnnotations.preview(reader, selection: job.input.selection, policy: .conservative, settings: settings,
                                                      limitContext: job.model != nil, checkpoint: control.checkpoint)
                let proposal = JobExclusionProposal(input: job.input, intervals: masks)
                try StreamFiles.publish(proposal, at: stage.appendingPathComponent("exclusion-proposal.json"))
                for mask in masks { try writer.item(mask) }
            case .fixture:
                guard let template = try FixtureTemplateStudy.templates(store).first(where: { $0.id == job.template }),
                      try StreamFiles.sha(StreamFiles.encoder.encode(template)) == job.templateHash,
                      try FixtureTemplateStudy.fullRange(reader) == job.input.selection else { throw ReviewWorkerError.stale }
                if let expected = job.timingHash, try FixtureEvidence.reference(reader).1 != expected { throw ReviewWorkerError.stale }
                recipe = .init(operation: .fixture_replay, run: run.id, template: template.id, weighted: job.weighted ?? false)
            default: throw ReviewWorkerError.invalid("Unsupported review job.")
            }
            if job.kind != .exclusions {
                var sources = 0
                let result = try ReviewWorker(store: store).execute(recipe, checkpoint: control.checkpoint) { kind, item in
                    try control.checkpoint()
                    if kind == "source" {
                        sources += 1
                        if sources.isMultiple(of: 256) {
                            progress(min(0.8, 0.8 * Double(sources * 256) / Double(job.input.recordedReadings)))
                        }
                    }
                    if kind != "proposal" { try writer.item(item) }
                    else if let proposal = item as? ReviewProposal {
                        try StreamFiles.publish(proposal, at: stage.appendingPathComponent("proposed-review.json"))
                    }
                }
                try StreamFiles.publish(StreamFiles.encoder.encode(result), at: stage.appendingPathComponent("summary.json"))
            }
            _ = try writer.finish(file: "findings.jsonl", type: "signalbench.job-findings")
            try StreamFiles.publish(job, at: stage.appendingPathComponent("job.json"))
            try verifyInputs()
            if let expected = job.timingHash, try FixtureEvidence.reference(reader).1 != expected { throw ReviewWorkerError.stale }
            try control.checkpoint()
        }
        progress(1)
        return url
    }
}

nonisolated struct JobExclusionProposal: Codable, Sendable {
    var version = 1
    let input: ProjectJob.Input
    let intervals: [ReviewInterval]
}

/// Only a background job waits on this condition. A recording never waits
/// on a job, and resuming continues at the exact export or analysis checkpoint.
nonisolated final class ProjectJobControl: @unchecked Sendable {
    private let gate = NSCondition()
    private var pause = false
    private var stopped = false

    func setPaused(_ value: Bool) {
        gate.lock()
        pause = value
        gate.broadcast()
        gate.unlock()
    }

    func cancel() {
        gate.lock()
        stopped = true
        gate.broadcast()
        gate.unlock()
    }

    func checkpoint() throws {
        gate.lock()
        defer { gate.unlock() }
        while pause && !stopped { gate.wait() }
        if stopped { throw CancellationError() }
        try Task.checkCancellation()
    }
}
