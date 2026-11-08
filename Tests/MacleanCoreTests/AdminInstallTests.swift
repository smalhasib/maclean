import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacleanCore

/// A fake installed `Maclean.app` in a TempDir, a test key pair and release
/// zips made with `ditto` as `package-release.sh` makes them.
private final class Fixture {
    let t = TempDir()
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    var parent: String { t.url("Apps") }
    var installed: String { t.url("Apps/Maclean.app") }

    init() {
        makeApp(at: installed, id: "org.maclean.Maclean", version: "0.2.0")
    }

    func makeApp(at path: String, id: String, version: String, extra: (String) -> Void = { _ in }) {
        let contents = path + "/Contents"
        try! FileManager.default.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        FileManager.default.createFile(atPath: contents + "/MacOS/Maclean", contents: Data(version.utf8))
        extra(path)
    }

    /// A release zip with `Maclean.app` at the top.
    func zip(id: String = "org.maclean.Maclean", version: String = "0.3.0",
             extra: (String) -> Void = { _ in }) -> Data {
        let stage = t.url("stage-\(UUID().uuidString)")
        makeApp(at: stage + "/Maclean.app", id: id, version: version, extra: extra)
        let out = stage + "/out.zip"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", stage + "/Maclean.app", out]
        try! p.run()
        p.waitUntilExit()
        let data = try! Data(contentsOf: URL(fileURLWithPath: out))
        try! FileManager.default.removeItem(atPath: stage)
        return data
    }

    func sign(_ data: Data) -> String { try! key.signature(for: data).base64EncodedString() }

    /// Writes the zip and signature as 0600 files and returns a request for them.
    func request(zip: Data, signature: String? = nil, version: String = "0.3.0", target: String? = nil,
                 zipSHA: String? = nil) -> AdminInstall.Request {
        let dir = t.url("req-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        let zipPath = dir + "/update.zip", sigPath = dir + "/update.zip.sig"
        let sig = Data((signature ?? sign(zip)).utf8)
        FileManager.default.createFile(atPath: zipPath, contents: zip, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: sigPath, contents: sig, attributes: [.posixPermissions: 0o600])
        return AdminInstall.Request(zip: zipPath, zipSHA256: zipSHA ?? sha(zip), signature: sigPath,
                                    signatureSHA256: sha(sig), version: version, target: target ?? installed)
    }

    func version(at path: String? = nil) -> String? {
        NSDictionary(contentsOfFile: (path ?? installed) + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }

    func parentEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).sorted()
    }
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func perform(_ f: Fixture, _ request: AdminInstall.Request,
                     unzip: @escaping AdminInstall.Unzip = AdminInstall.ditto,
                     renameNew: @escaping AdminInstall.Rename = AdminInstall.renameExclusive)
    -> Result<Void, AdminInstall.InstallError> {
    AdminInstall.perform(request, publicKeyBase64: f.publicKey, unzip: unzip, renameNew: renameNew)
}

private func failure(_ result: Result<Void, AdminInstall.InstallError>) -> AdminInstall.InstallError? {
    if case .failure(let e) = result { return e }
    return nil
}

@Test func installsVerifiedBundle() throws {
    let f = Fixture()
    // A framework-style relative link stays inside the bundle and is allowed.
    let zip = f.zip { app in
        try! FileManager.default.createSymbolicLink(atPath: app + "/Contents/Current", withDestinationPath: "MacOS")
        try! FileManager.default.createSymbolicLink(atPath: app + "/Contents/MacOS/Up",
                                                    withDestinationPath: "../Info.plist")
    }
    let result = perform(f, f.request(zip: zip))
    #expect(failure(result) == nil)
    #expect(f.version() == "0.3.0")
    #expect(try String(contentsOfFile: f.installed + "/Contents/MacOS/Maclean", encoding: .utf8) == "0.3.0")
    // No old copy, no work directory left in the parent.
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func keepsOldOwnerGroupAndMode() {
    let f = Fixture()
    #expect(chmod(f.installed, 0o750) == 0)
    var old = stat()
    lstat(f.installed, &old)
    #expect(failure(perform(f, f.request(zip: f.zip()))) == nil)
    var st = stat()
    lstat(f.installed, &st)
    #expect(st.st_mode & 0o7777 == 0o750)
    #expect(st.st_uid == old.st_uid && st.st_gid == old.st_gid)
}

@Test func rejectsBadSignature() {
    let f = Fixture()
    let zip = f.zip()
    let other = try! Curve25519.Signing.PrivateKey().signature(for: zip).base64EncodedString()
    var unzipped = false
    let result = perform(f, f.request(zip: zip, signature: other), unzip: { _, _, _ in unzipped = true; return true })
    #expect(failure(result) == .badSignature)
    #expect(!unzipped)
    #expect(f.version() == "0.2.0")
    #expect(f.parentEntries() == ["Maclean.app"])
    // The placeholder all-zero key never verifies anything.
    let placeholder = AdminInstall.perform(f.request(zip: zip), publicKeyBase64: UpdateKey.publicKeyBase64,
                                           unzip: AdminInstall.ditto)
    #expect(failure(placeholder) == .badSignature)
    #expect(f.version() == "0.2.0")
}

@Test func rejectsTamperedFiles() {
    let f = Fixture()
    let zip = f.zip()
    var unzipped = false
    let spy: AdminInstall.Unzip = { _, _, _ in unzipped = true; return true }
    // Bytes that don't match the fingerprint in argv.
    let mismatch = f.request(zip: zip, zipSHA: sha(Data("other".utf8)))
    #expect(failure(perform(f, mismatch, unzip: spy)) == .unreadableFiles)
    // A symlink in place of the zip file.
    let good = f.request(zip: zip)
    let link = f.t.url("link.zip")
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: good.zip)
    let viaLink = AdminInstall.Request(zip: link, zipSHA256: good.zipSHA256, signature: good.signature,
                                       signatureSHA256: good.signatureSHA256, version: good.version,
                                       target: good.target)
    #expect(failure(perform(f, viaLink, unzip: spy)) == .unreadableFiles)
    #expect(!unzipped)
    #expect(f.version() == "0.2.0")
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func rejectsWrongBundleIdOrVersion() {
    let f = Fixture()
    #expect(failure(perform(f, f.request(zip: f.zip(id: "com.example.Other")))) == .wrongBundle)
    #expect(failure(perform(f, f.request(zip: f.zip(version: "0.4.0")))) == .wrongVersion)
    #expect(f.version() == "0.2.0")
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func rejectsZipWithoutExactlyOneMacleanApp() {
    let f = Fixture()
    // Two top-level entries: unzip into the out dir and add a stray one.
    let zip = f.zip()
    let extra: AdminInstall.Unzip = { fd, z, out in
        guard AdminInstall.ditto(fd, z, out) else { return false }
        return mkdirat(fd, out + "/Other.app", 0o700) == 0
    }
    #expect(failure(perform(f, f.request(zip: zip), unzip: extra)) == .wrongBundle)
    #expect(failure(perform(f, f.request(zip: zip), unzip: { _, _, _ in false })) == .unpackFailed)
    #expect(f.version() == "0.2.0")
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func rejectsSymlinkLeavingTheBundle() {
    for target in ["/etc", "../../..", "../../../Maclean.app", "MacOS/../../.."] {
        let f = Fixture()
        let zip = f.zip { app in
            try! FileManager.default.createSymbolicLink(atPath: app + "/Contents/Escape", withDestinationPath: target)
        }
        #expect(failure(perform(f, f.request(zip: zip))) == .unsafeBundle, "link to \(target)")
        #expect(f.version() == "0.2.0")
        #expect(f.parentEntries() == ["Maclean.app"])
    }
}

@Test func rejectsTargetThatIsNotMaclean() {
    let f = Fixture()
    let zip = f.zip()
    f.makeApp(at: f.t.url("Apps/Other.app"), id: "com.example.Other", version: "1.0")
    f.t.dir("Apps/Plain.app")
    f.t.dir("Apps/NotAnApp")
    f.makeApp(at: f.t.url("Apps/NotAnApp/Maclean"), id: "org.maclean.Maclean", version: "0.2.0")
    f.t.symlink("Link", to: "Apps")
    f.t.symlink("Apps/Alias.app", to: "Maclean.app")
    // An Info.plist that is a symlink to a real Maclean plist.
    f.t.dir("Apps/Fake.app/Contents")
    f.t.symlink("Apps/Fake.app/Contents/Info.plist", to: f.installed + "/Contents/Info.plist")
    let before = f.parentEntries()
    let targets = [
        f.t.url("Apps/Other.app"), f.t.url("Apps/Plain.app"), f.t.url("Apps/NotAnApp/Maclean"),
        f.t.url("Link/Maclean.app"), f.t.url("Apps/Alias.app"), f.t.url("Apps/Fake.app"),
        f.t.url("Apps/../Apps/Maclean.app"), f.installed + "/", "Apps/Maclean.app", "/", "/.app",
        f.t.url("Apps/Missing.app"),
    ]
    for target in targets {
        let result = perform(f, f.request(zip: zip, target: target))
        #expect(failure(result) == .badTarget, "target \(target)")
    }
    #expect(f.version() == "0.2.0")
    #expect(f.version(at: f.t.url("Apps/Other.app")) == "1.0")
    #expect(f.parentEntries() == before)
}

@Test func restoresOldOnFailedMove() {
    let f = Fixture()
    let failing: AdminInstall.Rename = { _, _, _, _ in
        errno = EIO
        return -1
    }
    let result = perform(f, f.request(zip: f.zip()), renameNew: failing)
    #expect(failure(result) == .swapFailed)
    #expect(f.version() == "0.2.0")
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func rejectsTargetSwappedBeforeTheMove() {
    let f = Fixture()
    // The target is replaced by another directory after it was checked: the
    // rename aside sees a different inode, puts it back and stops.
    let unzip: AdminInstall.Unzip = { fd, z, out in
        try! FileManager.default.moveItem(atPath: f.installed, toPath: f.t.url("moved.app"))
        f.makeApp(at: f.installed, id: "org.maclean.Maclean", version: "9.9.9")
        return AdminInstall.ditto(fd, z, out)
    }
    #expect(failure(perform(f, f.request(zip: f.zip()), unzip: unzip)) == .badTarget)
    #expect(f.version() == "9.9.9")
    #expect(f.parentEntries() == ["Maclean.app"])
}

@Test func installArgumentsRoundTrip() throws {
    let args = AdminInstall.arguments(zip: "/tmp/a.zip", zipSHA256: String(repeating: "a", count: 64),
                                      signature: "/tmp/a.sig", signatureSHA256: String(repeating: "b", count: 64),
                                      version: "0.3.0", target: "/Applications/Maclean.app")
    #expect(args == ["install-update", "--zip", "/tmp/a.zip", "--zip-sha256", String(repeating: "a", count: 64),
                     "--sig", "/tmp/a.sig", "--sig-sha256", String(repeating: "b", count: 64),
                     "--version", "0.3.0", "--target", "/Applications/Maclean.app"])
    let r = try AdminInstall.parse(args)
    #expect(r.zip == "/tmp/a.zip" && r.signature == "/tmp/a.sig" && r.version == "0.3.0")
    #expect(r.target == "/Applications/Maclean.app")
    #expect(throws: (any Error).self) { try AdminInstall.parse(Array(args.dropLast())) }
    var badVersion = args
    badVersion[10] = "latest"
    #expect(throws: (any Error).self) { try AdminInstall.parse(badVersion) }
    var badHash = args
    badHash[4] = "xyz"
    #expect(throws: (any Error).self) { try AdminInstall.parse(badHash) }
}

@Test func installReplyRoundTrip() {
    #expect(AdminInstall.encode(.success(())) == #"{"ok":true}"#)
    #expect(AdminInstall.encode(.failure(.badSignature)) == #"{"error":"badSignature"}"#)
    #expect(failure(AdminInstall.decode(#"{"ok":true}"# + "\n")) == nil)
    #expect(failure(AdminInstall.decode(#"{"error":"badTarget"}"# + "\r")) == .badTarget)
    #expect(failure(AdminInstall.decode("garbage")) == .noReply)
    #expect(failure(AdminInstall.decode(#"{"error":"somethingNew"}"#)) == .noReply)
    for e in AdminInstall.InstallError.allCases { #expect(!e.message.isEmpty) }
}
