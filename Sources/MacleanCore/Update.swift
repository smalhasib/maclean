import CryptoKit
import Foundation

/// A `major.minor.patch` version. Accepts a leading `v` and missing minor or
/// patch parts; anything else (pre-release suffixes, junk) yields nil.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        major = nums[0]
        minor = nums.count > 1 ? nums[1] : 0
        patch = nums.count > 2 ? nums[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

public enum UpdateError: Error, Equatable {
    case malformedRelease
    case missingAsset(String)
}

/// The parts of a GitHub `releases/latest` response the updater needs.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: SemanticVersion
    public let notes: String
    public let zipURL: URL
    public let signatureURL: URL

    public init(version: SemanticVersion, notes: String, zipURL: URL, signatureURL: URL) {
        self.version = version
        self.notes = notes
        self.zipURL = zipURL
        self.signatureURL = signatureURL
    }

    public static func parse(_ json: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let body: String?; let assets: [Asset]? }
        guard let r = try? JSONDecoder().decode(Release.self, from: json),
              let version = SemanticVersion(r.tag_name) else { throw UpdateError.malformedRelease }
        let zipName = "Maclean-\(version).zip"
        let sigName = zipName + ".sig"
        func url(_ name: String) throws -> URL {
            guard let a = r.assets?.first(where: { $0.name == name }),
                  let u = URL(string: a.browser_download_url),
                  u.scheme == "https" else { throw UpdateError.missingAsset(name) }
            return u
        }
        return ReleaseInfo(version: version, notes: r.body ?? "", zipURL: try url(zipName), signatureURL: try url(sigName))
    }
}

/// Ed25519 verification. Key (32 bytes) and signature (64 bytes) are base64 of raw bytes.
public enum UpdateSignature {
    public static func isValid(_ data: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
        func b64(_ s: String) -> Data? { Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let sig = b64(signatureBase64), let keyData = b64(publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

public enum InstallSource: Equatable, Sendable {
    case homebrew, standalone

    /// Homebrew only when `<root>/maclean` exists as a directory in a Caskroom
    /// and the standardized bundle path is exactly `/Applications/Maclean.app`.
    public static func detect(
        bundlePath: String,
        caskroomRoots: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    ) -> InstallSource {
        let fm = FileManager.default
        let hasCask = caskroomRoots.contains { root in
            var isDir: ObjCBool = false
            let p = (root as NSString).appendingPathComponent("maclean")
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
        guard hasCask else { return .standalone }
        let standardized = (bundlePath as NSString).standardizingPath
        let inApplications = standardized == "/Applications/Maclean.app"
        return inApplications ? .homebrew : .standalone
    }
}

public enum UpdateCheck {
    /// True when no check has happened yet or more than 24 h have passed.
    public static func shouldCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) > 24 * 3600
    }
}
