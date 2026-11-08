import Darwin
import Foundation

/// The protocol between the app and `maclean-scan smart-measure`, run as root
/// (through an administrator prompt) to measure system-wide Smart Clean items
/// the user can't read (spec §5.3a).
///
/// Arguments: `smart-measure --env <JSON environment> --paths-file <path>
/// --paths-sha256 <hex>`. As with `AdminDelete`, the paths travel in a private
/// file whose SHA-256 is fixed in argv; root refuses a file that doesn't match.
/// Root measures only paths claimed by a catalog rule that `requiresAdmin`
/// and allowed by the Smart Clean protection rules; every other path gets an
/// `error` line. Output: one JSON line per path (`encode`), read with `decode`.
public enum AdminMeasure {
    /// One output line: a measurement, or why there is none.
    public struct Line: Codable, Sendable, Equatable {
        public let path: String
        public let measurement: Measurement?
        public let error: String?

        public init(path: String, measurement: Measurement?, error: String?) {
            self.path = path
            self.measurement = measurement
            self.error = error
        }
    }

    /// The error for a path root won't measure.
    public static let notATarget = "not a system cleanup target"

    public static func arguments(pathsFile: String, sha256: String, environment: ProtectionEnvironment) -> [String] {
        ["smart-measure", "--env", AdminDelete.json(environment), "--paths-file", pathsFile, "--paths-sha256", sha256]
    }

    /// Writes `paths` as JSON to a new private file; see `AdminDelete.writeItemsFile`.
    public static func writePathsFile(_ paths: [String]) throws -> (url: URL, sha256: String) {
        try AdminDelete.writePrivateFile(Data(AdminDelete.json(paths).utf8), name: "paths.json")
    }

    /// Removes a paths file written by `writePathsFile` and its directory.
    public static func removePathsFile(_ file: URL) {
        AdminDelete.removeItemsFile(file)
    }

    public static func parse(_ arguments: [String]) throws -> (paths: [String], environment: ProtectionEnvironment) {
        guard arguments.count == 7, arguments[0] == "smart-measure", arguments[1] == "--env",
              arguments[3] == "--paths-file", arguments[5] == "--paths-sha256" else {
            throw AdminDelete.ParseError.usage
        }
        let decoder = JSONDecoder()
        do {
            let env = try decoder.decode(ProtectionEnvironment.self, from: Data(arguments[2].utf8))
            let data = try AdminDelete.readVerifiedFile(path: arguments[4], sha256: arguments[6])
            return (try decoder.decode([String].self, from: data), env)
        } catch {
            throw AdminDelete.ParseError.malformed(String(describing: error))
        }
    }

    /// One line per path, in order. A path is measured only if the first
    /// catalog rule claiming it `requiresAdmin` and the Smart Clean protection
    /// rules allow it, both for the path and for its parent's real location.
    /// The item is measured relative to its opened parent, never through a
    /// symlink. Hard links and clones are counted once across all paths.
    public static func measureAll(_ paths: [String], environment: ProtectionEnvironment) -> [Line] {
        measureAll(paths, environment: environment, rules: CleanCatalog.rules)
    }

    static func measureAll(_ paths: [String], environment env: ProtectionEnvironment, rules: [CleanRule]) -> [Line] {
        let context = MeasureContext()
        return paths.map { path in
            func failure(_ error: String) -> Line { Line(path: path, measurement: nil, error: error) }
            guard let rule = AdminDelete.adminRule(for: path, rules: rules, home: env.home),
                  ProtectionRules.refusal(for: path, context: .smartClean, in: env) == nil else {
                return failure(notATarget)
            }
            let fd: Int32
            switch Deleter.openParent(of: path) {
            case .failure(let early): return failure(early.outcome == .missing ? "missing" : "unreadable")
            case .success(let opened): fd = opened
            }
            defer { close(fd) }
            guard AdminDelete.resolvedRefusal(for: path, parentFD: fd, context: .smartClean, in: env) == nil,
                  let (name, resolved) = AdminDelete.resolvedPath(of: path, parentFD: fd),
                  AdminDelete.adminRule(for: resolved, rules: rules, home: env.home)?.id == rule.id else {
                return failure(notATarget)
            }
            do throws(MeasureError) {
                return Line(path: path, measurement: try Measurer.measure(name: name, inParent: fd, context: context),
                            error: nil)
            } catch {
                switch error {
                case .notFound: return failure("missing")
                case .unreadable: return failure("unreadable")
                case .timedOut: return failure("timed out")
                }
            }
        }
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
