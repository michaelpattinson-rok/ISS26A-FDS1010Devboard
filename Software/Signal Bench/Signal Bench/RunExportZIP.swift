import Darwin
import Foundation
import zlib

/// Writes regular ZIP entries in order. ZIP64 sizes and offsets keep long
/// recordings readable even when an entry or the archive exceeds 4 GiB.
nonisolated final class RunExportZIP {
    private struct Entry {
        let name: Data
        let offset: UInt64
        let crc: UInt32
        let size: UInt64
        let compressed: UInt64
    }

    private let handle: FileHandle
    private let dosDate: UInt16
    private let dosTime: UInt16
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private var openEntry = false
    private let flags: UInt16 = 0x0808 // UTF-8 names and trailing data descriptor
    private let version: UInt16 = 45
    private let large: UInt32 = .max

    init(_ url: URL, date: Date) throws {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(2107, max(1980, parts.year ?? 1980))
        dosDate = UInt16((year - 1980) * 512 + (parts.month ?? 1) * 32 + (parts.day ?? 1))
        dosTime = UInt16((parts.hour ?? 0) * 2048 + (parts.minute ?? 0) * 32 + (parts.second ?? 0) / 2)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StreamFiles.posix() }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func entry(_ path: String) throws -> Member {
        let name = Data(path.utf8)
        guard !openEntry, !name.isEmpty, name.count <= Int(UInt16.max),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0")
              }) else { throw StreamFailure.storage("An export file has an invalid archive path.") }

        let member = try Member(archive: self, name: name, offset: offset)
        var header = Data()
        header.zip(UInt32(0x04034b50), version, flags, UInt16(Z_DEFLATED), dosTime, dosDate,
                   UInt32(0), large, large, UInt16(name.count), UInt16(20))
        header.append(name)
        header.zip(UInt16(1), UInt16(16), UInt64(0), UInt64(0))
        try write(header)
        openEntry = true
        return member
    }

    func addFile(_ url: URL, as path: String, checkpoint: () throws -> Void) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw StreamFiles.posix() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw StreamFailure.storage("An export entry is not a regular file.")
        }
        let member = try entry(path)
        while true {
            try checkpoint()
            guard let bytes = try file.read(upToCount: 262_144), !bytes.isEmpty else { break }
            try member.write(bytes)
        }
        try member.finish()
    }

    func finish() throws {
        guard !openEntry else { throw StreamFailure.storage("The ZIP has an unfinished entry.") }
        let start = offset
        for entry in entries {
            try Task.checkCancellation()
            var header = Data()
            header.zip(UInt32(0x02014b50), UInt16(0x032d), version, flags, UInt16(Z_DEFLATED), dosTime, dosDate,
                       entry.crc, large, large, UInt16(entry.name.count), UInt16(28), UInt16(0), UInt16(0),
                       UInt16(0), UInt32(0o100600 << 16), large)
            header.append(entry.name)
            header.zip(UInt16(1), UInt16(24), entry.size, entry.compressed, entry.offset)
            try write(header)
        }
        let centralSize = offset - start
        let footerOffset = offset
        let count = UInt64(entries.count)
        var footer = Data()
        footer.zip(UInt32(0x06064b50), UInt64(44), UInt16(0x032d), version, UInt32(0), UInt32(0),
                   count, count, centralSize, start)
        footer.zip(UInt32(0x07064b50), UInt32(0), footerOffset, UInt32(1))
        footer.zip(UInt32(0x06054b50), UInt16(0), UInt16(0), UInt16.max, UInt16.max, large, large, UInt16(0))
        try write(footer)
        try handle.synchronize()
        try handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    nonisolated final class Member {
        private let archive: RunExportZIP
        private let name: Data
        private let offset: UInt64
        private var stream: z_stream
        private var crc: UInt32 = 0
        private var bytes: UInt64 = 0
        private var compressed: UInt64 = 0
        private var output = [UInt8](repeating: 0, count: 65_536)
        private var finished = false

        fileprivate init(archive: RunExportZIP, name: Data, offset: UInt64) throws {
            self.archive = archive
            self.name = name
            self.offset = offset
            stream = z_stream()
            // ZIP uses raw DEFLATE, and level 1 favors export time over file size.
            guard deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw StreamFailure.storage("Could not start ZIP compression.")
            }
        }

        deinit { deflateEnd(&stream) }

        func write(_ data: Data) throws {
            try Task.checkCancellation()
            guard !data.isEmpty else { return }
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let input = source.bindMemory(to: UInt8.self).baseAddress!
                stream.next_in = UnsafeMutablePointer(mutating: input)
                defer { stream.next_in = nil }
                stream.avail_in = UInt32(source.count)
                crc = UInt32(crc32(uLong(crc), input, stream.avail_in))
                while stream.avail_in > 0 { _ = try pump(Z_NO_FLUSH) }
            }
            bytes += UInt64(data.count)
        }

        func finish() throws {
            guard !finished else { throw StreamFailure.storage("The ZIP entry is already complete.") }
            try Task.checkCancellation()
            while try pump(Z_FINISH) != Z_STREAM_END {}
            var descriptor = Data()
            descriptor.zip(UInt32(0x08074b50), crc, compressed, bytes)
            try archive.write(descriptor)
            archive.entries.append(.init(name: name, offset: offset, crc: crc, size: bytes, compressed: compressed))
            archive.openEntry = false
            finished = true
        }

        private func pump(_ mode: Int32) throws -> Int32 {
            let result = output.withUnsafeMutableBufferPointer { destination in
                stream.next_out = destination.baseAddress!
                defer { stream.next_out = nil }
                stream.avail_out = UInt32(destination.count)
                return deflate(&stream, mode)
            }
            guard result == Z_OK || result == Z_STREAM_END else {
                throw StreamFailure.storage("ZIP compression failed.")
            }
            let count = output.count - Int(stream.avail_out)
            if count > 0 {
                try archive.write(Data(output.prefix(count)))
                compressed += UInt64(count)
            }
            return result
        }
    }
}

private extension Data {
    nonisolated mutating func zip<each Field: FixedWidthInteger>(_ fields: repeat each Field) {
        repeat StreamWire.put(each fields, into: &self)
    }
}
