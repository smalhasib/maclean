import Darwin
import Foundation

/// Reads property-list dictionaries, telling a missing file from one that
/// couldn't be read or parsed (unknown means keep).
public enum PlistReader {
    public enum Failure: Error, Sendable { case missing, unreadable, malformed }

    /// Largest plist read (bytes); a larger file counts as unreadable.
    public static let maxSize = 1 << 20

    /// The dictionary in the plist file at `path`. See `dictionary(name:inDirectory:)`.
    public static func dictionary(atPath path: String) -> Result<[String: Any], Failure> {
        dictionary(name: path, inDirectory: AT_FDCWD)
    }

    /// The dictionary in plist file `name` of the directory open as `dirFD`
    /// (or path `name` with `AT_FDCWD`). Safe on folders other users or
    /// processes control: a symlink at the last component is not followed,
    /// only a regular file is read (a FIFO can't block), and at most
    /// `maxSize` bytes. Any of those is `.unreadable`.
    public static func dictionary(name: String, inDirectory dirFD: Int32) -> Result<[String: Any], Failure> {
        readRegularFile(name: name, inDirectory: dirFD, maxSize: maxSize).flatMap {
            dictionary(from: $0).map { .success($0) } ?? .failure(.malformed)
        }
    }

    /// The contents of regular file `name` in `dirFD`, opened with
    /// `O_NOFOLLOW | O_NONBLOCK`; `.missing` if absent, `.unreadable` if it
    /// can't be opened, is a symlink or not a regular file, or is larger than
    /// `maxSize` bytes (checked on the size and on the bytes read).
    static func readRegularFile(name: String, inDirectory dirFD: Int32, maxSize: Int) -> Result<Data, Failure> {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxSize,
              let data = try? handle.read(upToCount: maxSize + 1) ?? Data(), data.count <= maxSize
        else { return .failure(.unreadable) }
        return .success(data)
    }

    /// The dictionary in `data` (XML or binary), or nil.
    public static func dictionary(from data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// `key` of the plist at `path` as a string, or nil for any failure.
    public static func string(_ key: String, atPath path: String) -> String? {
        guard case .success(let dict) = dictionary(atPath: path) else { return nil }
        return dict[key] as? String
    }
}
