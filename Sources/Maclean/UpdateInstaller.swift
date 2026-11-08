import Darwin
import Foundation
import MacleanCore

/// Replaces the running app's bundle with a downloaded release (spec §5.3).
protocol UpdateInstalling: Sendable {
    func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws
}

enum UpdateInstallError: Error, Equatable {
    case badSignature
    case unpackFailed
    case wrongBundle
    /// The unpacked app's version.
    case wrongVersion(String)
    case swapFailed(String)
    /// No way to install into a folder only an administrator can write (yet).
    case privilegedUnavailable

    var message: String {
        switch self {
        case .badSignature: "The download isn't signed by Maclean's release key, so it wasn't installed."
        case .unpackFailed: "The download couldn't be unpacked."
        case .wrongBundle: "The download doesn't contain Maclean, so it wasn't installed."
        case .wrongVersion(let v): "The download is version \(v), not the one announced, so it wasn't installed."
        case .swapFailed(let why): "Maclean couldn't replace itself: \(why)"
        case .privilegedUnavailable: "Installing into this folder isn't available yet. Download the update instead."
        }
    }
}

/// The live installer for a bundle the user can write: verify, unpack with
/// `ditto`, check the bundle id and version, swap, clear quarantine, relaunch.
/// Everything before the swap leaves the installed app as it was.
struct UpdateInstaller: UpdateInstalling {
    static let bundleIdentifier = "org.maclean.Maclean"

    var publicKeyBase64: String = UpdateKey.publicKeyBase64
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var relaunch: @MainActor @Sendable (URL) -> Void = { Relauncher.relaunch(bundleURL: $0) }

    func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws {
        guard UpdateSignature.isValid(zip, signatureBase64: signature, publicKeyBase64: publicKeyBase64) else {
            throw UpdateInstallError.badSignature
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("maclean-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let unpacked = try Self.unpack(zip, in: work)
        try Self.check(unpacked, version: release.version)
        try swap(in: unpacked, at: bundleURL)
        Self.clearQuarantine(bundleURL)
        await relaunch(bundleURL)
    }

    /// Unzips into `work/out` and returns the one `.app` at its top.
    static func unpack(_ zip: Data, in work: URL) throws -> URL {
        let zipFile = work.appendingPathComponent("update.zip")
        let out = work.appendingPathComponent("out")
        do { try zip.write(to: zipFile) } catch { throw UpdateInstallError.unpackFailed }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zipFile.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateInstallError.unpackFailed }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateInstallError.unpackFailed }
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw UpdateInstallError.wrongBundle }
        return out.appendingPathComponent(apps[0])
    }

    static func check(_ app: URL, version: SemanticVersion) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier else { throw UpdateInstallError.wrongBundle }
        let found = plist["CFBundleShortVersionString"] as? String ?? "unknown"
        guard SemanticVersion(found) == version else { throw UpdateInstallError.wrongVersion(found) }
    }

    /// Moves the old bundle aside (same folder, so a rename), moves the new
    /// one into place, then trashes the old one. A failed move puts the old
    /// bundle back. Trash trouble after the swap is not an error.
    private func swap(in newApp: URL, at bundleURL: URL) throws {
        let fm = FileManager.default
        let aside = bundleURL.deletingLastPathComponent().appendingPathComponent(".maclean-update-\(UUID().uuidString)")
        let old = aside.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            try fm.createDirectory(at: aside, withIntermediateDirectories: false)
            try fm.moveItem(at: bundleURL, to: old)
        } catch {
            try? fm.removeItem(at: aside)   // empty: the bundle never moved
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            try? fm.moveItem(at: old, to: bundleURL)
            try? fm.removeItem(at: aside)
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        try? trash(old)
        // Only an empty folder goes; if the Trash refused, the old app stays here.
        rmdir(aside.path)
    }

    /// The download was verified, so Gatekeeper's quarantine flag isn't wanted.
    static func clearQuarantine(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
