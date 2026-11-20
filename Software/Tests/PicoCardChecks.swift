import CryptoKit
import Foundation

@main enum PicoCardChecks {
    static func fixture(_ url: URL, count: Int, clean: Bool, stream: UInt64) throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var header = Data("SBSDRAW1".utf8)
        StreamWire.put(stream, into: &header)
        StreamWire.put(UInt64(3), into: &header)
        StreamWire.put(UInt64(4), into: &header)
        StreamWire.put(UInt32(1800), into: &header)
        header.append(contentsOf: "1.11".utf8)
        header.append(Data(count: 20))
        StreamWire.put(StreamWire.crc(header), into: &header)
        try out.write(contentsOf: header)
        var configuration = Data()
        StreamWire.put(StreamWire.adcClock, into: &configuration)
        StreamWire.put(StreamWire.divider(for: 100_000)!, into: &configuration)
        try out.write(contentsOf: StreamWire.encode(.init(kind: .start, sequence: 0, stream: stream,
            boot: 10, index: 0, timeUS: 1000, count: 0, auxiliary: 100_000, flags: 0, payload: configuration)))
        var sequence: UInt32 = 1
        var samples = Data()
        for i in 0..<2048 {
            let value: UInt16 = i == 7 ? 0 : i == 8 ? 4095 : i == 9 ? 0x8800 : UInt16(i) + 1000
            StreamWire.put(value, into: &samples)
        }
        var hash = SHA256()
        for i in stride(from: 0, to: count, by: 2048) {
            let size = min(count - i, 2048)
            let payload = size == 2048 ? samples : Data(samples.prefix(size * 2))
            let frame = StreamFrame(kind: .samples, sequence: sequence, stream: stream, boot: 10,
                index: UInt64(i), timeUS: 1000 + UInt64((i + size) * 10), count: UInt32(size), auxiliary: 0, flags: 0,
                payload: payload)
            try out.write(contentsOf: StreamWire.encode(frame))
            hash.update(data: payload)
            sequence += 1
        }
        var stats = Data()
        StreamWire.put(UInt64(count), into: &stats)
        StreamWire.put(UInt32(1), into: &stats)
        let final = StreamWire.encode(.init(kind: .end, sequence: sequence, stream: stream, boot: 10, index: UInt64(count),
            timeUS: 1000 + UInt64(count * 10), count: 0, auxiliary: 0, flags: 0, payload: stats))
        try out.write(contentsOf: clean ? final : Data(final.prefix(23)))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try StreamProjectStore.create(named: "SD Import Checks", in: folder)
        let card = try StreamFiles.directory("SBRUNS", in: folder, create: true)
        for (file, count, complete, stream) in [("LARGE.SBR",180_000_000,true,100), ("PARTIAL.SBR",8192,false,101)] {
            let url = card.appendingPathComponent(file)
            let original = try fixture(url, count: count, clean: complete, stream: UInt64(stream))
            let preview = try PicoCardImport.preview(url)
            try CurveChecks.require(preview.complete == complete && preview.saved == UInt64(count), "Verified coverage and status")
            try CurveChecks.require(preview.low == UInt64((count + 2040) / 2048) && preview.low == preview.high &&
                                    preview.high == preview.errors, "Low rail, high rail and ADC error counts")
            let id = try PicoCardImport.publish(preview, in: store, wiring: .openInput, approximateStart: nil)
            let run = try store.openRun(id)
            try CurveChecks.require(run.status == (complete ? .complete : .interrupted) &&
                                    run.picoCardOrigin?.input == .openInput && run.rate_exposure_valid == 0 &&
                                    run.hasUnknownCoverage == !complete, "Preserve setup, provenance and interrupted status")
            let reader = try StreamRangeReader(store: store, run: run).prepared()
            let seconds = try reader.duration()
            try CurveChecks.require(seconds == Double(count) / 100_000, "Exact sample timing after reopening")
            var hash = SHA256()
            try reader.visit(.init(lower: 0, upper: seconds)) { hash.update(data: $0.words) }
            let restored = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try CurveChecks.require(original == restored, "All imported original ADC words match")
            try CurveChecks.require(try PicoCardImport.publish(preview, in: store, wiring: .openInput, approximateStart: nil) == id,
                                    "Repeat import reuses existing run")
            if !complete {
                let zip = try StreamExporter.export(reader, name: "Card Run", selection: .init(lower: 0, upper: seconds),
                    format: .zip, includeAnalyses: false)
                try CurveChecks.require(zip.pathExtension == "zip", "Imported run ZIP through normal workflow")
            }
            print("Verified \(file): \(count) exact samples, \(seconds) s, \(run.status.rawValue), SHA-256 \(restored)")
        }
        let bad = card.appendingPathComponent("BAD.SBR")
        try Data(repeating: 0, count: 64).write(to: bad)
        do {
            _ = try PicoCardImport.preview(bad)
            throw CocoaError(.fileReadUnknown)
        } catch is StreamFailure {}
        let alias = card.appendingPathComponent("ALIAS.SBR")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: card.appendingPathComponent("LARGE.SBR"))
        do {
            _ = try PicoCardImport.preview(alias)
            throw CocoaError(.fileReadUnknown)
        } catch {
            if (error as? CocoaError)?.code == .fileReadUnknown { throw error }
        }
        let torn = card.appendingPathComponent("TORN.SBR")
        _ = try fixture(torn, count: 8_192, clean: true, stream: 102)
        let handle = try FileHandle(forUpdating: torn)
        try handle.seek(toOffset: UInt64(64 + 72 + 4160 + 64))
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        let damaged = try PicoCardImport.preview(torn)
        try CurveChecks.require(damaged.saved == 2048 && !damaged.complete, "Reject a corrupt payload and retain the verified prefix")

        let worker = Task.detached {
            // Yield until the caller has requested cancellation.
            while !Task.isCancelled { await Task.yield() }
            return try PicoCardImport.publish(damaged, in: store, wiring: .unknown, approximateStart: nil)
        }
        worker.cancel()
        do { _ = try await worker.value; throw CocoaError(.fileWriteUnknown) }
        catch is CancellationError {}
        let folderEntries = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
        try CurveChecks.require(!folderEntries.contains { $0.hasPrefix(".pico-import-") }, "Cancellation cleans staging")

        let denied = try StreamProjectStore.create(named: "Unavailable runs folder", in: folder)
        try Data([1]).write(to: denied.folder.appendingPathComponent("runs"))
        do {
            _ = try PicoCardImport.publish(damaged, in: denied, wiring: .unknown, approximateStart: nil)
            throw CocoaError(.fileWriteUnknown)
        } catch is StreamFailure {}
        print("Verified corrupt-payload recovery, cancellation cleanup and a blocked destination")
        try CurveChecks.require(try store.list().count == 2, "No duplicate or damaged run was published")
    }
}
