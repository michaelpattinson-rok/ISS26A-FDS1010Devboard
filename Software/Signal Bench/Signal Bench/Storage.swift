import Foundation
import AppKit
import CryptoKit
import Darwin

nonisolated struct SessionMetadata: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var details: [String: String] = [:]
}

nonisolated struct CaptureRecord: Codable, Identifiable, Sendable {
    var id: String
    var capturedAt: Date = Date()
    var metadata: [String: String]
    var events: [[String: String]]
    var samples: [UInt16]
    var complete: Bool
    var averagedCodes: [Double]? = nil
}

/// A receipt written before capture. Its metadata remains stable across retries.
nonisolated struct CaptureIntent: Codable, Equatable, Sendable {
    var schema = 1
    let token: String
    let sessionID: UUID
    let tag: String?
    let gain: String?
    let calibrationRecordID: String?
    let calibrationID: UInt64?
    let sessionDetails: [String: String]
    let device: String
    let startedAt: Date
    var processingProfile: String? = nil
    var channel: Int? = nil
    var workspace: String? = nil
    var runID: String? = nil
    var probeSource: String? = nil
    var observationOnly: Bool? = nil
    var gainConfirmed: Bool? = nil
    var mainObservationOptions: MainObservationOptions? = nil
    var profileStamp: ProfileCaptureStamp? = nil

    var linked: Bool { tag != nil }

    static func makeToken(sessionID: UUID) -> String {
        // The marker occupies the version nibble of the old UUIDv4 token.
        // The digest is a routing hint. The receipt checks the full session UUID.
        sessionPrefix(sessionID) + "c901" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().suffix(16))
    }

    static func isBound(_ token: String) -> Bool {
        validToken(token) && token.dropFirst(12).prefix(4) == "c901"
    }

    static func matchesSession(_ token: String, _ sessionID: UUID) -> Bool {
        isBound(token) && token.hasPrefix(sessionPrefix(sessionID))
    }

    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sessionPrefix(_ id: UUID) -> String {
        SHA256.hash(data: Data(id.uuidString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum StorageError: LocalizedError {
    case invalidIdentifier, invalidSession, corruptRecord(String), duplicateRecord, unsafeLocation, fileTooLarge, unsupportedVersion, noData
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "The record identifier is invalid."
        case .invalidSession: return "This folder is not a Signal Bench session."
        case .corruptRecord(let name): return "Record \(name) is incomplete or has failed its integrity check."
        case .duplicateRecord: return "A different record with this identifier already exists."
        case .unsafeLocation: return "The selected location cannot be used safely."
        case .fileTooLarge: return "The session or record file exceeds the supported size."
        case .unsupportedVersion: return "This session was created with an unsupported format version."
        case .noData: return "There is no app data to export."
        }
    }
}

nonisolated enum ProjectStorageError: LocalizedError {
    case invalidName, nameConflict, projectChanged, confirmationMismatch

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a project name up to 120 bytes without slashes, colons, control characters or a leading period."
        case .nameConflict: return "Too many folders already use that name. Choose a different project name."
        case .projectChanged: return "The project changed on disk. Reopen it before making changes."
        case .confirmationMismatch: return "Type the exact project name to move it to the Trash."
        }
    }
}

nonisolated struct ProjectTrashSelection: Identifiable, Sendable {
    let id: UUID
    let name: String
    let folder: URL
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
}

/// Read-only snapshot of the session and folder authorized by the user.
/// The caller cancels review when the open session changes.
nonisolated struct MainNoiseReviewContext: Sendable {
    let store: SessionStore
    let folder: URL
    let sessionID: UUID

    func recordSummaries(for run: RunArchive) throws -> [CaptureRecord] {
        try Task.checkCancellation()
        guard run.sessionID == sessionID, try store.openSession(folder).id == sessionID else {
            throw StorageError.invalidSession
        }
        return try store.acknowledgedMainObservationSummaries(for: run, in: folder)
    }

    func loadRecord(_ summary: CaptureRecord) throws -> CaptureRecord {
        try Task.checkCancellation()
        guard try store.openSession(folder).id == sessionID else { throw StorageError.invalidSession }
        return try store.loadMainObservation(summary, in: folder)
    }
}

private nonisolated struct SessionEnvelope: Codable {
    let schema: Int
    var session: SessionMetadata
}
private nonisolated struct RecordEnvelope: Codable {
    let schema: Int
    let id: String
    let capturedAt: Date
    let metadata: [String: String]
    let events: [[String: String]]
    let complete: Bool
    let sampleCount: Int
    let sampleSHA256: String
}

/// A session is owned by the user. Callers must keep security-scoped access alive
/// while using a URL obtained from a system open or save panel.
nonisolated struct SessionStore: Sendable {
    let root: URL
    private var fm: FileManager { .default }
    private static let maxJSONBytes = 1_048_576
    private static let maxSampleBytes = 65_536
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func createSession(name: String, details: [String: String] = [:]) throws -> URL {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw StorageError.invalidSession }
        let meta = SessionMetadata(name: cleanName, details: details)
        let folder = root.appendingPathComponent("Signal Bench \(meta.id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("records", isDirectory: true), withIntermediateDirectories: false)
            try saveSession(meta, at: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    func openSession(_ folder: URL) throws -> SessionMetadata {
        try Self.requireSafeDirectory(folder)
        try Self.requireRegularFile(folder.appendingPathComponent("session.json"))
        let data = try Self.readBounded(folder.appendingPathComponent("session.json"), limit: Self.maxJSONBytes)
        let envelope = try Self.decoder.decode(SessionEnvelope.self, from: data)
        guard envelope.schema == 1 else { throw StorageError.unsupportedVersion }
        return envelope.session
    }

    func saveSession(_ session: SessionMetadata, at folder: URL) throws {
        guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StorageError.invalidSession }
        try Self.requireDirectory(folder)
        let data = try Self.encoder.encode(SessionEnvelope(schema: 1, session: session))
        guard data.count <= Self.maxJSONBytes else { throw StorageError.fileTooLarge }
        try data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
    }

    static func projectName(_ enteredName: String) throws -> String {
        let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let prohibited = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        guard !name.isEmpty, name.utf8.count <= 120, name.first != ".",
              name.unicodeScalars.allSatisfy({ !prohibited.contains($0) }) else { throw ProjectStorageError.invalidName }
        return name
    }

    func createProject(name enteredName: String) throws -> URL {
        let name = try Self.projectName(enteredName)
        try Self.requireSafeDirectory(root)
        let parentManifest = root.appendingPathComponent("session.json")
        var parentEntry = stat()
        if lstat(parentManifest.path, &parentEntry) == 0 { throw StorageError.unsafeLocation }
        guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let session = SessionMetadata(name: name)
        let staging = root.appendingPathComponent(".signal-bench-project-\(session.id.uuidString)", isDirectory: true)
        let manifest = staging.appendingPathComponent("session.json")
        let records = staging.appendingPathComponent("records", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let identity = try Self.projectDirectoryIdentity(staging)
        var published = false
        defer {
            // Clean only our own known files in our unpublished directory.
            if !published, let current = try? Self.projectDirectoryIdentity(staging),
               current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
                _ = unlink(manifest.path)
                _ = rmdir(records.path)
                _ = rmdir(staging.path)
            }
        }
        guard mkdir(records.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try Self.exclusiveJSON(try Self.encoder.encode(SessionEnvelope(schema: 1, session: session)), destination: manifest)
        try Self.syncDirectory(staging)
        for index in 1...100 {
            let folderName = index == 1 ? name : "\(name) \(index)"
            let destination = root.appendingPathComponent(folderName, isDirectory: true)
            if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                published = true
                try Self.syncDirectory(root)
                return destination
            }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        throw ProjectStorageError.nameConflict
    }

    func saveProjectMetadata(name: String, details: [String: String], expected: SessionMetadata,
                             in folder: URL) throws -> SessionMetadata {
        var session = try openSession(folder)
        guard session.id == expected.id, session.name == expected.name, session.details == expected.details else {
            throw ProjectStorageError.projectChanged
        }
        if name != session.name { session.name = try Self.projectName(name) }
        session.details = details
        let data = try Self.encoder.encode(SessionEnvelope(schema: 1, session: session))
        try Self.atomicJSON(data, destination: folder.appendingPathComponent("session.json"))
        return session
    }

    func saveCaptureIntent(_ intent: CaptureIntent, in folder: URL) throws {
        let session = try openSession(folder)
        try Self.validate(intent, token: intent.token, sessionID: session.id)
        let destination = Self.intentURL(intent.token, in: folder)
        let data = try Self.encoder.encode(intent)
        guard data.count <= Self.maxJSONBytes else { throw StorageError.fileTooLarge }
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        try Self.syncDirectory(folder)
    }

    func readCaptureIntent(_ token: String, in folder: URL) throws -> CaptureIntent? {
        guard CaptureIntent.validToken(token) else { throw StorageError.invalidIdentifier }
        let session = try openSession(folder)
        let data: Data
        do { data = try Self.readBounded(Self.intentURL(token, in: folder), limit: Self.maxJSONBytes) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
        let intent = try Self.decoder.decode(CaptureIntent.self, from: data)
        try Self.validate(intent, token: token, sessionID: session.id)
        return intent
    }

    func clearCaptureIntent(_ token: String, in folder: URL) throws {
        guard try readCaptureIntent(token, in: folder) != nil else { return }
        try fm.removeItem(at: Self.intentURL(token, in: folder))
        try Self.syncDirectory(folder)
    }

    private static func intentURL(_ token: String, in folder: URL) -> URL {
        folder.appendingPathComponent(".capture-intent-\(token).json")
    }

    private static func validate(_ intent: CaptureIntent, token: String, sessionID: UUID) throws {
        guard intent.schema == 1, CaptureIntent.validToken(token), intent.token == token, intent.sessionID == sessionID else {
            throw StorageError.invalidSession
        }
        guard intent.processingProfile == nil || ["NEGATIVE", "POSITIVE"].contains(intent.processingProfile!),
              intent.channel == nil || (0...2).contains(intent.channel!),
              intent.workspace == nil || ["measurements", "manual", "stage"].contains(intent.workspace!),
              intent.runID == nil || UUID(uuidString: intent.runID!) != nil,
              intent.probeSource == nil || ["ADC0", "VMID", "CSA", "GAIN", "SHP"].contains(intent.probeSource!) else {
            throw StorageError.corruptRecord(token)
        }
        if intent.observationOnly == true {
            guard ["BACKGROUND", "SOURCE"].contains(intent.tag ?? ""), intent.workspace == "measurements", intent.channel == 0,
                  intent.calibrationID == nil, intent.calibrationRecordID == nil else { throw StorageError.corruptRecord(token) }
        }
        if let stamp = intent.profileStamp {
            guard stamp.valid, intent.observationOnly == true, intent.runID != nil,
                  intent.mainObservationOptions == nil, intent.gainConfirmed == true else { throw StorageError.corruptRecord(token) }
        }
        if let options = intent.mainObservationOptions, intent.observationOnly != true || !options.isValid {
            throw StorageError.corruptRecord(token)
        }
        if let tag = intent.tag {
            guard CaptureIntent.matchesSession(token, sessionID),
                  intent.gain == "LOW" || intent.gain == "HIGH",
                  tag == "CAL" ? intent.calibrationRecordID == nil && intent.calibrationID == nil :
                    ((intent.observationOnly == true && ["BACKGROUND", "SOURCE"].contains(tag) && intent.workspace == "measurements" && intent.channel == 0 && intent.calibrationID == nil && intent.calibrationRecordID == nil) ||
                     (tag == "STAGE" && intent.channel.map { (1...2).contains($0) } == true && intent.workspace == "stage") ||
                     (["BACKGROUND", "SOURCE", "MANUAL", "STAGE"].contains(tag) &&
                      intent.calibrationID != nil && intent.calibrationRecordID.map(CaptureIntent.validToken) == true)) else {
                throw StorageError.corruptRecord(token)
            }
        } else if intent.observationOnly == true || CaptureIntent.isBound(token) || intent.gain != nil || intent.calibrationID != nil ||
                    intent.calibrationRecordID != nil || !intent.sessionDetails.isEmpty {
            throw StorageError.corruptRecord(token)
        }
    }

    /// A complete record is published by renaming a fully written sibling folder.
    /// Partial records have unique names so later retries cannot overwrite them.
    func saveRecord(_ record: CaptureRecord, to folder: URL) throws {
        let session = try openSession(folder)
        if let recordedSession = record.metadata["session_id"], recordedSession != session.id.uuidString { throw StorageError.invalidSession }
        let id = record.id.lowercased()
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StorageError.invalidIdentifier }
        guard record.samples.count <= 32768 else { throw StorageError.corruptRecord(id) }
        let records = folder.appendingPathComponent("records", isDirectory: true)
        try Self.requireSafeDirectory(records)
        let dest = records.appendingPathComponent(record.complete ? "record-\(id)" : "partial-\(id)-\(UUID().uuidString)", isDirectory: true)
        if record.complete && fm.fileExists(atPath: dest.path) {
            let existing = try readRecord(dest)
            guard existing.id.lowercased() == id, existing.samples == record.samples,
                  existing.metadata == record.metadata, existing.events == record.events, existing.complete else { throw StorageError.duplicateRecord }
            try Self.syncDirectory(dest)
            try Self.syncDirectory(records)
            return
        }
        var bytes = Data(capacity: record.samples.count * 2)
        for sample in record.samples { bytes.append(UInt8(sample & 0xff)); bytes.append(UInt8(sample >> 8)) }
        let digest = Self.digest(bytes)
        let envelope = RecordEnvelope(schema: 1, id: id, capturedAt: record.capturedAt, metadata: record.metadata,
                                      events: record.events, complete: record.complete, sampleCount: record.samples.count, sampleSHA256: digest)
        let recordData = try Self.encoder.encode(envelope)
        let pending = RecordEnvelope(schema: 1, id: id, capturedAt: record.capturedAt, metadata: record.metadata,
                                     events: record.events, complete: false, sampleCount: 0, sampleSHA256: Self.digest(Data()))
        let pendingData = try Self.encoder.encode(pending)
        guard recordData.count <= Self.maxJSONBytes, pendingData.count <= Self.maxJSONBytes else { throw StorageError.fileTooLarge }
        let staging = records.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try Self.writeSynchronized(pendingData, to: staging.appendingPathComponent("pending.json"))
            try Self.writeSynchronized(bytes, to: staging.appendingPathComponent("samples.bin"))
            try Self.writeSynchronized(recordData, to: staging.appendingPathComponent("record.json"))
            try Self.syncDirectory(staging)
            try fm.moveItem(at: staging, to: dest)
            try Self.syncDirectory(records)
        } catch {
            // Keep the pending directory for recovery rather than silently losing data.
            throw error
        }
    }

    func listRecords(_ folder: URL) throws -> [CaptureRecord] {
        _ = try openSession(folder)
        let records = folder.appendingPathComponent("records", isDirectory: true)
        try Self.requireSafeDirectory(records)
        let urls = try fm.contentsOfDirectory(at: records, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            .filter { $0.lastPathComponent.hasPrefix("record-") || $0.lastPathComponent.hasPrefix("partial-") || $0.lastPathComponent.hasPrefix(".pending-") }
        return urls.map { url in
            do {
                if url.lastPathComponent.hasPrefix(".pending-") { return try readPending(url) }
                return try readRecord(url)
            } catch {
                // Preserve the unreadable item on disk and make its failure visible without
                // preventing other intact records in the same session from being opened.
                // Do not expose unverified samples as a complete capture.
                return CaptureRecord(id: url.lastPathComponent,
                    capturedAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                    metadata: ["tag": "Unavailable record", "storage_recovery": "Could not verify \(url.lastPathComponent): \(error.localizedDescription). The original files remain in the session folder."],
                    events: [], samples: [], complete: false)
            }
        }.sorted { $0.capturedAt < $1.capturedAt }
    }

    func readRecord(_ folder: URL) throws -> CaptureRecord {
        try Self.requireSafeDirectory(folder)
        try Self.requireRegularFile(folder.appendingPathComponent("record.json"))
        try Self.requireRegularFile(folder.appendingPathComponent("samples.bin"))
        let envelope = try Self.decoder.decode(RecordEnvelope.self, from: Self.readBounded(folder.appendingPathComponent("record.json"), limit: Self.maxJSONBytes))
        guard envelope.schema == 1 else { throw StorageError.unsupportedVersion }
        let id = envelope.id
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StorageError.corruptRecord(id) }
        let name = folder.lastPathComponent
        if envelope.complete {
            guard name == "record-\(id)" else { throw StorageError.corruptRecord(id) }
        } else {
            let prefix = "partial-\(id)-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { throw StorageError.corruptRecord(id) }
        }
        let bytes = try Self.readBounded(folder.appendingPathComponent("samples.bin"), limit: Self.maxSampleBytes)
        guard envelope.sampleCount >= 0, envelope.sampleCount <= 32768,
              bytes.count == envelope.sampleCount * 2, Self.digest(bytes) == envelope.sampleSHA256 else { throw StorageError.corruptRecord(envelope.id) }
        let samples = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8) }
        return CaptureRecord(id: envelope.id, capturedAt: envelope.capturedAt, metadata: envelope.metadata,
                             events: envelope.events, samples: samples, complete: envelope.complete)
    }

    private func readPending(_ folder: URL) throws -> CaptureRecord {
        try Self.requireSafeDirectory(folder)
        let manifest = folder.appendingPathComponent("pending.json")
        if !fm.fileExists(atPath: manifest.path) {
            let provisionalID = folder.lastPathComponent.replacingOccurrences(of: ".pending-", with: "").replacingOccurrences(of: "-", with: "").lowercased()
            return CaptureRecord(id: provisionalID, capturedAt: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                                 metadata: ["storage_recovery": "Interrupted before record metadata was saved"], events: [], samples: [], complete: false)
        }
        try Self.requireRegularFile(manifest)
        let envelope = try Self.decoder.decode(RecordEnvelope.self, from: Self.readBounded(manifest, limit: Self.maxJSONBytes))
        guard envelope.schema == 1 else { throw StorageError.unsupportedVersion }
        let sampleURL = folder.appendingPathComponent("samples.bin")
        var bytes = Data()
        if fm.fileExists(atPath: sampleURL.path) {
            try Self.requireRegularFile(sampleURL)
            bytes = try Self.readBounded(sampleURL, limit: Self.maxSampleBytes)
        }
        let samples = stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map { UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8) }
        var metadata = envelope.metadata
        metadata["storage_recovery"] = "Interrupted save; samples may be incomplete"
        return CaptureRecord(id: envelope.id, capturedAt: envelope.capturedAt, metadata: metadata,
                             events: envelope.events, samples: samples, complete: false)
    }

    /// Streams a CSV while retaining the original raw words and ADC error bits.
    func exportRecord(_ record: CaptureRecord, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try Self.requireSafeDirectory(directory)
        let writer = try SessionCSVWriter(destination)
        try writer.append("section,key,value\n")
        try writer.append("record,id,\(Self.csv(record.id))\nrecord,complete,\(record.complete)\nrecord,captured_at,\(Self.csv(ISO8601DateFormatter().string(from: record.capturedAt)))\n")
        for key in record.metadata.keys.sorted() {
            try writer.append("metadata,\(Self.csv(key)),\(Self.csv(record.metadata[key] ?? ""))\n")
        }
        for (index, event) in record.events.enumerated() {
            for key in event.keys.sorted() {
                try writer.append("event_\(index),\(Self.csv(key)),\(Self.csv(event[key] ?? ""))\n")
            }
        }
        try writer.append("\nsample_index,raw_word,adc_code,adc_error\n")
        for (index, word) in record.samples.enumerated() {
            try writer.append("\(index),\(word),\(word & 0x0fff),\((word >> 15) & 1)\n")
        }
        try writer.finish()
        try Self.syncDirectory(directory)
    }

    func projectTrashSelection(in folder: URL) throws -> ProjectTrashSelection {
        let path = folder.standardizedFileURL
        guard path.path != "/", path.path != root.standardizedFileURL.path else { throw StorageError.unsafeLocation }
        try Self.requireSafeDirectory(path)
        try Self.requireSafeDirectory(path.appendingPathComponent("records", isDirectory: true))
        let info = try Self.projectDirectoryIdentity(path)
        let session = try openSession(path)
        return ProjectTrashSelection(id: session.id, name: session.name, folder: path,
                                     device: info.st_dev, inode: info.st_ino)
    }

    func trashProject(_ selection: ProjectTrashSelection, typedName: String,
                      moveToTrash: ((URL) throws -> Void)? = nil) throws {
        guard typedName == selection.name else { throw ProjectStorageError.confirmationMismatch }
        let current = try projectTrashSelection(in: selection.folder)
        guard current.id == selection.id, current.name == selection.name,
              current.device == selection.device, current.inode == selection.inode else { throw ProjectStorageError.projectChanged }
        if let moveToTrash { try moveToTrash(selection.folder) }
        else { try fm.trashItem(at: selection.folder, resultingItemURL: nil) }
    }

    private static func projectDirectoryIdentity(_ folder: URL) throws -> stat {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & mode_t(S_IFMT)) == S_IFDIR else { throw StorageError.unsafeLocation }
        return info
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Bound memory consumption and refuse final-component symlinks even if a
    /// selected session changes between directory enumeration and file access.
    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else { throw StorageError.unsafeLocation }
        guard info.st_size <= limit else { throw StorageError.fileTooLarge }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let capacity = min(chunk.count, limit + 1 - data.count)
            guard capacity > 0 else { throw StorageError.fileTooLarge }
            let n = Darwin.read(fd, &chunk, capacity)
            if n == 0 { return data }
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            data.append(contentsOf: chunk.prefix(n))
            guard data.count <= limit else { throw StorageError.fileTooLarge }
        }
    }
    private static func requireDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw StorageError.unsafeLocation }
    }
    private static func requireRegularFile(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true else { throw StorageError.unsafeLocation }
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private static func writeSynchronized(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
    }
}

struct StorageItem: Identifiable {
    var id: String { title }
    let title: String
    let url: URL
    let bytes: Int64
}

/// Owns only the app data directory inside the user-authorized Signal Bench folder.
/// Callers keep security-scoped access to `root` while using this service.
struct StorageManager {
    let root: URL
    private var fm: FileManager { .default }
    var dataURL: URL { root.appendingPathComponent("Signal Bench Data", isDirectory: true) }
    var appSupportURL: URL { dataURL.appendingPathComponent("Support", isDirectory: true) }
    var cacheURL: URL { dataURL.appendingPathComponent("Cache", isDirectory: true) }
    private var ownershipURL: URL { dataURL.appendingPathComponent(".signal-bench-owned") }
    private let ownershipText = "Signal Bench app data version 1\n"

    /// Check access without creating or modifying anything in the selected folder.
    /// This is a preflight, not a promise that a future write cannot fail.
    func checkRootAccess() throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(fd) }
        guard Darwin.access(root.path, R_OK | W_OK | X_OK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = try fm.contentsOfDirectory(atPath: root.path)
    }

    /// Do not adopt an existing folder: it may contain unrelated user files.
    func prepareDataDirectory() throws {
        try checkRootAccess()
        if fm.fileExists(atPath: dataURL.path) { try validateOwnedDataDirectory(); return }
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: false)
        do { try Data(ownershipText.utf8).write(to: ownershipURL, options: .withoutOverwriting) }
        catch { throw error }
    }

    private func validateOwnedDataDirectory() throws {
        let values = try dataURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw StorageError.unsafeLocation }
        let marker = try ownershipURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard marker.isSymbolicLink != true, marker.isRegularFile == true, marker.fileSize == ownershipText.utf8.count else { throw StorageError.unsafeLocation }
        let fd = Darwin.open(ownershipURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageError.unsafeLocation }
        defer { _ = Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: ownershipText.utf8.count + 1)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n == ownershipText.utf8.count, Array(buf.prefix(n)) == Array(ownershipText.utf8) else { throw StorageError.unsafeLocation }
    }
    private func hasOwnedDataDirectory() throws -> Bool {
        var info = stat()
        if Darwin.lstat(dataURL.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try validateOwnedDataDirectory()
        return true
    }

    func inventory() throws -> [StorageItem] {
        try checkRootAccess()
        guard try hasOwnedDataDirectory() else {
            return [StorageItem(title: "App Data", url: appSupportURL, bytes: 0),
                    StorageItem(title: "Cache", url: cacheURL, bytes: 0)]
        }
        return [StorageItem(title: "App Data", url: appSupportURL, bytes: try size(appSupportURL)),
                StorageItem(title: "Cache", url: cacheURL, bytes: try size(cacheURL))]
    }
    func clearCache() throws { try checkRootAccess(); try removeOwnedDirectory(cacheURL) }
    func resetSettings() throws {
        try checkRootAccess()
        guard try hasOwnedDataDirectory() else { return }
        let settings = appSupportURL.appendingPathComponent("settings.json")
        guard fm.fileExists(atPath: settings.path) else { return }
        try validateOwnedDataDirectory()
        try validateSafeTree(dataURL)
        let v = try settings.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard v.isSymbolicLink != true, v.isRegularFile == true else { throw StorageError.unsafeLocation }
        try fm.removeItem(at: settings)
    }
    func deleteAppData() throws {
        try checkRootAccess()
        guard try hasOwnedDataDirectory() else { return }
        var removed: [String] = []
        for (name, url) in [("Support", appSupportURL), ("Cache", cacheURL)] {
            do {
                if try existsWithoutFollowing(url) {
                    try removeOwnedDirectory(url)
                    removed.append(name)
                }
            } catch {
                guard !removed.isEmpty else { throw error }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "Removed \(removed.joined(separator: ", ")), but could not remove \(name): \(error.localizedDescription)", NSUnderlyingErrorKey: error])
            }
        }
    }
    func reveal(_ url: URL) { if fm.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func exportAppData(to destination: URL) throws {
        try checkRootAccess()
        guard try hasOwnedDataDirectory() else { throw StorageError.noData }
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let authorizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let support = appSupportURL.resolvingSymlinksInPath().standardizedFileURL.path
        let cache = cacheURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard (parent == authorizedRoot || parent.hasPrefix(authorizedRoot + "/")), parent != support, !parent.hasPrefix(support + "/"), parent != cache, !parent.hasPrefix(cache + "/") else { throw StorageError.unsafeLocation }
        guard fm.fileExists(atPath: appSupportURL.path) else { throw StorageError.noData }
        try validateOwnedDataDirectory()
        try validateSafeTree(dataURL)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try fm.copyItem(at: appSupportURL, to: destination.appendingPathComponent("App Data"))
        } catch {
            // Preserve the incomplete export for diagnosis; do not touch existing data.
            throw error
        }
    }

    private func removeOwnedDirectory(_ url: URL) throws {
        guard url.standardizedFileURL == appSupportURL.standardizedFileURL || url.standardizedFileURL == cacheURL.standardizedFileURL else { throw StorageError.unsafeLocation }
        guard try hasOwnedDataDirectory() else { return }
        guard try existsWithoutFollowing(url) else { return }
        try validateOwnedDataDirectory()
        let parent = dataURL.standardizedFileURL
        let parentValues = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard parentValues.isSymbolicLink != true, parentValues.isDirectory == true else { throw StorageError.unsafeLocation }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StorageError.unsafeLocation }
        // A user-selected session may be inside this directory. Never remove it.
        try validateSafeTree(url)
        try fm.removeItem(at: url)
    }
    /// Refuse the entire operation if any descendant cannot be inspected.
    /// Otherwise a protected session could be hidden in an unreadable folder.
    private func validateSafeTree(_ url: URL) throws {
        let rootValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { throw StorageError.unsafeLocation }
        var enumerationError: Error?
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        for case let child as URL in e {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard child.lastPathComponent != "session.json", values.isSymbolicLink != true else { throw StorageError.unsafeLocation }
        }
        if let enumerationError { throw enumerationError }
    }
    private func existsWithoutFollowing(_ url: URL) throws -> Bool {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    private func size(_ url: URL) throws -> Int64 {
        var info = stat()
        if Darwin.lstat(url.path, &info) != 0 {
            if errno == ENOENT { return 0 }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw StorageError.unsafeLocation }
        var enumerationError: Error?
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var total: Int64 = 0
        for case let child as URL in e {
            let v = try child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v.isSymbolicLink == true { e.skipDescendants(); continue }
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        if let enumerationError { throw enumerationError }
        return total
    }
}

private nonisolated struct StoredAnalysis: Codable {
    let schema: Int
    let id: UUID
    let recordID: String
    let inputSHA256: String
    let createdAt: Date
    let payload: Data
}

/// Bounded buffered output. A failed export leaves the explicitly named partial
/// file for inspection and never publishes it as a complete export.
nonisolated final class SessionCSVWriter {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(_ destination: URL) throws {
        self.destination = destination
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString)-\(destination.lastPathComponent)")
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= 16_384 { try flush() }
    }

    private func flush() throws {
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
    }

    func finish() throws {
        guard !finished else { return }
        try flush()
        try handle.synchronize()
        try handle.close()
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        finished = true
    }

    func discardPartial() {
        guard !finished else { return }
        try? handle.close()
        _ = unlink(temporary.path)
    }

    deinit { try? handle.close() }
}

nonisolated extension SessionStore {
    /// Enumerates metadata only. A waveform is verified when explicitly loaded.
    /// These transient host fields are never written back into record.json.
    func listRecordSummaries(_ folder: URL) throws -> [CaptureRecord] {
        _ = try openSession(folder)
        try Self.requireSafeDirectory(folder)
        let directory = folder.appendingPathComponent("records", isDirectory: true)
        try Self.requireSafeDirectory(directory)
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [])
            .filter { $0.lastPathComponent.hasPrefix("record-") || $0.lastPathComponent.hasPrefix("partial-") || $0.lastPathComponent.hasPrefix(".pending-") }
        return urls.map { item in
            do {
                try Self.requireSafeDirectory(item)
                let name = item.lastPathComponent.hasPrefix(".pending-") ? "pending.json" : "record.json"
                let envelope = try Self.decoder.decode(RecordEnvelope.self, from: Self.readBounded(item.appendingPathComponent(name), limit: Self.maxJSONBytes))
                guard envelope.schema == 1, CaptureIntent.validToken(envelope.id),
                      (0...32768).contains(envelope.sampleCount), Self.validSHA(envelope.sampleSHA256) else { throw StorageError.corruptRecord(envelope.id) }
                if envelope.complete {
                    guard item.lastPathComponent == "record-\(envelope.id)" else { throw StorageError.corruptRecord(envelope.id) }
                } else if !item.lastPathComponent.hasPrefix(".pending-") {
                    let prefix = "partial-\(envelope.id)-"
                    guard item.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(item.lastPathComponent.dropFirst(prefix.count))) != nil else { throw StorageError.corruptRecord(envelope.id) }
                }
                var metadata = envelope.metadata
                metadata["host_sample_count"] = String(envelope.sampleCount)
                metadata["host_sample_sha256"] = envelope.sampleSHA256
                metadata["host_samples_loaded"] = "0"
                metadata["host_record_directory"] = item.lastPathComponent
                return CaptureRecord(id: envelope.id, capturedAt: envelope.capturedAt, metadata: metadata,
                                     events: envelope.events, samples: [], complete: envelope.complete)
            } catch {
                return CaptureRecord(id: item.lastPathComponent,
                    capturedAt: (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                    metadata: ["tag": "Unavailable record", "host_record_directory": item.lastPathComponent,
                               "storage_recovery": "Could not read \(item.lastPathComponent): \(error.localizedDescription). Original files are retained."],
                    events: [], samples: [], complete: false)
            }
        }.sorted { $0.capturedAt < $1.capturedAt }
    }

    func loadRecord(_ id: String, in folder: URL) throws -> CaptureRecord {
        guard CaptureIntent.validToken(id) else { throw StorageError.invalidIdentifier }
        _ = try openSession(folder)
        let records = folder.appendingPathComponent("records", isDirectory: true)
        try Self.requireSafeDirectory(records)
        let complete = records.appendingPathComponent("record-\(id)", isDirectory: true)
        if fm.fileExists(atPath: complete.path) { return try readRecord(complete) }
        let summaries = try listRecordSummaries(folder)
        guard let summary = summaries.last(where: { $0.id == id }) else { throw StorageError.corruptRecord(id) }
        return try loadRecord(summary, in: folder)
    }

    func loadRecord(_ summary: CaptureRecord, in folder: URL) throws -> CaptureRecord {
        _ = try openSession(folder)
        guard let name = summary.metadata["host_record_directory"] else { return try loadRecord(summary.id, in: folder) }
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasPrefix("record-") || name.hasPrefix("partial-") || name.hasPrefix(".pending-") else { throw StorageError.unsafeLocation }
        let location = folder.appendingPathComponent("records", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try Self.requireSafeDirectory(location)
        if name.hasPrefix(".pending-") { return try readPending(location) }
        let record = try readRecord(location)
        guard record.id == summary.id else { throw StorageError.corruptRecord(summary.id) }
        return record
    }

    fileprivate func loadMainObservation(_ summary: CaptureRecord, in folder: URL) throws -> CaptureRecord {
        guard summary.complete, summary.metadata["observation_only"] == "1",
              let expectedSHA = summary.metadata["host_sample_sha256"] else { throw StorageError.corruptRecord(summary.id) }
        let record = try loadRecord(summary, in: folder)
        let bytes = Data(record.samples.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        guard record.complete, record.metadata["observation_only"] == "1",
              record.metadata["host_run_id"] == summary.metadata["host_run_id"],
              MainObservationOptions(metadata: record.metadata) == MainObservationOptions(metadata: summary.metadata),
              Self.digest(bytes) == expectedSHA else { throw StorageError.corruptRecord(summary.id) }
        return record
    }

    func saveRun(_ run: RunArchive, in folder: URL) throws {
        let session = try openSession(folder)
        try Self.validateRun(run, sessionID: session.id)
        let directory = try runDirectory(run.id, in: folder, create: true)
        let destination = directory.appendingPathComponent("run.json")
        if fm.fileExists(atPath: destination.path) {
            let previous = try Self.decoder.decode(RunArchive.self, from: Self.readBounded(destination, limit: Self.maxJSONBytes))
            guard previous.id == run.id, previous.sessionID == run.sessionID, previous.tag == run.tag,
                  previous.workspace == run.workspace, previous.targetCount == run.targetCount,
                  previous.durationSeconds == run.durationSeconds,
                  (previous.observationOnly ?? false) == (run.observationOnly ?? false),
                  previous.mainObservationOptions == run.mainObservationOptions,
                  previous.profileAcquisition == run.profileAcquisition,
                  Array((run.profileSegments ?? []).prefix(previous.profileSegments?.count ?? 0)) == (previous.profileSegments ?? []),
                  previous.processingProfile == nil || previous.processingProfile == run.processingProfile,
                  (previous.physicalGain == nil || previous.physicalGain == run.physicalGain),
                  previous.gainConfirmed == nil || previous.gainConfirmed == run.gainConfirmed else { throw StorageError.invalidSession }
        }
        try Self.atomicJSON(try Self.encoder.encode(run), destination: destination)
    }

    func loadRuns(_ folder: URL) throws -> [RunArchive] {
        let session = try openSession(folder)
        let directory = folder.appendingPathComponent("runs", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) { return [] }
        try Self.requireSafeDirectory(directory)
        let names = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        return try names.map { location in
            try Self.requireSafeDirectory(location)
            let run = try Self.decoder.decode(RunArchive.self, from: Self.readBounded(location.appendingPathComponent("run.json"), limit: Self.maxJSONBytes))
            try Self.validateRun(run, sessionID: session.id)
            guard run.id.uuidString == location.lastPathComponent else { throw StorageError.invalidIdentifier }
            return run
        }.sorted { $0.startedAt < $1.startedAt }
    }

    @discardableResult
    func acknowledgeRecord(_ record: CaptureRecord, runID: UUID, in folder: URL) throws -> RunRecordReceipt {
        let session = try openSession(folder)
        let runLocation = try runDirectory(runID, in: folder, create: false)
        let run = try Self.decoder.decode(RunArchive.self, from: Self.readBounded(runLocation.appendingPathComponent("run.json"), limit: Self.maxJSONBytes))
        try Self.validateRun(run, sessionID: session.id)
        guard record.complete, record.metadata["host_run_id"] == runID.uuidString,
              CaptureIntent.validToken(record.id) else { throw StorageError.corruptRecord(record.id) }
        let original = try loadRecord(record.id, in: folder)
        guard original.complete, original.metadata == record.metadata, original.events == record.events,
              original.samples == record.samples else { throw StorageError.corruptRecord(record.id) }
        let directory = try Self.createLocalDirectory("acks", under: runLocation)
        let path = directory.appendingPathComponent("\(record.id).json")
        let bytes = record.samples.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        let hash = Self.digest(Data(bytes))
        if fm.fileExists(atPath: path.path) {
            let old = try Self.decoder.decode(RunRecordReceipt.self, from: Self.readBounded(path, limit: Self.maxJSONBytes))
            guard old.id == record.id, old.sessionID == session.id, old.runID == runID,
                  old.sampleSHA256 == hash else { throw StorageError.duplicateRecord }
            return old
        }
        let hz = Double(record.metadata["sample_hz"] ?? "") ?? 0
        let validHZ = hz.isFinite && hz > 0
        let observing = record.metadata["observation_only"] == "1"
        let rejected = observing ? ((UInt32(record.metadata["acq_flags"] ?? "") ?? UInt32.max) != 0 || (UInt32(record.metadata["quality_flags"] ?? "") ?? UInt32.max) != 0) : record.metadata["usable"] != "1"
        let receipt = RunRecordReceipt(id: record.id, runID: runID, sessionID: session.id, sampleSHA256: hash,
            candidates: max(0, Int(record.metadata["candidates"] ?? "") ?? 0),
            qualifiedPulses: !observing && record.metadata["usable"] == "1" ? record.events.filter { $0["qualified"] == "1" }.count : 0,
            rejectedWindows: rejected ? 1 : 0,
            sampledSeconds: validHZ ? Double(record.samples.count) / hz : 0,
            gapSeconds: max(0, Double(record.metadata["gap_before_us"] ?? "") ?? 0) / 1_000_000, observationWindows: observing ? 1 : 0)
        let encoded = try Self.encoder.encode(receipt)
        try Self.exclusiveJSON(encoded, destination: path)
        try Self.syncDirectory(directory)
        return try Self.decoder.decode(RunRecordReceipt.self, from: encoded)
    }

    func acknowledgedRecords(runID: UUID, in folder: URL) throws -> [RunRecordReceipt] {
        try validatedAcknowledgements(runID: runID, in: folder).map(\.receipt)
    }

    fileprivate func acknowledgedMainObservationSummaries(for run: RunArchive, in folder: URL) throws -> [CaptureRecord] {
        let session = try openSession(folder)
        let location = try runDirectory(run.id, in: folder, create: false)
        let saved = try Self.decoder.decode(RunArchive.self, from: Self.readBounded(location.appendingPathComponent("run.json"), limit: Self.maxJSONBytes))
        try Self.validateRun(saved, sessionID: session.id)
        guard saved.id == run.id, saved.sessionID == run.sessionID, saved.workspace == "measurements",
              saved.observationOnly == true, saved.mainObservationOptions == run.mainObservationOptions else {
            throw StorageError.invalidSession
        }
        return try validatedAcknowledgements(runID: run.id, in: folder).map { _, record in
            guard record.metadata["observation_only"] == "1",
                  record.metadata["tag"] == saved.tag,
                  MainObservationOptions(metadata: record.metadata) == saved.mainObservationOptions else {
                throw StorageError.corruptRecord(record.id)
            }
            return record
        }
    }

    private func validatedAcknowledgements(runID: UUID, in folder: URL) throws -> [(receipt: RunRecordReceipt, record: CaptureRecord)] {
        let session = try openSession(folder)
        let run = try runDirectory(runID, in: folder, create: false)
        let acks = run.appendingPathComponent("acks", isDirectory: true)
        if !fm.fileExists(atPath: acks.path) { return [] }
        try Self.requireSafeDirectory(acks)
        let urls = try fm.contentsOfDirectory(at: acks, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let summaries = try listRecordSummaries(folder)
        let indexed = Dictionary(summaries.filter { $0.complete }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try urls.map { url in
            let value = try Self.decoder.decode(RunRecordReceipt.self, from: Self.readBounded(url, limit: 8192))
            guard value.schema == 1, value.runID == runID, value.sessionID == session.id,
                  CaptureIntent.validToken(value.id), url.lastPathComponent == "\(value.id).json",
                  Self.validSHA(value.sampleSHA256), value.candidates >= 0, value.qualifiedPulses >= 0,
                  value.qualifiedPulses <= value.candidates, (0...1).contains(value.rejectedWindows),
                  (0...1).contains(value.observationWindows ?? 0),
                  value.sampledSeconds.isFinite, value.sampledSeconds >= 0,
                  value.gapSeconds.isFinite, value.gapSeconds >= 0 else { throw StorageError.corruptRecord(url.lastPathComponent) }
            guard let record = indexed[value.id], record.metadata["host_run_id"] == runID.uuidString,
                  record.metadata["host_sample_sha256"] == value.sampleSHA256,
                  value.candidates == max(0, Int(record.metadata["candidates"] ?? "") ?? 0),
                  value.qualifiedPulses == (record.metadata["observation_only"] != "1" && record.metadata["usable"] == "1" ? record.events.filter { $0["qualified"] == "1" }.count : 0),
                  (value.observationWindows ?? 0) == (record.metadata["observation_only"] == "1" ? 1 : 0),
                  value.rejectedWindows == (record.metadata["observation_only"] == "1" ?
                    (((UInt32(record.metadata["acq_flags"] ?? "") ?? UInt32.max) != 0 || (UInt32(record.metadata["quality_flags"] ?? "") ?? UInt32.max) != 0) ? 1 : 0) : (record.metadata["usable"] == "1" ? 0 : 1)) else {
                throw StorageError.corruptRecord(value.id)
            }
            return (receipt: value, record: record)
        }.sorted { $0.receipt.acknowledgedAt < $1.receipt.acknowledgedAt }
    }

    func runTotals(runID: UUID, in folder: URL) throws -> RunRecordTotals {
        var totals = RunRecordTotals()
        for value in try acknowledgedRecords(runID: runID, in: folder) {
            totals.completed += 1; totals.candidates += value.candidates
            totals.qualifiedPulses += value.qualifiedPulses; totals.rejectedWindows += value.rejectedWindows
            totals.observationWindows += value.observationWindows ?? 0
            totals.sampledSeconds += value.sampledSeconds; totals.gapSeconds += value.gapSeconds
        }
        return totals
    }

    func saveAnalysis(_ data: Data, id: UUID, recordID: String, inputSHA256: String, in folder: URL) throws {
        guard data.count <= Self.maxJSONBytes / 2, Self.validSHA(inputSHA256) else { throw StorageError.fileTooLarge }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let record = try loadRecord(recordID, in: folder)
        let raw = Data(record.samples.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        guard record.complete, Self.digest(raw) == inputSHA256 else { throw StorageError.corruptRecord(recordID) }
        let root = try Self.createLocalDirectory("analyses", under: folder)
        let directory = try Self.createLocalDirectory(recordID, under: root)
        let envelope = StoredAnalysis(schema: 1, id: id, recordID: recordID, inputSHA256: inputSHA256, createdAt: Date(), payload: data)
        try Self.exclusiveJSON(try Self.encoder.encode(envelope), destination: directory.appendingPathComponent("\(id.uuidString).json"))
        try Self.syncDirectory(directory)
    }

    func readAnalyses(recordID: String, in folder: URL) throws -> [Data] {
        guard CaptureIntent.validToken(recordID) else { throw StorageError.invalidIdentifier }
        let record = try loadRecord(recordID, in: folder)
        let raw = Data(record.samples.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        let hash = Self.digest(raw)
        let directory = folder.appendingPathComponent("analyses", isDirectory: true).appendingPathComponent(recordID, isDirectory: true)
        if !fm.fileExists(atPath: directory.path) { return [] }
        try Self.requireSafeDirectory(directory)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { url in
            let value = try Self.decoder.decode(StoredAnalysis.self, from: Self.readBounded(url, limit: Self.maxJSONBytes))
            guard value.schema == 1, value.recordID == recordID, value.inputSHA256 == hash,
                  url.lastPathComponent == "\(value.id.uuidString).json" else { throw StorageError.corruptRecord(recordID) }
            return value.payload
        }
    }

    /// Exports one run into an exclusively created directory directly inside its
    /// session. Cancellation or failure retains a .partial-export directory.
    func exportRun(_ run: RunArchive, in folder: URL, to destination: URL,
                   includeRawSamples: Bool = false, cancelled: () -> Bool = { false }) throws {
        let session = try openSession(folder)
        try Self.validateRun(run, sessionID: session.id)
        try Self.requireSafeDirectory(folder)
        guard destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              !destination.lastPathComponent.hasPrefix("."), destination.lastPathComponent != "records",
              destination.lastPathComponent != "runs", destination.lastPathComponent != "analyses" else { throw StorageError.unsafeLocation }
        var status = stat()
        guard lstat(destination.path, &status) != 0, errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
        let partial = folder.appendingPathComponent(".partial-export-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(partial.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try Self.exclusiveJSON(Data("{\"schema\":1,\"complete\":false}\n".utf8), destination: partial.appendingPathComponent("export-state.json"))
        try Self.syncDirectory(folder)
        let receipts = try acknowledgedRecords(runID: run.id, in: folder)
        let acknowledged = Set(receipts.map(\.id))
        let records = try listRecordSummaries(folder).filter { $0.metadata["host_run_id"] == run.id.uuidString }
        let quality = try SessionCSVWriter(partial.appendingPathComponent("quality.csv"))
        let candidates = try SessionCSVWriter(partial.appendingPathComponent("candidates.csv"))
        let calibrations = try SessionCSVWriter(partial.appendingPathComponent("calibrations.json"))
        try quality.append("record_id,captured_at,complete,acknowledged,channel,source,profile,calibration_record_id,sample_count,sample_hz,acquisition_flags,quality_flags,usable,candidates,qualified_pulses,gap_before_us\n")
        try candidates.append("record_id,acknowledged,candidate_index,start_sample,peak_sample,end_sample,delta_codes,flags,qualified,details_json\n")
        try calibrations.append("[\n")
        var firstCalibration = true
        let rawDirectory = includeRawSamples ? try Self.createLocalDirectory("raw", under: partial) : nil
        let analysisDirectory = try Self.createLocalDirectory("analyses", under: partial)
        for summary in records {
            if cancelled() { throw CocoaError(.userCancelled) }
            let record = try loadRecord(summary, in: folder)
            let fields = [record.id, ISO8601DateFormatter().string(from: record.capturedAt), String(record.complete),
                          String(acknowledged.contains(record.id)), record.metadata["channel"] ?? "0",
                          record.metadata["host_probe_source"] ?? record.metadata["probe_source"] ?? "ADC0",
                          record.metadata["profile"] ?? record.metadata["host_processing_profile"] ?? "POSITIVE",
                          record.metadata["calibration_record_id"] ?? "", String(record.samples.count),
                          record.metadata["sample_hz"] ?? "", record.metadata["acq_flags"] ?? "",
                          record.metadata["quality_flags"] ?? "", record.metadata["usable"] ?? "",
                          record.metadata["candidates"] ?? "", String(record.events.filter { $0["qualified"] == "1" }.count),
                          record.metadata["gap_before_us"] ?? ""]
            try quality.append(fields.map(Self.csv).joined(separator: ",") + "\n")
            for (index, event) in record.events.enumerated() {
                let details = String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
                let values = [record.id, String(acknowledged.contains(record.id)), String(index), event["start"] ?? "",
                              event["peak"] ?? "", event["end"] ?? "", event["delta_codes"] ?? "", event["flags"] ?? "",
                              event["qualified"] ?? "", details]
                try candidates.append(values.map(Self.csv).joined(separator: ",") + "\n")
            }
            if let rawDirectory {
                try exportRecord(record, to: rawDirectory.appendingPathComponent("\(record.id).csv"))
                let bytes = Data(record.samples.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
                try Self.exclusiveJSON(bytes, destination: rawDirectory.appendingPathComponent("\(record.id).bin"))
            }
            for (index, data) in try readAnalyses(recordID: record.id, in: folder).enumerated() {
                try Self.exclusiveJSON(data, destination: analysisDirectory.appendingPathComponent("\(record.id)-\(index).json"))
            }
        }
        for id in Array(Set(run.calibrationRecordIDs)).sorted() {
            if cancelled() { throw CocoaError(.userCancelled) }
            let record = try loadRecord(id, in: folder)
            guard record.metadata["tag"] == "CAL" else { throw StorageError.corruptRecord(id) }
            if !firstCalibration { try calibrations.append(",\n") }
            firstCalibration = false
            let data = try Self.encoder.encode(record)
            try calibrations.append(String(decoding: data, as: UTF8.self))
        }
        try calibrations.append("\n]\n")
        try quality.finish(); try candidates.finish(); try calibrations.finish()
        let totals = try runTotals(runID: run.id, in: folder)
        let summary = RunExportSummary(schema: 1, run: run, complete: true, savedRecords: records.count,
            acknowledgedRecords: totals.completed, unacknowledgedRecords: records.filter { !acknowledged.contains($0.id) }.count,
            candidates: totals.candidates, qualifiedPulses: totals.qualifiedPulses,
            rejectedWindows: totals.rejectedWindows, nominalSampledSeconds: totals.sampledSeconds,
            gapSeconds: totals.gapSeconds, rateExposureValid: false)
        try Self.exclusiveJSON(try Self.encoder.encode(summary), destination: partial.appendingPathComponent("run-summary.json"))
        try Self.exclusiveJSON(try Self.encoder.encode(session), destination: partial.appendingPathComponent("session.json"))
        try Self.atomicJSON(Data("{\"schema\":1,\"complete\":true}\n".utf8), destination: partial.appendingPathComponent("export-state.json"))
        try Self.syncDirectory(partial)
        if cancelled() { throw CocoaError(.userCancelled) }
        // RENAME_EXCL prevents replacing a directory created after the initial check.
        guard renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try Self.syncDirectory(folder)
    }

    private func runDirectory(_ id: UUID, in folder: URL, create: Bool) throws -> URL {
        _ = try openSession(folder)
        try Self.requireSafeDirectory(folder)
        if create {
            let runs = try Self.createLocalDirectory("runs", under: folder)
            return try Self.createLocalDirectory(id.uuidString, under: runs)
        }
        let path = folder.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.requireSafeDirectory(path)
        return path
    }

    private static func validateRun(_ run: RunArchive, sessionID: UUID) throws {
        guard run.schema == 1, run.sessionID == sessionID,
              ["BACKGROUND", "SOURCE", "MANUAL", "STAGE"].contains(run.tag),
              ["measurements", "manual", "stage"].contains(run.workspace),
              run.processingProfile == nil || ["POSITIVE", "NEGATIVE"].contains(run.processingProfile!),
              run.physicalGain == nil || ["LOW", "HIGH"].contains(run.physicalGain!),
              run.targetCount.map({ (1...100_000).contains($0) }) ?? true,
              run.durationSeconds.map({ $0.isFinite && $0 >= 1 && $0 <= 86_400 }) ?? true,
              run.targetCount != nil || run.durationSeconds != nil,
              run.elapsedActiveSeconds.isFinite, run.elapsedActiveSeconds >= 0,
              ["running", "pausing", "paused", "completed", "interrupted", "failed"].contains(run.phase),
              run.calibrationRecordIDs.count <= 10_000,
              run.calibrationRecordIDs.allSatisfy(CaptureIntent.validToken),
              run.completed >= 0, run.candidates >= 0, run.qualifiedPulses >= 0, run.rejectedWindows >= 0,
              run.qualifiedPulses <= run.candidates, run.rejectedWindows <= run.completed,
              (run.observationWindows ?? 0) >= 0, (run.observationWindows ?? 0) <= run.completed,
              run.sampledSeconds.isFinite, run.sampledSeconds >= 0,
              run.gapSeconds.isFinite, run.gapSeconds >= 0 else { throw StorageError.invalidSession }
        if let acquisition = run.profileAcquisition {
            let segments = run.profileSegments ?? []
            guard acquisition.valid, run.observationOnly == true, run.workspace == "measurements",
                  run.mainObservationOptions == nil, run.durationSeconds != nil,
                  (1...2000).contains(segments.count), segments.first?.id == acquisition.segment,
                  (run.profilePauseReason?.utf8.count ?? 0) <= 500,
                  segments.allSatisfy({ (0...86_400).contains($0.elapsedAtStart) && $0.boot.count == 16 && UInt64($0.boot, radix: 16) != nil })
            else { throw StorageError.invalidSession }
        } else if run.profileSegments != nil { throw StorageError.invalidSession }
        if let options = run.mainObservationOptions,
           !options.isValid || run.observationOnly != true || run.workspace != "measurements" || !["BACKGROUND", "SOURCE"].contains(run.tag) {
            throw StorageError.invalidSession
        }
    }

    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func createLocalDirectory(_ name: String, under parent: URL) throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name != ".", name != ".." else { throw StorageError.unsafeLocation }
        try requireSafeDirectory(parent)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try requireSafeDirectory(directory)
        try syncDirectory(parent)
        return directory
    }

    /// Refuse links anywhere in an application-controlled path. macOS canonical
    /// system aliases are permitted only before an approved user data subtree.
    private static func requireSafeDirectory(_ directory: URL) throws {
        let standardized = directory.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if current.path == "/var" || current.path == "/tmp" { continue }
            try requireDirectory(current)
        }
    }

    private static func atomicJSON(_ data: Data, destination: URL) throws {
        guard data.count <= maxJSONBytes else { throw StorageError.fileTooLarge }
        let parent = destination.deletingLastPathComponent()
        try requireSafeDirectory(parent)
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw StorageError.unsafeLocation }
        } else if errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let temporary = parent.appendingPathComponent(".pending-\(UUID().uuidString).json")
        try exclusiveJSON(data, destination: temporary)
        guard rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try syncDirectory(parent)
    }

    private static func exclusiveJSON(_ data: Data, destination: URL) throws {
        guard data.count <= maxJSONBytes else { throw StorageError.fileTooLarge }
        try requireSafeDirectory(destination.deletingLastPathComponent())
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
    }

    private static func csv(_ value: String) -> String {
        let trimmed = value.drop(while: { $0.isWhitespace })
        let unsafe = value.first.map { $0 == "\t" || $0 == "\r" || $0 == "\n" } == true || trimmed.first.map { "=+-@".contains($0) } == true
        return "\"" + (unsafe ? "'" : "") + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private nonisolated struct RunExportSummary: Codable {
    let schema: Int
    let run: RunArchive
    let complete: Bool
    let savedRecords: Int
    let acknowledgedRecords: Int
    let unacknowledgedRecords: Int
    let candidates: Int
    let qualifiedPulses: Int
    let rejectedWindows: Int
    let nominalSampledSeconds: Double
    let gapSeconds: Double
    let rateExposureValid: Bool
}

nonisolated extension SessionStore {
    func projectExportsDirectory(in folder: URL, create: Bool) throws -> URL {
        _ = try openSession(folder)
        let exports = folder.appendingPathComponent("Exports", isDirectory: true)
        if create {
            let directory = try Self.createLocalDirectory("Exports", under: folder)
            try Self.syncDirectory(folder)
            return directory
        }
        var state = stat()
        if lstat(exports.path, &state) != 0, errno == ENOENT { throw StorageError.noData }
        try Self.requireSafeDirectory(exports)
        return exports
    }

    func exportProjectCSV(runID: UUID?, recordID: String?, request: ProjectCSVRequest,
                          projectID: UUID, in folder: URL, cancelled: () -> Bool) throws -> URL {
        guard try openSession(folder).id == projectID else { throw StorageError.invalidSession }
        guard !cancelled() else { throw CocoaError(.userCancelled) }
        let summaries: [CaptureRecord]
        let state: String
        let requestedSeconds: Double?
        let elapsedSeconds: Double?
        let acknowledged: Set<String>
        if let runID, recordID == nil {
            guard let run = try loadRuns(folder).first(where: { $0.id == runID }) else {
                throw StorageError.invalidIdentifier
            }
            summaries = try listRecordSummaries(folder).filter {
                $0.complete && $0.metadata["host_run_id"] == runID.uuidString
            }
            guard summaries.count >= run.completed else { throw StorageError.corruptRecord(runID.uuidString) }
            acknowledged = Set(try acknowledgedRecords(runID: runID, in: folder).map(\.id))
            if run.phase != "completed" { state = "interrupted" }
            else if let target = run.durationSeconds, run.elapsedActiveSeconds < target { state = "stopped_early" }
            else { state = "completed" }
            requestedSeconds = run.durationSeconds
            elapsedSeconds = run.elapsedActiveSeconds
        } else if let recordID, runID == nil {
            summaries = try listRecordSummaries(folder).filter { $0.complete && $0.id == recordID }
            state = "saved_window"
            requestedSeconds = nil
            elapsedSeconds = nil
            acknowledged = []
        } else {
            throw StorageError.invalidIdentifier
        }
        guard !summaries.isEmpty else { throw StorageError.noData }
        let directory = try projectExportsDirectory(in: folder, create: true)
        let destination = directory.appendingPathComponent(request.filename, isDirectory: false)
        let writer = try SessionCSVWriter(destination)
        defer { writer.discardPartial() }
        try writer.append("format_version,filename,description,project_id,run_id,run_status,requested_run_seconds,elapsed_run_seconds,window_index,window_id,window_ack_status,window_host_utc,pico_boot_id,window_start_device_us,window_end_device_us,gap_before_window_us,nominal_sample_hz,sample_index,nominal_sample_offset_us,raw_word,adc_code,adc_error\r\n")
        let dateFormat = ISO8601DateFormatter()
        dateFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (windowIndex, summary) in summaries.enumerated() {
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            let record = try loadRecord(summary, in: folder)
            guard !record.samples.isEmpty else { throw StorageError.corruptRecord(record.id) }
            let metadata = record.metadata
            let sampleHz = metadata["sample_hz"].flatMap(UInt64.init).flatMap { (1...1_000_000).contains($0) ? $0 : nil }
            let ackStatus = runID == nil ? "" : (acknowledged.contains(record.id) ? "confirmed" : "unconfirmed")
            let windowFields = [
                record.id, ackStatus, dateFormat.string(from: record.capturedAt), Self.csv(metadata["boot_id"] ?? ""),
                metadata["start_us"].flatMap(UInt64.init).map(String.init) ?? "",
                metadata["end_us"].flatMap(UInt64.init).map(String.init) ?? "",
                metadata["gap_before_us"].flatMap(UInt64.init).map(String.init) ?? "",
                sampleHz.map(String.init) ?? ""
            ].joined(separator: ",")
            let firstRow = [
                "1", Self.csv(request.filename), Self.csv(request.description),
                projectID.uuidString, runID?.uuidString ?? "", state,
                requestedSeconds.map { String($0) } ?? "", elapsedSeconds.map { String($0) } ?? ""
            ].joined(separator: ",")
            for (index, word) in record.samples.enumerated() {
                if index % 512 == 0, cancelled() { throw CocoaError(.userCancelled) }
                let offset = sampleHz.map { frequency -> String in
                    let numerator = UInt64(index) * 1_000_000
                    if numerator.isMultiple(of: frequency) { return String(numerator / frequency) }
                    return String(Double(numerator) / Double(frequency))
                } ?? ""
                let runFields = index == 0 && windowIndex == 0 ? firstRow : ",,,,,,,"
                let fields = index == 0 ? windowFields : ",,,,,,,"
                try writer.append("\(runFields),\(windowIndex),\(fields),\(index),\(offset),\(word),\(word & 0x0fff),\((word >> 15) & 1)\r\n")
            }
        }
        guard !cancelled() else { throw CocoaError(.userCancelled) }
        try writer.finish()
        try Self.syncDirectory(directory)
        return destination
    }

    /// Writes an explicitly selected export without changing original session data.
    /// A failed or cancelled export retains a marked partial directory.
    func exportData(recordIDs: [String], run: RunArchive? = nil, options: ExportOptions,
                    in folder: URL, to destination: URL, approvedProjectFolder: URL? = nil,
                    selectedRecords: [CaptureRecord]? = nil,
                    cancelled: () -> Bool = { false }) throws {
        let session = try openSession(folder)
        try Self.requireSafeDirectory(folder)
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        if options.destination == .session {
            let exports = folder.appendingPathComponent("Exports", isDirectory: true).standardizedFileURL
            guard parent.path == folder.standardizedFileURL.path || parent.path == exports.path else { throw StorageError.unsafeLocation }
        } else {
            guard let project = approvedProjectFolder,
                  project.lastPathComponent == "Signal Bench",
                  fm.fileExists(atPath: project.appendingPathComponent("Signal Bench.xcodeproj").path),
                  parent.path == project.standardizedFileURL.path else { throw StorageError.unsafeLocation }
        }
        try Self.requireSafeDirectory(parent)
        guard destination.lastPathComponent == URL(fileURLWithPath: destination.lastPathComponent).lastPathComponent,
              !destination.lastPathComponent.hasPrefix("."),
              !["records", "runs", "analyses", "Signal Bench Data", "Signal Bench.xcodeproj"].contains(destination.lastPathComponent) else { throw StorageError.unsafeLocation }
        var state = stat()
        guard lstat(destination.path, &state) != 0, errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
        guard recordIDs.count <= 100_000 else { throw StorageError.fileTooLarge }
        let all = try listRecordSummaries(folder)
        let selection: [CaptureRecord]
        switch options.scope {
        case .session:
            selection = all
        case .run:
            guard let run else { throw StorageError.invalidSession }
            try Self.validateRun(run, sessionID: session.id)
            selection = all.filter { $0.metadata["host_run_id"] == run.id.uuidString }
        case .record:
            guard !recordIDs.isEmpty else { throw StorageError.noData }
            let requested = Set(recordIDs)
            guard requested.isSubset(of: Set(all.map(\.id))) else { throw StorageError.invalidIdentifier }
            if let exact = selectedRecords {
                guard exact.count <= 100_000, exact.allSatisfy({ requested.contains($0.id) }) else { throw StorageError.invalidIdentifier }
                selection = try exact.map { wanted in
                    for summary in all where summary.id == wanted.id && summary.complete == wanted.complete {
                        if let actual = try? loadRecord(summary, in: folder), Self.sameRecord(actual, wanted) { return summary }
                    }
                    throw StorageError.corruptRecord(wanted.id)
                }
            } else {
                // IDs alone prefer the complete record; an exact recovery copy is
                // selected by passing the inspected CaptureRecord explicitly.
                selection = requested.sorted().compactMap { id in
                    all.last(where: { $0.id == id && $0.complete }) ?? all.last(where: { $0.id == id })
                }
            }
        }
        let records = selection.filter { options.includeIncomplete || $0.complete }
        guard !records.isEmpty else { throw StorageError.noData }
        let partial = parent.appendingPathComponent(".partial-export-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(partial.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try Self.exclusiveJSON(Data("{\"schema\":1,\"complete\":false}\n".utf8), destination: partial.appendingPathComponent("export-state.json"))
        try Self.syncDirectory(parent)
        let summary = try SessionCSVWriter(partial.appendingPathComponent("summary.json"))
        let optionsJSON = String(decoding: try Self.encoder.encode(options), as: UTF8.self)
        try summary.append("{\"schema\":1,\"scope\":\(Self.jsonString(options.scope.rawValue)),\"session_id\":\(Self.jsonString(session.id.uuidString)),\"run_id\":\(run.map { Self.jsonString($0.id.uuidString) } ?? "null"),\"exported_at\":\(Self.jsonString(ISO8601DateFormatter().string(from: Date()))),\"options\":\(optionsJSON),\"rate_exposure_valid\":false,\"timing\":\"Nominal sample timing; finite captures include gaps and processing exclusions\",\"measurement_limits\":\"Candidates may be noise or interference. Raw observations are unqualified. No calibrated energy, radiation response, dose or count rate is established.\",\"records\":[\n")
        let quality = options.qualityCSV ? try SessionCSVWriter(partial.appendingPathComponent("quality.csv")) : nil
        let candidates = options.candidatesCSV ? try SessionCSVWriter(partial.appendingPathComponent("candidates.csv")) : nil
        try quality?.append("record_id,captured_at,tag,workspace,run_id,complete,observation_only,qualified_window,channel,source,profile,calibration_record_id,sample_count,sample_hz,baseline_codes,noise_codes,threshold_codes,acquisition_flags,quality_flags,adc_errors,clipped_samples,candidates,qualified_pulses,gap_before_us,availability_error\n")
        try candidates?.append("record_id,captured_at,tag,profile,complete,observation_only,candidate_index,start_sample,peak_sample,end_sample,amplitude_codes,signed_amplitude_codes,flags,qualified,details_json\n")
        let metadataDirectory = options.metadataJSON ? try Self.createLocalDirectory("metadata", under: partial) : nil
        let rawDirectory = (options.rawCSV || options.rawBinary) ? try Self.createLocalDirectory("raw", under: partial) : nil
        let analysisDirectory = options.savedAnalyses ? try Self.createLocalDirectory("analyses", under: partial) : nil
        var calibrationIDs = Set<String>()
        if options.calibrationsJSON, let run { calibrationIDs.formUnion(run.calibrationRecordIDs) }
        var unavailable = 0
        for (index, recordSummary) in records.enumerated() {
            if cancelled() { throw CocoaError(.userCancelled) }
            guard try openSession(folder).id == session.id else { throw StorageError.invalidSession }
            let record: CaptureRecord
            let readIssue: String?
            do { record = try loadRecord(recordSummary, in: folder); readIssue = nil }
            catch {
                unavailable += 1
                record = CaptureRecord(id: recordSummary.id, capturedAt: recordSummary.capturedAt,
                                       metadata: recordSummary.metadata, events: [], samples: [], complete: false)
                readIssue = error.localizedDescription
            }
            if let calibration = record.metadata["calibration_record_id"], CaptureIntent.validToken(calibration) { calibrationIDs.insert(calibration) }
            if record.metadata["tag"] == "CAL", CaptureIntent.validToken(record.id) { calibrationIDs.insert(record.id) }
            let observed = record.metadata["observation_only"] == "1" || record.metadata["host_observation_only"] == "1"
            let qualified = readIssue == nil && record.complete && !observed && record.metadata["calibrated"] == "1" &&
                record.metadata["usable"] == "1" && record.metadata["acq_flags"] == "0" && record.metadata["quality_flags"] == "0"
            let item = ExportRecordSummary(record: record, source: recordSummary, observationOnly: observed,
                                           qualified: qualified, availabilityError: readIssue)
            if index > 0 { try summary.append(",\n") }
            try summary.append(String(decoding: try Self.encoder.encode(item), as: UTF8.self))
            let fields = [record.id, ISO8601DateFormatter().string(from: record.capturedAt), record.metadata["tag"] ?? "", record.metadata["host_workspace"] ?? "", record.metadata["host_run_id"] ?? "", String(record.complete), String(observed), String(qualified), record.metadata["channel"] ?? "ADC0",
                          record.metadata["probe_source"] ?? "ADC0", record.metadata["profile"] ?? record.metadata["host_processing_profile"] ?? "POSITIVE",
                          record.metadata["calibration_record_id"] ?? "", String(readIssue == nil ? record.samples.count : 0), record.metadata["sample_hz"] ?? "",
                          record.metadata["baseline"] ?? "", record.metadata["sigma"] ?? "", record.metadata["threshold"] ?? "",
                          record.metadata["acq_flags"] ?? "", record.metadata["quality_flags"] ?? "", record.metadata["adc_errors"] ?? "",
                          record.metadata["clipped_samples"] ?? "", record.metadata["candidates"] ?? "0", String(item.qualifiedPulses),
                          record.metadata["gap_before_us"] ?? "", readIssue ?? ""]
            try quality?.append(fields.map(Self.csv).joined(separator: ",") + "\n")
            guard readIssue == nil else { continue }
            for (eventIndex, event) in record.events.enumerated() {
                let delta = Double(event["delta_codes"] ?? "")
                let direction = (record.metadata["profile"] ?? "POSITIVE") == "NEGATIVE" ? -1.0 : 1.0
                let details = String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
                let values = [record.id, ISO8601DateFormatter().string(from: record.capturedAt), record.metadata["tag"] ?? "", record.metadata["profile"] ?? "POSITIVE", String(record.complete), String(observed), String(eventIndex), event["start"] ?? "", event["peak"] ?? "", event["end"] ?? "",
                              event["delta_codes"] ?? "", delta.map { String($0 * direction) } ?? "", event["flags"] ?? "",
                              String(qualified && event["qualified"] == "1"), details]
                var encoded = values.map(Self.csv)
                if let delta, delta.isFinite {
                    encoded[10] = String(delta)
                    encoded[11] = String(delta * direction)
                }
                try candidates?.append(encoded.joined(separator: ",") + "\n")
            }
            let stem = String(format: "%06d", index) + "-" + record.id
            if let metadataDirectory {
                let metadata = ExportMetadata(schema: 1, recordID: record.id, capturedAt: record.capturedAt,
                                              complete: record.complete, sampleCount: record.samples.count, metadata: record.metadata)
                try Self.exclusiveJSON(try Self.encoder.encode(metadata), destination: metadataDirectory.appendingPathComponent(stem + ".json"))
            }
            if let rawDirectory {
                if options.rawCSV { try Self.exportRawCSV(record, to: rawDirectory.appendingPathComponent(stem + ".csv"), cancelled: cancelled) }
                if options.rawBinary {
                    let bytes = Data(record.samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
                    try Self.exclusiveJSON(bytes, destination: rawDirectory.appendingPathComponent(stem + ".bin"))
                }
            }
            if let analysisDirectory, record.complete {
                for (analysisIndex, data) in try readAnalyses(recordID: record.id, in: folder).enumerated() {
                    if cancelled() { throw CocoaError(.userCancelled) }
                    try Self.exclusiveJSON(data, destination: analysisDirectory.appendingPathComponent(stem + "-\(analysisIndex).json"))
                }
            }
        }
        try summary.append("\n],\"selected_records\":\(records.count),\"unavailable_records\":\(unavailable)}\n")
        try summary.finish(); try candidates?.finish(); try quality?.finish()
        if options.metadataJSON {
            try Self.exclusiveJSON(try Self.encoder.encode(session), destination: partial.appendingPathComponent("session.json"))
            if let run { try Self.exclusiveJSON(try Self.encoder.encode(run), destination: partial.appendingPathComponent("run.json")) }
        }
        if options.calibrationsJSON {
            let calibrations = try SessionCSVWriter(partial.appendingPathComponent("calibrations.json"))
            try calibrations.append("[\n")
            for (index, id) in calibrationIDs.sorted().enumerated() {
                if cancelled() { throw CocoaError(.userCancelled) }
                let calibration = try loadRecord(id, in: folder)
                guard calibration.metadata["tag"] == "CAL" else { throw StorageError.corruptRecord(id) }
                if index > 0 { try calibrations.append(",\n") }
                try calibrations.append(String(decoding: try Self.encoder.encode(calibration), as: UTF8.self))
            }
            try calibrations.append("\n]\n"); try calibrations.finish()
        }
        if cancelled() { throw CocoaError(.userCancelled) }
        guard try openSession(folder).id == session.id else { throw StorageError.invalidSession }
        try Self.syncDirectory(partial)
        guard renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try Self.syncDirectory(parent)
        try Self.atomicJSON(Data("{\"schema\":1,\"complete\":true}\n".utf8), destination: destination.appendingPathComponent("export-state.json"))
        try Self.syncDirectory(destination)
        try Self.syncDirectory(parent)
    }

    private static func sameRecord(_ lhs: CaptureRecord, _ rhs: CaptureRecord) -> Bool {
        lhs.id == rhs.id && ISO8601DateFormatter().string(from: lhs.capturedAt) == ISO8601DateFormatter().string(from: rhs.capturedAt) && lhs.complete == rhs.complete &&
            lhs.metadata == rhs.metadata && lhs.events == rhs.events && lhs.samples == rhs.samples
    }

    private static func jsonString(_ value: String) -> String {
        let encoded = try! JSONEncoder().encode(value)
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func exportRawCSV(_ record: CaptureRecord, to destination: URL, cancelled: () -> Bool) throws {
        let writer = try SessionCSVWriter(destination)
        try writer.append("sample_index,raw_word,adc_code,adc_error\n")
        for (index, word) in record.samples.enumerated() {
            if index % 512 == 0, cancelled() { throw CocoaError(.userCancelled) }
            try writer.append("\(index),\(word),\(word & 0x0fff),\((word >> 15) & 1)\n")
        }
        try writer.finish()
    }
}

private nonisolated struct ExportMetadata: Codable {
    let schema: Int
    let recordID: String
    let capturedAt: Date
    let complete: Bool
    let sampleCount: Int
    let metadata: [String: String]
}

private nonisolated struct ExportRecordSummary: Codable {
    let recordID: String
    let recordDirectory: String?
    let capturedAt: Date
    let complete: Bool
    let observationOnly: Bool
    let qualified: Bool
    let tag: String?
    let workspace: String?
    let runID: String?
    let channel: String
    let profile: String
    let gain: String?
    let physicalGainConfirmed: Bool?
    let sampleCount: Int
    let sampleSHA256: String?
    let nominalSampleHz: String?
    let calibrationRecordID: String?
    let baselineCodes: String?
    let noiseCodes: String?
    let thresholdCodes: String?
    let thresholdOrigin: String
    let acquisitionFlags: String?
    let qualityFlags: String?
    let candidates: Int
    let qualifiedPulses: Int
    let availabilityError: String?

    init(record: CaptureRecord, source: CaptureRecord, observationOnly: Bool, qualified: Bool, availabilityError: String?) {
        self.recordID = record.id; self.recordDirectory = source.metadata["host_record_directory"]
        self.capturedAt = record.capturedAt; self.complete = record.complete; self.observationOnly = observationOnly
        self.tag = record.metadata["tag"]; self.workspace = record.metadata["host_workspace"]; self.runID = record.metadata["host_run_id"]
        self.qualified = qualified; self.channel = record.metadata["channel"] ?? "ADC0"
        self.profile = record.metadata["profile"] ?? record.metadata["host_processing_profile"] ?? "POSITIVE"
        self.gain = record.metadata["gain"]
        let confirmation = record.metadata["host_gain_confirmed"] ?? record.metadata["gain_confirmed"]
        self.physicalGainConfirmed = confirmation == "1" ? true : confirmation == "0" ? false : nil
        self.sampleCount = record.samples.count
        self.sampleSHA256 = availabilityError == nil ? SHA256.hash(data: Data(record.samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })).map { String(format: "%02x", $0) }.joined() : nil
        self.nominalSampleHz = record.metadata["sample_hz"]; self.calibrationRecordID = record.metadata["calibration_record_id"]
        self.baselineCodes = record.metadata["baseline"]; self.noiseCodes = record.metadata["sigma"]
        self.thresholdCodes = record.metadata["threshold"]
        self.thresholdOrigin = record.metadata["threshold_origin"] ?? ((observationOnly || record.metadata["tag"] == "CAL" || record.metadata["calibrated"] != "1") ? "record_noise" : "calibration")
        self.acquisitionFlags = record.metadata["acq_flags"]; self.qualityFlags = record.metadata["quality_flags"]
        self.candidates = max(0, Int(record.metadata["candidates"] ?? "") ?? 0)
        self.qualifiedPulses = qualified ? record.events.filter { $0["qualified"] == "1" }.count : 0
        self.availabilityError = availabilityError
    }
}

nonisolated extension SessionStore {
    private func profileFolder(_ name: String, project: UUID, in folder: URL, create: Bool) throws -> URL? {
        guard try openSession(folder).id == project else { throw StorageError.invalidSession }
        var current = folder
        for component in ["calibrations", name] {
            if create {
                current = try Self.createLocalDirectory(component, under: current)
            } else {
                current = current.appendingPathComponent(component, isDirectory: true)
                var info = stat()
                if lstat(current.path, &info) != 0, errno == ENOENT { return nil }
                try Self.requireSafeDirectory(current)
            }
        }
        return current
    }

    func profileLibrary(in folder: URL, project: UUID) throws -> ([CalibrationAttempt], [CalibrationProfile]) {
        func items<T: Decodable>(_ folderName: String, type: T.Type) throws -> [T] {
            guard let location = try profileFolder(folderName, project: project, in: folder, create: false) else { return [] }
            let files = try fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            guard files.count <= 10_000 else { throw StorageError.fileTooLarge }
            return try files.map { try Self.decoder.decode(type, from: Self.readBounded($0, limit: Self.maxJSONBytes)) }
        }
        let attempts = try items("attempts", type: CalibrationAttempt.self)
        let profiles = try items("profiles", type: CalibrationProfile.self)
        guard attempts.allSatisfy(\.valid), profiles.allSatisfy(\.valid),
              Set(attempts.map(\.id)).count == attempts.count,
              Set(profiles.map(\.id)).count == profiles.count else { throw StorageError.invalidSession }
        return (attempts.sorted { ($0.name, $0.revision) < ($1.name, $1.revision) },
                profiles.sorted { ($0.name, $0.revision) < ($1.name, $1.revision) })
    }

    func saveCalibrationAttempt(_ attempt: CalibrationAttempt, in folder: URL, project: UUID) throws {
        guard attempt.valid, let location = try profileFolder("attempts", project: project, in: folder, create: true) else {
            throw StorageError.invalidSession
        }
        let path = location.appendingPathComponent(attempt.id.uuidString + ".json")
        if fm.fileExists(atPath: path.path) {
            let previous = try Self.decoder.decode(CalibrationAttempt.self, from: Self.readBounded(path, limit: Self.maxJSONBytes))
            var permitted = attempt
            permitted.resultID = previous.resultID
            guard previous.id == attempt.id, previous.setup == attempt.setup, previous.profileID == attempt.profileID,
                  previous.preset == attempt.preset, previous.revision == attempt.revision,
                  !previous.locked || (previous == permitted && (previous.resultID == nil || previous.resultID == attempt.resultID))
            else { throw ProfileWorkflowError.staleProfile }
        }
        try Self.atomicJSON(Self.encoder.encode(attempt), destination: path)
    }

    func saveCalibrationProfile(_ profile: CalibrationProfile, in folder: URL, project: UUID) throws {
        guard profile.valid, let location = try profileFolder("profiles", project: project, in: folder, create: true) else {
            throw StorageError.invalidSession
        }
        let path = location.appendingPathComponent(profile.id.uuidString + ".json")
        if fm.fileExists(atPath: path.path) {
            let previous = try Self.decoder.decode(CalibrationProfile.self, from: Self.readBounded(path, limit: Self.maxJSONBytes))
            guard previous == profile else { throw ProfileWorkflowError.staleProfile }
            return
        }
        try Self.exclusiveJSON(Self.encoder.encode(profile), destination: path)
        try Self.syncDirectory(location)
    }

    static func readCalibrationSetup(_ url: URL) throws -> CalibrationSetupDocument {
        guard url.isFileURL, url.pathExtension.lowercased() == "sigb" else { throw ProfileWorkflowError.invalidSetupFile }
        return try decoder.decode(CalibrationSetupDocument.self, from: readBounded(url, limit: CalibrationSetupDocument.byteLimit)).checked()
    }

    static func calibrationSetupDocument(_ source: CalibrationProfile) throws -> CalibrationSetupDocument {
        var portable = source
        portable.setup.notes = ""
        portable.origin = "local"
        portable.locallyVerifiedElectrical = nil
        portable.sourceDigest = nil
        return try CalibrationSetupDocument(profile: portable).checked()
    }

    func importCalibrationSetup(_ document: CalibrationSetupDocument, in folder: URL, project: UUID) throws -> CalibrationProfile {
        var profile = try document.checked().profile
        let existing = try profileLibrary(in: folder, project: project).1
        profile.origin = "imported"
        let sourceDigest = ProfileAnalyzer.hash(try Self.encoder.encode(document))
        if let existingCopy = existing.first(where: { $0.sourceDigest == sourceDigest }) { return existingCopy }
        // Match content irrespective of the local evidence attribution label.
        if let match = existing.first(where: { candidate in
            var comparable = candidate
            comparable.origin = "imported"
            comparable.setup.notes = ""
            comparable.locallyVerifiedElectrical = nil
            comparable.sourceDigest = nil
            return comparable == profile
        }) { return match }
        if existing.contains(where: { $0.id == profile.id || ($0.profileID == profile.profileID && $0.revision == profile.revision) }) {
            profile.id = UUID()
            profile.profileID = UUID()
            profile.name = String(profile.name.prefix(18)) + " (imported)"
        }
        profile.sourceDigest = sourceDigest
        try saveCalibrationProfile(profile, in: folder, project: project)
        return profile
    }

    func exportCalibrationSetup(_ document: CalibrationSetupDocument, filename: String, in folder: URL, project: UUID) throws -> URL {
        guard try openSession(folder).id == project else { throw StorageError.invalidSession }
        let name = try Self.projectName(filename)
        let target = try projectExportsDirectory(in: folder, create: true)
            .appendingPathComponent(name.lowercased().hasSuffix(".sigb") ? name : name + ".sigb")
        let body = try Self.encoder.encode(document.checked())
        guard body.count <= CalibrationSetupDocument.byteLimit else { throw StorageError.fileTooLarge }
        let writer = try SessionCSVWriter(target)
        defer { writer.discardPartial() }
        try writer.append(String(decoding: body, as: UTF8.self))
        try writer.finish()
        try Self.syncDirectory(target.deletingLastPathComponent())
        return target
    }

    private func profileReceipts(_ run: RunArchive, summaries: [CaptureRecord], in folder: URL) throws -> [(CaptureRecord, String)] {
        let receipts = try acknowledgedRecords(runID: run.id, in: folder)
        let byID = Dictionary(uniqueKeysWithValues: summaries.filter {
            $0.complete && $0.metadata["host_run_id"] == run.id.uuidString
        }.map { ($0.id, $0) })
        return try receipts.map { receipt in
            guard let summary = byID[receipt.id], Self.profileTime(summary) >= 0,
                  let segment = run.profileSegments?.first(where: { $0.id.uuidString == summary.metadata["host_profile_segment"] }),
                  segment.boot == summary.metadata["boot_id"],
                  summary.metadata["host_profile_purpose"] == run.profileAcquisition?.purpose.rawValue,
                  summary.metadata["host_profile_owner"] == run.profileAcquisition?.owner.uuidString
            else { throw ProfileWorkflowError.invalidEvidence }
            return (summary, receipt.sampleSHA256)
        }.sorted { (Self.profileTime($0.0), $0.0.id) < (Self.profileTime($1.0), $1.0.id) }
    }

    private static func profileTime(_ record: CaptureRecord) -> Double {
        let value = record.metadata["host_profile_elapsed"].flatMap(Double.init) ?? -1
        return (0...90_000).contains(value) ? value : -1
    }

    private func evaluateProfileRecord(_ summary: CaptureRecord, sha: String, in folder: URL,
                                       rules: ProfilePulseRules, limits: ProfileLimits?, envelope: ProfileEnvelope?,
                                       exclusions: [ProfileManualExclusion] = [], spectrum: Bool = false) throws -> ProfileWindowResult {
        let raw = try loadRecord(summary, in: folder)
        let elapsed = Self.profileTime(raw)
        guard elapsed >= 0 else { throw ProfileWorkflowError.invalidEvidence }
        let result = try ProfileAnalyzer.evaluate(raw, rules: rules, limits: limits, envelope: envelope,
                                                  elapsed: elapsed, exclusions: exclusions, spectrum: spectrum)
        guard result.sampleHash == sha else { throw ProfileWorkflowError.invalidEvidence }
        return result
    }

    func trainingRecordIDs(_ attempt: CalibrationAttempt, in folder: URL) throws -> [String] {
        let summaries = try listRecordSummaries(folder)
        let boundary = Double(attempt.preset.seconds * 2 / 3)
        return try loadRuns(folder).filter { $0.profileAcquisition?.owner == attempt.id }.flatMap {
            try profileReceipts($0, summaries: summaries, in: folder).map(\.0)
                .filter { (0..<boundary).contains(Self.profileTime($0)) }.map(\.id)
        }
    }

    func fitCalibration(_ attempt: CalibrationAttempt, in folder: URL, project: UUID) throws -> ProfileEvaluation {
        let library = try profileLibrary(in: folder, project: project)
        guard attempt.locked, attempt.limits.valid, library.0.contains(attempt) else {
            throw ProfileWorkflowError.validationNotLocked
        }
        let runs = try loadRuns(folder).filter { $0.profileAcquisition?.owner == attempt.id && $0.profileAcquisition?.purpose == .calibrationPhase }
        let summaries = try listRecordSummaries(folder)
        let boundary = Double(attempt.preset.seconds * 2 / 3)
        var byPhase: [CalibrationPhase: [(CaptureRecord, String)]] = [:]
        var elapsed: [CalibrationPhase: Double] = [:]
        var missing: [CalibrationPhase: Int] = [:]
        for run in runs {
            guard let acquisition = run.profileAcquisition, let phase = acquisition.phase, acquisition.setup == attempt.setup else {
                throw ProfileWorkflowError.invalidEvidence
            }
            let receipts = try profileReceipts(run, summaries: summaries, in: folder)
            byPhase[phase, default: []] += receipts
            elapsed[phase] = max(elapsed[phase] ?? 0, acquisition.offsetSeconds + run.elapsedActiveSeconds)
            missing[phase, default: 0] += max(0, run.completed - receipts.count)
                + summaries.count { $0.metadata["host_run_id"] == run.id.uuidString && !$0.complete }
        }
        // Only the chronological training portion defines the local envelope.
        var fitted: [CalibrationPhase: ProfileEnvelope] = [:]
        let tolerance = attempt.limits.baselineTolerance
        for phase in [CalibrationPhase.empty, .dark] {
            let training = try (byPhase[phase] ?? []).filter { (0..<boundary).contains(Self.profileTime($0.0)) }.compactMap {
                let result = try evaluateProfileRecord($0.0, sha: $0.1, in: folder, rules: attempt.rules, limits: attempt.limits, envelope: nil)
                return result.usableSeconds > 0 ? result.baseline : nil
            }
            fitted[phase] = .init(baselineLow: max(0, (training.min() ?? 0) - tolerance),
                                  baselineHigh: min(4095, (training.max() ?? 4095) + tolerance))
        }
        let envelope = fitted[.dark]!

        var phases: [ProfilePhaseSummary] = []
        var allBlocks: [CalibrationPhase: [ProfileBlock]] = [:]
        for phase in attempt.phases {
            let refs = byPhase[phase] ?? []
            let duration = elapsed[phase] ?? 0
            let metrics = try refs.map {
                try ProfileWindowMetric(evaluateProfileRecord($0.0, sha: $0.1, in: folder, rules: attempt.rules,
                                                              limits: attempt.limits, envelope: fitted[phase == .repeatEmpty ? .empty : phase],
                                                              spectrum: true))
            }
            let fit = metrics.filter { $0.elapsed < boundary }
            let holdout = metrics.filter { $0.elapsed >= boundary }
            let fitDuration = min(duration, boundary)
            let holdoutDuration = max(0, duration - boundary)
            let fitCoverage = ProfileWindowMetric.coverage(fit, elapsed: fitDuration)
            let holdoutCoverage = ProfileWindowMetric.coverage(holdout, elapsed: holdoutDuration, missing: missing[phase] ?? 0)
            let blocks = ProfileWindowMetric.blocks(metrics)
            var issues: [String] = []
            if duration < Double(attempt.preset.seconds) || fitCoverage.usableWindows < attempt.limits.minimumFitWindows
                || holdoutCoverage.usableWindows < attempt.limits.minimumHoldoutWindows {
                issues.append("More usable fit or holdout data required")
            }
            if !Self.profileBlocksCovered(blocks, elapsed: duration, limits: attempt.limits) {
                issues.append("One or more elapsed minute blocks lack usable coverage")
            }
            if fitCoverage.outside > 0 || holdoutCoverage.outside > 0 { issues.append("Noise, drift, headroom or baseline limits exceeded") }
            if (missing[phase] ?? 0) > 0 { issues.append("Some raw windows were not verified and acknowledged") }
            if phase != .dark && blocks.contains(where: { $0.coverage.matches > attempt.limits.maximumEmptyMatchesPerBlock }) {
                issues.append("Electronics-only matches exceed the locked limit")
            }
            if phase == .repeatEmpty, let darkBoot = byPhase[.dark]?.last?.0.metadata["boot_id"],
               metrics.isEmpty || metrics.contains(where: { $0.boot == darkBoot }) {
                issues.append("A new Pico boot was not verified for the repeat")
            }
            allBlocks[phase] = blocks
            let evidence = Data(refs.sorted { $0.0.id < $1.0.id }.map { $0.1 }.joined(separator: "\n").utf8)
            phases.append(.init(phase: phase, fit: fitCoverage, holdout: holdoutCoverage,
                                fitBaselineMedian: ProfileAnalyzer.median(fit.compactMap(\.baseline)),
                                fitNoiseMedian: ProfileAnalyzer.median(fit.compactMap(\.noise)),
                                holdoutBaselineMedian: ProfileAnalyzer.median(holdout.compactMap(\.baseline)),
                                holdoutNoiseMedian: ProfileAnalyzer.median(holdout.compactMap(\.noise)),
                                evidenceSHA256: ProfileAnalyzer.hash(evidence), issues: issues))
        }
        let profile = CalibrationProfile(profileID: attempt.profileID, id: attempt.resultID ?? attempt.id,
                                         revision: attempt.revision, name: attempt.name, preset: attempt.preset, setup: attempt.setup,
                                         rules: attempt.rules, limits: attempt.limits, envelope: envelope, phases: phases)
        return ProfileEvaluation(profile: profile, blocks: allBlocks)
    }

    static func profileBlocksCovered(_ blocks: [ProfileBlock], elapsed: Double, limits: ProfileLimits) -> Bool {
        guard elapsed.isFinite, elapsed >= 1 else { return false }
        // A finite capture can finish just after the requested minute. A
        // deadline tail shorter than five seconds is not a separate block.
        let fullMinutes = Int(elapsed / 60)
        let remainder = elapsed - Double(fullMinutes * 60)
        let count = max(1, fullMinutes + (remainder >= 5 ? 1 : 0))
        return (0..<count).allSatisfy { minute in
            let seconds = min(60, elapsed - Double(minute * 60))
            let usable = blocks.filter { $0.minute == minute }.reduce(0) { $0 + $1.coverage.usable }
            return usable + 0.000_001 >= limits.minimumUsableSecondsPerMinute * seconds / 60
        }
    }

    private func profileResultFolder(_ runID: UUID, revisionID: UUID, in folder: URL, create: Bool) throws -> URL {
        let run = try runDirectory(runID, in: folder, create: false)
        if create {
            let revisions = try Self.createLocalDirectory("profile-analysis", under: run)
            return try Self.createLocalDirectory(revisionID.uuidString, under: revisions)
        }
        let result = run.appendingPathComponent("profile-analysis", isDirectory: true).appendingPathComponent(revisionID.uuidString, isDirectory: true)
        try Self.requireSafeDirectory(result)
        return result
    }

    func saveProfileWindow(_ result: ProfileWindowResult, for runID: UUID, revisionID: UUID, in folder: URL) throws {
        guard CaptureIntent.validToken(result.id) else { throw StorageError.invalidIdentifier }
        let location = try profileResultFolder(runID, revisionID: revisionID, in: folder, create: true)
        try Self.atomicJSON(Self.encoder.encode(result), destination: location.appendingPathComponent(result.id + ".json"))
    }

    func profileRunReview(_ run: RunArchive, revision: ProfileAnalysisRevision? = nil, in folder: URL) throws -> ProfileRunReview {
        guard let acquisition = run.profileAcquisition, let profile = acquisition.snapshot else { throw StorageError.invalidSession }
        let refs = try profileReceipts(run, summaries: listRecordSummaries(folder), in: folder)
        let metrics = try refs.map { summary, sha in
            try ProfileWindowMetric(evaluateProfileRecord(summary, sha: sha, in: folder, rules: revision?.rules ?? profile.rules,
                                                          limits: profile.limits, envelope: acquisition.purpose == .fixture ? nil : profile.envelope,
                                                          exclusions: revision?.exclusions ?? [], spectrum: true))
        }
        return .init(coverage: ProfileWindowMetric.coverage(metrics, elapsed: run.elapsedActiveSeconds,
                                                          uncertain: ["interrupted", "paused", "running", "pausing"].contains(run.phase),
                                                          missing: max(0, run.completed - refs.count)),
                     blocks: ProfileWindowMetric.blocks(metrics), recordIDs: metrics.map(\.id))
    }

    func saveProfileAnalysisRevision(_ revision: ProfileAnalysisRevision, run: RunArchive, in folder: URL) throws -> ProfileRunReview {
        guard revision.rules.valid, revision.exclusions.count <= 256, revision.exclusions.allSatisfy(\.valid),
              let profile = run.profileAcquisition?.snapshot, revision.algorithmVersion == CalibrationProfile.algorithm else {
            throw StorageError.invalidSession
        }
        let refs = try profileReceipts(run, summaries: listRecordSummaries(folder), in: folder)
        guard !refs.isEmpty, Set(revision.exclusions.map(\.recordID)).isSubset(of: Set(refs.map { $0.0.id })) else {
            throw ProfileWorkflowError.invalidEvidence
        }
        var metrics: [ProfileWindowMetric] = []
        for (summary, sha) in refs {
            let result = try evaluateProfileRecord(summary, sha: sha, in: folder, rules: revision.rules,
                                                   limits: profile.limits, envelope: profile.envelope,
                                                   exclusions: revision.exclusions, spectrum: true)
            try saveProfileWindow(result, for: run.id, revisionID: revision.id, in: folder)
            metrics.append(ProfileWindowMetric(result))
        }
        let location = try profileResultFolder(run.id, revisionID: revision.id, in: folder, create: false)
        try Self.atomicJSON(Self.encoder.encode(revision), destination: location.appendingPathComponent("revision.json"))
        return .init(coverage: ProfileWindowMetric.coverage(metrics, elapsed: run.elapsedActiveSeconds),
                     blocks: ProfileWindowMetric.blocks(metrics), recordIDs: metrics.map(\.id))
    }

    func profileRevisions(_ run: RunArchive, in folder: URL) throws -> [ProfileAnalysisRevision] {
        let location = try runDirectory(run.id, in: folder, create: false).appendingPathComponent("profile-analysis")
        var info = stat()
        if lstat(location.path, &info) != 0, errno == ENOENT { return [] }
        try Self.requireSafeDirectory(location)
        return try fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil).compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
            try Self.requireSafeDirectory(directory)
            let path = directory.appendingPathComponent("revision.json")
            if lstat(path.path, &info) != 0, errno == ENOENT { return nil }
            let revision = try Self.decoder.decode(ProfileAnalysisRevision.self, from: Self.readBounded(path, limit: Self.maxJSONBytes))
            guard revision.id == id, revision.algorithmVersion == CalibrationProfile.algorithm,
                  revision.rules.valid, revision.exclusions.count <= 256, revision.exclusions.allSatisfy(\.valid) else {
                throw ProfileWorkflowError.invalidEvidence
            }
            return revision
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

nonisolated extension SessionStore {
    func checkProfileSetup(_ profile: CalibrationProfile, runs: [RunArchive], in folder: URL) throws -> ProfileSetupEvaluation {
        guard !runs.isEmpty, runs.allSatisfy({
            $0.profileAcquisition?.purpose == .setupCheck && $0.profileAcquisition?.snapshot == profile && $0.phase == "completed"
        }) else { throw ProfileWorkflowError.invalidEvidence }
        let summaries = try listRecordSummaries(folder)
        var metrics: [ProfileWindowMetric] = []
        var elapsed = 0.0
        var missing = 0
        for run in runs {
            let refs = try profileReceipts(run, summaries: summaries, in: folder)
            missing += max(0, run.completed - refs.count)
            elapsed = max(elapsed, (run.profileAcquisition?.offsetSeconds ?? 0) + run.elapsedActiveSeconds)
            metrics += try refs.map {
                try ProfileWindowMetric(evaluateProfileRecord($0.0, sha: $0.1, in: folder, rules: profile.rules,
                                                              limits: profile.limits, envelope: profile.envelope))
            }
        }
        let coverage = ProfileWindowMetric.coverage(metrics, elapsed: elapsed, missing: missing)
        var issues: [String] = []
        if elapsed < 120 || coverage.usableWindows < profile.limits.minimumHoldoutWindows
            || !Self.profileBlocksCovered(ProfileWindowMetric.blocks(metrics), elapsed: elapsed, limits: profile.limits) {
            issues.append("The local dark check needs more usable windows.")
        }
        if coverage.outside > 0 { issues.append("Noise, drift, headroom or baseline exceeded the profile limits.") }
        if missing > 0 { issues.append("The check has unverified capture windows.") }
        return .init(coverage: coverage, issues: issues)
    }
}

nonisolated extension SessionStore {
    func exportProfileRun(_ run: RunArchive, revision: ProfileAnalysisRevision?, options: ProfileResultsOptions,
                          name: String, in folder: URL, cancelled: @Sendable () -> Bool) throws -> URL {
        guard let acquisition = run.profileAcquisition, let profile = acquisition.snapshot,
              try openSession(folder).id == run.sessionID else { throw StorageError.invalidSession }
        let exportName = try Self.projectName(name)
        let root = try projectExportsDirectory(in: folder, create: true)
        let destination = root.appendingPathComponent(exportName, isDirectory: true)
        let staged = root.appendingPathComponent(".profile-export-" + UUID().uuidString, isDirectory: true)
        guard mkdir(staged.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        var published = false
        defer { if !published { try? fm.removeItem(at: staged) } }
        let refs = try profileReceipts(run, summaries: listRecordSummaries(folder), in: folder)
        guard !refs.isEmpty else { throw StorageError.noData }
        let cleaned = options.cleaned ? try SessionCSVWriter(staged.appendingPathComponent("cleaned.csv")) : nil
        let pulses = options.pulses ? try SessionCSVWriter(staged.appendingPathComponent("pulse-matches.csv")) : nil
        let exclusions = options.exclusions || options.cleaned ? try SessionCSVWriter(staged.appendingPathComponent("exclusions.csv")) : nil
        let quality = options.quality ? try SessionCSVWriter(staged.appendingPathComponent("quality.csv")) : nil
        try cleaned?.append("record_id,boot_id,original_index,window_start_device_us,nominal_offset_us,original_word\n")
        try pulses?.append("record_id,start_index,end_exclusive,peak_index,height_codes,max_slope_codes,decision,review\n")
        try exclusions?.append("record_id,boot_id,window_start_device_us,start_index,end_exclusive,omit_from_cleaned,reason,analysis_revision\n")
        try quality?.append("record_id,sha256,baseline,robust_noise,drift,headroom,threshold,adc_errors,clipped,firmware_flags,complete,reasons\n")
        var metrics: [ProfileWindowMetric] = []
        for (summary, sha) in refs {
            guard !cancelled() else { throw CancellationError() }
            let result = try evaluateProfileRecord(summary, sha: sha, in: folder, rules: revision?.rules ?? profile.rules,
                                                   limits: profile.limits, envelope: acquisition.purpose == .fixture ? nil : profile.envelope,
                                                   exclusions: revision?.exclusions ?? [])
            metrics.append(ProfileWindowMetric(result))
            for event in result.candidates {
                try pulses?.append("\(result.id),\(event.start),\(event.end),\(event.peak),\(event.height),\(event.maximumSlope),\(event.decision),\(event.review)\n")
            }
            for mask in result.intervals {
                try exclusions?.append("\(result.id),\(result.boot),\(result.deviceStartUS.map(String.init) ?? ""),\(mask.start),\(mask.end),\(mask.omitFromCleaned),\(Self.csv(mask.reason)),\(revision?.id ?? run.id)\n")
            }
            if let quality {
                func number(_ value: Double?) -> String { value.map { String($0) } ?? "" }
                let fields = [result.id, result.sampleHash, number(result.baseline), number(result.noise),
                              number(result.drift), number(result.headroom), number(result.threshold), String(result.adcErrors),
                              String(result.clipped), Self.csv(result.firmwareQualityFlags ?? ""), String(result.complete),
                              Self.csv(result.reasons.joined(separator: " | "))]
                try quality.append(fields.joined(separator: ",") + "\n")
            }
            if let cleaned, let start = result.deviceStartUS, result.sampleHz == ProfileAnalyzer.sampleRate {
                let raw = try loadRecord(summary, in: folder)
                var skip = [Bool](repeating: false, count: raw.samples.count)
                for range in result.intervals where range.omitFromCleaned {
                    for index in range.start..<range.end { skip[index] = true }
                }
                for (index, sample) in raw.samples.enumerated() {
                    if index.isMultiple(of: 512), cancelled() { throw CancellationError() }
                    if !skip[index] {
                        try cleaned.append("\(result.id),\(result.boot),\(index),\(start),\(10 * index),\(sample)\n")
                    }
                }
            }
        }
        for writer in [cleaned, pulses, exclusions, quality].compactMap({ $0 }) { try writer.finish() }
        let blocks = ProfileWindowMetric.blocks(metrics)
        if options.coverage {
            let writer = try SessionCSVWriter(staged.appendingPathComponent("coverage.csv"))
            try writer.append("boot_id,elapsed_minute,nominal_sampled_seconds,usable_seconds,pulse_matches,windows,outside_envelope\n")
            for item in blocks {
                try writer.append("\(item.boot),\(item.minute),\(item.coverage.sampled),\(item.coverage.usable),\(item.coverage.matches),\(item.coverage.windows),\(item.coverage.outside)\n")
            }
            try writer.finish()
        }
        struct Summary: Encodable {
            var format = 1
            var rate_exposure_valid = 0
            var run: RunArchive
            var revision: ProfileAnalysisRevision?
            var coverage: ProfileCoverage
        }
        let report = Summary(run: run, revision: revision, coverage: ProfileWindowMetric.coverage(metrics, elapsed: run.elapsedActiveSeconds,
                              uncertain: run.phase != "completed", missing: max(0, run.completed - refs.count)))
        try Self.exclusiveJSON(Self.encoder.encode(report), destination: staged.appendingPathComponent("run-summary.json"))
        try Self.syncDirectory(staged)
        guard !cancelled(), try openSession(folder).id == run.sessionID,
              try projectExportsDirectory(in: folder, create: false) == root else { throw CancellationError() }
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        published = true
        try Self.syncDirectory(root)
        return destination
    }

    func evaluateFixture(_ referenceFile: URL, run: RunArchive, profile: CalibrationProfile, in folder: URL) throws -> CalibrationProfile {
        let bytes = try Self.readBounded(referenceFile, limit: CalibrationSetupDocument.byteLimit)
        let reference = try Self.decoder.decode(FixtureReference.self, from: bytes)
        guard reference.valid, reference.gain == profile.setup.gain, reference.polarity == profile.rules.polarity,
              run.profileAcquisition?.purpose == .fixture, run.profileAcquisition?.snapshot == profile, run.phase == "completed" else {
            throw ProfileWorkflowError.invalidEvidence
        }
        let refs = try profileReceipts(run, summaries: listRecordSummaries(folder), in: folder)
        let windows = try refs.map { try evaluateProfileRecord($0.0, sha: $0.1, in: folder, rules: profile.rules,
                                                              limits: profile.limits, envelope: nil) }
        let alignments = Dictionary(uniqueKeysWithValues: reference.alignments.map { ($0.boot, $0) })
        var accepted: [FixtureReference.Pulse] = []
        var hits = 0, missed = 0, gaps = 0, uncertain = 0, excludedChecks = 0
        var used = Set<String>()
        for pulse in reference.pulses {
            try Task.checkCancellation()
            guard let alignment = alignments[pulse.boot], let time = alignment.picoTime(pulse.scopePeakUS) else { uncertain += 1; continue }
            let segment = windows.filter { $0.boot == pulse.boot && $0.sampleHz == ProfileAnalyzer.sampleRate }
            let earliest = segment.compactMap(\.deviceStartUS).min().map(Double.init)
            let latest = segment.compactMap { item in item.deviceStartUS.map { Double($0) + item.sampledSeconds * 1e6 } }.max()
            guard let earliest, let latest, (earliest..<latest).contains(time) else { uncertain += 1; continue }
            guard let window = segment.first(where: {
                guard $0.boot == pulse.boot, let start = $0.deviceStartUS, $0.sampleHz == ProfileAnalyzer.sampleRate else { return false }
                return time >= Double(start) && time < Double(start) + $0.sampledSeconds * 1e6
            }), let start = window.deviceStartUS else { gaps += 1; continue }
            let center = Int(((time - Double(start)) / 10).rounded())
            let tolerance = Int(ceil(alignment.uncertaintyUS / 10)) + 1
            let widthRadius = (pulse.widthSamples + 1) / 2
            let lower = center - tolerance - widthRadius
            let upper = center + tolerance + widthRadius + 1
            guard window.complete, lower >= 0, upper <= window.samples,
                  !window.intervals.contains(where: { $0.omitFromCleaned && $0.start < upper && lower < $0.end }),
                  !window.outsideEnvelope else { uncertain += 1; continue }
            let match = window.candidates.filter {
                $0.decision == "match" && abs($0.peak - center) <= tolerance
                && !used.contains("\(window.id):\($0.peak)")
            }.min(by: { abs($0.peak - center) < abs($1.peak - center) })
            if pulse.expectedMatch {
                accepted.append(pulse)
                if let match { hits += 1; used.insert("\(window.id):\(match.peak)") } else { missed += 1 }
            } else {
                excludedChecks += 1
            }
        }
        guard let minHeight = accepted.map(\.heightCodes).min(), let maxHeight = accepted.map(\.heightCodes).max(),
              let minWidth = accepted.map(\.widthSamples).min(), let maxWidth = accepted.map(\.widthSamples).max(),
              excludedChecks > 0 else { throw ProfileWorkflowError.invalidEvidence }
        let falseMatches = windows.reduce(0) { $0 + $1.matchCount } - hits
        var revised = profile
        revised.id = UUID()
        let revisions = try profileLibrary(in: folder, project: run.sessionID).1.filter { $0.profileID == profile.profileID }
        revised.revision = (revisions.map(\.revision).max() ?? profile.revision) + 1
        let evidence = ProfileAnalyzer.hash(bytes + Data(windows.map(\.sampleHash).joined(separator: "\n").utf8))
        revised.locallyVerifiedElectrical = true
        revised.electrical = .init(evidenceSHA256: evidence, gain: reference.gain, polarity: reference.polarity,
                                   minimumHeight: minHeight, maximumHeight: maxHeight, minimumWidthSamples: minWidth,
                                   maximumWidthSamples: maxWidth, hits: hits, missed: missed, inGaps: gaps, uncertain: uncertain,
                                   falseMatches: falseMatches, allowedMisses: reference.allowedMisses,
                                   allowedFalseMatches: reference.allowedFalseMatches)
        guard let location = try profileFolder("fixture", project: run.sessionID, in: folder, create: true) else {
            throw StorageError.invalidSession
        }
        try Self.exclusiveJSON(bytes, destination: location.appendingPathComponent(revised.id.uuidString + ".json"))
        try Self.syncDirectory(location)
        try saveCalibrationProfile(revised, in: folder, project: run.sessionID)
        return revised
    }
}

nonisolated extension SessionStore {
    func suggestedPulseRules(_ attempt: CalibrationAttempt, in folder: URL) throws -> ProfilePulseRules {
        guard !attempt.locked, attempt.rules.valid else { throw ProfileWorkflowError.staleProfile }
        let runs = try loadRuns(folder).filter { $0.profileAcquisition?.owner == attempt.id }
        let summaries = try listRecordSummaries(folder)
        let boundary = Double(attempt.preset.seconds * 2 / 3)
        var noise: [Double] = []
        var emptyPeaks: [Double] = []
        var emptyWindows = 0
        for run in runs {
            guard let phase = run.profileAcquisition?.phase else { continue }
            for (record, sha) in try profileReceipts(run, summaries: summaries, in: folder) where Self.profileTime(record) < boundary {
                let item = try evaluateProfileRecord(record, sha: sha, in: folder, rules: attempt.rules, limits: nil, envelope: nil)
                guard item.complete, item.usableSamples > 0 else { continue }
                if phase == .dark { if let sigma = item.noise { noise.append(sigma) } }
                else {
                    emptyWindows += 1
                    if let peak = item.candidates.filter({ $0.decision == "match" }).map(\.height).max() { emptyPeaks.append(peak) }
                }
            }
        }
        guard emptyWindows > 0, let darkNoise = ProfileAnalyzer.median(noise) else { throw ProfileWorkflowError.moreData }
        emptyPeaks.sort()
        let noiseFloor = darkNoise * (attempt.rules.threshold == .adaptive ? attempt.rules.sigmaMultiplier : 6)
        let typicalPeak = emptyPeaks.isEmpty ? 0 : emptyPeaks[max(0, Int(ceil(0.95 * Double(emptyPeaks.count))) - 1)] + 1
        var proposal = attempt.rules
        proposal.height = min(4095, ceil(max(proposal.height, noiseFloor, typicalPeak)))
        return proposal
    }
}
