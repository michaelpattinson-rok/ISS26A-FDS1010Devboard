import Foundation

nonisolated enum PostRunOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case quality = "Quality Summary"
    case noise = "Quality and Noise Review"
    case profile = "Quality and Profile Analysis"
    var id: Self { self }
}

nonisolated enum PostRunAnalysis {
    static let noiseAnalyzer = "signalbench.noise-review"

    struct Spectrum: Codable, Sendable {
        struct Point: Codable, Sendable {
            let hz: Double
            let density: Double
        }
        let ranges: [StreamRangeReference]
        let sampleRate: Double
        let transformSize: Int
        let windows: Int
        let points: [Point]
        var gridStrideSamples: UInt64? = nil
        var sampledAtRateSeconds: Double? = nil
        var analyzedSeconds: Double? { gridStrideSamples == nil ? nil : Double(windows * transformSize) / sampleRate }
    }

    struct Review: Sendable {
        let settings: ReviewSettings
        let proposals: [ReviewInterval]
        let spectra: [Spectrum]
    }

    static func load(_ manifest: StreamAnalysisManifest, reader: StreamRangeReader) throws -> Review {
        guard manifest.analyzer == noiseAnalyzer, (1...2).contains(manifest.analyzerVersion), manifest.run == reader.run.id,
              let overview = try WaveformOverview.read(reader), overview.sourceHash == manifest.sourceHash else {
            throw StreamFailure.storage("This noise review describes an earlier saved prefix. Reprocess this run to review new samples.")
        }
        let root = try reader.store.runDirectory(reader.run.id)
        let parent = try StreamFiles.directory("analyses", in: root, create: false)
        let folder = try StreamFiles.directory(manifest.id.uuidString, in: parent, create: false)
        func verified(_ name: String, limit: Int) throws -> Data {
            guard let expected = manifest.outputs.first(where: { $0.file == name }), expected.valid else {
                throw StreamFailure.storage("The analysis is missing a result file.")
            }
            let bytes = try StreamFiles.read(folder.appendingPathComponent(name), limit: limit)
            guard expected.bytes == UInt64(bytes.count), expected.sha256 == StreamFiles.sha(bytes) else {
                throw StreamFailure.storage("An analysis result changed on disk.")
            }
            return bytes
        }
        let settings = try StreamFiles.decoder.decode(ReviewSettings.self, from: verified("noise-settings.json", limit: 16_384))
        guard settings.valid else { throw StreamFailure.storage("The saved review settings are invalid.") }
        let proposals = try verified("proposed-exclusions.jsonl", limit: 8 * 1024 * 1024).split(separator: 10).map {
            try StreamFiles.decoder.decode(ReviewInterval.self, from: Data($0))
        }
        let spectra = try verified("spectra.jsonl", limit: 4 * 1024 * 1024).split(separator: 10).map {
            try StreamFiles.decoder.decode(Spectrum.self, from: Data($0))
        }
        guard proposals.count <= 20_000, spectra.count <= 32 else { throw StreamFailure.storage("The review exceeds its size limit.") }
        return .init(settings: settings, proposals: proposals, spectra: spectra)
    }

    static func noise(_ reader: StreamRangeReader, overview: WaveformOverview) throws -> StreamAnalysisManifest {
        let full = StreamSelection(lower: 0, upper: overview.duration)
        let run = reader.run
        let settings = ReviewSettings(sampleRate: Int(run.settings.recordedRate.rounded()))
        let proposals = try RunAnnotations.preview(reader, selection: full, policy: .conservative, settings: settings)
        let annotations = try RunAnnotations.read(reader)
        let runDirectory = try reader.store.runDirectory(run.id)
        let parent = try StreamFiles.directory("analyses", in: runDirectory, create: true)
        var manifest = StreamAnalysisManifest(run: run.id, selection: full,
                                              streams: run.segments.map(\.stream), analyzer: noiseAnalyzer,
                                              analyzerVersion: 2, profileRevision: run.settings.profile?.id, rules: nil,
                                              annotationRevision: annotations?.id,
                                              sourceHash: overview.sourceHash, outputs: [])
        _ = try ReviewFiles.publish(in: parent, name: manifest.id.uuidString) { stage in
            let spans = try StreamOutput(stage.appendingPathComponent("input-ranges.jsonl"))
            try reader.visit(full) { try spans.item($0.reference) }
            let report = try StreamOutput(stage.appendingPathComponent("noise-settings.json"))
            try report.write(StreamFiles.encoder.encode(settings))
            let proposed = try StreamOutput(stage.appendingPathComponent("proposed-exclusions.jsonl"))
            for proposal in proposals { try proposed.item(proposal) }
            let spectra = try StreamOutput(stage.appendingPathComponent("spectra.jsonl"))
            for spectrum in try Self.spectra(reader, selection: full, exclusions: annotations?.masks ?? []) {
                try spectra.item(spectrum)
            }
            let maskSnapshot = try StreamOutput(stage.appendingPathComponent("approved-exclusions.jsonl"))
            for mask in annotations?.masks ?? [] { try maskSnapshot.item(mask) }
            manifest.outputs = [
                try spans.finish(file: "input-ranges.jsonl", type: "signalbench.raw-ranges"),
                try report.finish(file: "noise-settings.json", type: "signalbench.noise-settings"),
                try proposed.finish(file: "proposed-exclusions.jsonl", type: "signalbench.proposed-exclusions"),
                try maskSnapshot.finish(file: "approved-exclusions.jsonl", type: "signalbench.exclusion-intervals"),
                try spectra.finish(file: "spectra.jsonl", type: "signalbench.welch-spectra")
            ]
            try StreamFiles.publish(manifest, at: stage.appendingPathComponent("analysis.json"))
        }
        return manifest
    }

    // One non-overlapping Hann window on each quarter-second sample grid.
    // A window must be wholly inside the range and one usable segment.
    static func spectra(_ reader: StreamRangeReader, selection: StreamSelection,
                        exclusions: [ReviewInterval]) throws -> [Spectrum] {
        let masks = RunAnnotations.merged(exclusions)
        var averages: [Double: ADCSpectrumAverage] = [:]
        var samples: [Double: UInt64] = [:]
        var examples: [Double: [StreamRangeReference]] = [:]
        var steps: [Double: UInt64] = [:]
        var segment: UUID?
        var windowStart: UInt64?
        var words: [Double] = []
        var references: [StreamRangeReference] = []
        try reader.visit(selection) { part in
            let rate = part.configuredRate
            let first = part.reference.first
            let end = first + UInt64(part.reference.count)
            samples[rate, default: 0] += UInt64(part.reference.count)
            let average: ADCSpectrumAverage
            if let existing = averages[rate] {
                average = existing
            } else {
                var size = 128
                while size * 2 <= min(32_768, Int(16_384 * rate / Double(StreamWire.rate))) { size *= 2 }
                guard let created = ADCSpectrumAverage(size: size, rate: rate) else {
                    throw StreamFailure.storage("Could not prepare the spectrum transform.")
                }
                averages[rate] = created
                steps[rate] = UInt64(max(size, Int((rate / 4).rounded())))
                average = created
            }
            let stride = steps[rate]!
            let count = UInt64(average.size)
            for piece in RunAnnotations.retained(first..<end, excluding: masks[part.segment.id] ?? []) {
                var cursor = piece.lowerBound
                if segment != part.segment.id || windowStart.map({ $0 + UInt64(words.count) != cursor }) != false {
                    words.removeAll(keepingCapacity: true)
                    references.removeAll(keepingCapacity: true)
                    windowStart = nil
                }
                segment = part.segment.id
                while cursor < piece.upperBound {
                    let start = windowStart ?? ((cursor + stride - 1) / stride * stride)
                    guard start < piece.upperBound else { break }
                    cursor = max(cursor, start)
                    let stop = min(piece.upperBound, start + count)
                    var clean = true
                    part.words.withUnsafeBytes { data in
                        for index in cursor..<stop {
                            let word = UInt16(littleEndian: data.loadUnaligned(fromByteOffset: 2 * Int(index - first), as: UInt16.self))
                            guard FixtureKernel.usable(word) else { clean = false; break }
                            words.append(part.groups?[Int(index - first)].mean ?? Double(part.segment.board.sampleCode(word)))
                        }
                    }
                    if clean {
                        if examples[rate] == nil {
                            var ref = part.reference
                            ref.first = cursor
                            ref.count = Int(stop - cursor)
                            references.append(ref)
                        }
                        if stop == start + count {
                            average.append(words)
                            if examples[rate] == nil { examples[rate] = references }
                        } else {
                            windowStart = start
                            break
                        }
                    }
                    words.removeAll(keepingCapacity: true)
                    references.removeAll(keepingCapacity: true)
                    windowStart = nil
                    cursor = start + stride
                }
            }
        }
        return averages.keys.sorted().compactMap { rate in
            guard let average = averages[rate], average.windows > 0 else { return nil }
            return .init(ranges: examples[rate, default: []], sampleRate: rate, transformSize: average.size,
                         windows: average.windows, points: average.points.map { .init(hz: $0.x, density: $0.y) },
                         gridStrideSamples: steps[rate], sampledAtRateSeconds: Double(samples[rate, default: 0]) / rate)
        }
    }
}
