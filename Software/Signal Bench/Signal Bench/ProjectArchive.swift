import Darwin
import Foundation

/// One ZIP containing exact copies of the selected Project files.
nonisolated enum ProjectArchive {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: UInt64
        let modified: timespec
        let changed: timespec

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = UInt64(max(0, info.st_size))
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
                lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private struct Item: Equatable {
        let parts: [String]
        let stamp: Stamp
        var path: String { parts.joined(separator: "/") }
    }

    private struct Source {
        let project: StreamProjectStore
        let archivePath: String
        let items: [Item]
    }

    private struct Index: Encodable {
        let format = "signalbench.project-zip"
        let version = 1
        let projects: [Project]

        struct Project: Encodable {
            let id: UUID
            let name: String
            let folder: String
            let files: Int
        }
    }

    private static let changed = StreamFailure.storage("A Project changed during export. Finish saving and retry the export.")
    private static let unsupported = StreamFailure.storage("A Project contains a linked or unsupported file. Move it out of the Project and try again.")

    static func filename(_ name: String) throws -> String {
        let title = try SessionStore.projectName(name)
        let base = title.lowercased().hasSuffix(".zip") ? String(title.dropLast(4)) : title
        return try SessionStore.projectName(base) + ".zip"
    }

    static func export(_ folders: [URL], named name: String, to destination: URL,
                       checkpoint: () throws -> Void = {},
                       progress: (Double) -> Void = { _ in }) throws -> URL {
        guard !folders.isEmpty else { throw StreamFailure.project("Select at least one Signal Bench Project.") }
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        try StreamFiles.directory(root)
        let target = root.appendingPathComponent(try filename(name))
        guard try !StreamFiles.isPresent(target) else { throw POSIXError(.EEXIST) }

        func check() throws {
            try Task.checkCancellation()
            try checkpoint()
        }

        let projects = try folders.map { url in
            try check()
            do { return try StreamProjectStore(opening: url) }
            catch { throw StreamFailure.project("Could not open “\(url.lastPathComponent)” as a Signal Bench Project. \(error.localizedDescription)") }
        }
        guard Set(projects.map(\.folder)).count == projects.count else {
            throw StreamFailure.project("Choose each Project folder once.")
        }
        func contains(_ parent: URL, _ child: URL) -> Bool {
            child.pathComponents.starts(with: parent.pathComponents)
        }
        for project in projects {
            guard !contains(project.folder, root) else {
                throw StreamFailure.project("Save the ZIP outside the selected Project folders.")
            }
            guard !projects.contains(where: { $0.folder != project.folder && contains(project.folder, $0.folder) }) else {
                throw StreamFailure.project("Choose Project folders that do not contain one another.")
            }
        }
        let sources = try projects.enumerated().map { index, project in
            Source(project: project, archivePath: "Projects/\(index + 1). \(project.identity.name)",
                   items: try items(in: project, checkpoint: check))
        }
        let total = sources.reduce(0.0) { count, source in
            count + source.items.reduce(0.0) { $0 + Double($1.stamp.size) }
        }
        let stage = root.appendingPathComponent(".project-export-\(UUID().uuidString).partial")
        let archive = try RunExportZIP(stage, date: Date())
        defer { _ = unlink(stage.path) }
        let guide = try StreamOutput(member: archive.entry("Main.md"))
        try guide.line("# Signal Bench Projects")
        try guide.line("")
        try guide.line("Unzip this archive, then open a folder under Projects in Signal Bench.")
        try guide.line("Each folder contains the saved Project files, including prior exports.")
        try guide.line("Temporary writes, locks and Finder metadata are omitted.")
        try guide.line("")
        for source in sources {
            try guide.line("- \(source.archivePath) (\(source.items.count) files)")
        }
        let guideInfo = try guide.finish(file: "Main.md", type: "signalbench.project-guide")
        let index = Index(projects: sources.map {
            .init(id: $0.project.identity.id, name: $0.project.identity.name, folder: $0.archivePath, files: $0.items.count)
        })
        let metadata = try StreamOutput(member: archive.entry("Projects.json"))
        try metadata.write(StreamFiles.encoder.encode(index))
        let metadataInfo = try metadata.finish(file: "Projects.json", type: "signalbench.project-index")
        var hashes = [guideInfo, metadataInfo]

        var written = 0.0
        var reported = -1
        func report(_ value: Double) {
            let percent = Int(value * 100)
            if percent > reported {
                reported = percent
                progress(value)
            }
        }
        for source in sources {
            try withRoot(source.project) { fd in
                for item in source.items {
                    try check()
                    let path = source.archivePath + "/" + item.path
                    let output = try StreamOutput(member: archive.entry(path))
                    try withFile(item.parts[...], at: fd) { file in
                        var begin = stat()
                        guard fstat(file.fileDescriptor, &begin) == 0, kind(begin) == S_IFREG,
                              Stamp(begin) == item.stamp else { throw changed }
                        while let data = try file.read(upToCount: 262_144), !data.isEmpty {
                            try check()
                            guard output.bytes + UInt64(data.count) <= item.stamp.size else { throw changed }
                            try output.write(data)
                            written += Double(data.count)
                            report(0.75 * written / max(1, total))
                        }
                        var end = stat()
                        guard fstat(file.fileDescriptor, &end) == 0, Stamp(end) == item.stamp,
                              output.bytes == item.stamp.size else { throw changed }
                    }
                    hashes.append(try output.finish(file: path, type: "signalbench.project-file"))
                }
            }
        }
        let checksums = try StreamOutput(member: archive.entry("SHA256SUMS.txt"))
        for file in hashes {
            try check()
            try checksums.line("\(file.sha256)  \(file.file)")
        }
        _ = try checksums.finish(file: "SHA256SUMS.txt", type: "signalbench.project-checksums")

        try archive.finish()
        report(0.75)
        try archive.verify(checkpoint: check) { report(0.75 + 0.24 * $0) }
        for source in sources {
            guard try items(in: source.project, checkpoint: check) == source.items else { throw changed }
        }
        try check()
        try StreamFiles.directory(root)
        guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw StreamFiles.posix() }
        do { try StreamFiles.sync(root) }
        catch { throw StreamFailure.storage("The ZIP passed verification, but the destination could not confirm the save. Check the selected folder.") }
        report(1)
        return target
    }

    private static func items(in project: StreamProjectStore, checkpoint: () throws -> Void) throws -> [Item] {
        try withRoot(project) { fd in
            var result: [Item] = []
            var seen = Set<String>()
            try scan(fd, components: [], files: &result, seen: &seen, checkpoint: checkpoint)
            return result.sorted { $0.path < $1.path }
        }
    }

    private static func withRoot<T>(_ project: StreamProjectStore, action: (Int32) throws -> T) throws -> T {
        try project.verify()
        let fd = open(project.folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StreamFiles.posix() }
        defer { close(fd) }
        try project.verify()
        var opened = stat()
        var found = stat()
        guard fstat(fd, &opened) == 0, lstat(project.folder.path, &found) == 0,
              opened.st_dev == found.st_dev, opened.st_ino == found.st_ino else { throw changed }
        return try action(fd)
    }

    private static func scan(_ fd: Int32, components: [String], files: inout [Item],
                             seen: inout Set<String>, checkpoint: () throws -> Void) throws {
        let copy = dup(fd)
        guard copy >= 0 else { throw StreamFiles.posix() }
        guard let directory = fdopendir(copy) else {
            let error = StreamFiles.posix()
            close(copy)
            throw error
        }
        defer { closedir(directory) }
        while true {
            try checkpoint()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw StreamFiles.posix() }
                break
            }
            let nameLength = Int(entry.pointee.d_namlen)
            let string = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(nameLength), encoding: .utf8)
            }
            guard let name = string else { throw unsupported }
            if name == "." || name == ".." || name == ".DS_Store" || name == ".writer-lock" ||
                [".pending-", ".export-", ".partial-", ".project-export-"].contains(where: name.hasPrefix) { continue }
            guard !name.contains("\\"), !name.contains(":"),
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw unsupported }
            let parts = components + [name]
            let key = parts.joined(separator: "/").precomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else {
                throw StreamFailure.storage("A Project contains file names that would collide when the ZIP is extracted.")
            }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw StreamFiles.posix() }
            switch kind(info) {
            case S_IFREG: files.append(.init(parts: parts, stamp: Stamp(info)))
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw StreamFiles.posix() }
                defer { close(child) }
                try scan(child, components: parts, files: &files, seen: &seen, checkpoint: checkpoint)
            default: throw unsupported
            }
        }
    }

    private static func withFile<T>(_ parts: ArraySlice<String>, at parent: Int32,
                                    action: (FileHandle) throws -> T) throws -> T {
        guard let name = parts.first else { throw unsupported }
        let isFile = parts.count == 1
        let kind = isFile ? O_NONBLOCK : O_DIRECTORY
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | kind)
        guard fd >= 0 else { throw StreamFiles.posix() }
        if isFile {
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            return try action(file)
        }
        defer { close(fd) }
        return try withFile(parts.dropFirst(), at: fd, action: action)
    }

    private static func kind(_ info: stat) -> mode_t { info.st_mode & S_IFMT }
}
