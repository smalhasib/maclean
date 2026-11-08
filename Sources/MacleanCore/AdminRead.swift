import Darwin
import Foundation

/// The protocol between the app and `maclean-scan read-restricted`, run as
/// root (through an administrator prompt) to read the folders a manual scan
/// found `.restricted` (spec §4.2, §4.4, §6a.5).
///
/// Arguments: `read-restricted --root <scan root> --paths-file <path>
/// --paths-sha256 <hex> --out-dir <dir> --uid <n>`. The paths travel in a
/// private file whose SHA-256 is fixed in argv, as with `AdminDelete`. The
/// out dir is a fresh 0700 directory the app made (`makeOutDir`); root checks
/// that it is owned by `uid`, writes one tree archive per path into it and
/// hands each archive to `uid`. Root only reads: each path must be canonical,
/// strictly inside the canonical scan root and within its boundary
/// (`ScanBoundary.forRoot`). Output: one JSON line per path (`encode`), read
/// with `decode`.
public enum AdminRead {
    public struct Request: Sendable, Equatable {
        public let root: String
        public let paths: [String]
        public let outDir: String
        public let uid: uid_t

        public init(root: String, paths: [String], outDir: String, uid: uid_t) {
            self.root = root
            self.paths = paths
            self.outDir = outDir
            self.uid = uid
        }
    }

    /// One output line: the archive written for `path`, or why there is none.
    public struct Line: Codable, Sendable, Equatable {
        public let path: String
        public let file: String?
        public let error: String?

        public init(path: String, file: String?, error: String?) {
            self.path = path
            self.file = file
            self.error = error
        }
    }

    /// The error for a path root won't read.
    public static let outsideTheScan = "outside the scan"
    static let badOutDir = "output folder refused"
    static let unresolvable = "not found"
    static let unreadable = "unreadable"
    static let writeFailed = "couldn't save the result"
    static let duplicate = "listed twice"
    /// Most paths one request may list.
    public static let maxPaths = 10_000

    public static func arguments(root: String, pathsFile: String, sha256: String, outDir: String,
                                 uid: uid_t) -> [String] {
        ["read-restricted", "--root", root, "--paths-file", pathsFile, "--paths-sha256", sha256,
         "--out-dir", outDir, "--uid", String(uid)]
    }

    /// Writes `paths` as JSON to a new private file; see `AdminDelete.writeItemsFile`.
    public static func writePathsFile(_ paths: [String]) throws -> (url: URL, sha256: String) {
        try AdminDelete.writePrivateFile(Data(AdminDelete.json(paths).utf8), name: "paths.json")
    }

    /// A fresh, empty 0700 directory (`mkdtemp`) for root's archives. The
    /// caller removes it when done.
    public static func makeOutDir() throws -> URL {
        var template = Array((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("maclean-read-XXXXXX").utf8CString)
        guard let dir = mkdtemp(&template) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    /// Parses the argv of `read-restricted`. Refuses uid 0 (root never hands
    /// archives to itself), more than `maxPaths` paths, and duplicate paths.
    public static func parse(_ arguments: [String]) throws -> Request {
        guard arguments.count == 11, arguments[0] == "read-restricted", arguments[1] == "--root",
              arguments[3] == "--paths-file", arguments[5] == "--paths-sha256", arguments[7] == "--out-dir",
              arguments[9] == "--uid" else {
            throw AdminDelete.ParseError.usage
        }
        guard let uid = uid_t(arguments[10]), uid != 0, String(uid) == arguments[10] else {
            throw AdminDelete.ParseError.malformed("bad uid")
        }
        do {
            let data = try AdminDelete.readVerifiedFile(path: arguments[4], sha256: arguments[6])
            let paths = try JSONDecoder().decode([String].self, from: data)
            guard paths.count <= maxPaths else { throw AdminDelete.ParseError.malformed("too many paths") }
            guard Set(paths).count == paths.count else { throw AdminDelete.ParseError.malformed("duplicate paths") }
            return Request(root: arguments[2], paths: paths, outDir: arguments[8], uid: uid)
        } catch {
            throw AdminDelete.ParseError.malformed(String(describing: error))
        }
    }

    /// One line per path, in order. The whole request is refused (every path
    /// gets an error line, nothing is scanned) unless `outDir` opens, without
    /// following a symlink, as a directory with mode 0700 owned by `uid`;
    /// archives are then created relative to that open directory, so the
    /// path can't be swapped afterwards. Each path must be its own canonical
    /// (`realpath`) form, strictly inside the canonical root, on a device the
    /// root's boundary allows and not under a skipped path; the scanned tree's
    /// root (resolved by the scanner, device from its open fd) is checked
    /// again before anything is written. Before the scan the folder is pinned:
    /// opened component by component from `/` with `O_NOFOLLOW` (the path is
    /// canonical, so no component may be a symlink) and held open; the
    /// scanned tree's root inode and device must equal the pinned folder's
    /// (directories can't be hard-linked), so a folder swapped after the
    /// checks, by a symlink anywhere in its path or by another directory, is
    /// refused. More than `maxPaths` paths refuse the whole request; a repeated
    /// path gets an error line. Path `i` is written to
    /// `outDir/<i>.mtree`: created `O_EXCL | O_NOFOLLOW` under a temp name,
    /// mode 0600, `fchown`ed to `uid` when running as root, then renamed into
    /// place without replacing anything.
    public static func perform(_ request: Request,
                               scan: (String, ScanBoundary) async throws -> FileTree) async -> [Line] {
        func failAll(_ error: String) -> [Line] {
            request.paths.map { Line(path: $0, file: nil, error: error) }
        }
        guard request.paths.count <= maxPaths else { return failAll(outsideTheScan) }
        guard request.uid != 0, let dirFD = openOutDir(request.outDir, uid: request.uid) else {
            return failAll(badOutDir)
        }
        defer { close(dirFD) }
        guard let root = ScanBoundary.canonicalPath(request.root) else { return failAll(unresolvable) }
        let boundary = ScanBoundary.forRoot(root)

        func allowed(_ path: String, device: Int32?) -> Bool {
            guard path != root, PathUtil.isInside(path, orEqualTo: root),
                  let device, boundary.allowedDevices.contains(device) else { return false }
            return !boundary.skippedPaths.contains { PathUtil.isInside(path, orEqualTo: $0) }
        }

        var lines: [Line] = []
        var seen: Set<String> = []
        for (index, path) in request.paths.enumerated() {
            func failure(_ error: String) -> Line { Line(path: path, file: nil, error: error) }
            guard seen.insert(path).inserted else {
                lines.append(failure(duplicate))
                continue
            }
            guard let canonical = ScanBoundary.canonicalPath(path) else {
                lines.append(failure(unresolvable))
                continue
            }
            var st = stat()
            guard canonical == path, allowed(path, device: lstat(path, &st) == 0 ? st.st_dev : nil) else {
                lines.append(failure(outsideTheScan))
                continue
            }
            let pinned: (fd: Int32, inode: UInt64, device: Int32)
            switch pin(path) {
            case .success(let p): pinned = p
            case .failure(let error):
                lines.append(failure(error.errno == ELOOP || error.errno == ENOTDIR ? outsideTheScan : unreadable))
                continue
            }
            defer { close(pinned.fd) }  // held open so its inode can't be reused during the scan
            guard allowed(path, device: pinned.device) else {
                lines.append(failure(outsideTheScan))
                continue
            }
            let tree: FileTree
            do { tree = try await scan(path, boundary) } catch {
                lines.append(failure(unreadable))
                continue
            }
            // The scanner resolved and opened the folder itself: it must be the pinned one.
            guard tree.rootPath == path, tree.inode(of: tree.root) == pinned.inode,
                  tree.device(of: tree.root) == pinned.device,
                  allowed(tree.rootPath, device: tree.device(of: tree.root)) else {
                lines.append(failure(outsideTheScan))
                continue
            }
            let name = "\(index).mtree"
            guard writeArchive(tree, named: name, in: dirFD, uid: request.uid) else {
                lines.append(failure(writeFailed))
                continue
            }
            lines.append(Line(path: path, file: (request.outDir as NSString).appendingPathComponent(name),
                              error: nil))
        }
        return lines
    }

    struct OpenError: Error { let errno: Int32 }

    /// Opens the directory at the absolute `path` one component at a time
    /// from `/`, never following a symlink, and returns the open fd with its
    /// inode and device; or the failing `errno` (`ELOOP`/`ENOTDIR` when a
    /// component is a symlink or not a directory).
    static func pin(_ path: String) -> Result<(fd: Int32, inode: UInt64, device: Int32), OpenError> {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open("/", flags)
        guard fd >= 0 else { return .failure(OpenError(errno: errno)) }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), flags)
            let e = errno
            close(fd)
            guard next >= 0 else { return .failure(OpenError(errno: e)) }
            fd = next
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            let e = errno
            close(fd)
            return .failure(OpenError(errno: e == 0 ? ENOTDIR : e))
        }
        return .success((fd, UInt64(st.st_ino), st.st_dev))
    }

    /// The open out dir, or nil unless it is a real directory (not a symlink)
    /// with mode 0700 owned by `uid`.
    static func openOutDir(_ path: String, uid: uid_t) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, (st.st_mode & 0o7777) == 0o700,
              st.st_uid == uid else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes `tree` to `name` in the directory `dirFD`; false on any failure
    /// (nothing is left behind).
    static func writeArchive(_ tree: FileTree, named name: String, in dirFD: Int32, uid: uid_t) -> Bool {
        let tmp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dirFD, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, 0o600) == 0
        if ok, getuid() == 0 { ok = fchown(fd, uid, gid_t.max) == 0 }
        if ok { ok = (try? TreeArchive.write(tree, toFD: fd)) != nil }
        ok = close(fd) == 0 && ok
        if ok { ok = renameatx_np(dirFD, tmp, dirFD, name, UInt32(RENAME_EXCL)) == 0 }
        if !ok { unlinkat(dirFD, tmp, 0) }
        return ok
    }

    /// One JSON line (control characters are escaped, so it stays one line).
    public static func encode(_ line: Line) -> String {
        AdminDelete.json(line)
    }

    /// Path → line for every well-formed line of `output` (LF or CR endings).
    public static func decode(_ output: String) -> [String: Line] {
        let decoder = JSONDecoder()
        var result: [String: Line] = [:]
        for text in output.split(whereSeparator: \.isNewline) {
            if let line = try? decoder.decode(Line.self, from: Data(text.utf8)) { result[line.path] = line }
        }
        return result
    }
}
