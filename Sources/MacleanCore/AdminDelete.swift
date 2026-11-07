import Darwin
import Foundation

/// The protocol between the app and `maclean-scan --delete`, the helper the
/// app runs as root (through an administrator prompt) for items it couldn't
/// delete itself.
///
/// Arguments: `--delete --env <JSON environment> --items <JSON items>`.
/// Output: one JSON line per item (`encode`), read back with `decode`.
public enum AdminDelete {
    public struct Item: Codable, Sendable, Equatable {
        public let request: DeleteRequest
        /// Skip the changed-since-scan re-walk (the item was partly deleted already).
        public let force: Bool

        public init(request: DeleteRequest, force: Bool) {
            self.request = request
            self.force = force
        }
    }

    public enum ParseError: Error, Equatable { case usage, malformed(String) }

    public static func arguments(items: [Item], environment: ProtectionEnvironment) -> [String] {
        ["--delete", "--env", json(environment), "--items", json(items)]
    }

    public static func parse(_ arguments: [String]) throws -> (items: [Item], environment: ProtectionEnvironment) {
        guard arguments.count == 5, arguments[0] == "--delete", arguments[1] == "--env", arguments[3] == "--items" else {
            throw ParseError.usage
        }
        let decoder = JSONDecoder()
        do {
            let env = try decoder.decode(ProtectionEnvironment.self, from: Data(arguments[2].utf8))
            let items = try decoder.decode([Item].self, from: Data(arguments[4].utf8))
            return (items, env)
        } catch {
            throw ParseError.malformed(String(describing: error))
        }
    }

    /// One JSON line (JSON escapes control characters, so a path with a
    /// newline still gives one line).
    public static func encode(path: String, outcome: DeleteOutcome) -> String {
        json(Line(path: path, outcome: outcome))
    }

    /// Path → outcome for every well-formed line of `output`. Lines may end
    /// in LF or CR (`do shell script` turns LF into CR); others are ignored.
    public static func decode(_ output: String) -> [String: DeleteOutcome] {
        let decoder = JSONDecoder()
        var result: [String: DeleteOutcome] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            if let l = try? decoder.decode(Line.self, from: Data(line.utf8)) { result[l.path] = l.outcome }
        }
        return result
    }

    /// Deletes one item as the root helper does: the parent is opened once,
    /// its real location is checked (`resolvedRefusal(for:parentFD:in:)`),
    /// and the same fd is handed to the deleter, so nothing can be swapped
    /// between the check and the removal.
    public static func perform(_ item: Item, with deleter: Deleter) async -> DeleteOutcome {
        let path = item.request.path
        if let refusal = ProtectionRules.refusal(for: path, in: deleter.environment) { return .refused(refusal) }
        let fd: Int32
        switch Deleter.openParent(of: path) {
        case .failure(let early): return early.outcome
        case .success(let opened): fd = opened
        }
        defer { close(fd) }
        if let refusal = resolvedRefusal(for: path, parentFD: fd, in: deleter.environment) { return .refused(refusal) }
        return await deleter.delete(item.request, force: item.force, parentFD: fd)
    }

    /// The protection verdict for `path` whose parent is open as `parentFD`.
    ///
    /// The requested path's own verdict comes first. Then the parent's real
    /// location is read back with `F_GETPATH`, and `<resolved parent>/<name>`
    /// must not be refused either, so a path through a symlinked ancestor
    /// can't reach a protected item.
    public static func resolvedRefusal(for path: String, parentFD: Int32, in env: ProtectionEnvironment) -> Refusal? {
        if let refusal = ProtectionRules.refusal(for: path, in: env) { return refusal }
        guard let (_, nameBytes) = Deleter.split(path) else { return .unsafePath }
        let name = String(decoding: nameBytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parentFD, F_GETPATH, &buffer) != -1 else { return .unsafePath }
        let resolved = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let full = resolved.hasSuffix("/") ? resolved + name : resolved + "/" + name
        return ProtectionRules.refusal(for: full, in: env)
    }

    private struct Line: Codable {
        let path: String
        let outcome: DeleteOutcome
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain value types can't fail.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
