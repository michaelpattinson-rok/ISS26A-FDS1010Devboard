import Darwin
import Foundation

@main enum RunBatchArchiveChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "Bench Test", in: root)
        let first = try CurveChecks.make(store, count: 8_192, rate: 100_000, gapped: true, name: "Trial")
        let second = try CurveChecks.make(store, count: 2_048, rate: 500_000, factor: .eight, name: "Trial")
        _ = try CurveChecks.make(store, count: 2_048, rate: 100_000, name: "Unselected")
        let curve = try CurveChecks.fit(first, tolerance: 1)
        let standalone = UUID()
        _ = try CurveDelivery.copy(curve, store: store, id: standalone, name: "Saved Curve", checkpoint: {}, progress: { _ in })

        var note = RunTimelineEntry()
        note.note = "Maintain the bench setup while reviewing this run."
        _ = try RunTimeline.save(note, replacing: nil, in: first, finished: true)
        let ids = [first.run.id, second.run.id, standalone]
        let before = try hashes(in: store.folder)
        let out = try store.exports()
        var progress = [Double]()
        let archiveURL = try RunBatchArchive.export(ids, in: store, named: "Compare Trials.ZIP", to: out, progress: { progress.append($0) })
        try require(archiveURL.lastPathComponent == "Compare Trials.zip" && progress.last == 1 &&
                    progress == progress.sorted(), "Normalize the name and report monotonic progress")

        let unpacked = try StreamFiles.directory("Unpacked", in: root, create: true)
        try unzip(["-tqq", archiveURL.path])
        try unzip(["-q", archiveURL.path, "-d", unpacked.path])
        let checksums = try String(contentsOf: unpacked.appendingPathComponent("SHA256SUMS.txt"), encoding: .utf8)
        for line in checksums.split(separator: "\n") {
            let path = String(line.dropFirst(66))
            let data = try Data(contentsOf: unpacked.appendingPathComponent(path))
            try require(String(line.prefix(64)) == StreamFiles.sha(data), "Checksum for \(path)")
        }
        let index = try StreamFiles.read(RunBatchArchive.Index.self, unpacked.appendingPathComponent("Runs.json"))
        try require(index.project == store.identity.id && index.runs.map(\.id) == ids, "Include exactly the selected IDs in order")
        try require(index.runs.map(\.folder) == ["Runs/1. Trial", "Runs/2. Trial", "Runs/3. Saved Curve"], "Distinguish duplicate names")
        try require(index.runs[0].status == .interrupted && index.runs[2].standaloneCurve, "Identify interrupted and curve recordings")

        let raw = unpacked.appendingPathComponent(index.runs[0].folder)
        let averaged = unpacked.appendingPathComponent(index.runs[1].folder)
        let modeled = unpacked.appendingPathComponent(index.runs[2].folder)
        for (id, folder) in zip(ids, [raw, averaged, modeled]) {
            let run = try StreamFiles.read(StreamRun.self, folder.appendingPathComponent("run.json"))
            try require(run.id == id && StreamFiles.exists(folder.appendingPathComponent("Main.md")), "Run metadata and guide")
        }
        try require(try String(contentsOf: raw.appendingPathComponent("timeline.jsonl"), encoding: .utf8).contains(note.note), "Preserve saved note")
        try require(StreamFiles.exists(raw.appendingPathComponent("manifest.json")) &&
                    StreamFiles.exists(raw.appendingPathComponent("timing.csv")) &&
                    StreamFiles.exists(raw.appendingPathComponent("quality.csv")) &&
                    StreamFiles.exists(raw.appendingPathComponent("curves/\(curve.manifest.id.uuidString)/curve.json")), "Export coverage, quality and named curves")
        let rawCSV = try FileManager.default.contentsOfDirectory(atPath: raw.path).filter { $0.hasSuffix(".csv") }
        let averagedCSV = try FileManager.default.contentsOfDirectory(atPath: averaged.path).filter { $0.hasSuffix(".csv") }
        try require(rawCSV.contains { $0.hasPrefix("raw") } && averagedCSV.contains { $0.hasPrefix("averaged") }, "Raw and averaged readings in CSVs")
        let rows = try String(contentsOf: modeled.appendingPathComponent("waveform.csv"), encoding: .utf8)
        try require(rows.contains(",modeled,") && rows.contains(",exact,") &&
                    StreamFiles.exists(modeled.appendingPathComponent("curve.json")), "Keep coefficients and exact versus modeled reading labels")

        try reject("Duplicate run") { _ = try RunBatchArchive.export([ids[0], ids[0]], in: store, named: "Duplicate", to: out) }
        try reject("Missing run") { _ = try RunBatchArchive.export([ids[0], UUID()], in: store, named: "Missing", to: out) }
        try reject("Name collision") { _ = try RunBatchArchive.export(ids, in: store, named: "Compare Trials", to: out) }
        try reject("Source destination") {
            _ = try RunBatchArchive.export(ids, in: store, named: "Invalid folder", to: store.runDirectory(ids[0]))
        }
        var verification = false
        do {
            _ = try RunBatchArchive.export(ids, in: store, named: "Cancelled", to: out, checkpoint: {
                if verification { throw CancellationError() }
            }, progress: { verification = $0 > 0.8 })
            throw StreamFailure.storage("Cancellation did not stop ZIP verification.")
        } catch is CancellationError {}
        var corruptReady = false
        var corruptionInjected = false
        try reject("Reject ZIP payload corruption") {
            _ = try RunBatchArchive.export(ids, in: store, named: "Corrupt", to: out, checkpoint: {
                guard corruptReady, !corruptionInjected else { return }
                let partials = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                guard let partial = partials.first(where: { $0.lastPathComponent.hasPrefix(".run-batch-") }) else {
                    throw StreamFailure.storage("Expected a staged archive.")
                }
                let handle = try FileHandle(forUpdating: partial.appendingPathComponent("archive.zip"))
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data([0]))
                try handle.synchronize()
                corruptionInjected = true
            }, progress: { corruptReady = $0 >= 0.8 })
        }
        try require(corruptionInjected, "Simulated corruption reached the on-disk ZIP")
        let source = try store.runDirectory(first.run.id)
        let lease = try StreamRunLock(source)
        try withExtendedLifetime(lease) {
            try reject("Active writer") { _ = try RunBatchArchive.export(ids, in: store, named: "Active", to: out) }
        }
        try require(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Compare Trials.zip"],
                    "No partial archives, and the existing ZIP is untouched")
        try require(try hashes(in: store.folder) == before, "Source samples and Project metadata were unchanged")
        print("PASS grouped ZIP selection, duplicate names, raw and averaged samples, interrupted runs, standalone and named curves, notes, checksums, independent unzip, corruption rejection, cancellation, collision, active writer and source integrity")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        try CurveChecks.require(value(), label)
    }

    static func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw StreamFailure.storage("Expected rejection: \(label)")
    }

    static func hashes(in root: URL) throws -> [String: String] {
        var hashes = [String: String]()
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent("runs"), includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw StreamFailure.storage("Could not inspect the run folders.")
        }
        for case let url as URL in files {
            guard !url.lastPathComponent.hasPrefix("."), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hashes[url.path] = StreamFiles.sha(try Data(contentsOf: url))
        }
        return hashes
    }

    static func unzip(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Independent ZIP readback")
    }

}
