import Darwin
import Foundation

/// Reads property-list dictionaries, telling a missing file from one that
/// couldn't be read or parsed (unknown means keep).
public enum PlistReader {
    public enum Failure: Error, Sendable { case missing, unreadable, malformed }

    /// The dictionary in the plist file at `path`.
    public static func dictionary(atPath path: String) -> Result<[String: Any], Failure> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return .failure(.unreadable) }
        return dictionary(from: data).map { .success($0) } ?? .failure(.malformed)
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
