import Darwin
import Foundation

nonisolated enum RunBatchArchive {
    struct Index: Codable {
        var format = "signalbench.run-batch-zip"
        var version = 1
        let project: UUID
        let projectName: String
        let runs: [Item]

        struct Item: Codable {
            let id: UUID
            let name: String
            let description: String
            let folder: String
            let status: StreamRun.Status
            let mode: RecordingMode
            let standaloneCurve: Bool
        }
    }

    static func canExport(_ run: StreamRun) -> Bool {
        run.status != .recording && !run.isManualDraft &&
            (run.primaryCurve != nil || !run.segments.isEmpty)
    }

    static func export(_ ids: [UUID], in store: StreamProjectStore, named name: String, to destination: URL,
                       checkpoint: () throws -> Void = {}, progress: (Double) -> Void = { _ in }) throws -> URL {
        guard (1...10_000).contains(ids.count), Set(ids).count == ids.count else {
            throw StreamFailure.storage("Select one or more distinct saved runs.")
        }
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        let runs = store.folder.appendingPathComponent("runs")
        guard !root.pathComponents.starts(with: runs.pathComponents) else {
            throw StreamFailure.storage("Choose a destination outside the Project’s recordings folder.")
        }
        try StreamFiles.directory(root)
        try store.verify()
        let target = root.appendingPathComponent(try ProjectArchive.filename(name))
        guard try !StreamFiles.isPresent(target) else { throw POSIXError(.EEXIST) }
        func check() throws {
            try Task.checkCancellation()
            try checkpoint()
        }

        try check()
        let stage = try StreamFiles.directory(".run-batch-" + UUID().uuidString, in: root, create: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("archive.zip")
        let archive = try RunExportZIP(file, date: Date())
        var items: [Index.Item] = []
        for (offset, id) in ids.enumerated() {
            try check()
            let lease = try ProjectReview.ReadLease(store.runDirectory(id))
            defer { withExtendedLifetime(lease) {} }
            let run = try store.openRun(id)
            guard canExport(run) else { throw StreamFailure.storage("“\(run.name)” has no saved data to export.") }

            let folder = "Runs/\(offset + 1). \(run.name)"
            let sidecars = try StreamFiles.directory("contents", in: stage, create: true)
            defer { try? FileManager.default.removeItem(at: sidecars) }
            func report(_ fraction: Double) {
                progress(0.8 * (Double(offset) + fraction) / Double(ids.count))
            }
            do {
                try archive.inFolder(folder) {
                    if let primaryCurve = run.primaryCurve {
                        let reader = try CurveStore.open(store, run: run, id: primaryCurve)
                        try CurveDelivery.writeArchive(reader, store: store, archive: archive, checkpoint: check) { report($0 * 0.5) }
                        let writer = try StreamOutput(member: archive.entry("waveform.csv"))
                        try CurveDelivery.writeCSV(reader, into: writer, file: "waveform.csv", range: reader.manifest.selection,
                                                  checkpoint: check) { report(0.5 + $0 * 0.49) }
                    } else {
                        let reader = try StreamRangeReader(store: store, run: run).prepared()
                        let selection = try FixtureTemplateStudy.fullRange(reader)
                        let curves = try CurveStore.list(store, run)
                        try StreamExporter.writeContents(reader, selection: selection, format: .zip, includeAnalyses: true,
                                                         stage: sidecars, archive: archive, progress: { report($0 * (curves.isEmpty ? 1 : 0.8)) },
                                                         checkpoint: check)
                        for (index, curve) in curves.enumerated() {
                            try check()
                            let curveReader = try CurveStore.open(store, run: run, id: curve.id)
                            try archive.inFolder("curves/" + curve.id.uuidString) {
                                try CurveDelivery.writeArchive(curveReader, store: store, archive: archive, checkpoint: check) {
                                    report(0.8 + 0.2 * (Double(index) + $0) / Double(curves.count))
                                }
                            }
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw StreamFailure.storage("Could not export “\(run.name)”. \(error.localizedDescription)")
            }
            items.append(.init(id: id, name: run.name, description: run.description, folder: folder, status: run.status,
                               mode: run.settings.mode, standaloneCurve: run.primaryCurve != nil))
            report(1)
        }

        let guide = try StreamOutput(member: archive.entry("Main.md"))
        try guide.line("# Signal Bench run export")
        try guide.line("")
        try guide.line("Project: \(store.identity.name)")
        try guide.line("")
        try guide.line("These folders contain exported run data. Use the Project ZIP option for a reopenable Project backup.")
        try guide.line("Each run has its own Main.md with field descriptions. Runs.json maps names and IDs to archive folders.")
        try guide.line("SHA256SUMS.txt lists the checksums for the exported files.")
        try guide.line("Where included, waveform.csv in a curve run labels exact and modeled readings. Named curve representations are in curves/.")
        try guide.line("")
        for item in items {
            try check()
            try guide.line("- \(item.folder) (\(item.status.rawValue.capitalized))")
        }
        _ = try guide.finish(file: "Main.md", type: "signalbench.export-guide")
        let index = try StreamOutput(member: archive.entry("Runs.json"))
        try index.write(StreamFiles.encoder.encode(Index(project: store.identity.id, projectName: store.identity.name, runs: items)))
        _ = try index.finish(file: "Runs.json", type: "signalbench.run-index")

        try archive.writeChecksums(checkpoint: check)
        try archive.finish()
        try archive.verify(checkpoint: check) { progress(0.8 + 0.199 * $0) }
        try check()
        try store.verify()
        try StreamFiles.sync(stage)
        guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        do { try StreamFiles.sync(root) }
        catch { throw StreamFailure.storage("The ZIP was verified as \(target.lastPathComponent), but the destination could not confirm it was saved. Check the folder before retrying.") }
        progress(1)
        return target
    }
}
