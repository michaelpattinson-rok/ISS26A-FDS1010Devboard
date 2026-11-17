import Foundation
import Darwin

enum StageProbeLabel: String, CaseIterable, Codable {
    case disconnected = "Disconnected", vmid = "VMID", csa = "CSA", gain = "GAIN", shp = "SHP"
}

struct StageChannelReading: Codable {
    let timeUS: UInt64
    let adc: Int?
    let adcError: Bool
}

struct StageSnapshot: Codable {
    let sequence: UInt32
    let channels: [StageChannelReading]

    static func parse(_ line: String, expectedSequence: UInt32, after previous: StageSnapshot?) throws -> StageSnapshot {
        let fields = try StageWire.fields(line, prefix: "SB1 STAGES", limit: 384)
        guard fields.count == 10, let seqText = fields["seq"],
              let sequence = StageWire.integer(seqText).flatMap(UInt32.init(exactly:)), sequence > 0, sequence == expectedSequence else {
            throw SBProtocolError.invalid("Unexpected stage reading identity.")
        }
        var readings: [StageChannelReading] = []
        for channel in 0...2 {
            guard let code = fields["adc\(channel)"], let error = fields["err\(channel)"],
                  let time = fields["t\(channel)_us"].flatMap(StageWire.integer),
                  (error == "1" && code == "-") || (error == "0" && StageWire.integer(code).map { $0 <= 4095 } == true) else {
                throw SBProtocolError.invalid("Invalid stage ADC reading.")
            }
            if let last = readings.last, time < last.timeUS { throw SBProtocolError.invalid("Stage timestamps are out of order.") }
            readings.append(.init(timeUS: time, adc: Int(code), adcError: error == "1"))
        }
        guard previous?.channels.last.map({ readings[0].timeUS > $0.timeUS }) ?? true else {
            throw SBProtocolError.invalid("Stale stage readings or a changed device clock.")
        }
        return .init(sequence: sequence, channels: readings)
    }
}

enum StageWire {
    nonisolated static func integer(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }),
              text == "0" || !text.hasPrefix("0") else { return nil }
        return UInt64(text)
    }
    static func fields(_ line: String, prefix: String, limit: Int) throws -> [String: String] {
        guard line.utf8.count <= limit, line.utf8.allSatisfy({ (32...126).contains($0) }), line.hasPrefix(prefix + " ") else {
            throw SBProtocolError.invalid("Invalid or oversized device message.")
        }
        let words = line.dropFirst(prefix.count + 1).split(separator: " ", omittingEmptySubsequences: false)
        var fields: [String: String] = [:]
        for word in words {
            let parts = word.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, fields[String(parts[0])] == nil else {
                throw SBProtocolError.invalid("Duplicate or malformed device fields.")
            }
            fields[String(parts[0])] = String(parts[1])
        }
        return fields
    }
}

/// Slow diagnostic sweeps only. Never touches the finite capture buffer or disk.
struct StageHistory {
    private(set) var snapshots: [StageSnapshot] = []
    private(set) var totalSweeps: UInt64 = 0
    static let limit = 120
    mutating func append(_ value: StageSnapshot) {
        snapshots.append(value)
        if totalSweeps < .max { totalSweeps += 1 }
        if snapshots.count > Self.limit { snapshots.removeFirst(snapshots.count - Self.limit) }
        if let last = value.channels.last {
            snapshots.removeAll { sweep in
                guard let first = sweep.channels.first, last.timeUS >= first.timeUS else { return false }
                return last.timeUS - first.timeUS > 60_000_000
            }
        }
    }
}

struct StageDiagnosticReport: Codable {
    let formatVersion: Int
    let firmware: String
    let protocolVersion: Int
    let exportedAt: Date
    let wiringConfirmedAt: Date
    let optionalProbeLabels: [StageProbeLabel]
    let totalSweeps: UInt64
    let readings: [StageSnapshot]
    let limitations: String
}

enum StageReportExporter {
    /// Explicit report export into the direct authorized session or project folder.
    /// Stage under a unique partial name, then publish with an exclusive link.
    static func write(_ report: StageDiagnosticReport, to destination: URL, within root: URL) throws {
        guard destination.isFileURL, root.isFileURL,
              destination.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              destination.lastPathComponent.hasSuffix(".json"), !destination.lastPathComponent.hasPrefix(".") else { throw StorageError.unsafeLocation }
        let folder = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(folder) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        guard data.count <= 1_048_576 else { throw StorageError.fileTooLarge }
        let temporary = ".partial-diagnostics-\(UUID().uuidString).json"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard linkat(folder, temporary, folder, destination.lastPathComponent, 0) == 0 else {
            let code = errno
            // Preserve a complete partial export for recovery. Never overwrite a target.
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard unlinkat(folder, temporary, 0) == 0 else { throw SBProtocolError.invalid("Report saved, but a partial copy could not be removed. Inspect the destination folder.") }
        guard fsync(folder) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
