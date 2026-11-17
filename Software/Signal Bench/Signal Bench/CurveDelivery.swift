import Darwin
import Foundation

nonisolated struct CurveJobSpec: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case fit, standalone, zip, csv
        var title: String {
            switch self {
            case .fit: "Fit Waveform Curve"
            case .standalone: "Create Standalone Curve Run"
            case .zip: "Curve ZIP"
            case .csv: "Curve CSV"
            }
        }
    }

    var action: Action
    var curve: UUID
    var request: CurveRequest?
    var indexHash: String?
    var valid: Bool { action == .fit ? request?.valid == true && indexHash == nil : request == nil && indexHash.map(ProfileDigest.valid) == true }
}

nonisolated enum CurveDelivery {
    static func pin(_ reader: CurveReader, selection: StreamSelection) throws -> ProjectJob.Input {
        guard selection.valid, selection.lower >= reader.manifest.selection.lower,
              selection.upper <= reader.manifest.selection.upper else { throw CurveCodec.fault }
        return .init(run: reader.run.id, selection: selection,
                     source: StreamFiles.sha(try StreamFiles.encoder.encode(reader.manifest)), profile: reader.run.settings.profile?.id,
                     annotations: nil, recordedReadings: reader.blocks.reduce(0) { $0 + UInt64($1.count) })
    }

    static func execute(_ job: ProjectJob, store: StreamProjectStore, destination: URL?, control: ProjectJobControl,
                        progress: (Double) -> Void) throws -> URL {
        guard let spec = job.curve, spec.valid else { throw CurveCodec.fault }
        let folder = try store.runDirectory(job.input.run)
        // The writer lock protects fit publication and metadata snapshots. It also prevents a resume of this source.
        let lock = try StreamRunLock(folder)
        defer { withExtendedLifetime(lock) {} }
        let run = try store.openRun(job.input.run)
        try control.checkpoint()
        if spec.action == .fit {
            let source = try StreamRangeReader(store: store, run: run).prepared()
            try job.input.verify(source)
            guard run.curveSource == nil, !run.isManualDraft else { throw CurveCodec.fault }
            let parent = try CurveStore.root(store, run, create: true)
            let result = try ReviewFiles.publish(in: parent, name: spec.curve.uuidString) { stage in
                guard let request = spec.request else { throw CurveCodec.fault }
                _ = try CurveStore.fit(source, id: spec.curve, name: job.name, selection: job.input.selection, request: request,
                    fingerprint: job.input.source, stage: stage, checkpoint: control.checkpoint, progress: progress)
                try job.input.verify(.init(store: store, run: store.openRun(run.id)))
                try control.checkpoint()
            }
            progress(1)
            return result
        }
        let curve = try CurveStore.open(store, run: run, id: spec.curve)
        try verifyPinned(job, curve, store: store)
        if spec.action == .standalone {
            guard curve.manifest.wholeRun, run.curveSource == nil, job.input.selection == curve.manifest.selection else {
                throw StreamFailure.storage("Fit the full run before creating a standalone copy.")
            }
            let original = try ProjectJob.Input.pin(.init(store: store, run: run), selection: curve.manifest.selection)
            guard original.source == curve.manifest.sourceFingerprint else {
                throw StreamFailure.storage("The source changed after this curve was fitted. Fit the full run again before making a copy.")
            }
            let url = try copy(curve, store: store, id: job.id, name: job.name, checkpoint: control.checkpoint, progress: progress)
            progress(1)
            return url
        }
        guard !job.needsDestination || destination != nil else { throw StreamFailure.storage("Choose an export folder before retrying.") }
        let root = try destination ?? store.exports()
        let timeline = folder.appendingPathComponent("timeline")
        let timelineLock = try StreamFiles.isPresent(timeline) ? try StreamRunLock(timeline) : nil
        defer { withExtendedLifetime(timelineLock) {} }
        return try export(curve, store: store, root: root, name: job.name, range: job.input.selection, csv: spec.action == .csv,
                          checkpoint: control.checkpoint, progress: progress) {
            try verifyPinned(job, curve, store: store)
        }
    }

    static func verifyPinned(_ job: ProjectJob, _ reader: CurveReader, store: StreamProjectStore) throws {
        try store.verify()
        let run = try store.openRun(job.input.run)
        let current = try CurveStore.open(store, run: run, id: reader.manifest.id)
        let input = try pin(current, selection: job.input.selection)
        guard current.manifest.indexHash == job.curve?.indexHash,
              input.source == job.input.source, input.profile == job.input.profile, current.run == reader.run else {
            throw ReviewWorkerError.stale
        }
    }

    static func copy(_ reader: CurveReader, store: StreamProjectStore, id: UUID, name: String,
                     checkpoint: () throws -> Void, progress: (Double) -> Void) throws -> URL {
        let original = reader.run
        let parent = try StreamFiles.directory("runs", in: store.folder, create: false)
        return try ReviewFiles.publish(in: parent, name: id.uuidString) { stage in
            var run = original
            run.id = id
            run.name = try SessionStore.projectName(name)
            run.version = 3
            run.curveSource = original.id
            run.primaryCurve = reader.manifest.id
            run.prerunReport = nil
            run.settings.draft = nil
            let curves = try StreamFiles.directory("curves", in: stage, create: true)
            let target = try StreamFiles.directory(reader.manifest.id.uuidString, in: curves, create: true)
            let sourceRoot = try store.runDirectory(original.id)
            for (i, block) in reader.blocks.enumerated() {
                try checkpoint()
                try autoreleasepool {
                    let base = block.source.id.uuidString
                    try StreamFiles.publish(reader.frameData(block), at: target.appendingPathComponent(base + ".frames"))
                    try StreamFiles.publish(reader.storedBlock(block), at: target.appendingPathComponent(base + ".curve"))
                }
                if i.isMultiple(of: 16) { progress(0.7 * Double(i + 1) / Double(reader.blocks.count)) }
            }
            for (name, limit) in [("index.json", 32 * 1024 * 1024), ("curve.json", 1_048_576)] {
                try StreamFiles.publish(StreamFiles.read(reader.folder.appendingPathComponent(name), limit: limit),
                                        at: target.appendingPathComponent(name))
            }
            if try StreamFiles.isPresent(sourceRoot.appendingPathComponent("timeline")) {
                let targetTimeline = try StreamFiles.directory("timeline", in: stage, create: true)
                let sourceTimeline = try StreamFiles.directory("timeline", in: sourceRoot, create: false)
                let timelineLock = try StreamRunLock(sourceTimeline)
                defer { withExtendedLifetime(timelineLock) {} }
                for entry in try RunTimeline.entries(.init(store: store, run: original), finished: true) {
                    try checkpoint()
                    try StreamFiles.publish(entry, at: targetTimeline.appendingPathComponent(entry.id.uuidString + ".json"))
                }
            }
            let metadata = ["annotations", "moments", "gpio"]
            for name in metadata {
                let origin = sourceRoot.appendingPathComponent(name)
                if try StreamFiles.isPresent(origin) {
                    try copyMetadata(origin, to: stage.appendingPathComponent(name), checkpoint: checkpoint)
                }
            }
            let reports = try StreamStudio.analyses(.init(store: store, run: original))
            if !reports.isEmpty {
                let root = try StreamFiles.directory("source-analyses", in: stage, create: true)
                let source = try StreamFiles.directory("analyses", in: sourceRoot, create: false)
                for report in reports {
                    try checkpoint()
                    let from = try StreamFiles.directory(report.id.uuidString, in: source, create: false)
                    let to = try StreamFiles.directory(report.id.uuidString, in: root, create: true)
                    for output in report.outputs {
                        try checkpoint()
                        let copied = try copyRegular(from.appendingPathComponent(output.file), to: to.appendingPathComponent(output.file), checkpoint: checkpoint)
                        guard copied.sha256 == output.sha256, copied.bytes == output.bytes else { throw CurveCodec.fault }
                    }
                    try StreamFiles.publish(report, at: to.appendingPathComponent("analysis.json"))
                }
            }
            for name in ["fixture-reference.json", WaveformOverview.fileName] {
                let source = sourceRoot.appendingPathComponent(name)
                if try StreamFiles.isPresent(source) {
                    try StreamFiles.publish(StreamFiles.read(source, limit: WaveformOverview.maxFileBytes), at: stage.appendingPathComponent("source-" + name))
                }
            }
            try StreamFiles.publish(original, at: stage.appendingPathComponent("source-run.json"))
            try StreamFiles.publish(run, at: stage.appendingPathComponent("run.json"))
            try CurveReader(folder: target, run: run).verify(checkpoint: checkpoint)
            try store.verify()
            try checkpoint()
        }
    }

    private static func copyMetadata(_ input: URL, to output: URL, checkpoint: () throws -> Void) throws {
        try StreamFiles.directory(input)
        let output = try StreamFiles.directory(output.lastPathComponent, in: output.deletingLastPathComponent(), create: true)
        let items = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
        guard items.count <= 100_000 else { throw CurveCodec.fault }
        for file in items where !file.lastPathComponent.hasPrefix(".") {
            try checkpoint()
            let target = output.appendingPathComponent(file.lastPathComponent)
            _ = try copyRegular(file, to: target, checkpoint: checkpoint)
        }
        try StreamFiles.sync(output)
    }

    private static func copyRegular(_ input: URL, to output: URL, checkpoint: () throws -> Void) throws -> StreamAnalysisOutput {
        let fd = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw StreamFiles.posix() }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CurveCodec.fault }
        let output = try StreamOutput(output)
        while let data = try source.read(upToCount: 262_144), !data.isEmpty {
            try checkpoint()
            try output.write(data)
        }
        let result = try output.finish(file: input.lastPathComponent, type: "signalbench.source-report")
        guard info.st_size >= 0, result.bytes == UInt64(info.st_size) else { throw CurveCodec.fault }
        return result
    }

    static func blockers(_ store: StreamProjectStore, original: StreamRun) throws -> [String] {
        var reasons: [String] = []
        if original.settings.bench != nil || original.settings.calibrationAttempt != nil || original.settings.prerunPlan != nil {
            reasons.append("Bench and calibration evidence")
        }
        if try store.list().contains(where: { $0.run?.settings.profile?.electrical?.fixtureRun == original.id }) {
            reasons.append("Calibration profiles that reference this run")
        }
        if try TrainingLabels.list(store).contains(where: { $0.run == original.id }) { reasons.append("Training labels") }
        if try FixtureTemplateStudy.templates(store).contains(where: {
            $0.training.contains(where: { $0.run == original.id }) || $0.noise?.run == original.id || $0.reservedValidationRuns.contains(original.id)
        }) { reasons.append("Fixture templates") }
        if try ProjectJobFiles.load(store, reconcile: false).contains(where: {
            $0.state.unfinished && ($0.input.run == original.id || $0.fixtureInputs?.contains(original.id) == true)
        }) { reasons.append("Queued or active jobs") }
        if try CurveStore.list(store, original).count > 1 {
            reasons.append("Other saved curves")
        }
        return reasons
    }

    static func trashSource(for standalone: StreamRun, in store: StreamProjectStore, typed: String,
                            move: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard let id = standalone.curveSource, let curveID = standalone.primaryCurve else { throw CurveCodec.fault }
        try store.verify()
        let original = try store.openRun(id)
        let originalRoot = try store.runDirectory(id)
        let copyRoot = try store.runDirectory(standalone.id)
        let lock = try StreamRunLock(originalRoot)
        let copyLock = try StreamRunLock(copyRoot)
        let timelineLock = try StreamFiles.isPresent(originalRoot.appendingPathComponent("timeline"))
            ? try StreamRunLock(StreamFiles.directory("timeline", in: originalRoot, create: false)) : nil
        defer { withExtendedLifetime((lock, copyLock, timelineLock)) {} }
        guard typed == original.name, !original.isManualDraft else { throw CurveCodec.fault }
        let copy = try CurveStore.open(store, run: store.openRun(standalone.id), id: curveID)
        guard copy.manifest.wholeRun else { throw CurveCodec.fault }
        let sourceCurve = try CurveStore.open(store, run: original, id: curveID)
        guard StreamFiles.sha(try StreamFiles.encoder.encode(sourceCurve.manifest)) ==
              StreamFiles.sha(try StreamFiles.encoder.encode(copy.manifest)) else { throw CurveCodec.fault }
        try copy.verify()
        let source = StreamRangeReader(store: store, run: original)
        try copy.verifySourceGrid(source)
        let pin = try ProjectJob.Input.pin(source, selection: copy.manifest.selection)
        guard pin.source == copy.manifest.sourceFingerprint,
              try blockers(store, original: original).isEmpty else {
            throw StreamFailure.storage("The source changed or is still used by this Project. Keep the original.")
        }
        // Since the copy was built, reject a destructive action if source-only work was added or edited.
        let sourceTimeline = try RunTimeline.entries(source, finished: true)
        let copiedTimeline = try RunTimeline.entries(.init(store: store, run: standalone), finished: true, resolving: false)
        let current = Dictionary(uniqueKeysWithValues: copiedTimeline.map { ($0.id, $0) })
        guard sourceTimeline.allSatisfy({ current[$0.id] == $0 }) else {
            throw StreamFailure.storage("The source has flags or notes missing from this copy. Make a new standalone copy.")
        }
        try requireMetadataCopy(originalRoot, copyRoot, name: "analyses", target: "source-analyses", depth: 2)
        try requireMetadataCopy(originalRoot, copyRoot, name: "annotations", target: "annotations", depth: 1)
        try requireMetadataCopy(originalRoot, copyRoot, name: "moments", target: "moments", depth: 1)
        try requireMetadataCopy(originalRoot, copyRoot, name: "gpio", target: "gpio", depth: 1)
        for file in ["fixture-reference.json", WaveformOverview.fileName] {
            let source = originalRoot.appendingPathComponent(file)
            if try StreamFiles.isPresent(source) { try compareFile(source, copyRoot.appendingPathComponent("source-" + file)) }
        }
        try store.verify()
        try Task.checkCancellation()
        try move(originalRoot)
    }

    private static func requireMetadataCopy(_ original: URL, _ copy: URL, name: String, target: String, depth: Int) throws {
        let source = original.appendingPathComponent(name)
        guard try StreamFiles.isPresent(source) else { return }
        try StreamFiles.directory(source)
        let result = try StreamFiles.directory(target, in: copy, create: false)
        for file in try FileManager.default.contentsOfDirectory(atPath: source.path) where !file.hasPrefix(".") {
            let origin = source.appendingPathComponent(file)
            let other = result.appendingPathComponent(file)
            var info = stat()
            guard lstat(origin.path, &info) == 0 else { throw StreamFiles.posix() }
            if info.st_mode & S_IFMT == S_IFDIR, depth > 1 {
                try requireMetadataCopy(source, result, name: file, target: file, depth: depth - 1)
            } else {
                try compareFile(origin, other)
            }
        }
    }

    private static func compareFile(_ first: URL, _ second: URL) throws {
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        for file in [first, second] {
            let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw StreamFiles.posix() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            handles.append(handle)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CurveCodec.fault }
        }
        while true {
            try Task.checkCancellation()
            let a = try handles[0].read(upToCount: 262_144)
            let b = try handles[1].read(upToCount: 262_144)
            guard a == b else { throw StreamFailure.storage("The source has changed reports or annotations. Make a new standalone copy.") }
            if a?.isEmpty != false { return }
        }
    }
}
