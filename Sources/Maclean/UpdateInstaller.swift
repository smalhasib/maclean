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
    /// The swap failed and the old app couldn't be put back; it is at this path.
    case rollbackFailed(String)
    /// The root helper's install failed; its user-facing message.
    case privileged(String)

    var message: String {
        switch self {
        case .badSignature: "The download isn't signed by Maclean's release key, so it wasn't installed."
        case .unpackFailed: "The download couldn't be unpacked."
        case .wrongBundle: "The download doesn't contain Maclean, so it wasn't installed."
        case .wrongVersion(let v): "The download is version \(v), not the one announced, so it wasn't installed."
        case .swapFailed(let why): "Maclean couldn't replace itself: \(why)"
        case .privilegedUnavailable: "Installing into this folder isn't available yet. Download the update instead."
        case .rollbackFailed(let path): "Maclean couldn't replace itself or put the old version back. The old app is at \(path)."
        case .privileged(let message): message
        }
    }
}

/// The live installer for a bundle the user can write: verify, unpack with
/// `ditto`, check the bundle id and version, swap, clear quarantine, relaunch.
///
/// Everything is staged in a hidden folder next to the bundle, so every step
/// that touches the old bundle is a same-volume rename. Everything before the
/// swap leaves the installed app as it was; a failed swap puts it back.
struct UpdateInstaller: UpdateInstalling {
    static let bundleIdentifier = "org.maclean.Maclean"

    var publicKeyBase64: String = UpdateKey.publicKeyBase64
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var relaunch: @MainActor @Sendable (URL) -> Void = { Relauncher.relaunch(bundleURL: $0) }
    /// Every rename of a bundle; injectable so tests can fail one.
    var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws {
        guard UpdateSignature.isValid(zip, signatureBase64: signature, publicKeyBase64: publicKeyBase64) else {
            throw UpdateInstallError.badSignature
        }
        let fm = FileManager.default
        let stage = bundleURL.deletingLastPathComponent().appendingPathComponent(".maclean-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        } catch {
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        let unpacked: URL
        do {
            unpacked = try Self.unpack(zip, in: stage)
            try Self.check(unpacked, version: release.version)
        } catch {
            try? fm.removeItem(at: stage)   // holds only the download: the old bundle never moved
            throw error
        }
        try swap(in: unpacked, at: bundleURL, stage: stage)
        Self.clearQuarantine(bundleURL)
        await relaunch(bundleURL)
    }

    /// Unzips into `stage/new` and returns the one `.app` at its top.
    static func unpack(_ zip: Data, in stage: URL) throws -> URL {
        let zipFile = stage.appendingPathComponent("update.zip")
        let out = stage.appendingPathComponent("new")
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

    /// Renames the old bundle into `stage/old`, renames the new one into
    /// place, then trashes the old one. If the second rename fails, anything
    /// it left at the bundle path is removed and the old bundle goes back; if
    /// that fails too, the error says where the old app is. Trash trouble
    /// after the swap is not an error.
    private func swap(in newApp: URL, at bundleURL: URL, stage: URL) throws {
        let fm = FileManager.default
        let oldDir = stage.appendingPathComponent("old")
        let old = oldDir.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            try fm.createDirectory(at: oldDir, withIntermediateDirectories: false)
            try move(bundleURL, old)
        } catch {
            try? fm.removeItem(at: stage)   // the old bundle never moved
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        do {
            try move(newApp, bundleURL)
        } catch let moveError {
            do {
                // Only the new app (or part of it) can be there: the old one is in `old`.
                if Self.exists(bundleURL) { try fm.removeItem(at: bundleURL) }
                try move(old, bundleURL)
            } catch {
                throw UpdateInstallError.rollbackFailed(old.path)
            }
            try? fm.removeItem(at: stage)
            throw UpdateInstallError.swapFailed(moveError.localizedDescription)
        }
        try? trash(old)
        // Leftovers of the download go; the old app stays here only if the Trash refused it.
        try? fm.removeItem(at: stage.appendingPathComponent("new"))
        try? fm.removeItem(at: stage.appendingPathComponent("update.zip"))
        rmdir(oldDir.path)
        rmdir(stage.path)
    }

    /// True for anything at `url`, a dangling symlink included.
    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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

/// The password route (spec §6a.2): for a bundle whose folder the user can't
/// write, the root helper's `install-update` mode does the install behind the
/// administrator dialog, re-checking everything itself (`AdminInstall`).
///
/// The signature is checked here first, so a bad download never asks for the
/// password. The zip and signature go to the helper as 0600 files whose
/// SHA-256 is in argv, and are removed afterwards. A cancelled dialog throws
/// `AdminRunnerError.cancelled` (the sheet then offers Download).
struct PrivilegedUpdateInstaller: Sendable {
    static let prompt = "Maclean needs your password to update itself."

    var runner: any AdminRunning = AdminRunner()
    var publicKeyBase64: String = UpdateKey.publicKeyBase64
    var relaunch: @MainActor @Sendable (URL) -> Void = { Relauncher.relaunch(bundleURL: $0) }
    /// Writes the 0600 request files; injectable so tests can fail it.
    var writeFiles: @Sendable (Data, String) throws -> AdminInstall.RequestFiles = {
        try AdminInstall.writeRequestFiles(zip: $0, signature: $1)
    }

    func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws {
        guard UpdateSignature.isValid(zip, signatureBase64: signature, publicKeyBase64: publicKeyBase64) else {
            throw UpdateInstallError.badSignature
        }
        // Root requires the canonical path (no symlinked components).
        let target = ScanBoundary.canonicalPath(bundleURL.path) ?? bundleURL.path
        let files: AdminInstall.RequestFiles
        do {
            files = try writeFiles(zip, signature)
        } catch {
            throw UpdateInstallError.privileged("The update couldn't be prepared: \(error.localizedDescription)")
        }
        defer { AdminInstall.removeRequestFiles(files) }
        let arguments = AdminInstall.arguments(
            zip: files.zip.path, zipSHA256: files.zipSHA256, signature: files.signature.path,
            signatureSHA256: files.signatureSHA256, version: release.version.description, target: target)
        let output: String
        do {
            output = try await runner.run(arguments, prompt: Self.prompt)
        } catch AdminRunnerError.failed(let why) {
            throw UpdateInstallError.privileged("The update couldn't be installed: \(why)")
        }
        if case .failure(let error) = AdminInstall.decode(output) {
            throw UpdateInstallError.privileged(error.message)
        }
        await relaunch(URL(fileURLWithPath: target))
    }
}
