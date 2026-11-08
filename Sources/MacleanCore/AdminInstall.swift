import Darwin
import Foundation

/// The protocol between the app and `maclean-scan install-update`, run as root
/// (after the administrator dialog) to install an update when the user can't
/// replace Maclean's bundle themselves (spec §6a.2).
///
/// Arguments: `install-update --zip <p> --zip-sha256 <h> --sig <p>
/// --sig-sha256 <h> --version <v> --target <path>`. The zip and its signature
/// travel as private files whose SHA-256 is fixed in argv, as with
/// `AdminDelete`. Output: one JSON line, `{"ok":true}` or `{"error":"<code>"}`
/// (`encode`, read back with `decode`).
///
/// Root trusts nothing from the request but the bytes it verifies: the
/// signature is checked with the key compiled into MacleanCore, and the only
/// place root writes is its own work directory in the target's parent and the
/// target itself, which must already be a Maclean bundle (`perform`).
public enum AdminInstall {
    public static let bundleIdentifier = "org.maclean.Maclean"
    /// Largest zip root reads (matches the download cap).
    static let maxZipSize = 300 << 20
    static let maxSignatureSize = 4096
    static let workDirPrefix = ".maclean-update-root-"

    public struct Request: Sendable, Equatable {
        public let zip: String
        public let zipSHA256: String
        public let signature: String
        public let signatureSHA256: String
        public let version: String
        public let target: String

        public init(zip: String, zipSHA256: String, signature: String, signatureSHA256: String,
                    version: String, target: String) {
            self.zip = zip
            self.zipSHA256 = zipSHA256
            self.signature = signature
            self.signatureSHA256 = signatureSHA256
            self.version = version
            self.target = target
        }
    }

    /// Why root refused or failed; the raw value is the reply's `error` code.
    public enum InstallError: String, Error, Sendable, CaseIterable {
        case usage, notRoot, unreadableFiles, badSignature, unpackFailed, wrongBundle, wrongVersion,
             unsafeBundle, badTarget, swapFailed, rollbackFailed
        /// The helper's reply was missing, malformed or unknown.
        case noReply

        public var message: String {
            switch self {
            case .usage: "The update request was malformed, so nothing was installed."
            case .notRoot: "The update helper didn't get administrator rights, so nothing was installed."
            case .unreadableFiles: "The downloaded update changed before it could be installed, so it wasn't installed."
            case .badSignature: "The download isn't signed by Maclean's release key, so it wasn't installed."
            case .unpackFailed: "The download couldn't be unpacked."
            case .wrongBundle: "The download doesn't contain Maclean, so it wasn't installed."
            case .wrongVersion: "The download isn't the version announced, so it wasn't installed."
            case .unsafeBundle: "The download contains a link pointing outside Maclean, so it wasn't installed."
            case .badTarget: "Maclean can only replace its own app, and this one couldn't be confirmed, so nothing was installed."
            case .swapFailed: "Maclean couldn't replace itself. The old version is still in place."
            case .rollbackFailed: "Maclean couldn't replace itself or put the old version back. Look for a file ending in .maclean-old next to where Maclean was."
            case .noReply: "The update helper didn't answer, so Maclean may not have been updated."
            }
        }
    }

    /// Unpacks zip `zip` into new directory `outDir`, both names relative to
    /// the work directory open as `dirFD`; true on success.
    public typealias Unzip = (_ dirFD: Int32, _ zip: String, _ outDir: String) -> Bool
    /// `renameat`-style rename; returns 0 or -1 with `errno` set.
    typealias Rename = (_ fromFD: Int32, _ from: String, _ toFD: Int32, _ to: String) -> Int32

    public static func arguments(zip: String, zipSHA256: String, signature: String, signatureSHA256: String,
                                 version: String, target: String) -> [String] {
        ["install-update", "--zip", zip, "--zip-sha256", zipSHA256, "--sig", signature,
         "--sig-sha256", signatureSHA256, "--version", version, "--target", target]
    }

    /// Parses argv only (`perform` reads and verifies the files).
    public static func parse(_ arguments: [String]) throws -> Request {
        guard arguments.count == 13, arguments[0] == "install-update", arguments[1] == "--zip",
              arguments[3] == "--zip-sha256", arguments[5] == "--sig", arguments[7] == "--sig-sha256",
              arguments[9] == "--version", arguments[11] == "--target" else {
            throw AdminDelete.ParseError.usage
        }
        func isHash(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard isHash(arguments[4]), isHash(arguments[8]) else { throw AdminDelete.ParseError.malformed("bad hash") }
        guard SemanticVersion(arguments[10]) != nil else { throw AdminDelete.ParseError.malformed("bad version") }
        return Request(zip: arguments[2], zipSHA256: arguments[4], signature: arguments[6],
                       signatureSHA256: arguments[8], version: arguments[10], target: arguments[12])
    }

    // MARK: - Request files (app side)

    public struct RequestFiles: Sendable {
        public let zip: URL
        public let zipSHA256: String
        public let signature: URL
        public let signatureSHA256: String
    }

    /// Writes the zip and the signature to new 0600 files, each in its own
    /// fresh 0700 temporary directory. Remove them with `removeRequestFiles`.
    public static func writeRequestFiles(zip: Data, signature: String) throws -> RequestFiles {
        let z = try AdminDelete.writePrivateFile(zip, name: "update.zip")
        do {
            let s = try AdminDelete.writePrivateFile(Data(signature.utf8), name: "update.zip.sig")
            return RequestFiles(zip: z.url, zipSHA256: z.sha256, signature: s.url, signatureSHA256: s.sha256)
        } catch {
            AdminDelete.removeItemsFile(z.url)
            throw error
        }
    }

    public static func removeRequestFiles(_ files: RequestFiles) {
        AdminDelete.removeItemsFile(files.zip)
        AdminDelete.removeItemsFile(files.signature)
    }

    // MARK: - Reply

    private struct Reply: Codable {
        var ok: Bool?
        var error: String?
    }

    public static func encode(_ result: Result<Void, InstallError>) -> String {
        switch result {
        case .success: AdminDelete.json(Reply(ok: true))
        case .failure(let e): AdminDelete.json(Reply(error: e.rawValue))
        }
    }

    /// The helper's single reply line (LF or CR endings); anything else is `.noReply`.
    public static func decode(_ output: String) -> Result<Void, InstallError> {
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard lines.count == 1, let reply = try? JSONDecoder().decode(Reply.self, from: Data(lines[0].utf8)) else {
            return .failure(.noReply)
        }
        if reply.ok == true, reply.error == nil { return .success(()) }
        return .failure(reply.error.flatMap(InstallError.init(rawValue:)) ?? .noReply)
    }

    // MARK: - Install (root side)

    /// Installs the update, refusing at the first check that fails. In order:
    /// 1. Reads the zip and the signature with `readVerifiedFile` (SHA-256
    ///    from argv, `O_NOFOLLOW`, regular file, size-capped).
    /// 2. Verifies the Ed25519 signature with `publicKeyBase64`.
    /// 3. Checks the target before anything is written: canonical (`realpath`
    ///    equals it), absolute, ending in `.app`; its parent opened one
    ///    component at a time from `/` with `O_NOFOLLOW`; the target opened
    ///    relative to that fd as a directory (not a symlink) on the parent's
    ///    device (not a volume root), whose `Contents/Info.plist` (bounded,
    ///    no-follow read) has bundle id `org.maclean.Maclean`.
    /// 4. Creates the work directory: `mkdtemp` in the target's parent
    ///    (`.maclean-update-root-XXXXXX`, mode 0700, ours), so every rename
    ///    stays on one volume.
    /// 5. Copies the verified zip bytes into it (never re-reading the user's
    ///    file) and unpacks them there with `unzip`.
    /// 6. The unpacked folder must hold exactly one entry, a `Maclean.app`
    ///    directory with bundle id `org.maclean.Maclean` and
    ///    `CFBundleShortVersionString` equal to the request's version.
    /// 7. Walks the new bundle by fd: refuses any symlink that is absolute or
    ///    climbs out of the bundle, and anything but files, directories and
    ///    links; takes the old bundle's owner and group (`lchown`-style, only
    ///    as root) and clears set-id bits; the bundle gets the old one's mode.
    /// 8. Renames the old bundle into the work directory and checks it is the
    ///    inode checked in step 3 (else puts it back and refuses), then renames
    ///    the new one into place without replacing anything. If that fails the
    ///    old one goes back (or, failing that, next to the target as
    ///    `<name>.maclean-old-<uuid>`).
    /// 9. Removes the work directory (with the old bundle), walking it by fd.
    /// Every rename is relative to the open parent and work directory fds.
    public static func perform(_ request: Request, publicKeyBase64: String = UpdateKey.publicKeyBase64,
                               unzip: Unzip = ditto) -> Result<Void, InstallError> {
        perform(request, publicKeyBase64: publicKeyBase64, unzip: unzip, renameNew: renameExclusive)
    }

    /// `perform` with the rename of the new bundle injectable, for tests.
    static func perform(_ request: Request, publicKeyBase64: String, unzip: Unzip,
                        renameNew: Rename) -> Result<Void, InstallError> {
        // 1–2: the bytes, then the signature. Nothing is touched before both pass.
        let zip: Data
        let signature: String
        do {
            zip = try AdminDelete.readVerifiedFile(path: request.zip, sha256: request.zipSHA256, maxSize: maxZipSize)
            signature = String(decoding: try AdminDelete.readVerifiedFile(
                path: request.signature, sha256: request.signatureSHA256, maxSize: maxSignatureSize), as: UTF8.self)
        } catch {
            return .failure(.unreadableFiles)
        }
        guard UpdateSignature.isValid(zip, signatureBase64: signature, publicKeyBase64: publicKeyBase64) else {
            return .failure(.badSignature)
        }
        guard let version = SemanticVersion(request.version) else { return .failure(.usage) }

        // 3: the target, still before any write.
        guard let target = openTarget(request.target) else { return .failure(.badTarget) }
        defer {
            close(target.fd)
            close(target.parentFD)
        }

        // 4: the work directory, next to the target.
        guard let work = makeWorkDir(in: target.parentFD) else { return .failure(.swapFailed) }
        var keepWork = false
        defer {
            if !keepWork { _ = Deleter.removeDirectory(named: work.name, in: target.parentFD, expectIno: work.inode) }
            close(work.fd)
        }

        // 5: unpack a copy of the verified bytes.
        guard writeFile(zip, named: "update.zip", in: work.fd), unzip(work.fd, "update.zip", "unpacked") else {
            return .failure(.unpackFailed)
        }

        // 6: exactly one Maclean.app of the requested version.
        let unpackedFD = openat(work.fd, "unpacked", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard unpackedFD >= 0 else { return .failure(.unpackFailed) }
        defer { close(unpackedFD) }
        guard let top = entries(unpackedFD), top == ["Maclean.app"] else { return .failure(.wrongBundle) }
        let appFD = openat(unpackedFD, "Maclean.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard appFD >= 0 else { return .failure(.wrongBundle) }
        defer { close(appFD) }
        guard let info = infoPlist(of: appFD), info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            return .failure(.wrongBundle)
        }
        guard let found = info["CFBundleShortVersionString"] as? String, SemanticVersion(found) == version else {
            return .failure(.wrongVersion)
        }

        // 7: links stay inside; the old bundle's owner, group and mode.
        let owner = geteuid() == 0 ? (target.stat.st_uid, target.stat.st_gid) : nil
        guard prepare(appFD, depth: 0, owner: owner) else { return .failure(.unsafeBundle) }
        if let (uid, gid) = owner, fchown(appFD, uid, gid) != 0 { return .failure(.swapFailed) }
        guard fchmod(appFD, target.stat.st_mode & 0o1777) == 0 else { return .failure(.swapFailed) }

        // 8: the swap.
        let name = target.name
        let old = "old.app"
        guard renameExclusive(target.parentFD, name, work.fd, old) == 0 else { return .failure(.swapFailed) }
        var aside = stat()
        guard fstatat(work.fd, old, &aside, AT_SYMLINK_NOFOLLOW) == 0, aside.st_ino == target.stat.st_ino,
              aside.st_dev == target.stat.st_dev else {
            // Something replaced the target after it was checked: never delete it.
            if renameExclusive(work.fd, old, target.parentFD, name) != 0 { keepWork = true }
            return .failure(.badTarget)
        }
        guard renameNew(unpackedFD, "Maclean.app", target.parentFD, name) == 0 else {
            if renameExclusive(work.fd, old, target.parentFD, name) == 0 { return .failure(.swapFailed) }
            if renameExclusive(work.fd, old, target.parentFD, "\(name).maclean-old-\(UUID().uuidString)") != 0 {
                keepWork = true   // the old bundle is still in the work directory
            }
            return .failure(.rollbackFailed)
        }
        // 9: the defer removes the work directory, the old bundle with it.
        return .success(())
    }

    /// `renameatx_np` with `RENAME_EXCL`: never replaces anything.
    static func renameExclusive(_ fromFD: Int32, _ from: String, _ toFD: Int32, _ to: String) -> Int32 {
        renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_EXCL))
    }

    /// Runs `/usr/bin/ditto -x -k <zip> <outDir>` with its working directory
    /// set to `dirFD` (by fd, so a renamed work directory can't redirect it),
    /// a minimal environment, standard streams on `/dev/null` (stdout is the
    /// reply channel) and no other inherited fds.
    public static func ditto(_ dirFD: Int32, _ zip: String, _ outDir: String) -> Bool {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawn_file_actions_addfchdir_np(&actions, dirFD) == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return false }
        let tool = "/usr/bin/ditto"
        let argv: [UnsafeMutablePointer<CChar>?] = [tool, "-x", "-k", zip, outDir].map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, tool, &actions, &attr, argv, envp) == 0 else { return false }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return false }
        }
        return status & 0x7f == 0 && (status >> 8) & 0xff == 0
    }

    // MARK: - Helpers

    struct Target {
        let parentFD: Int32
        let fd: Int32
        let name: String
        let stat: stat
    }

    /// The open target and its parent, or nil unless every target check holds.
    static func openTarget(_ path: String) -> Target? {
        guard path.hasPrefix("/"), path.hasSuffix(".app"), ScanBoundary.canonicalPath(path) == path else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.count > 4, name != ".", name != ".." else { return nil }
        guard case .success(let parent) = AdminRead.pin((path as NSString).deletingLastPathComponent) else { return nil }
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var st = stat()
        guard fd >= 0, fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_dev == parent.device,
              infoPlist(of: fd)?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            if fd >= 0 { close(fd) }
            close(parent.fd)
            return nil
        }
        return Target(parentFD: parent.fd, fd: fd, name: name, stat: st)
    }

    /// `Contents/Info.plist` of the bundle open as `bundleFD`, read without
    /// following a symlink at either level.
    static func infoPlist(of bundleFD: Int32) -> [String: Any]? {
        let contents = openat(bundleFD, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { return nil }
        defer { close(contents) }
        guard case .success(let dict) = PlistReader.dictionary(name: "Info.plist", inDirectory: contents) else { return nil }
        return dict
    }

    /// A fresh `mkdtemp` directory in `parentFD`, opened, and confirmed to be
    /// a 0700 directory owned by us.
    static func makeWorkDir(in parentFD: Int32) -> (fd: Int32, name: String, inode: UInt64)? {
        var template = Array((workDirPrefix + "XXXXXX").utf8CString)
        guard mkdtempat_np(parentFD, &template) != nil else { return nil }
        let name = String(decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o7777 == 0o700,
              st.st_uid == geteuid() else {
            close(fd)
            return nil
        }
        return (fd, name, UInt64(st.st_ino))
    }

    /// Writes `data` to new file `name` (0600) in `dirFD`.
    static func writeFile(_ data: Data, named name: String, in dirFD: Int32) -> Bool {
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    /// The entry names of directory `fd` (without `.` and `..`), sorted; nil on error.
    static func entries(_ fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let dir = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            var ent = entry.pointee
            let length = Int(ent.d_namlen)
            let bytes = withUnsafeBytes(of: &ent.d_name) { Array($0.prefix(length)) }
            guard let name = String(bytes: bytes, encoding: .utf8) else { return nil }
            if name != "." && name != ".." { names.append(name) }
        }
        guard errno == 0 else { return nil }
        return names.sorted()
    }

    /// Walks the directory `fd`, `depth` levels below the bundle root, by fd
    /// and without following links. False on a link that is absolute or
    /// climbs out of the bundle (`linkStaysInside`), on anything but a file,
    /// directory or link, or on any error. Gives each entry `owner` (with
    /// `AT_SYMLINK_NOFOLLOW`) when set, and clears set-id bits.
    static func prepare(_ fd: Int32, depth: Int, owner: (uid_t, gid_t)?) -> Bool {
        guard let names = entries(fd) else { return false }
        for name in names {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
                let n = readlinkat(fd, name, &buffer, Int(MAXPATHLEN))
                guard n > 0, let link = String(bytes: buffer.prefix(n).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                      linkStaysInside(link, depth: depth) else { return false }
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                let ok = prepare(child, depth: depth + 1, owner: owner)
                close(child)
                guard ok else { return false }
            case S_IFREG:
                break
            default:
                return false
            }
            if let (uid, gid) = owner, fchownat(fd, name, uid, gid, AT_SYMLINK_NOFOLLOW) != 0 { return false }
            if st.st_mode & S_IFMT != S_IFLNK, st.st_mode & (S_ISUID | S_ISGID) != 0,
               fchmodat(fd, name, st.st_mode & 0o1777, 0) != 0 { return false }
        }
        return true
    }

    /// Whether symlink text `link`, in a directory `depth` levels below the
    /// bundle root, stays inside the bundle: relative, and any `..` only at
    /// the start (applied to real directories, so the climb is exact) and no
    /// more of them than `depth`. A `..` after a name could climb out of a
    /// directory reached through another link, so it is refused.
    static func linkStaysInside(_ link: String, depth: Int) -> Bool {
        guard !link.isEmpty, !link.hasPrefix("/") else { return false }
        var ups = 0
        var descended = false
        for component in link.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !descended else { return false }
                ups += 1
            default: descended = true
            }
        }
        return ups <= depth
    }
}
