import Foundation

nonisolated struct ReviewJobDraft: Encodable, Identifiable, Sendable {
    let id = UUID()
    let jobs: [ProjectJob]

    static func make(_ request: ReviewRequest, readers: [StreamRangeReader], approved: Set<UUID>) throws -> Self {
        guard let kind = request.jobKind, [.quality, .comparison, .fixture, .exclusions, .zip].contains(kind),
              (1...20).contains(readers.count), request.range == nil || readers.count == 1,
              request.visibleSelection == nil || readers.count == 1 else {
            throw ReviewWorkerError.invalid("Choose an allowed job and specific approved runs.")
        }
        switch kind {
        case .comparison:
            guard request.settings != nil, request.reference != nil, request.template == nil, request.weighted == nil else {
                throw ReviewWorkerError.invalid("A comparison requires two explicit filter configurations.")
            }
        case .fixture:
            guard request.template != nil, request.weighted != nil, request.settings == nil, request.reference == nil,
                  request.range == nil, request.visibleSelection == nil else {
                throw ReviewWorkerError.invalid("Fixture replay requires a template, weighting and the complete run.")
            }
        case .exclusions:
            guard request.reference == nil, request.template == nil, request.weighted == nil else {
                throw ReviewWorkerError.invalid("Exclusion proposals use the Conservative policy and optional settings.")
            }
        default:
            guard request.settings == nil, request.reference == nil, request.template == nil, request.weighted == nil else {
                throw ReviewWorkerError.invalid("This job does not accept analysis or fixture settings.")
            }
        }
        return try .init(jobs: readers.map { original in
            try Task.checkCancellation()
            let reader = try original.prepared()
            let run = reader.run
            guard approved.contains(run.id), !run.isManualDraft, !run.segments.isEmpty else {
                throw ReviewWorkerError.invalid("This run is outside the approved Project review.")
            }
            let selection = try ReviewWorker.selection(request, reader: reader)
            if kind == .zip {
                // A generated suffix distinguishes queued exports without replacing any existing file.
                var prefix = run.name
                while prefix.utf8.count > 100 { prefix.removeLast() }
                let name = prefix + " " + String(UUID().uuidString.prefix(8))
                return try ProjectJob.export(reader, name: name, selection: selection, format: .zip, includeAnalyses: true, external: false)
            }
            let input = try ProjectJob.Input.pin(reader, selection: selection)
            var job = ProjectJob(project: reader.store.identity.id, kind: kind, input: input,
                                 name: run.name, estimatedBytes: Self.outputEstimate(kind, input: input),
                                 settings: request.settings, reference: request.reference)
            _ = try request.settings?.resolved(run)
            _ = try request.reference?.resolved(run)
            if kind == .fixture {
                guard let template = try FixtureTemplateStudy.templates(reader.store).first(where: { $0.id == request.template }),
                      FixtureReplay.eligible(reader, template: template),
                      request.weighted != true || template.weightedLimits != nil else {
                    throw ReviewWorkerError.invalid("Use an eligible held out run and a compatible template.")
                }
                let dependencies = template.training.map(\.run) + [template.noise?.run].compactMap { $0 }
                guard dependencies.allSatisfy(approved.contains) else {
                    throw ReviewWorkerError.invalid("Approve the fixture template’s training and noise runs first.")
                }
                job.template = template.id
                job.templateHash = try StreamFiles.sha(StreamFiles.encoder.encode(template))
                job.fixtureInputs = dependencies
                job.weighted = request.weighted
                if run.settings.bench?.step == .fixture { job.timingHash = try FixtureEvidence.reference(reader).1 }
            }
            guard job.valid else { throw ReviewWorkerError.invalid("Invalid job proposal.") }
            return job
        })
    }

    private static func outputEstimate(_ kind: ProjectJob.Kind, input: ProjectJob.Input) -> Int64 {
        let frames = (input.recordedReadings + 2047) / 2048
        switch kind {
        case .quality: return Int64(frames) * 430 + 1_048_576
        case .exclusions: return 8_388_608
        case .comparison, .fixture: return Int64(frames) * 640 + 16_777_216
        default: return 0
        }
    }
}

nonisolated enum ProjectReviewTools {
    struct Interruption: Encodable {
        struct Segment: Encodable {
            let id: UUID
            let first: UInt64
            let end: UInt64
            let saved: UInt64
            let knownMissing: UInt64
            let unknown: Bool
            let stop: String?
            let code: UInt32?
            let firmwareQueue: UInt32?
            let hostQueue: Int?
            let longestWriterUS: UInt64?
            let longestPreparationUS: UInt32?
            let longestUSBWaitUS: UInt64?
        }
        let run: UUID
        let status: StreamRun.Status
        let message: String?
        let segments: [Segment]
        let evidence = "Recorded metadata and indexed sample counts. Raw content was not re-read."
    }

    static func interruption(_ reader: StreamRangeReader, request: ReviewRequest) throws -> Interruption {
        let reader = try reader.prepared()
        let run = reader.run
        let stats = Dictionary(grouping: reader.index ?? [], by: \.segment)
        let segments = run.segments.dropFirst(request.page.lowerBound).prefix(request.page.count).map { segment in
            let indexed = stats[segment.id] ?? []
            let saved = indexed.reduce(UInt64(0)) { $0 + UInt64($1.readingCount) }
            let end = max(segment.accountedSamples, indexed.last?.end ?? 0)
            return Interruption.Segment(id: segment.id, first: 0, end: end, saved: saved,
                knownMissing: end - min(end, saved), unknown: segment.unknown,
                stop: segment.displayEndReason, code: segment.firmwareStopCode,
                firmwareQueue: segment.firmwareQueuePeak, hostQueue: segment.hostQueuePeak,
                longestWriterUS: segment.maximumWriterUS, longestPreparationUS: segment.maximumPackingUS,
                longestUSBWaitUS: segment.maximumUSBBackpressureUS)
        }
        return .init(run: run.id, status: run.status, message: run.displayMessage, segments: segments)
    }

    struct QualitySearch: Encodable {
        struct Finding: Encodable {
            let range: ReviewRange
            let reason: String
            let location: StreamMatchLocation?
            let firstConversion: UInt64
            let endConversionExclusive: UInt64
        }
        let run: UUID
        let selection: StreamSelection
        let findings: [Finding]
        let itemsAvailable: Int
        let hasUnknownTime: Bool
        let evidence: String
    }

    static func qualitySearch(_ reader: StreamRangeReader, request: ReviewRequest, clipping: Bool) throws -> QualitySearch {
        let reader = try reader.prepared()
        let selection = try ReviewWorker.selection(request, reader: reader)
        if clipping && (selection.upper - selection.lower) > 30 {
            throw ReviewWorkerError.invalid("Search clipping in up to 30 seconds at a time. Use quality summaries to locate a range.")
        }
        var findings: [QualitySearch.Finding] = [], total = 0
        var pending: (segment: UUID, first: UInt64, end: UInt64, reason: String, factor: UInt64)?
        func report(_ segment: UUID, first: UInt64, end: UInt64, reason: String, factor: UInt64) {
            guard first < end else { return }
            if request.page.contains(total) {
                findings.append(.init(range: .init(segment: segment, first: first, end: end), reason: reason,
                                      location: clipping ? .init(segment: segment, sample: first) : nil,
                                      firstConversion: first * factor, endConversionExclusive: end * factor))
            }
            total += 1
        }
        func closePending() {
            if let value = pending {
                report(value.segment, first: value.first, end: value.end, reason: value.reason, factor: value.factor)
            }
            pending = nil
        }
        if clipping {
            try reader.visit(selection) { part in
                part.words.withUnsafeBytes { bytes in
                    for i in 0..<part.reference.count {
                        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                        let code = part.segment.board.sampleCode(word)
                        let group = part.groups?[i]
                        let low = group.map { $0.lowRail > 0 } ?? (word & 0x8000 == 0 && code == 0)
                        let high = group.map { $0.highRail > 0 } ?? (word & 0x8000 == 0 && code == part.segment.board.maxCode)
                        guard low || high else { closePending(); continue }
                        let reason = low ? (high ? "Both ADC rails" : "Low ADC rail") : "High ADC rail"
                        let index = part.reference.first + UInt64(i)
                        if pending?.segment == part.segment.id, pending?.end == index, pending?.reason == reason {
                            pending?.end = index + 1
                        } else {
                            closePending()
                            pending = (part.segment.id, index, index + 1, reason, part.segment.factor)
                        }
                    }
                }
            }
            closePending()
        } else {
            // Walk compact headers, loading verified timing only for selected chunks.
            let bySegment = Dictionary(grouping: reader.index ?? [], by: \.segment)
            for segment in reader.run.segments {
                let range = ReviewInput.indices(selection, segment: segment, rate: reader.run.settings.nominalRate)
                let chunks = bySegment[segment.id] ?? []
                let end = min(range.upperBound, max(segment.accountedSamples, chunks.last?.end ?? 0))
                var next = min(range.lowerBound, end)
                for summary in chunks where summary.end > next && summary.first < end {
                    try Task.checkCancellation()
                    let chunk = try reader.store.chunk(summary, run: reader.run)
                    for slice in chunk.slices where slice.first < end {
                        report(segment.id, first: next, end: min(end, slice.first), reason: "Known missing readings", factor: segment.factor)
                        next = min(end, max(next, slice.first + UInt64(slice.count)))
                    }
                }
                report(segment.id, first: next, end: end, reason: "Known missing readings", factor: segment.factor)
            }
        }
        return .init(run: reader.run.id, selection: selection, findings: findings, itemsAvailable: total,
                     hasUnknownTime: reader.run.hasUnknownCoverage,
                     evidence: clipping ? "Fresh SHA-256 verified readings" : "Verified frame indexes. Sample payloads were not re-read.")
    }

    struct Estimate: Encodable {
        let run: UUID
        let selection: StreamSelection
        let indexedReadings: UInt64
        let fullZIPUncompressedSampleBytes: Int64
        let binaryPayloadBytes: Int64
        let evidence = "Estimate from the saved sample index. ZIP size depends on compression and metadata."
    }

    static func exportEstimate(_ reader: StreamRangeReader, request: ReviewRequest) throws -> Estimate {
        let reader = try reader.prepared()
        let selection = try ReviewWorker.selection(request, reader: reader)
        let input = try ProjectJob.Input.pin(reader, selection: selection)
        let settings = reader.run.settings
        let exclusions = try RunAnnotations.read(reader)?.masks.isEmpty == false
        let bytes = StreamExporter.Format.zip.estimatedBytes(samples: input.recordedReadings,
            averaging: settings.adcAveraging, pico: settings.picoAveraging, hasExclusions: exclusions)
        return .init(run: reader.run.id, selection: selection, indexedReadings: input.recordedReadings,
                     fullZIPUncompressedSampleBytes: Int64(bytes),
                     binaryPayloadBytes: Int64(input.recordedReadings) * Int64(PicoAverage.stride(settings.picoAveraging)))
    }
}
