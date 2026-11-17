import Darwin
import Foundation

nonisolated enum ReviewFiles {
    static func publish(in parent: URL, name: String, _ write: (URL) throws -> Void) throws -> URL {
        let target = parent.appendingPathComponent(try SessionStore.projectName(name), isDirectory: true)
        try StreamFiles.directory(parent)
        if try StreamFiles.isPresent(target) { throw POSIXError(.EEXIST) }
        let stage = try StreamFiles.directory(".pending-" + UUID().uuidString, in: parent, create: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }
        try write(stage)
        try Task.checkCancellation()
        try StreamFiles.sync(stage)
        guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        published = true
        try StreamFiles.sync(parent)
        return target
    }

    static func csv(_ value: String) -> String {
        var text = value
        if let first = text.first, first.isWhitespace ||
            ["=", "+", "-", "@"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).first ?? " ") {
            text = "'" + text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

nonisolated struct SavedReview: Codable, Sendable {
    var type = "signalbench.waveform-review"
    var version = ReviewSettings.version
    var selection: StreamSelection
    var settings: ReviewSettings
    var manual: [ReviewInterval]
    var sources: [StreamRangeReference]
    var sampled: UInt64
    var excluded: UInt64
    var rawMatches: Int
    var previewMatches: Int
    var overflow: Bool
    var countingValidated = false
    var timingReferenceSHA256: String? = nil
    var rawFixture: FixtureComparison? = nil
    var processedFixture: FixtureComparison? = nil
    var templateSourceIsThisRun: Bool? = nil
}

nonisolated enum ReviewStorage {
    static func save(_ reader: StreamRangeReader, selection: StreamSelection, settings: ReviewSettings,
                     manual: [ReviewInterval]) throws -> StreamAnalysisManifest {
        let input = try ReviewInput.load(reader, selection: selection)
        let result = try StudioReview.analyze(input, settings: settings, manual: manual)
        guard result.sampled > 0 else { throw StreamFailure.storage("The selection contains no saved samples.") }
        let folder = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: true)
        var config = SavedReview(version: settings.ruleVersion, selection: selection, settings: settings, manual: manual, sources: input.refs,
                                 sampled: result.sampled, excluded: result.excluded, rawMatches: result.rawCount,
                                 previewMatches: result.processedCount, overflow: result.overflow)
        if let (reference, hash) = try? FixtureEvidence.reference(reader) {
            config.timingReferenceSHA256 = hash
            config.rawFixture = FixtureEvidence.compare(reference, input: input, result: result, processed: false)
            config.processedFixture = FixtureEvidence.compare(reference, input: input, result: result, processed: true)
            config.templateSourceIsThisRun = settings.template?.run == reader.run.id
        }
        var manifest = StreamAnalysisManifest(run: reader.run.id, selection: selection,
                                              streams: Array(Set(input.refs.map(\.stream))).sorted(), analyzer: "signalbench.waveform-review",
                                              analyzerVersion: config.version, profileRevision: reader.run.settings.profile?.id,
                                              rules: reader.run.settings.profile?.rules, status: result.overflow ? "partial" : "complete", outputs: [])
        _ = try ReviewFiles.publish(in: folder, name: manifest.id.uuidString) { stage in
            let setting = try StreamOutput(stage.appendingPathComponent("review.json"))
            try setting.write(StreamFiles.encoder.encode(config))
            let intervals = try StreamOutput(stage.appendingPathComponent("exclusions.jsonl"))
            for item in result.intervals { try intervals.item(item) }
            let raw = try StreamOutput(stage.appendingPathComponent("raw-decisions.jsonl"))
            for item in result.raw { try raw.item(item) }
            let processed = try StreamOutput(stage.appendingPathComponent("processed-decisions.jsonl"))
            for item in result.processed { try processed.item(item) }
            manifest.outputs = [
                try setting.finish(file: "review.json", type: config.type),
                try intervals.finish(file: "exclusions.jsonl", type: "signalbench.exclusion-intervals"),
                try raw.finish(file: "raw-decisions.jsonl", type: "signalbench.review-pulse-decisions"),
                try processed.finish(file: "processed-decisions.jsonl", type: "signalbench.review-pulse-decisions")
            ]
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return manifest
    }

    static func load(_ reader: StreamRangeReader, manifest: StreamAnalysisManifest) throws -> SavedReview {
        guard manifest.run == reader.run.id, manifest.analyzer == "signalbench.waveform-review",
              let output = manifest.outputs.first(where: { $0.file == "review.json" && $0.type == "signalbench.waveform-review" && $0.version == 1 }) else {
            throw StreamFailure.storage("This analysis is not a saved waveform review.")
        }
        let root = try reader.store.runDirectory(reader.run.id).appendingPathComponent("analyses").appendingPathComponent(manifest.id.uuidString)
        let data = try StreamFiles.read(root.appendingPathComponent(output.file), limit: 1_048_576)
        guard data.count == output.bytes, StreamFiles.sha(data) == output.sha256 else {
            throw StreamFailure.storage("The saved review failed its integrity check.")
        }
        var config = try StreamFiles.decoder.decode(SavedReview.self, from: data)
        if config.version == 1, config.settings.algorithmVersion == nil { config.settings.algorithmVersion = 1 }
        guard (1...ReviewSettings.version).contains(config.version), config.version == manifest.analyzerVersion,
              config.version == config.settings.ruleVersion, config.type == output.type, config.settings.valid,
              config.selection == manifest.selection, config.manual.count <= 256, !config.countingValidated else {
            throw StreamFailure.storage("The saved review uses unsupported settings.")
        }
        let current = try ReviewInput.load(reader, selection: config.selection)
        guard current.refs == config.sources else { throw StreamFailure.storage("The saved review’s raw range or filter context differs from the current index. Its original results remain in the analysis folder.") }
        return config
    }

    static func cleaned(_ reader: StreamRangeReader, name: String, selection: StreamSelection, settings: ReviewSettings,
                        manual: [ReviewInterval], destination: URL? = nil) throws -> URL {
        let name = try SessionStore.projectName(name)
        let input = try ReviewInput.load(reader, selection: selection)
        let result = try StudioReview.analyze(input, settings: settings, manual: manual)
        guard result.sampled > 0 else { throw StreamFailure.storage("The selection contains no saved samples.") }
        return try ReviewFiles.publish(in: destination ?? reader.store.exports(), name: name) { folder in
            let samples = try StreamOutput(folder.appendingPathComponent("cleaned.csv"))
            let exclusions = try StreamOutput(folder.appendingPathComponent("exclusions.csv"))
            let timing = try StreamOutput(folder.appendingPathComponent("source-ranges.jsonl"))
            try reader.visit(selection) { part in
                try timing.item(StreamExportRange(input: part.reference, firstNominalSeconds: part.firstSeconds,
                                                  frame: part.frameAnchor))
            }
            try samples.line("segment,stream_id,original_index,nominal_time_s,raw_word,adc_code")
            try exclusions.line("segment,first_index,end_index_exclusive,reason,action,note,rule_version")
            let rate = reader.run.settings.nominalRate
            let masks = Dictionary(grouping: result.intervals.filter { $0.action == .excluded }, by: { $0.range.segment })
            for span in input.spans {
                let bounds = ReviewInput.indices(selection, segment: span.segment, rate: rate)
                let first = max(span.first, bounds.lowerBound), end = min(span.end, bounds.upperBound)
                guard first < end else { continue }
                let intervals = masks[span.segment.id, default: []].map(\.range).sorted { $0.first < $1.first }
                var cursor = 0
                for i in first..<end {
                    if i.isMultiple(of: 1024) { try Task.checkCancellation() }
                    while cursor < intervals.count && intervals[cursor].end <= i { cursor += 1 }
                    guard cursor == intervals.count || intervals[cursor].first > i else { continue }
                    let word = span.words[Int(i - span.first)]
                    let time = span.segment.timelineStart + Double(i) / Double(rate)
                    try samples.line("\(span.segment.id),\(span.segment.stream),\(i),\(time),\(word),\(span.segment.board.sampleCode(word))")
                }
            }
            for item in result.intervals {
                let range = item.range
                try exclusions.line("\(range.segment),\(range.first),\(range.end),\(ReviewFiles.csv(item.reason.rawValue)),\(item.action.rawValue),\(ReviewFiles.csv(item.note)),\(settings.ruleVersion)")
            }
            let files = [try samples.finish(file: "cleaned.csv", type: "signalbench.cleaned-raw-csv"),
                         try exclusions.finish(file: "exclusions.csv", type: "signalbench.exclusion-csv"),
                         try timing.finish(file: "source-ranges.jsonl", type: "signalbench.raw-ranges")]
            try StreamFiles.publish(files, at: folder.appendingPathComponent("files.json"))
            try StreamFiles.publish(reader.run, at: folder.appendingPathComponent("run.json"))
            let config = SavedReview(version: settings.ruleVersion, selection: selection, settings: settings, manual: manual, sources: input.refs,
                                     sampled: result.sampled, excluded: result.excluded, rawMatches: result.rawCount,
                                     previewMatches: result.processedCount, overflow: result.overflow)
            try StreamFiles.publish(config, at: folder.appendingPathComponent("review.json"))
            try reader.store.verify()
        }
    }
}
