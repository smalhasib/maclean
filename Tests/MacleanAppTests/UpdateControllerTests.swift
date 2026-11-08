import CryptoKit
import Foundation
import Testing
import MacleanCore
@testable import Maclean

// Fakes only: no network, no real Trash, no relaunch, nothing under /Applications.

private let zipURL = URL(string: "https://example.com/Maclean-0.3.0.zip")!
private let sigURL = URL(string: "https://example.com/Maclean-0.3.0.zip.sig")!

private func releaseJSON(_ tag: String = "v0.3.0") -> Data {
    let v = SemanticVersion(tag)!.description
    return Data("""
    {"tag_name":"\(tag)","body":"• Automatic updates","assets":[
      {"name":"Maclean-\(v).zip","browser_download_url":"https://example.com/Maclean-\(v).zip"},
      {"name":"Maclean-\(v).zip.sig","browser_download_url":"https://example.com/Maclean-\(v).zip.sig"}]}
    """.utf8)
}

/// Answers the API URL with `json` (or throws), and the assets with fixed bytes.
@MainActor private final class FakeNet {
    var json: Data? = releaseJSON()
    var urls: [URL] = []
    /// Per zip request, in order: a delay (that ignores cancellation) and whether it then fails.
    var zipPlan: [(Duration, Bool)] = []
    func fetch(_ url: URL) async throws -> Data {
        urls.append(url)
        if url == UpdateController.latestReleaseURL {
            guard let json else { throw URLError(.notConnectedToInternet) }
            return json
        }
        if url == sigURL { return Data("c2lnbmF0dXJl".utf8) }
        if !zipPlan.isEmpty {
            let (delay, fails) = zipPlan.removeFirst()
            let clock = ContinuousClock()
            let end = clock.now + delay
            while clock.now < end { await Task.yield() }
            if fails { throw URLError(.networkConnectionLost) }
        }
        return Data("zip".utf8)
    }
}

private actor FakeInstaller: UpdateInstalling {
    private(set) var calls = 0
    func install(zip: Data, signature: String, release: ReleaseInfo, replacing bundleURL: URL) async throws {
        calls += 1
    }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "maclean-update-tests-\(UUID().uuidString)")!
}

@MainActor private func make(
    net: FakeNet, defaults: UserDefaults = freshDefaults(), coordinator: PromptCoordinator = PromptCoordinator(hasAccess: { true }),
    installer: FakeInstaller = FakeInstaller(), bundleURL: URL = URL(fileURLWithPath: "/Users/x/Apps/Maclean.app"),
    caskroomRoots: [String] = [], writable: Bool = true, busy: @escaping () -> Bool = { false },
    installPrivileged: @escaping (Data, String, ReleaseInfo, URL) async throws -> Void = { _, _, _, _ in }
) -> UpdateController {
    UpdateController(currentVersion: "0.2.0", bundleURL: bundleURL, fetch: { try await net.fetch($0) },
                     defaults: defaults, coordinator: coordinator, installer: installer,
                     caskroomRoots: caskroomRoots, isWritable: { _ in writable }, isBusy: busy,
                     installPrivileged: installPrivileged, open: { _ in })
}

@MainActor @Test func automaticCheckThrottledAndSilent() async {
    let net = FakeNet()
    let defaults = freshDefaults()
    defaults.set(Date().addingTimeInterval(-3600), forKey: UpdateController.lastCheckKey)
    let throttled = make(net: net, defaults: defaults)
    throttled.checkAutomatically()
    await throttled.checkTask?.value
    #expect(net.urls.isEmpty)
    #expect(throttled.state == .idle)

    net.json = nil
    let coordinator = PromptCoordinator(hasAccess: { true })
    let failing = make(net: net, coordinator: coordinator)
    failing.checkAutomatically()
    await failing.checkTask?.value
    #expect(net.urls == [UpdateController.latestReleaseURL])
    #expect(failing.state == .idle)
    #expect(coordinator.sheet == nil)

    let off = freshDefaults()
    off.set(false, forKey: UpdateController.automaticKey)
    net.urls = []
    let disabled = make(net: net, defaults: off)
    disabled.checkAutomatically()
    await disabled.checkTask?.value
    #expect(net.urls.isEmpty)
}

@MainActor @Test func skippedVersionSuppressesAutomaticOnly() async {
    let net = FakeNet()
    let defaults = freshDefaults()
    let coordinator = PromptCoordinator(hasAccess: { true })
    let controller = make(net: net, defaults: defaults, coordinator: coordinator)
    controller.checkAutomatically()
    await controller.checkTask?.value
    guard case .available = controller.state else { Issue.record("no release: \(controller.state)"); return }
    controller.skip()
    #expect(defaults.string(forKey: UpdateController.skippedVersionKey) == "0.3.0")
    #expect(coordinator.sheet == nil)

    // Automatic: suppressed (throttle cleared so the fetch happens).
    defaults.removeObject(forKey: UpdateController.lastCheckKey)
    controller.checkAutomatically()
    await controller.checkTask?.value
    #expect(controller.state == .idle)
    #expect(coordinator.sheet == nil)

    // Manual: shown anyway.
    controller.checkNow()
    #expect(coordinator.sheet == .update)
    await controller.checkTask?.value
    guard case .available(let release) = controller.state else { Issue.record("manual hid it"); return }
    #expect(release.version.description == "0.3.0")
}

@MainActor @Test func manualCheckShowsUpToDateAndErrors() async {
    let net = FakeNet()
    net.json = releaseJSON("v0.2.0")
    let controller = make(net: net)
    controller.checkNow()
    await controller.checkTask?.value
    #expect(controller.state == .upToDate)
    net.json = nil
    controller.checkNow()
    await controller.checkTask?.value
    guard case .failed = controller.state else { Issue.record("no error shown"); return }
}

@MainActor @Test func newerReleaseRequestsSheet() async {
    let net = FakeNet()
    let coordinator = PromptCoordinator(hasAccess: { false })
    coordinator.launch()
    let controller = make(net: net, coordinator: coordinator)
    controller.checkAutomatically()
    await controller.checkTask?.value
    #expect(coordinator.sheet == .fullDiskAccess(granted: false))
    coordinator.continueWithoutAccess()
    #expect(coordinator.sheet == .update)
}

@MainActor @Test func sheetWaitsWhileAnotherSheetIsVisible() async {
    let net = FakeNet()
    let coordinator = PromptCoordinator(hasAccess: { true })
    var otherSheet = true
    let controller = UpdateController(
        currentVersion: "0.2.0", bundleURL: URL(fileURLWithPath: "/Users/x/Maclean.app"), fetch: { try await net.fetch($0) },
        defaults: freshDefaults(), coordinator: coordinator, installer: FakeInstaller(),
        canPresent: { !otherSheet }, presentPoll: .milliseconds(5))
    controller.checkAutomatically()
    await controller.checkTask?.value
    try? await Task.sleep(for: .milliseconds(30))
    #expect(coordinator.sheet == nil)
    otherSheet = false
    for _ in 0..<100 where coordinator.sheet == nil { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(coordinator.sheet == .update)
}

@MainActor @Test func homebrewActionIsBrew() async {
    let cask = Scratch()
    try! FileManager.default.createDirectory(atPath: cask.path + "/maclean", withIntermediateDirectories: true)
    let net = FakeNet()
    let brew = make(net: net, bundleURL: URL(fileURLWithPath: "/Applications/Maclean.app"), caskroomRoots: [cask.path])
    #expect(brew.action == .brew)
    #expect(make(net: net).action == .install)
    // Not the app bundle (`swift run`): never replaced.
    #expect(make(net: net, bundleURL: URL(fileURLWithPath: "/tmp/build/debug")).action == .download)
    // Translocated (run from a quarantined download): a read-only copy, never replaced.
    let translocated = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/1234/d/Maclean.app")
    #expect(make(net: net, bundleURL: translocated).action == .download)

    let locked = make(net: net, writable: false,
                      installPrivileged: { _, _, _, _ in throw AdminRunnerError.cancelled })
    #expect(locked.action == .installWithPassword)
    locked.checkNow()
    await locked.checkTask?.value
    await locked.install()
    #expect(locked.action == .download)
    guard case .available = locked.state else { Issue.record("cancel lost the release: \(locked.state)"); return }
}

@MainActor @Test func installDownloadsAndCallsInstaller() async {
    let net = FakeNet()
    let installer = FakeInstaller()
    let controller = make(net: net, installer: installer)
    controller.checkNow()
    await controller.checkTask?.value
    await controller.install()
    #expect(await installer.calls == 1)
    #expect(net.urls.contains(zipURL) && net.urls.contains(sigURL))
}

/// A cancelled download that finishes late must not touch the newer attempt.
@MainActor @Test func staleDownloadDoesNotClobberNewerAttempt() async {
    let net = FakeNet()
    net.zipPlan = [(.milliseconds(100), true), (.milliseconds(300), false)]
    let installer = FakeInstaller()
    let controller = make(net: net, installer: installer)
    controller.checkNow()
    await controller.checkTask?.value
    let first = Task { await controller.install() }
    for _ in 0..<100 where controller.state != .downloading(0) { await Task.yield() }
    controller.cancel()
    guard case .available = controller.state else { Issue.record("cancel: \(controller.state)"); return }
    let second = Task { await controller.install() }
    await first.value
    #expect(controller.state != .failed("The update couldn't be downloaded. Check your internet connection and try again."))
    await second.value
    #expect(await installer.calls == 1)
    #expect(controller.state == .installing)
}

@MainActor @Test func installRefusedDuringDelete() async {
    let net = FakeNet()
    let installer = FakeInstaller()
    var busy = true
    let controller = make(net: net, installer: installer, busy: { busy })
    controller.checkNow()
    await controller.checkTask?.value
    await controller.install()
    #expect(await installer.calls == 0)
    #expect(controller.notice == "Finish the current delete first.")
    guard case .available = controller.state else { Issue.record("refusal lost the release"); return }
    busy = false
    await controller.install()
    #expect(await installer.calls == 1)
}

// MARK: - The real installer, in a scratch folder with a test key

private struct Fixture {
    let scratch = Scratch()
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    var installed: URL { URL(fileURLWithPath: scratch.path + "/Applications/Maclean.app") }
    var trashDir: URL { URL(fileURLWithPath: scratch.path + "/Trash") }

    init() {
        makeApp(at: installed, id: "org.maclean.Maclean", version: "0.2.0")
        try! FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    func makeApp(at url: URL, id: String, version: String) {
        let contents = url.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A release zip (as `package-release.sh` makes it: `Maclean.app` at the top).
    func zip(id: String = "org.maclean.Maclean", version: String = "0.3.0") -> Data {
        let stage = URL(fileURLWithPath: scratch.path + "/stage-\(UUID().uuidString)")
        makeApp(at: stage.appendingPathComponent("Maclean.app"), id: id, version: version)
        let out = stage.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", stage.appendingPathComponent("Maclean.app").path, out.path]
        try! p.run()
        p.waitUntilExit()
        return try! Data(contentsOf: out)
    }

    func sign(_ data: Data) -> String { try! key.signature(for: data).base64EncodedString() }

    var release: ReleaseInfo { try! ReleaseInfo.parse(releaseJSON()) }

    func installedVersion() -> String? {
        let plist = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    func trashed() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? [] }
}

private final class Relaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func add(_ url: URL) { lock.withLock { _urls.append(url) } }
}

private func installer(_ f: Fixture, relaunches: Relaunches,
                       move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
    -> UpdateInstaller {
    let trashDir = f.trashDir
    return UpdateInstaller(
        publicKeyBase64: f.publicKey,
        trash: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        },
        relaunch: { relaunches.add($0) },
        move: move)
}

@Test func installerRejectsBadSignature() async throws {
    let f = Fixture()
    let relaunches = Relaunches()
    let zip = f.zip()
    let signature = f.sign(zip)
    var tampered = zip
    tampered.append(0)
    await #expect(throws: UpdateInstallError.badSignature) {
        try await installer(f, relaunches: relaunches)
            .install(zip: tampered, signature: signature, release: f.release, replacing: f.installed)
    }
    // The placeholder key never verifies anything.
    let placeholder = UpdateInstaller(trash: { _ in Issue.record("trashed") }, relaunch: { _ in Issue.record("relaunched") })
    await #expect(throws: UpdateInstallError.badSignature) {
        try await placeholder.install(zip: zip, signature: signature, release: f.release, replacing: f.installed)
    }
    #expect(f.installedVersion() == "0.2.0")
    #expect(f.trashed().isEmpty)
    #expect(relaunches.urls.isEmpty)
}

@Test func installerRejectsWrongBundleOrVersion() async throws {
    let f = Fixture()
    let relaunches = Relaunches()
    let other = f.zip(id: "com.example.Other")
    await #expect(throws: UpdateInstallError.wrongBundle) {
        try await installer(f, relaunches: relaunches)
            .install(zip: other, signature: f.sign(other), release: f.release, replacing: f.installed)
    }
    let old = f.zip(version: "0.2.5")
    await #expect(throws: UpdateInstallError.wrongVersion("0.2.5")) {
        try await installer(f, relaunches: relaunches)
            .install(zip: old, signature: f.sign(old), release: f.release, replacing: f.installed)
    }
    let junk = Data("not a zip".utf8)
    await #expect(throws: UpdateInstallError.unpackFailed) {
        try await installer(f, relaunches: relaunches)
            .install(zip: junk, signature: f.sign(junk), release: f.release, replacing: f.installed)
    }
    #expect(f.installedVersion() == "0.2.0")
    #expect(f.trashed().isEmpty)
    #expect(relaunches.urls.isEmpty)
}

@Test func installerSwapsBundle() async throws {
    let f = Fixture()
    let relaunches = Relaunches()
    let zip = f.zip()
    try await installer(f, relaunches: relaunches)
        .install(zip: zip, signature: f.sign(zip), release: f.release, replacing: f.installed)
    #expect(f.installedVersion() == "0.3.0")
    #expect(f.trashed() == ["Maclean.app"])
    let trashedPlist = NSDictionary(contentsOf: f.trashDir.appendingPathComponent("Maclean.app/Contents/Info.plist"))
    #expect(trashedPlist?["CFBundleShortVersionString"] as? String == "0.2.0")
    #expect(relaunches.urls == [f.installed])
    // Nothing left behind next to the app.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: f.installed.deletingLastPathComponent().path)
    #expect(siblings == ["Maclean.app"])
}

/// Moving the new app in fails after leaving a partial copy: the partial item
/// goes and the old app is back at the bundle path.
@Test func swapRollsBackAfterPartialMove() async throws {
    let f = Fixture()
    let relaunches = Relaunches()
    let zip = f.zip()
    let bundlePath = f.installed.path
    let failing = installer(f, relaunches: relaunches, move: { from, to in
        if to.path == bundlePath, from.lastPathComponent == "Maclean.app", !from.path.contains("/old/") {
            try FileManager.default.createDirectory(at: to.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.moveItem(at: from, to: to)
    })
    await #expect(throws: UpdateInstallError.self) {
        try await failing.install(zip: zip, signature: f.sign(zip), release: f.release, replacing: f.installed)
    }
    #expect(f.installedVersion() == "0.2.0")
    #expect(f.trashed().isEmpty)
    #expect(relaunches.urls.isEmpty)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: f.installed.deletingLastPathComponent().path)
    #expect(siblings == ["Maclean.app"])
}

/// When even the restore fails, the error names where the old app is, and it is there.
@Test func rollbackFailureSaysWhereTheOldAppIs() async throws {
    let f = Fixture()
    let relaunches = Relaunches()
    let zip = f.zip()
    let bundlePath = f.installed.path
    let failing = installer(f, relaunches: relaunches, move: { from, to in
        if to.path == bundlePath { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.moveItem(at: from, to: to)
    })
    do {
        try await failing.install(zip: zip, signature: f.sign(zip), release: f.release, replacing: f.installed)
        Issue.record("installed")
    } catch let UpdateInstallError.rollbackFailed(oldPath) {
        let plist = NSDictionary(contentsOfFile: oldPath + "/Contents/Info.plist")
        #expect(plist?["CFBundleShortVersionString"] as? String == "0.2.0")
        #expect(UpdateInstallError.rollbackFailed(oldPath).message.contains(oldPath))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(relaunches.urls.isEmpty)
}

@Test func downloadCap() {
    let mb: Int64 = 1024 * 1024
    #expect(UpdateFetch.limit(expected: -1) == 300 * mb)
    #expect(UpdateFetch.limit(expected: 10 * mb) == 11 * mb)
    #expect(UpdateFetch.limit(expected: 400 * mb) == 300 * mb)
}
