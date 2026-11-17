import Darwin
import Foundation

nonisolated struct ManualCSVReport: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case recording, complete, interrupted }
    enum Reason: String, Codable, Sendable {
        case stopped, durationReached = "duration_reached", disconnected
        case storageError = "storage_error", appInterrupted = "app_interrupted"

        var completesRecording: Bool { self == .stopped || self == .durationReached }
    }

    var schema = 1
    let id: UUID
    let projectID: UUID
    let startedAt: Date
    let requestedRateHz: Int?
    var requestedDurationSeconds: Double?
    var endedAt: Date?
    var rows: UInt64 = 0
    var state: State = .recording
    var reason: Reason?

    var isIncomplete: Bool { state != .complete }
    var title: String {
        startedAt.formatted(date: .abbreviated, time: .standard) +
            (isIncomplete ? " · Incomplete" : " · \(rows.formatted()) readings")
    }
}

/// Used only on BenchModel's persistence queue. The caller bounds pending rows
/// before sending them to the queue and keeps USB commands on the main actor.
nonisolated final class ManualCSVRecording: @unchecked Sendable {
    static let durationRange = 1.0...7200.0
    private static let header = "reading_index,device_time_us,elapsed_us,adc_code,adc_error,gpio_directions_hex,gpio_levels_hex,gpio_output_latches_hex,source"
    let id: UUID
    private let folder: URL
    private let handle: FileHandle
    private var report: ManualCSVReport
    private var firstUS: UInt64?
    private var previousUS: UInt64?
    private var lastSyncUS: UInt64 = 0
    private var failed = false

    init(project: URL, projectID: UUID, rateHz: Int?, durationSeconds: Double? = nil) throws {
        guard durationSeconds.map(Self.durationRange.contains) ?? true else { throw StorageError.invalidSession }
        let root = try Self.root(in: project, projectID: projectID, create: true)
        id = UUID()
        report = ManualCSVReport(id: id, projectID: projectID, startedAt: Date(), requestedRateHz: rateHz,
                                 requestedDurationSeconds: durationSeconds)
        folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw Self.posixError() }
        let path = folder.appendingPathComponent("readings.csv").path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let error = Self.posixError()
            _ = rmdir(folder.path)
            throw error
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data((Self.header + "\n").utf8))
            try handle.synchronize()
            try saveStatus()
            try Self.syncDirectory(root)
        } catch {
            try? handle.close()
            _ = unlink(path)
            _ = unlink(folder.appendingPathComponent("recording.json").path)
            _ = rmdir(folder.path)
            throw error
        }
    }

    func append(_ sample: ManualSnapshot, fromPinChange: Bool) throws {
        guard !failed else { return }
        do {
            if firstUS == nil { firstUS = sample.timeUS; lastSyncUS = sample.timeUS }
            guard let firstUS, sample.timeUS >= (previousUS ?? firstUS) else { throw StorageError.invalidSession }
            previousUS = sample.timeUS
            let line = [
                String(report.rows), String(sample.timeUS), String(sample.timeUS - firstUS),
                sample.adc.map(String.init) ?? "", sample.adcError ? "1" : "0",
                Self.hex(sample.directions), Self.hex(sample.levels), Self.hex(sample.outputs), fromPinChange ? "pin" : "read"
            ].joined(separator: ",")
            try handle.write(contentsOf: Data((line + "\n").utf8))
            report.rows += 1
            if report.rows.isMultiple(of: 256) || sample.timeUS - lastSyncUS >= 1_000_000 {
                try handle.synchronize()
                lastSyncUS = sample.timeUS
            }
        } catch {
            failed = true
            throw error
        }
    }

    func finish(_ reason: ManualCSVReport.Reason) throws -> ManualCSVReport {
        do { try handle.synchronize() }
        catch { failed = true }
        do { try handle.close() }
        catch { failed = true }
        report.endedAt = Date()
        report.reason = failed ? .storageError : reason
        report.state = report.reason?.completesRecording == true ? .complete : .interrupted
        try saveStatus()
        return report
    }

    static func list(in project: URL, projectID: UUID) throws -> [ManualCSVReport] {
        let root = try root(in: project, projectID: projectID, create: false)
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw posixError()
        }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return directories.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent), folder.lastPathComponent == id.uuidString else { return nil }
            return try? loadReport(in: folder, projectID: projectID, id: id)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    static func export(_ id: UUID, in project: URL, projectID: UUID, cancelled: () -> Bool = { false }) throws -> URL {
        guard !cancelled() else { throw CocoaError(.userCancelled) }
        let folder = try root(in: project, projectID: projectID, create: false).appendingPathComponent(id.uuidString, isDirectory: true)
        let report = try loadReport(in: folder, projectID: projectID, id: id)
        let store = SessionStore(root: project.deletingLastPathComponent())
        let directory = try store.projectExportsDirectory(in: project, create: true)
        let suffix = report.isIncomplete ? "-incomplete" : ""
        let destination = directory.appendingPathComponent("Manual Monitor-\(id.uuidString)-\(UUID().uuidString.prefix(8))\(suffix).csv")
        let input = try openRegular(folder.appendingPathComponent("readings.csv"))
        defer { try? input.close() }
        let output = try SessionCSVWriter(destination)
        do {
            try output.append(header + ",recording_status,stop_reason\n")
            var headerRead = false
            var pending = Data()
            var rows: UInt64 = 0
            var first: UInt64?
            var previous: UInt64?
            let reason = report.reason ?? .appInterrupted
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                guard !cancelled() else { throw CocoaError(.userCancelled) }
                pending.append(data)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 10) {
                    let line = pending[start..<end]
                    guard line.count <= 200, let text = String(data: line, encoding: .ascii) else { throw StorageError.invalidSession }
                    if !headerRead {
                        guard text == header else { throw StorageError.invalidSession }
                        headerRead = true
                    } else {
                        let time = try verifyRow(text, index: rows, first: first, previous: previous)
                        if first == nil { first = time }
                        previous = time
                        try output.append(text + "," + (report.isIncomplete ? "interrupted" : "complete") + "," + reason.rawValue + "\n")
                        rows += 1
                    }
                    start = end + 1
                }
                pending.removeSubrange(..<start)
                guard pending.count <= 200 else { throw StorageError.invalidSession }
            }
            guard headerRead, report.isIncomplete || (pending.isEmpty && rows == report.rows) else { throw StorageError.invalidSession }
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            let session = try store.openSession(project)
            guard session.id == projectID else { throw StorageError.invalidSession }
            try output.finish()
            try syncDirectory(directory)
            return destination
        } catch {
            output.discardPartial()
            throw error
        }
    }

    private func saveStatus() throws {
        try Self.requireDirectory(folder)
        let status = folder.appendingPathComponent("recording.json")
        try JSONEncoder().encode(report).write(to: status, options: .atomic)
        let handle = try Self.openRegular(status)
        defer { try? handle.close() }
        try handle.synchronize()
        try Self.syncDirectory(folder)
    }

    private static func loadReport(in folder: URL, projectID: UUID, id: UUID) throws -> ManualCSVReport {
        try requireDirectory(folder)
        let handle = try openRegular(folder.appendingPathComponent("recording.json"))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw StorageError.fileTooLarge }
        var report = try JSONDecoder().decode(ManualCSVReport.self, from: data)
        guard report.schema == 1, report.id == id, report.projectID == projectID,
              report.startedAt.timeIntervalSince1970.isFinite,
              report.requestedRateHz.map({ (1...1000).contains($0) }) ?? true,
              report.requestedDurationSeconds.map(durationRange.contains) ?? true,
              (report.state == .recording) == (report.endedAt == nil && report.reason == nil),
              (report.state == .complete) == (report.reason?.completesRecording == true) else { throw StorageError.invalidSession }
        if report.state == .recording {
            report.state = .interrupted
            report.reason = .appInterrupted
        }
        return report
    }

    private static func verifyRow(_ text: String, index: UInt64, first: UInt64?, previous: UInt64?) throws -> UInt64 {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 9,
              decimal(fields[0]) == index,
              let time = decimal(fields[1]), previous.map({ time >= $0 }) ?? true,
              let elapsed = decimal(fields[2]), time - (first ?? time) == elapsed,
              (fields[4] == "1" && fields[3].isEmpty) || (fields[4] == "0" && decimal(fields[3]).map({ $0 <= 4095 }) == true),
              fields[5...7].allSatisfy({ $0.utf8.count == 8 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
              fields[8] == "read" || fields[8] == "pin" else { throw StorageError.invalidSession }
        return time
    }

    private static func decimal(_ value: Substring) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(value)
    }

    private static func hex(_ value: UInt32) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: 8 - text.count) + text
    }

    private static func root(in project: URL, projectID: UUID, create: Bool) throws -> URL {
        let session = try SessionStore(root: project.deletingLastPathComponent()).openSession(project)
        guard session.id == projectID else { throw StorageError.invalidSession }
        let root = project.appendingPathComponent("Manual Recordings", isDirectory: true)
        let created = create && mkdir(root.path, 0o700) == 0
        if create, !created, errno != EEXIST { throw posixError() }
        var info = stat()
        if lstat(root.path, &info) == 0 { try requireDirectory(root) }
        else if create || errno != ENOENT { throw posixError() }
        if created { try syncDirectory(project) }
        return root
    }

    private static func requireDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw StorageError.unsafeLocation }
    }

    private static func openRegular(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw StorageError.unsafeLocation }
        return handle
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
