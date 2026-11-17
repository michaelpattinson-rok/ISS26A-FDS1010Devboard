import Foundation

nonisolated struct RunEventFlag: Codable, Identifiable, Sendable {
    var id = UUID()
    var segment: UUID
    var sample: UInt64
    var description: String
}

nonisolated struct RunAnnotationRevision: Codable, Sendable {
    var id = UUID()
    var previous: UUID?
    var flags: [RunEventFlag] = []
    var masks: [ReviewInterval] = []
    var policy: NoisePolicy = .review
    var autoSettings: ReviewSettings?
    var noiseProfile: UUID?
    var created = Date()

    var valid: Bool {
        flags.count <= 10_000 && masks.count <= 20_000 && (autoSettings?.valid ?? true)
        && flags.allSatisfy { !$0.description.isEmpty && $0.description.utf8.count <= 400 }
        && masks.allSatisfy { $0.range.count > 0 && $0.note.utf8.count <= 400 && $0.action == .excluded }
    }
}

nonisolated enum RunAnnotations {
    static func read(_ reader: StreamRangeReader) throws -> RunAnnotationRevision? {
        let folder = try reader.store.runDirectory(reader.run.id).appendingPathComponent("annotations")
        guard try StreamFiles.isPresent(folder) else { return nil }
        try StreamFiles.directory(folder)
        let pointer = folder.appendingPathComponent("current.json")
        guard try StreamFiles.isPresent(pointer) else { return nil }
        return try load(folder, id: StreamFiles.read(UUID.self, pointer))
    }

    private static func load(_ folder: URL, id: UUID) throws -> RunAnnotationRevision {
        let bytes = try StreamFiles.read(folder.appendingPathComponent(id.uuidString + ".json"), limit: 16 * 1024 * 1024)
        let revision = try StreamFiles.decoder.decode(RunAnnotationRevision.self, from: bytes)
        guard revision.id == id, revision.valid else { throw StreamFailure.storage("The annotation revision could not be read.") }
        return revision
    }

    static func save(_ proposed: RunAnnotationRevision, reader: StreamRangeReader, replacing: UUID?) throws -> RunAnnotationRevision {
        try reader.store.verify()
        let runFolder = try reader.store.runDirectory(reader.run.id)
        let lock = try StreamRunLock(runFolder)
        defer { withExtendedLifetime(lock) {} }
        let current = try read(reader)
        guard current?.id == replacing, proposed.valid else {
            throw StreamFailure.storage("Annotations changed or exceed the recording’s annotation limit. Reopen the run.")
        }
        let folder = try StreamFiles.directory("annotations", in: runFolder, create: true)
        var revision = proposed
        revision.id = UUID()
        revision.previous = replacing
        revision.created = Date()
        let bytes = try StreamFiles.encoder.encode(revision)
        guard bytes.count <= 16 * 1024 * 1024 else { throw StreamFailure.storage("The annotation revision is too large.") }
        try StreamFiles.publish(bytes, at: folder.appendingPathComponent(revision.id.uuidString + ".json"))
        try StreamFiles.publish(revision.id, at: folder.appendingPathComponent("current.json"), replace: current != nil)
        return revision
    }

    static func undo(_ reader: StreamRangeReader, revision: UUID) throws -> RunAnnotationRevision? {
        try reader.store.verify()
        let runFolder = try reader.store.runDirectory(reader.run.id)
        let lock = try StreamRunLock(runFolder)
        defer { withExtendedLifetime(lock) {} }
        guard let current = try read(reader), current.id == revision else {
            throw StreamFailure.storage("Annotations changed. Reopen the run.")
        }
        let folder = try StreamFiles.directory("annotations", in: runFolder, create: false)
        let prior = try current.previous.map { try load(folder, id: $0) }
        if let prior {
            try StreamFiles.publish(prior.id, at: folder.appendingPathComponent("current.json"), replace: true)
        } else {
            try FileManager.default.removeItem(at: folder.appendingPathComponent("current.json"))
            try StreamFiles.sync(folder)
        }
        return prior
    }

    static func range(_ selection: StreamSelection, segment: StreamRunSegment, reader: StreamRangeReader) throws -> ReviewRange {
        guard selection.valid else { throw StreamFailure.storage("Enter a start and end time within the selected segment.") }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let first = (selection.lower - segment.timelineStart) * rate
        let end = (selection.upper - segment.timelineStart) * rate
        guard first >= -0.000001, end <= Double(segment.accountedSamples) + 0.000001 else {
            throw StreamFailure.storage("The time range crosses a segment boundary. Choose the relevant segment.")
        }
        let lo = UInt64(max(0, ceil(first - 0.0000001)))
        let hi = UInt64(max(0, ceil(end - 0.0000001)))
        guard hi > lo else { throw StreamFailure.storage("Choose a range at least one sample wide.") }
        return .init(segment: segment.id, first: lo, end: hi)
    }

    static func flag(_ time: Double, segment: StreamRunSegment, note: String, reader: StreamRangeReader) throws -> RunEventFlag {
        let offset = (time - segment.timelineStart) * segment.configuredRate(reader.run.settings.nominalRate)
        let description = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard offset.isFinite, offset >= 0, offset < Double(segment.accountedSamples),
              !description.isEmpty, description.utf8.count <= 400 else {
            throw StreamFailure.storage("Enter a time in this segment and a description of up to 400 bytes.")
        }
        return .init(segment: segment.id, sample: UInt64(min(Double(segment.accountedSamples - 1), (offset + 0.0000001).rounded(.down))), description: description)
    }

    static func merged(_ masks: [ReviewInterval]) -> [UUID: [Range<UInt64>]] {
        Dictionary(grouping: masks, by: { $0.range.segment }).mapValues { values in
            var result: [Range<UInt64>] = []
            for item in values.sorted(by: { $0.range.first < $1.range.first }) {
                if let last = result.last, item.range.first <= last.upperBound {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, item.range.end)
                } else { result.append(item.range.first..<item.range.end) }
            }
            return result
        }
    }

    static func retained(_ range: Range<UInt64>, excluding masks: [Range<UInt64>]) -> [Range<UInt64>] {
        var lo = 0, hi = masks.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if masks[mid].upperBound <= range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var first = range.lowerBound, result: [Range<UInt64>] = []
        while lo < masks.count {
            let item = masks[lo]
            if item.lowerBound >= range.upperBound { break }
            if item.lowerBound > first { result.append(first..<item.lowerBound) }
            first = min(range.upperBound, max(first, item.upperBound))
            lo += 1
        }
        if first < range.upperBound { result.append(first..<range.upperBound) }
        return result
    }

    static func preview(_ reader: StreamRangeReader, selection: StreamSelection, policy: NoisePolicy,
                        settings: ReviewSettings, noiseProfile: CalibrationProfile? = nil,
                        checkpoint: () throws -> Void = {}) throws -> [ReviewInterval] {
        var settings = settings
        settings.maskGlitches = policy != .review
        settings.maskNoise = policy == .standard || policy == .custom
        if policy == .standard {
            guard let profile = noiseProfile ?? reader.run.settings.profile, profile.valid, profile.ready else {
                throw StreamFailure.storage("Standard uses a locked noise profile. Choose Conservative or set a custom threshold.")
            }
            settings.noiseLimit = profile.rules.noisyBlockSigma
        }
        guard selection.valid, settings.valid else { throw StreamFailure.storage("Choose a valid range and exclusion settings.") }
        guard policy != .review, try reader.duration() > 0 else { return [] }
        settings.drift = false
        settings.notch60 = false
        settings.notch120 = false
        settings.template = nil
        var proposals: [ReviewInterval] = []
        let requested = reader.run.settings.nominalRate
        let rates = reader.run.segments.map { $0.configuredRate(requested) }
        let tile = 65_536
        let halo = StreamWire.samples(1024, at: rates.max() ?? Double(requested)) + settings.padBefore + settings.padAfter + settings.spikeWidth
        let context = Double(tile + halo + 2) / (rates.min() ?? Double(requested))
        let expanded = StreamSelection(lower: max(0, selection.lower - context),
                                       upper: min(try reader.duration(), selection.upper + context))
        try FixtureTiles.visit(reader, selection: expanded, halo: halo, tileSamples: tile, aligned: true) { span, owned in
            try checkpoint()
            let spanTime = span.segment.timelineStart
            let rate = span.segment.configuredRate(reader.run.settings.nominalRate)
            let selected = ReviewInput.indices(selection, segment: span.segment, rate: requested)
            let start = max(owned.lowerBound, selected.lowerBound), end = min(owned.upperBound, selected.upperBound)
            guard start < end else { return }
            let spanSelection = StreamSelection(lower: spanTime + Double(start) / rate,
                                                upper: spanTime + Double(end) / rate)
            let input = ReviewInput(run: reader.run, selection: spanSelection, spans: [span], refs: [], gaps: [])
            let review = try StudioReview.analyze(input, settings: settings, manual: [], includePulses: false,
                                                  ownedIndices: start..<end)
            for interval in review.intervals where interval.action == .excluded && interval.reason != .error {
                guard proposals.count < 20_000 else {
                    throw StreamFailure.storage("Too many intervals. Preview a shorter range.")
                }
                if let last = proposals.last, last.reason == interval.reason, last.range.segment == interval.range.segment,
                   interval.range.first <= last.range.end, interval.range.first >= last.range.first {
                    proposals[proposals.count - 1].range.end = max(last.range.end, interval.range.end)
                } else { proposals.append(interval) }
            }
        }
        return proposals
    }
}
