import CryptoKit
import Darwin
import Foundation

nonisolated enum PicoCardImport {
    static let headerSize = 64
    static let maximumSize = 384 * 1024 * 1024
    static let duration = 1800
    static let rate = 100_000

    enum Wiring: String, Codable, CaseIterable, Sendable {
        case unknown = "Unknown"
        case devboard = "Rev E.1 connected"
        case openInput = "GP26 open"
        case knownInput = "Known electrical test input"
    }

    struct Origin: Codable, Equatable, Sendable {
        var device: String
        var firmware: String
        var digest: String
        var input: Wiring
        var approximateStart: Date?
    }

    struct Preview: Identifiable, Equatable, Sendable {
        var id: UUID
        var url: URL
        var origin: Origin
        var stream: UInt64
        var saved: UInt64
        var missing: UInt64
        var low: UInt64
        var high: UInt64
        var errors: UInt64
        var issue: String?
        var complete: Bool { issue == nil }
    }

    static func candidates(_ selections: [URL]) throws -> [URL] {
        var found: [URL] = []
        for url in selections {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                let directory = url.lastPathComponent.uppercased() == "SBRUNS" ? url :
                    url.appendingPathComponent("SBRUNS", isDirectory: true)
                try StreamFiles.directory(directory)
                found += try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "sbr" }
            } else if url.pathExtension.lowercased() == "sbr" {
                found.append(url)
            }
        }
        guard !found.isEmpty, found.count <= 256 else {
            throw StreamFailure.storage("Choose a Pico card with recordings, or select up to 256 SBR files.")
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func preview(_ url: URL) throws -> Preview { try scan(url).0 }

    private static func scan(_ url: URL, receive: (StreamFrame) throws -> Void = { _ in }) throws -> (Preview, StreamAccounting) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw StreamFiles.posix() }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (Int64(headerSize)...Int64(maximumSize)).contains(info.st_size) else {
            throw StreamFailure.storage("This Pico recording has an invalid file size.")
        }
        func exact(_ n: Int) throws -> Data {
            var data = Data()
            while data.count < n, let part = try input.read(upToCount: n - data.count), !part.isEmpty { data.append(part) }
            return data
        }
        let header = try exact(headerSize)
        guard header.count == headerSize, header.prefix(8).elementsEqual("SBSDRAW1".utf8),
              StreamWire.read(UInt32.self, header, at: 32) == duration,
              StreamWire.read(UInt32.self, header, at: 60) == StreamWire.crc(Data(header.prefix(60))),
              let version = String(bytes: header[36..<60].prefix(while: { $0 != 0 }), encoding: .ascii),
              !version.isEmpty, version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw StreamFailure.storage("This Pico recording has an unsupported or damaged header.")
        }
        let b = Array(header[8..<24])
        let id = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        let stream = StreamWire.read(UInt64.self, header, at: 8)
        guard stream != 0 else { throw StreamFailure.storage("The Pico recording has an invalid run ID.") }
        let device = header[24..<32].map { String(format: "%02x", $0) }.joined()
        var report = Preview(id: id, url: url, origin: .init(device: device, firmware: version, digest: "", input: .unknown),
                             stream: stream, saved: 0, missing: 0, low: 0, high: 0, errors: 0)
        var digest = SHA256()
        digest.update(data: header)
        var parser = StreamParser()
        var accounting = StreamAccounting(stream: stream, channel: 0, rate: rate)
        while accounting.end == nil {
            try Task.checkCancellation()
            let raw = try exact(StreamWire.headerSize)
            guard raw.count == StreamWire.headerSize, raw.prefix(4).elementsEqual("SBS1".utf8) else {
                report.issue = "No verified ending. Only the verified sample prefix is available."
                break
            }
            let length = Int(StreamWire.read(UInt32.self, raw, at: 8))
            guard length <= StreamWire.maxSamples * 2 else {
                report.issue = "A frame exceeded the recording format limit."
                break
            }
            let data = try exact(length)
            guard data.count == length else { report.issue = "The final frame is incomplete."; break }
            let frame: StreamFrame
            do {
                let frames = try parser.append(raw + data)
                guard frames.count == 1, let decoded = frames.first, decoded.kind != .gpio,
                      decoded.flags == 0 || decoded.kind == .end,
                      (accounting.boot == nil ? decoded.kind == .start : decoded.kind != .start),
                      decoded.index <= UInt64(rate * duration + StreamWire.maxSamples * 2) - UInt64(decoded.count) else {
                    throw StreamFailure.protocolError("Unsupported Pico card frame.")
                }
                var checked = accounting
                try checked.accept(decoded)
                accounting = checked
                frame = decoded
            } catch {
                report.issue = "A frame failed validation. Only the verified sample prefix is available."
                break
            }
            try receive(frame)
            digest.update(data: raw)
            digest.update(data: data)
            if frame.kind == .samples {
                data.withUnsafeBytes { bytes in
                    for offset in stride(from: 0, to: bytes.count, by: 2) {
                        let word = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        if word & 0x8000 != 0 { report.errors += 1 }
                        else if word & 4095 == 0 { report.low += 1 }
                        else if word & 4095 == 4095 { report.high += 1 }
                    }
                }
            }
        }
        report.saved = accounting.received
        report.missing = accounting.knownLoss
        guard report.saved != 0 else { throw StreamFailure.storage("This file contains no verified ADC readings.") }
        if let end = accounting.end {
            if end.auxiliary != 0 || end.flags != 0 || report.missing > 0 {
                report.issue = StreamRunSegment.stopReason(end.auxiliary) ?? "The Pico reported missing or unknown coverage."
            } else if try !exact(1).isEmpty {
                report.issue = "The file was not truncated after the final frame. Check the card before reuse."
            }
        }
        report.origin.digest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return (report, accounting)
    }

    static func publish(_ entry: Preview, in store: StreamProjectStore, wiring: Wiring, approximateStart: Date?) throws -> UUID {
        try store.verify()
        let runs = try StreamFiles.directory("runs", in: store.folder, create: true)
        let destination = runs.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        if try StreamFiles.isPresent(destination) {
            let run = try store.openRun(entry.id)
            guard run.picoCardOrigin?.digest == entry.origin.digest else {
                throw StreamFailure.storage("This run ID already exists with different data.")
            }
            return run.id
        }
        let staging = store.folder.appendingPathComponent(".pico-import-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw StreamFiles.posix() }
        defer { try? FileManager.default.removeItem(at: staging) }
        try StreamFiles.publish(store.identity, at: staging.appendingPathComponent("project.json"))
        let temporary = try StreamProjectStore(opening: staging)
        let settings = StreamRunSettings(mode: .main, nominalRate: rate, duration: Double(duration),
                                         wiring: wiring.rawValue, acquisitionBoard: .picoW)
        let name = "Pico Card " + entry.id.uuidString.prefix(8)
        let run = try temporary.makeRun(name: name, description: "Imported from a Pico W microSD recording.", settings: settings, id: entry.id)
        let writer = try StreamRunWriter(store: temporary, run: run, stream: entry.stream, firmware: entry.origin.firmware)
        let (verified, accounting) = try scan(entry.url) { try writer.append($0) }
        guard verified == entry else { throw StreamFailure.storage("The recording changed after preview. Read the card again.") }
        var saved = try writer.finish(accounting: accounting, issue: verified.issue)
        if verified.issue != nil && accounting.end == nil { saved.segments[0].unknown = true }
        var origin = verified.origin
        origin.input = wiring
        origin.approximateStart = approximateStart
        saved.picoCardOrigin = origin
        if let approximateStart { saved.created = approximateStart }
        try temporary.save(saved)
        try Task.checkCancellation()
        try store.verify()
        let source = try temporary.runDirectory(saved.id)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        try StreamFiles.sync(runs)
        return saved.id
    }
}
