import Testing
import Foundation
@testable import MacleanCore

private let env = ProtectionEnvironment(
    home: "/Users/me", appBundle: "/Applications/Maclean.app",
    mountPoints: ["/", "/System/Volumes/Data", "/Volumes/Ext"], timeMachineMounts: ["/Volumes/TM"])

private func refusal(_ p: String) -> Refusal? { ProtectionRules.refusal(for: p, in: env) }

@Test func refusesCollectorProtectedPaths() {
    for p in ["/System", "/System/Library/X", "/usr/bin/ls", "/bin", "/sbin/x", "/Library/Apple/x"] {
        #expect(refusal(p) == .systemProtected, "\(p)")
    }
    #expect(refusal("/") == .volumeRoot)
    #expect(refusal("/Volumes/Ext") == .volumeRoot)
    #expect(refusal("/Library") == .libraryItself)
    #expect(refusal("/Users/me") == .homeItself)
    #expect(refusal("/Applications/Maclean.app") == .macleanItself)
    #expect(refusal("/Applications/Maclean.app/Contents") == .macleanItself)
    #expect(refusal("/Volumes/TM/x") == .timeMachine)
    #expect(refusal("/Volumes/.timemachine/UUID/x") == .timeMachine)
}

@Test func caseVariantsAreRefused() {
    #expect(refusal("/SYSTEM/Library") == .systemProtected)
    #expect(refusal("/users/ME") == .homeItself)
}

@Test func varEtcTmpMatchPrivateForms() {
    #expect(refusal("/var/db/x") == .systemProtected)
    #expect(refusal("/private/var/db/x") == .systemProtected)
    #expect(refusal("/etc/passwd") == .systemProtected)
    #expect(refusal("/var/folders/x") == nil)
    #expect(refusal("/tmp/x") == nil)
}

@Test func allowsContentsDaisyDiskAllows() {
    for p in ["/usr/local/lib", "/Library/Caches", "/Users/me/Library",
              "/Users/me/Pictures/Photos Library.photoslibrary", "/Users/me/Library/Keychains",
              "/Volumes/Ext/x", "/private/var/folders/x"] {
        #expect(refusal(p) == nil, "\(p)")
    }
}

@Test func unsafeShapesRefused() {
    for p in ["relative", "/a/../System", "/a/./b", "/a//b", "/a/\u{1B}b", "/a/b/", "/a/\u{85}b", "/a/\u{7F}b"] {
        #expect(refusal(p) == .unsafePath, "\(p.debugDescription)")
    }
}

@Test func messagesUseExactCopy() {
    #expect(Refusal.systemProtected.message(name: "X") == "“X” is protected by macOS and can't be deleted.")
    #expect(Refusal.macleanItself.message(name: "X") == "Maclean can't delete itself.")
}

/// Corpus entries that the collector deliberately allows: user data or
/// ordinary folders that §5.8 rule 2 and the path shape do not cover, which
/// DaisyDisk also lets you collect. Every other corpus entry must be refused.
private let collectable: [String: String] = [
    "/Users/me/Library": "the user's own Library is ordinary user data",
    "/Users/me/Library/Keychains": "personal data, collectable as in DaisyDisk",
    "/Users/me/Library/Keychains/login.keychain-db": "personal data inside the user's Library",
    "/users/me/library/KEYCHAINS": "case alias of a collectable user path",
    "/Library/Keychains": "shared keychains are data, not protected by rule 2",
    "/Library/Keychains/System.keychain": "data file below a collectable folder",
    "/Users/Guest": "another account's home: data, and the OS enforces its permissions",
    "/Users/other": "another account's home: data, and the OS enforces its permissions",
    "/Users/me/Pictures/Photos Library.photoslibrary": "user data DaisyDisk lets you collect",
    "/Library/Application Support": "a folder of app data; its contents are what users collect",
    "/Library/Caches": "caches are the main reclaimable data",
    "/usr/local/lib": "user-installed software, outside the sealed system volume",
    "/usr/local/bin/brew": "user-installed software",
    "/opt/homebrew": "user-installed Homebrew prefix",
    "/Volumes/Ext/Movies": "content of an external disk; only the disk root is refused",
    "/private/var/folders/zz/abc/T": "per-user temp data below the folders container",
    "/tmp/scratch": "temp data below /private/tmp",
    "/var/tmp/scratch": "temp data below /private/var/tmp",
]

private func corpus() throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: "dangerous_paths", withExtension: "txt",
                                             subdirectory: "Resources"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }.map(decode)
}

/// Turns `\u{XX}` escapes into scalars.
private func decode(_ line: String) -> String {
    var out = "", rest = Substring(line)
    while let r = rest.range(of: "\\u{") {
        out += rest[..<r.lowerBound]
        let tail = rest[r.upperBound...]
        guard let end = tail.firstIndex(of: "}"), let v = UInt32(tail[..<end], radix: 16),
              let s = Unicode.Scalar(v) else { return line }
        out.unicodeScalars.append(s)
        rest = tail[tail.index(after: end)...]
    }
    return out + rest
}

@Test func dangerousCorpusIsRefusedExceptListedCollectables() throws {
    let lines = try corpus()
    #expect(lines.count >= 100)
    for allowed in collectable.keys { #expect(lines.contains(allowed), "not in corpus: \(allowed)") }
    for p in lines where collectable[p] == nil {
        #expect(refusal(p) != nil, "should be refused: \(p.debugDescription)")
    }
    for p in lines where collectable[p] != nil {
        #expect(refusal(p) == nil, "should be collectable: \(p)")
    }
}

private func env(home: String = "/Users/me", app: String = "/Applications/Maclean.app") -> ProtectionEnvironment {
    ProtectionEnvironment(home: home, appBundle: app, mountPoints: ["/"], timeMachineMounts: [])
}

@Test func ancestorsOfAppAndHomeAreRefused() {
    // Maclean is checked first: an app inside the home folder wins for its own ancestors.
    let e = env(app: "/Users/me/Downloads/Maclean.app")
    #expect(ProtectionRules.refusal(for: "/Users/me/Downloads", in: e) == .macleanItself)
    #expect(ProtectionRules.refusal(for: "/Users/me/Downloads/Maclean.app/Contents", in: e) == .macleanItself)
    #expect(ProtectionRules.refusal(for: "/Users/me", in: e) == .macleanItself)
    #expect(ProtectionRules.refusal(for: "/Users/me/Documents", in: e) == nil)

    let h = env(home: "/Volumes/X/home/me")
    #expect(ProtectionRules.refusal(for: "/Volumes/X/home", in: h) == .homeItself)
    #expect(ProtectionRules.refusal(for: "/Volumes/X/home/me", in: h) == .homeItself)
    #expect(ProtectionRules.refusal(for: "/Volumes/X/home/me/Documents", in: h) == nil)
}

@Test func emptyOrRootHomeAndAppAreIgnored() {
    for bad in ["", "/"] {
        let e = env(home: bad, app: bad)
        #expect(ProtectionRules.refusal(for: "/Users/x/Documents", in: e) == nil, "\(bad)")
    }
}

@Test func usrLocalItselfIsCollectable() {
    #expect(refusal("/usr/local") == nil)
    #expect(refusal("/usr/local/lib") == nil)
    #expect(refusal("/usr/share") == .systemProtected)
}

@Test func unicodeEquivalentNamesCompareEqual() {
    let nfd = "/Users/Jose\u{301}"          // "José" decomposed
    let nfc = "/Users/Jos\u{E9}"            // composed
    #expect(ProtectionRules.refusal(for: nfc, in: env(home: nfd)) == .homeItself)
    #expect(ProtectionRules.refusal(for: nfd, in: env(home: nfc)) == .homeItself)
    #expect(ProtectionRules.refusal(for: nfd + "/Documents", in: env(home: nfc)) == nil)
}

@Test func dataVolumeAliasKeepsRootVerdict() {
    #expect(refusal("/System/Volumes/Data/Users/me") == .homeItself)
    #expect(refusal("/System/Volumes/Data/Users/me/Documents") == nil)
    #expect(refusal("/System/Volumes/Data/System/Library") == .systemProtected)
}
