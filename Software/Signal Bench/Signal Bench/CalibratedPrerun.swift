import CryptoKit
import Foundation

nonisolated enum CalibratedPrerun {
    enum Length: Int, CaseIterable, Identifiable, Codable, Sendable {
        case one = 1, five = 5, fifteen = 15
        var id: Int { rawValue }
        var seconds: Double { Double(rawValue * 60) }
    }

    enum Measurement: Int, CaseIterable, Identifiable, Codable, Sendable {
        case five = 5, fifteen = 15, thirty = 30, hour = 60, twoHours = 120
        var id: Int { rawValue }
        var seconds: Double { Double(rawValue * 60) }
        var title: String {
            if self == .hour { return "1 hour" }
            if self == .twoHours { return "2 hours" }
            return "\(rawValue) min"
        }
    }

    struct Plan: Codable, Equatable, Sendable {
        let length: Length
        let measurementSeconds: Double
        let continuation: UUID?
        let policy: NoisePolicy

        var valid: Bool {
            if continuation != nil { return (1...StreamWire.maxDuration).contains(measurementSeconds) }
            return Measurement.allCases.contains { $0.seconds == measurementSeconds }
        }
    }

    struct Link: Codable, Hashable, Sendable {
        let run: UUID
        let reportSHA256: String
        var valid: Bool { ProfileDigest.valid(reportSHA256) }
    }

    struct Report: Codable, Equatable, Sendable {
        var version = 1
        var algorithm = CalibrationProfile.algorithm
        let plan: Plan
        let project: UUID
        let run: UUID
        let profile: UUID
        let inputSHA256: String
        let coverage: ProfileCoverage
        let quality: ManualSampleQuality
        let baseline: Double?
        let noise: Double?
        let drift: Double?
        let issues: [String]

        var passed: Bool { issues.isEmpty }

        func matches(_ run: StreamRun) -> Bool {
            version == 1 && algorithm == CalibrationProfile.algorithm && plan.valid &&
                run.settings.prerunPlan == plan && run.project == project && run.id == self.run &&
                run.settings.profile?.id == profile && ProfileDigest.valid(inputSHA256) &&
                coverage.valid && issues.count <= 32 && issues.allSatisfy { $0.utf8.count <= 500 } &&
                (!passed || (run.status == .complete && run.segments.count == 1 && !run.hasCadenceMismatch &&
                    run.segments.first?.deadlineReached == true && run.segments.first?.knownLoss == 0 &&
                    !run.hasUnknownCoverage && quality.samples > 0 &&
                    quality.samples == run.segments.first?.savedSamples))
        }

        func link() throws -> Link {
            .init(run: run, reportSHA256: StreamFiles.sha(try StreamFiles.encoder.encode(self)))
        }
    }

    struct Result: Sendable {
        let report: Report
        let link: Link
    }

    static func snapshot(_ reader: StreamRangeReader, verifyPayload: Bool = false,
                         checkpoint: () throws -> Void = {}) throws -> String {
        var hash = SHA256()
        hash.update(data: try StreamFiles.encoder.encode(reader.run.settings))
        hash.update(data: try StreamFiles.encoder.encode(reader.run.segments))
        for summary in try reader.index ?? reader.store.chunkSummaries(reader.run) {
            try Task.checkCancellation()
            try checkpoint()
            try autoreleasepool {
                let chunk = try reader.store.chunk(summary, run: reader.run)
                if verifyPayload { _ = try reader.store.data(summary, run: reader.run) }
                hash.update(data: Data(SHA256.hash(data: try StreamFiles.encoder.encode(chunk))))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ link: Link, in store: StreamProjectStore, checkPayload: Bool = false,
                       checkpoint: () throws -> Void = {}) throws -> StreamRangeReader {
        do {
            let run = try store.openRun(link.run)
            guard link.valid, run.curveSource == nil, let report = run.prerunReport,
                  report.matches(run), try report.link() == link else {
                throw StreamFailure.storage("The check report is missing or changed.")
            }
            let reader = try StreamRangeReader(store: store, run: run).prepared()
            guard try snapshot(reader, verifyPayload: checkPayload, checkpoint: checkpoint) == report.inputSHA256 else {
                throw StreamFailure.storage("The saved samples or timing changed.")
            }
            return reader
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StreamFailure.storage("Prerun \(link.run.uuidString) could not be verified. " + error.localizedDescription)
        }
    }

    static func verifyForRecording(_ link: Link, settings: StreamRunSettings, in store: StreamProjectStore,
                                   continuing: UUID? = nil) throws {
        let source = try verify(link, in: store, checkPayload: true).run
        guard let report = source.prerunReport, source.settings.board == settings.board,
              source.settings.nominalRate == settings.nominalRate, source.settings.channel == settings.channel,
              source.settings.picoAveraging == settings.picoAveraging else {
            throw StreamFailure.storage("The prerun belongs to a different device or sample configuration.")
        }
        if settings.mode == .calibrated {
            guard source.settings.profile == settings.profile, source.settings.gain == settings.gain,
                  validate(.init(report: report, link: link), for: settings, continuation: continuing) else {
                throw StreamFailure.storage("The saved prerun does not qualify this measurement.")
            }
        }
    }

    static func remaining(for run: StreamRun) -> Double {
        guard let last = run.segments.last else { return run.settings.duration }
        let end = last.timelineStart + Double(last.accountedSamples) / last.configuredRate(run.settings.nominalRate)
        return max(0, run.settings.duration - end)
    }

    static func validate(_ result: Result, for settings: StreamRunSettings, continuation: UUID?) -> Bool {
        result.report.passed && result.report.profile == settings.profile?.id &&
            result.report.plan.measurementSeconds == settings.duration &&
            result.report.plan.continuation == continuation &&
            result.report.plan.policy == (settings.noisePolicy ?? .review)
    }
}

extension CalibratedPrerun {
    nonisolated static func export(_ link: Link, in store: StreamProjectStore, archive: RunExportZIP,
                       format: StreamExporter.Format, staging: URL, checkpoint: () throws -> Void,
                       progress: (Double) -> Void) throws -> [StreamAnalysisOutput] {
        let reader = try verify(link, in: store, checkpoint: checkpoint)
        let run = reader.run
        let prefix = "calibration/\(run.id.uuidString)/"
        var outputs: [StreamAnalysisOutput] = []
        func metadata<T: Encodable>(_ value: T, name: String, type: String) throws {
            try checkpoint()
            let output = try StreamOutput(member: archive.entry(prefix + name))
            try output.write(StreamFiles.encoder.encode(value))
            outputs.append(try output.finish(file: prefix + name, type: type))
        }
        try metadata(run, name: "run.json", type: run.type)
        if let report = run.prerunReport { try metadata(report, name: "check.json", type: "signalbench.dark-prerun") }
        if let profile = run.settings.profile { try metadata(profile, name: "profile.json", type: "signalbench.calibration-profile") }

        let duration = try reader.duration()
        if duration > 0, let report = run.prerunReport, reader.index?.isEmpty == false {
            let folder = try StreamFiles.directory(".prerun-\(run.id.uuidString)", in: staging, create: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let indexURL = folder.appendingPathComponent("ranges.jsonl")
            let index = try StreamOutput(indexURL)
            let samples = try RunExportSamples(root: folder, archive: archive, format: format,
                                               settings: run.settings, hasExclusions: false, prefix: prefix)
            let prefixes = Dictionary(uniqueKeysWithValues: run.segments.map {
                ($0.id, Data("\($0.id.uuidString),\($0.stream),".utf8))
            })
            var offset: UInt64 = 0
            var percent = 0
            try reader.visit(.init(lower: 0, upper: duration)) { part in
                try checkpoint()
                try index.item(StreamExportRange(input: part.reference, outputSampleOffset: offset,
                                                 firstNominalSeconds: part.firstSeconds, frame: part.frameAnchor))
                let range = part.reference.first..<(part.reference.first + UInt64(part.reference.count))
                try samples.append(part, range: range, retained: [range],
                                   prefix: prefixes[part.segment.id] ?? Data(), checkpoint: checkpoint)
                offset += UInt64(part.reference.count)
                let next = min(99, Int(Double(offset) * 100 / Double(max(1, report.quality.samples))))
                if next > percent { percent = next; progress(Double(next) / 100) }
            }
            guard offset == report.quality.samples else {
                throw StreamFailure.storage("Prerun \(run.id.uuidString) reading counts did not reconcile.")
            }
            outputs += try samples.finish(checkpoint: checkpoint)
            outputs.append(try index.finish(file: prefix + "ranges.jsonl", type: "signalbench.raw-ranges"))
            try archive.addFile(indexURL, as: prefix + "ranges.jsonl", checkpoint: checkpoint)
        }
        _ = try verify(link, in: store, checkpoint: checkpoint)
        progress(1)
        return outputs
    }
}
