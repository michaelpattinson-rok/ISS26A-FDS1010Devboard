import Darwin
import Foundation

@main enum ProjectArchiveChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let parent1 = try StreamFiles.directory("First", in: root, create: true)
        let parent2 = try StreamFiles.directory("Second", in: root, create: true)
        let first = try StreamProjectStore.create(named: "Same Name", in: parent1)
        let second = try StreamProjectStore.create(named: "Same Name", in: parent2)
        _ = try CurveChecks.make(first, count: 8_192, rate: 100_000, gapped: true, name: "Source reading")
        _ = try CurveChecks.make(second, count: 8_192, rate: 100_000, name: "Second reading")

        let savedExport = try second.exports().appendingPathComponent("notes.txt")
        try Data("Bench note\n".utf8).write(to: savedExport)
        let zero = first.folder.appendingPathComponent("empty.txt")
        try Data().write(to: zero)
        try Data("Staging only".utf8).write(to: first.folder.appendingPathComponent(".pending-ignore"))
        try Data("Finder info".utf8).write(to: first.folder.appendingPathComponent(".DS_Store"))
        let hashBefore = try files(first.folder)
        let secondBefore = try files(second.folder)
        var progress = [Double]()
        let zip = try ProjectArchive.export([first.folder, second.folder], named: "My study.ZIP", to: root,
                                            progress: { progress.append($0) })
        try CurveChecks.require(zip.lastPathComponent == "My study.zip" && progress.last == 1 && progress == progress.sorted(),
                                "Name, extension and progress")
        let extract = try StreamFiles.directory("Unpacked", in: root, create: true)
        try run("/usr/bin/unzip", ["-q", zip.path, "-d", extract.path])
        let expected = [(first, hashBefore), (second, secondBefore)]
        for (index, pair) in expected.enumerated() {
            let folder = extract.appendingPathComponent("Projects/\(index + 1). Same Name")
            let reopened = try StreamProjectStore(opening: folder)
            let entries = try reopened.list()
            try CurveChecks.require(reopened.identity.id == pair.0.identity.id && entries.count == 1,
                                    "Reopen each labeled Project and retain run identity")
            let original = pair.1.filter { $0.key != ".pending-ignore" && $0.key != ".DS_Store" && !$0.key.hasSuffix(".writer-lock") }
            let restored = try files(folder)
            try CurveChecks.require(restored == original, "Read back every saved Project file byte for byte")
            let untouched = try files(pair.0.folder)
            try CurveChecks.require(untouched == pair.1, "Export does not touch the source")
        }
        let sums = try String(contentsOf: extract.appendingPathComponent("SHA256SUMS.txt"), encoding: .utf8)
        for line in sums.split(separator: "\n") {
            let name = String(line.dropFirst(66))
            let bytes = try Data(contentsOf: extract.appendingPathComponent(name))
            try CurveChecks.require(String(line.prefix(64)) == StreamFiles.sha(bytes), "Manifest matches \(name)")
        }
        let index = try String(contentsOf: extract.appendingPathComponent("Projects.json"), encoding: .utf8)
        try CurveChecks.require(index.contains(first.identity.id.uuidString) && index.contains(second.identity.id.uuidString),
                               "IDs and directory labels in metadata")
        for request in [[first.folder, first.folder], [root]] {
            try reject("Invalid folder selection") { _ = try ProjectArchive.export(request, named: "Invalid", to: root) }
        }
        try reject("Inside source") { _ = try ProjectArchive.export([first.folder], named: "Recursive", to: first.folder) }
        try reject("Collision") { _ = try ProjectArchive.export([first.folder], named: "My study", to: root) }

        let link = first.folder.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: savedExport)
        try reject("Linked source") { _ = try ProjectArchive.export([first.folder], named: "Link", to: root) }
        try FileManager.default.removeItem(at: link)
        try reject("Cancel during ZIP verification") {
            var verifying = false
            _ = try ProjectArchive.export([first.folder], named: "Cancel", to: root, checkpoint: {
                if verifying { throw CancellationError() }
            }) { verifying = $0 >= 0.75 }
        }
        try CurveChecks.require(!StreamFiles.exists(root.appendingPathComponent("Cancel.zip")), "Cancelled archive must stay unpublished")
        try reject("Reject Project changes during export") {
            var verifying = false
            _ = try ProjectArchive.export([second.folder], named: "Changed", to: root, checkpoint: {
                if verifying {
                    verifying = false
                    try Data("New bench note".utf8).write(to: savedExport)
                }
            }, progress: { if $0 == 0.75 { verifying = true } })
        }
        try CurveChecks.require(!StreamFiles.exists(root.appendingPathComponent("Changed.zip")), "Changed files must block publication")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".project-export-") }
        try CurveChecks.require(leftovers.isEmpty, "No partial ZIPs remain on failure")

        // Check corruption detection independently of Project scanning.
        for kind in ["payload", "central", "truncate"] {
            let corrupt = root.appendingPathComponent("\(kind).zip")
            let archive = try RunExportZIP(corrupt, date: .now)
            let member = try archive.entry("data.bin")
            try member.write(Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 ^ ($0 / 271)) }))
            try member.finish()
            try archive.finish()
            try archive.verify()
            var data = try Data(contentsOf: corrupt)
            if kind == "truncate" { data.removeLast() }
            else if kind == "central" {
                guard let header = data.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards) else {
                    throw StreamFailure.storage("Missing central directory in test ZIP.")
                }
                data[header.lowerBound + 8] ^= 1
            } else { data[60] ^= 1 }
            try data.write(to: corrupt)
            try reject("Corrupt \(kind)") { try archive.verify() }
        }
        print("PASS Project ZIP name, manifest, collision, linked paths, cancellation, mutation, byte-for-byte extraction and ZIP64 corruption checks")
    }

    private static func reject(_ name: String, _ attempt: () throws -> Void) throws {
        do { try attempt() } catch { return }
        throw StreamFailure.storage("Expected rejection: \(name)")
    }

    private static func files(_ folder: URL) throws -> [String: String] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: String] = [:]
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(folder.path.count + 1))] = StreamFiles.sha(try Data(contentsOf: url))
        }
        return result
    }

    private static func run(_ program: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try CurveChecks.require(process.terminationStatus == 0, "Independent unzip")
    }
}
