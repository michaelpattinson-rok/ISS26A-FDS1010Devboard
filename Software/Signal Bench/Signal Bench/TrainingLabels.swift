import Foundation

nonisolated enum RegionLabel: String, CaseIterable, Codable, Identifiable, Sendable {
    case fixture = "Known fixture pulse", glitch = "Short glitch", noise = "Noise burst", baseline = "Ordinary baseline", unknown = "Unknown"
    var id: Self { self }
}
nonisolated enum DatasetGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case training, validation, test, review
    var id: Self { self }
}
nonisolated struct TrainingFrameAnchor: Codable, Equatable, Sendable {
    var firstIndex: UInt64
    var endIndex: UInt64
    var sequence: UInt32
    var deviceEndUS: UInt64
}
nonisolated struct TrainingLabel: Codable, Identifiable, Sendable {
    var version = 1
    var id = UUID()
    var project: UUID
    var run: UUID
    var group: UUID
    var created = Date()
    var category: RegionLabel
    var source: String
    var reason: String
    var event: ReviewRange
    var context: ReviewRange
    var nominalRate: Int
    var deviceStartUS: UInt64?
    var timelineStart: Double
    var profileRevision: UUID?
    var benchSetup: BenchRunContext?
    var runSettings: StreamRunSettings
    var refs: [StreamRangeReference]
    var rawSHA256: String
    var timingReferenceSHA256: String?
    var frameAnchors: [TrainingFrameAnchor]? = nil
}

nonisolated enum TrainingLabels {
    private static func directory(_ project: StreamProjectStore, _ kind: String, create: Bool) throws -> URL? {
        let root = project.folder.appendingPathComponent("training")
        let path = root.appendingPathComponent(kind)
        guard create || StreamFiles.exists(path) else { return nil }
        let folder = try StreamFiles.directory("training", in: project.folder, create: create)
        return try StreamFiles.directory(kind, in: folder, create: create)
    }

    static func partition(_ project: StreamProjectStore, group: UUID) throws -> DatasetGroup {
        guard let dir = try directory(project, "groups", create: false) else { return .review }
        let file = dir.appendingPathComponent(group.uuidString + ".json")
        guard StreamFiles.exists(file) else { return .review }
        struct Assignment: Decodable { var version: Int; var group: UUID; var partition: DatasetGroup }
        let value = try StreamFiles.read(Assignment.self, file)
        guard value.version == 1, value.group == group else { throw ProfileWorkflowError.invalidEvidence }
        return value.partition
    }

    static func assign(_ partition: DatasetGroup, project: StreamProjectStore, group: UUID) throws {
        try project.verify()
        guard let dir = try directory(project, "groups", create: true) else { throw ProfileWorkflowError.unavailable }
        let file = dir.appendingPathComponent(group.uuidString + ".json")
        struct Assignment: Encodable { var version = 1; var group: UUID; var partition: DatasetGroup }
        try StreamFiles.publish(Assignment(group: group, partition: partition), at: file, replace: StreamFiles.exists(file))
    }

    static func list(_ project: StreamProjectStore) throws -> [TrainingLabel] {
        guard let folder = try directory(project, "labels", create: false) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard entries.count <= 20_000 else { throw StreamFailure.storage("Too many labels in this Project.") }
        return try entries.filter { $0.pathExtension == "json" }.map { file in
            let label = try StreamFiles.read(TrainingLabel.self, file)
            guard label.version == (label.runSettings.picoAveraging == nil ? 1 : 2), label.project == project.identity.id, label.id.uuidString + ".json" == file.lastPathComponent,
                  label.event.segment == label.context.segment, (1...32_768).contains(label.event.count),
                  (1...65_536).contains(label.context.count), label.context.first <= label.event.first,
                  label.context.end >= label.event.end, StreamWire.customRates.contains(label.nominalRate),
                  ProfileDigest.valid(label.rawSHA256), label.reason.utf8.count <= 2048 else {
                throw ProfileWorkflowError.invalidEvidence
            }
            return label
        }.sorted { $0.created > $1.created }
    }

    static func add(_ reader: StreamRangeReader, selection: StreamSelection, category: RegionLabel,
                    reason: String, context count: Int) throws -> TrainingLabel {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.utf8.count <= 2048, (0...16_384).contains(count) else {
            throw StreamFailure.storage("Enter a reason and valid context in samples.")
        }
        try reader.store.verify()
        let lock = try StreamRunLock(reader.store.runDirectory(reader.run.id))
        defer { withExtendedLifetime(lock) {} }
        let reader = try reader.prepared()
        let rate = reader.run.settings.nominalRate
        let input = try ReviewInput.load(reader, selection: selection, context: min(0.5, Double(count) / reader.run.settings.recordedRate))
        let intersecting = input.spans.filter {
            let bounds = ReviewInput.indices(selection, segment: $0.segment, rate: rate)
            return max(bounds.lowerBound, $0.first) < min(bounds.upperBound, $0.end)
        }
        guard intersecting.count == 1, let span = intersecting.first else {
            throw StreamFailure.storage("A label must fit inside one contiguous acquisition span.")
        }
        let event = ReviewInput.indices(selection, segment: span.segment, rate: rate)
        guard event.lowerBound >= span.first, event.upperBound <= span.end, (1...32_768).contains(event.count) else {
            throw StreamFailure.storage("Select up to 32,768 saved samples inside one contiguous span.")
        }
        var timing: String?
        if category == .fixture {
            let (reference, digest) = try FixtureEvidence.reference(reader)
            let tolerance = reference.uncertaintySamples
            let values = reference.pulsesUS.map(reference.index).filter {
                $0 + tolerance >= Double(event.lowerBound) && $0 - tolerance < Double(event.upperBound)
            }
            guard reference.stream == span.segment.stream, values.count == 1, let tick = values.first,
                  tick - tolerance >= Double(event.lowerBound), tick + tolerance < Double(event.upperBound) else {
                throw StreamFailure.storage("A known fixture label requires one aligned reference pulse within the selected range.")
            }
            timing = digest
        }
        let first = max(span.first, event.lowerBound - min(event.lowerBound, UInt64(count)))
        let end = min(span.end, event.upperBound + UInt64(count))
        let context = ReviewRange(segment: span.segment.id, first: first, end: end)
        let (data, refs) = try raw(reader, range: context)
        let label = TrainingLabel(version: reader.run.settings.picoAveraging == nil ? 1 : 2, project: reader.store.identity.id, run: reader.run.id,
                                  group: reader.run.settings.bench?.sequence ?? reader.run.id,
                                  category: category, source: timing == nil ? "operator" : "operator and independent fixture timing",
                                  reason: reason, event: .init(segment: span.segment.id, first: event.lowerBound, end: event.upperBound),
                                  context: context, nominalRate: rate, deviceStartUS: span.segment.firstDeviceUS,
                                  timelineStart: span.segment.timelineStart, profileRevision: reader.run.settings.profile?.id,
                                  benchSetup: reader.run.settings.bench, runSettings: reader.run.settings,
                                  refs: refs, rawSHA256: StreamFiles.sha(data), timingReferenceSHA256: timing,
                                  frameAnchors: try anchors(reader, range: context, refs: refs))
        if let existing = try list(reader.store).first(where: { $0.run == label.run && $0.event == label.event }) {
            guard existing.category == label.category, existing.reason == label.reason, existing.context == label.context,
                  existing.rawSHA256 == label.rawSHA256 else {
                throw StreamFailure.storage("This exact range already has a saved label. The original label is still available.")
            }
            return existing
        }
        guard let folder = try directory(reader.store, "labels", create: true) else { throw ProfileWorkflowError.unavailable }
        try StreamFiles.publish(label, at: folder.appendingPathComponent(label.id.uuidString + ".json"))
        return label
    }

    private static func anchors(_ reader: StreamRangeReader, range: ReviewRange,
                                refs: [StreamRangeReference]) throws -> [TrainingFrameAnchor] {
        let chunks = Set(refs.map(\.chunk))
        let prepared = try reader.prepared()
        return try (prepared.index ?? []).filter { chunks.contains($0.id) }.flatMap { summary in
            let chunk = try reader.store.chunk(summary, run: reader.run)
            return chunk.slices.compactMap { item -> TrainingFrameAnchor? in
                let end = item.first + UInt64(item.count)
                guard item.first < range.end, end > range.first else { return nil }
                return TrainingFrameAnchor(firstIndex: item.first, endIndex: end, sequence: item.sequence, deviceEndUS: item.deviceEndUS)
            }
        }
    }

    private static func raw(_ reader: StreamRangeReader, range: ReviewRange) throws -> (Data, [StreamRangeReference]) {
        guard let segment = reader.run.segments.first(where: { $0.id == range.segment }), range.count <= 65_536 else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let selection = StreamSelection(lower: segment.timelineStart + Double(range.first) / rate,
                                        upper: segment.timelineStart + Double(range.end) / rate)
        var data = Data(), refs: [StreamRangeReference] = []
        var next = range.first
        try reader.visit(selection) { part in
            guard part.reference.segment == range.segment, part.reference.first == next else { throw ProfileWorkflowError.invalidEvidence }
            refs.append(part.reference)
            data.append(part.originalPayload)
            next += UInt64(part.reference.count)
        }
        guard next == range.end else { throw ProfileWorkflowError.invalidEvidence }
        return (data, refs)
    }

    static func export(_ project: StreamProjectStore, name: String, destination: URL? = nil) throws -> URL {
        let name = try SessionStore.projectName(name)
        let labels = try list(project)
        guard !labels.isEmpty else { throw StreamFailure.storage("Label one or more waveform regions first.") }
        return try ReviewFiles.publish(in: destination ?? project.exports(), name: name) { folder in
            let windows = try StreamFiles.directory("waveforms", in: folder, create: true)
            let index = try StreamOutput(folder.appendingPathComponent("windows.jsonl"))
            var csv: [DatasetGroup: StreamOutput] = [:]
            for part in DatasetGroup.allCases {
                let file = try StreamOutput(folder.appendingPathComponent(part.rawValue + ".csv"))
                try file.line("label,width_us,minimum,maximum,peak_from_median,rms_from_median,mean_absolute_slope,adc_errors,clipped")
                csv[part] = file
            }
            struct Item: Encodable {
                var label: TrainingLabel
                var partition: DatasetGroup
                var waveform: String
            }
            var cached: StreamRangeReader?
            var partitions: [UUID: DatasetGroup] = [:]
            for label in labels.sorted(by: { $0.run.uuidString < $1.run.uuidString }) {
                try Task.checkCancellation()
                if cached?.run.id != label.run { cached = try StreamRangeReader(store: project, run: project.openRun(label.run)).prepared() }
                guard let reader = cached, label.group == (reader.run.settings.bench?.sequence ?? reader.run.id),
                      label.runSettings == reader.run.settings else { throw ProfileWorkflowError.invalidEvidence }
                let (words, refs) = try raw(reader, range: label.context)
                guard refs == label.refs, StreamFiles.sha(words) == label.rawSHA256 else { throw ProfileWorkflowError.invalidEvidence }
                if let savedAnchors = label.frameAnchors {
                    guard savedAnchors == (try anchors(reader, range: label.context, refs: refs)) else {
                        throw ProfileWorkflowError.invalidEvidence
                    }
                }
                let split = try partitions[label.group] ?? partition(project, group: label.group)
                partitions[label.group] = split
                let actual = label.category == .unknown ? DatasetGroup.review : split
                let file = label.id.uuidString + (label.runSettings.picoAveraging == nil ? ".bin" : ".avg1")
                try StreamFiles.publish(words, at: windows.appendingPathComponent(file))
                try index.item(Item(label: label, partition: actual, waveform: "waveforms/" + file))
                try csv[actual]?.line(features(words, label: label))
            }
            var files = [try index.finish(file: "windows.jsonl", type: "signalbench.training-windows")]
            for part in DatasetGroup.allCases {
                if let file = csv[part] { files.append(try file.finish(file: part.rawValue + ".csv", type: "signalbench.training-features")) }
            }
            struct Manifest: Encodable {
                var type = "com.issa26.signal-bench-training"
                var version = 1
                var featureVersion = 1
                var project: UUID
                var groups: [String: DatasetGroup]
                var files: [StreamAnalysisOutput]
            }
            try StreamFiles.publish(Manifest(project: project.identity.id,
                                             groups: Dictionary(uniqueKeysWithValues: partitions.map { ($0.key.uuidString, $0.value) }),
                                             files: files), at: folder.appendingPathComponent("training.json"))
            try project.verify()
        }
    }

    private static func features(_ data: Data, label: TrainingLabel) throws -> String {
        let start = Int(label.event.first - label.context.first)
        if let factor = label.runSettings.picoAveraging {
            let groups = try PicoAverage.groups(data, first: label.context.first, factor: factor)
            let event = groups[start..<(start + Int(label.event.count))]
            let valid = event.compactMap(\.mean)
            let center = ProfileAnalyzer.median(valid) ?? 0
            let residual = valid.map { $0 - center }
            let rms = sqrt(residual.reduce(0) { $0 + $1 * $1 } / Double(max(1, valid.count)))
            let slopes = zip(event, event.dropFirst()).compactMap { left, right -> Double? in
                guard let a = left.mean, let b = right.mean else { return nil }
                return abs(b - a)
            }
            let slope = slopes.reduce(0, +) / Double(max(1, slopes.count))
            let errors = event.count { $0.adcErrors > 0 }
            let rails = event.count { $0.lowRail + $0.highRail > 0 }
            return "\(ReviewFiles.csv(label.category.rawValue)),\(Double(event.count) * 1_000_000 / label.runSettings.recordedRate),\(valid.min() ?? 0),\(valid.max() ?? 0),\(residual.map(abs).max() ?? 0),\(rms),\(slope),\(errors),\(rails)"
        }
        let words = data.withUnsafeBytes { raw in
            (0..<(data.count / 2)).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        let event = words[start..<(start + Int(label.event.count))]
        let board = label.runSettings.board
        let valid = event.filter { $0 & 0x8000 == 0 }.map { Double(board.sampleCode($0)) }
        let median = ProfileAnalyzer.median(valid) ?? 0
        let residual = valid.map { $0 - median }
        let rms = sqrt(residual.reduce(0) { $0 + $1 * $1 } / Double(max(1, valid.count)))
        let slope = zip(event, event.dropFirst()).filter { $0 & 0x8000 == 0 && $1 & 0x8000 == 0 }
            .map { abs(Double(board.sampleCode($0)) - Double(board.sampleCode($1))) }
        let meanSlope = slope.reduce(0, +) / Double(max(1, slope.count))
        let clipped = valid.filter { $0 == 0 || $0 == Double(board.maxCode) }.count
        return "\(ReviewFiles.csv(label.category.rawValue)),\(Double(event.count) * 1_000_000 / Double(label.nominalRate)),\(valid.min() ?? 0),\(valid.max() ?? 0),\(residual.map { abs($0) }.max() ?? 0),\(rms),\(meanSlope),\(event.count - valid.count),\(clipped)"
    }
}
