import Foundation

nonisolated enum UnoCandidateAnalysis {
    struct Event: Codable, Identifiable, Sendable {
        let range: ReviewRange
        let device: UnoCandidateBlock.Pulse?
        let mac: ReviewPulse?
        let label: String
        var id: String { "\(range.segment):\(range.first):\(device?.peak ?? 0):\(mac?.peakIndex ?? 0)" }
    }

    struct Comparison: Codable, Sendable {
        let segment: UUID
        let selection: StreamSelection
        let settings: UnoCandidateSettings
        let macSettings: ReviewSettings
        let ranges: [StreamRangeReference]
        let archiveHashes: [String]
        let annotationRevision: UUID?
        let coverage: [String: UInt64]
        let sharedReadings: UInt64
        let sharedRanges: [ReviewRange]
        let events: [Event]
        var rate_exposure_valid = 0
    }

    static func compare(_ original: StreamRangeReader, segment: StreamRunSegment, start: Double, length: Double) throws
        -> (Comparison, StudioPlot) {
        let reader = try original.prepared()
        guard reader.run.settings.unoCandidates?.valid == true, reader.run.status != .recording,
              segment.board == .unoR4, start.isFinite, start >= 0, (0.1...3).contains(length) else {
            throw StreamFailure.storage("Choose a saved Device Candidates segment and up to three seconds.")
        }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        guard let end = reader.index?.lazy.filter({ $0.segment == segment.id }).map(\.end).max() else {
            throw StreamFailure.storage("There are no saved samples in this segment.")
        }
        let firstTime = segment.timelineStart + start
        let endTime = min(firstTime + length, segment.timelineStart + Double(end) / rate)
        let selection = StreamSelection(lower: firstTime, upper: endTime)
        guard selection.valid else { throw StreamFailure.storage("The selection begins past the saved recording.") }
        let result = try compare(reader, segment: segment, selection: selection, scoped: false)
        return (result, try StreamStudio.plot(reader, selection: selection))
    }

    struct Review: Encodable {
        let range: ReviewRange
        let selection: StreamSelection
        let settings: UnoCandidateSettings
        let macSettings: ReviewSettings
        let sourceSHA256: [String]
        let coverage: [String: UInt64]
        let sharedReadings: UInt64
        let annotationRevision: UUID?
        let decisions: [String: Int]
        let findings: [Event]
        let itemsAvailable: Int
        let rate_exposure_valid = 0
        let evidence = "Device reports and Mac Pulse Matches within the selected range. Boundary-spanning candidates may be omitted."
    }

    static func review(_ reader: StreamRangeReader, range: ReviewRange, selection: StreamSelection, page: Range<Int>) throws -> Review {
        guard let segment = reader.run.segments.first(where: { $0.id == range.segment }),
              selection.upper - selection.lower <= 3.0000001 else {
            throw ReviewWorkerError.invalid("Choose up to three seconds in one Device Candidates timing segment.")
        }
        let comparison = try compare(reader, segment: segment, selection: selection, scoped: true)
        let decisions = comparison.events.reduce(into: [String: Int]()) { counts, event in counts[event.label, default: 0] += 1 }
        return .init(range: range, selection: selection, settings: comparison.settings, macSettings: comparison.macSettings,
                     sourceSHA256: Array(Set(comparison.ranges.map(\.sha256) + comparison.archiveHashes)).sorted(),
                     coverage: comparison.coverage, sharedReadings: comparison.sharedReadings,
                     annotationRevision: comparison.annotationRevision, decisions: decisions,
                     findings: Array(comparison.events.dropFirst(page.lowerBound).prefix(min(12, page.count))),
                     itemsAvailable: comparison.events.count)
    }

    private static func compare(_ reader: StreamRangeReader, segment: StreamRunSegment,
                                selection: StreamSelection, scoped: Bool) throws -> Comparison {
        guard let settings = reader.run.settings.unoCandidates, settings.valid,
              reader.run.status != .recording, segment.board == .unoR4 else {
            throw StreamFailure.storage("Choose a saved Uno segment with Device Candidates enabled.")
        }
        let rate = segment.configuredRate(reader.run.settings.nominalRate)
        let owned = ReviewInput.indices(selection, segment: segment, rate: reader.run.settings.nominalRate)
        let loaded = try ReviewInput.load(reader, selection: selection, context: scoped ? 0 : 0.4)
        let input = ReviewInput(run: reader.run, selection: selection,
                                spans: loaded.spans.filter { $0.segment.id == segment.id },
                                refs: loaded.refs.filter { $0.segment == segment.id },
                                gaps: loaded.gaps.filter { $0.range.segment == segment.id })
        let folder = try reader.store.runDirectory(reader.run.id).appendingPathComponent("device-candidates", isDirectory: true)
        let available = try StreamFiles.isPresent(folder)
        if available { try StreamFiles.directory(folder) }
        var covered: [Range<UInt64>] = []
        var device: [UnoCandidateBlock.Pulse] = []
        var coverage: [String: UInt64] = [:]
        var sourceIDs = Set<UInt64>(), archiveHashes: [String] = []
        // The right edge can contain a pulse finalized in the following block.
        let lookahead: UInt64 = scoped ? 0 : UInt64(settings.maxWidthUS / 10) + UnoCandidateBlock.width
        for summary in reader.index ?? [] where summary.segment == segment.id &&
            summary.first < owned.upperBound + lookahead && summary.end > owned.lowerBound {
            try Task.checkCancellation()
            let file = folder.appendingPathComponent(summary.id.uuidString + ".json")
            guard available, try StreamFiles.isPresent(file) else { continue }
            let bytes = try StreamFiles.read(file, limit: 1_048_576)
            let archive = try StreamFiles.decoder.decode(UnoCandidateArchive.self, from: bytes)
            let raw = try reader.store.chunk(summary, run: reader.run)
            _ = try reader.store.data(summary, run: reader.run)
            let blocks = Set(raw.slices.filter { $0.count == Int(UnoCandidateBlock.width) }.map(\.first))
            guard archive.version == 1, archive.algorithmVersion == 1, archive.segment == segment.id,
                  archive.stream == segment.stream, archive.rawChunk == summary.id, archive.rawSHA256 == summary.sha256,
                  archive.settings == settings, archive.blocks.count <= blocks.count,
                  archive.blocks.allSatisfy({ blocks.contains($0.first) && $0.pulses.count <= 6 }) else {
                throw StreamFailure.storage("Device Candidates evidence does not match its raw checkpoint.")
            }
            archiveHashes.append(StreamFiles.sha(bytes))
            for block in archive.blocks where !scoped || (block.first < owned.upperBound && block.end > owned.lowerBound) {
                guard sourceIDs.insert(block.first).inserted else { throw StreamFailure.storage("Duplicate candidate coverage.") }
                let lo = max(owned.lowerBound, block.first), hi = min(owned.upperBound, block.end)
                if hi > lo { coverage[block.state.title, default: 0] += hi - lo }
                if block.state == .eligible {
                    if scoped {
                        if hi > lo { covered.append(lo..<hi) }
                    } else {
                        covered.append(block.first..<block.end)
                    }
                }
                for pulse in block.pulses where owned.contains(pulse.peak) {
                    if scoped && (pulse.first < owned.lowerBound || pulse.end > owned.upperBound) { continue }
                    guard pulse.first <= pulse.peak, pulse.peak < pulse.end, pulse.end <= block.end,
                          pulse.end >= block.first, pulse.height > 0, pulse.height < pulse.baseline,
                          pulse.baseline < 16383 else { throw StreamFailure.storage("A saved candidate has invalid bounds.") }
                    device.append(pulse)
                }
            }
        }
        coverage["Missing candidate coverage"] = UInt64(owned.count) - min(UInt64(owned.count), coverage.values.reduce(0, +))
        let macSettings = ReviewSettings(profile: reader.run.settings.profile, sampleRate: Int(rate.rounded()))
        let annotations = try RunAnnotations.read(reader)
        let savedMasks = annotations?.masks.filter { $0.range.segment == segment.id } ?? []
        var macCoverage: [Range<UInt64>] = []
        let analysis = try StudioReview.analyze(input, settings: macSettings, manual: [], approved: savedMasks, trace: { index, _, _, masked, settling in
            if !masked && !settling {
                if let last = macCoverage.last, last.upperBound == index {
                    macCoverage[macCoverage.count - 1] = last.lowerBound..<(index + 1)
                } else { macCoverage.append(index..<(index + 1)) }
            }
        })
        guard !analysis.overflow else { throw StreamFailure.storage("The Mac exceeded its candidate limit. Choose a shorter range.") }
        // Do not count detector boundaries as misses. A block can contain a
        // pulse which is finalized after its own coverage report.
        let spans = merged(covered)
        let margin = UInt64(settings.maxWidthUS / 10)
        let deviceEligible = spans.compactMap { range -> Range<UInt64>? in
            let lo = max(owned.lowerBound, range.lowerBound + margin)
            let hi = min(owned.upperBound, range.upperBound - min(range.upperBound, margin))
            return lo < hi ? lo..<hi : nil
        }
        let shared = intersect(deviceEligible, macCoverage)
        let mac = analysis.processed.filter { owned.contains($0.peakIndex) && $0.range.segment == segment.id }
        let tolerance = max(1, UInt64((settings.minWidthUS + 9) / 10))
        var used = Set<Int>()
        var events: [Event] = []
        for pulse in device {
            let eligible = contains(pulse.first..<pulse.end, in: shared)
            let peers = mac.indices.filter { i in
                !used.contains(i) && contains(mac[i].range.first..<mac[i].range.end, in: shared) &&
                    max(mac[i].peakIndex, pulse.peak) - min(mac[i].peakIndex, pulse.peak) <= tolerance
            }
            let peer = eligible && peers.count == 1 ? peers.first : nil
            if let peer { used.insert(peer) }
            let hit = peer.map { mac[$0] }
            let label: String
            if !eligible { label = "Outside shared coverage" }
            else if peers.count > 1 { label = "Ambiguous pairing" }
            else if let hit {
                label = (pulse.decision == .candidate) == (hit.decision == "match") ? "Paired" : "Different decisions"
            } else { label = "Device only" }
            events.append(.init(range: .init(segment: segment.id, first: min(pulse.first, hit?.range.first ?? pulse.first),
                                             end: max(pulse.end, hit?.range.end ?? pulse.end)), device: pulse, mac: hit, label: label))
        }
        for i in mac.indices where !used.contains(i) && mac[i].decision == "match" {
            let match = mac[i]
            events.append(.init(range: match.range, device: nil, mac: match,
                                label: contains(match.range.first..<match.range.end, in: shared) ? "Mac only" : "Outside shared coverage"))
        }
        return .init(segment: segment.id, selection: selection, settings: settings, macSettings: macSettings,
                      ranges: input.refs, archiveHashes: archiveHashes, annotationRevision: annotations?.id, coverage: coverage,
                      sharedReadings: shared.reduce(0) { $0 + UInt64($1.count) },
                      sharedRanges: shared.map { .init(segment: segment.id, first: $0.lowerBound, end: $0.upperBound) },
                      events: events.sorted { $0.range.first < $1.range.first })
    }

    static func contains(_ candidate: Range<UInt64>, in ranges: [Range<UInt64>]) -> Bool {
        ranges.contains { $0.lowerBound <= candidate.lowerBound && $0.upperBound >= candidate.upperBound }
    }

    static func merged(_ ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    static func intersect(_ left: [Range<UInt64>], _ right: [Range<UInt64>]) -> [Range<UInt64>] {
        var i = 0, j = 0
        var result: [Range<UInt64>] = []
        while i < left.count && j < right.count {
            let lo = max(left[i].lowerBound, right[j].lowerBound)
            let hi = min(left[i].upperBound, right[j].upperBound)
            if lo < hi { result.append(lo..<hi) }
            if left[i].upperBound < right[j].upperBound { i += 1 } else { j += 1 }
        }
        return result
    }

    static func load<T: Decodable>(_ type: T.Type, reader: StreamRangeReader,
                                   manifest: StreamAnalysisManifest, name: String) throws -> T {
        guard manifest.run == reader.run.id, manifest.analyzerVersion == 1, manifest.rate_exposure_valid == 0,
              let output = manifest.outputs.first(where: { $0.file == name }), output.bytes <= 64 * 1024 * 1024 else {
            throw StreamFailure.storage("This analysis revision is unavailable.")
        }
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: false)
        let folder = try StreamFiles.directory(manifest.id.uuidString, in: parent, create: false)
        let bytes = try StreamFiles.read(folder.appendingPathComponent(name), limit: 64 * 1024 * 1024)
        guard bytes.count == output.bytes, StreamFiles.sha(bytes) == output.sha256 else { throw ReviewWorkerError.stale }
        return try StreamFiles.decoder.decode(T.self, from: bytes)
    }

    static func save<T: Encodable>(_ result: T, reader: StreamRangeReader,
                                   selection: StreamSelection, analyzer: String, name: String) throws -> StreamAnalysisManifest {
        let parent = try StreamFiles.directory("analyses", in: reader.store.runDirectory(reader.run.id), create: true)
        var manifest = StreamAnalysisManifest(run: reader.run.id, selection: selection, streams: reader.run.segments.map(\.stream),
            analyzer: analyzer, analyzerVersion: 1, profileRevision: reader.run.settings.profile?.id, outputs: [])
        _ = try ReviewFiles.publish(in: parent, name: manifest.id.uuidString) { stage in
            let output = try StreamOutput(stage.appendingPathComponent(name))
            try output.item(result)
            manifest.outputs = [try output.finish(file: name, type: analyzer)]
            try Task.checkCancellation()
            try reader.store.verify()
            guard try reader.store.openRun(reader.run.id) == reader.run else { throw ReviewWorkerError.stale }
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return manifest
    }
}
