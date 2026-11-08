import CryptoKit
import Foundation
import Testing
@testable import MacleanCore

private func releaseJSON(assets: [(String, String)]) -> Data {
    let list = assets.map {
        #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)","size":123,"content_type":"application/zip"}"#
    }.joined(separator: ",")
    return Data(#"""
    {"url":"https://api.github.com/repos/smalhasib/maclean/releases/1","tag_name":"v0.3.0","name":"Maclean 0.3.0",
     "draft":false,"prerelease":false,"body":"- Faster scans\n- Fixes","assets":[\#(list)]}
    """#.utf8)
}

@Test func versionsCompare() {
    #expect(SemanticVersion("0.2.0")! < SemanticVersion("0.3.0")!)
    #expect(SemanticVersion("0.3.0")! < SemanticVersion("0.10.0")!)
    #expect(SemanticVersion("v0.3")! == SemanticVersion("0.3.0")!)
    #expect(SemanticVersion("abc") == nil)
    #expect(SemanticVersion("1.2.3-beta") == nil)
}

@Test func parsesRelease() throws {
    let base = "https://github.com/smalhasib/maclean/releases/download/v0.3.0/"
    let info = try ReleaseInfo.parse(releaseJSON(assets: [
        ("Maclean-0.3.0.zip", base + "Maclean-0.3.0.zip"),
        ("Maclean-0.3.0.zip.sig", base + "Maclean-0.3.0.zip.sig"),
    ]))
    #expect(info.version == SemanticVersion("0.3.0")!)
    #expect(info.notes.contains("Faster scans"))
    #expect(info.zipURL.absoluteString == base + "Maclean-0.3.0.zip")
    #expect(info.signatureURL.absoluteString == base + "Maclean-0.3.0.zip.sig")
}

@Test func releaseWithoutSigRejected() {
    let data = releaseJSON(assets: [("Maclean-0.3.0.zip", "https://example.com/Maclean-0.3.0.zip")])
    #expect(throws: UpdateError.self) { try ReleaseInfo.parse(data) }
    #expect(throws: UpdateError.self) { try ReleaseInfo.parse(Data("{}".utf8)) }
}

@Test func signatureVerifies() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let pub = priv.publicKey.rawRepresentation.base64EncodedString()
    let data = Data("zip bytes".utf8)
    let sig = try priv.signature(for: data).base64EncodedString()
    #expect(UpdateSignature.isValid(data, signatureBase64: sig, publicKeyBase64: pub))
    var bad = data
    bad[0] ^= 0xFF
    #expect(!UpdateSignature.isValid(bad, signatureBase64: sig, publicKeyBase64: pub))
    #expect(!UpdateSignature.isValid(data, signatureBase64: "!!!not base64", publicKeyBase64: pub))
    #expect(!UpdateSignature.isValid(data, signatureBase64: sig, publicKeyBase64: "AAAA"))
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(!UpdateSignature.isValid(data, signatureBase64: sig, publicKeyBase64: other))
}

@Test func homebrewNeedsCaskroomAndPath() {
    let t = TempDir()
    defer { withExtendedLifetime(t) {} }
    t.dir("caskroom/maclean")
    t.dir("emptyroom")
    t.file("fileroom/maclean")
    let roots = [t.url("emptyroom"), t.url("caskroom")]
    #expect(InstallSource.detect(bundlePath: "/Applications/Maclean.app", caskroomRoots: roots) == .homebrew)
    #expect(InstallSource.detect(bundlePath: "/Users/x/Downloads/Maclean.app", caskroomRoots: roots) == .standalone)
    #expect(InstallSource.detect(bundlePath: "/Applications/Maclean.app", caskroomRoots: [t.url("emptyroom")]) == .standalone)
    #expect(InstallSource.detect(bundlePath: "/Applications/Maclean.app", caskroomRoots: [t.url("fileroom")]) == .standalone)
}

@Test func checkThrottle() {
    let now = Date()
    #expect(UpdateCheck.shouldCheck(lastCheck: nil, now: now))
    #expect(!UpdateCheck.shouldCheck(lastCheck: now.addingTimeInterval(-3600), now: now))
    #expect(UpdateCheck.shouldCheck(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
}
