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

// MARK: - Smart Clean context

/// A fake home inside a TempDir (so every ancestor exists and is a real directory).
private struct SmartFixture {
    let t = TempDir()
    var home: String { t.url("home") }
    func env(neverClean: [String] = []) -> ProtectionEnvironment {
        ProtectionEnvironment(home: home, appBundle: "/Applications/Maclean.app",
                              mountPoints: ["/"], timeMachineMounts: [], neverClean: neverClean)
    }
    /// Creates `home/<rel>` and returns its path.
    @discardableResult func make(_ rel: String) -> String { t.dir("home/" + rel); return home + "/" + rel }
    func check(_ path: String, _ e: ProtectionEnvironment? = nil) -> Refusal? {
        ProtectionRules.refusal(for: path, context: .smartClean, in: e ?? env())
    }
}

/// Corpus entries Smart Clean does not refuse by rule: user-installed software
/// outside the sealed volume, which the catalog never targets anyway.
private let smartCleanUnruled: Set<String> = ["/usr/local/lib", "/usr/local/bin/brew"]

@Test func smartCleanRefusesEveryCorpusEntry() throws {
    for p in try corpus() where !smartCleanUnruled.contains(p) {
        #expect(ProtectionRules.refusal(for: p, context: .smartClean, in: env) != nil,
                "should be refused: \(p.debugDescription)")
    }
}

@Test func smartCleanAllowsCatalogShapes() {
    let f = SmartFixture()
    f.make("Library/Caches/com.example.app"); f.make("Library/Logs/x"); f.make("Library/Caches/com.apple.Safari")
    for rel in ["Library/Caches/com.example.app", "Library/Logs/x", "Library/Caches/com.apple.Safari"] {
        #expect(f.check(f.home + "/" + rel) == nil, "\(rel)")
    }
    #expect(f.check("/Library/Logs/DiagnosticReports/a.ips") == nil)
}

@Test func criticalRootsRefusedChildrenAllowed() {
    let f = SmartFixture()
    f.make("Library/Caches/foo"); f.make("Library/Containers"); f.make("Library/Application Support")
    f.make("Library/Logs"); f.make("Library/Developer")
    for rel in ["Library", "Library/Caches", "Library/Containers", "Library/Application Support",
                "Library/Logs", "Library/Developer"] {
        #expect(f.check(f.home + "/" + rel) == .criticalRoot, "\(rel)")
    }
    #expect(f.check(f.home + "/Library/Caches/foo") == nil)
    for p in ["/Applications", "/Users", "/Users/anyone", "/Users/Shared", "/Volumes", "/opt/homebrew",
              "/Library/Caches", "/Library/Logs", "/private/var/log", "/etc", "/private/etc", "/private/var/db"] {
        #expect(ProtectionRules.refusal(for: p, context: .smartClean, in: env) != nil, "\(p)")
    }
}

@Test func neverCleanCoversAncestorsAndDescendants() {
    let f = SmartFixture()
    f.make("Library/Caches/A/b/c"); f.make("Library/Caches/B")
    let e = f.env(neverClean: ["~/Library/Caches/a/B"])
    let c = f.home + "/Library/Caches"
    #expect(f.check(c + "/A", e) == .neverClean)
    #expect(f.check(c + "/A/b", e) == .neverClean)
    #expect(f.check(c + "/A/b/c", e) == .neverClean)
    #expect(f.check(c + "/B", e) == nil)
    let e2 = f.env(neverClean: ["~/Library/Caches/A/b"])
    #expect(f.check(c + "/A", e2) == .neverClean)
    #expect(f.check(c + "/A/b/c", e2) == .neverClean)
    #expect(f.check(c + "/B", e2) == nil)
    #expect(f.check(c + "/B", f.env()) == nil)
}

@Test func collectorIgnoresNeverClean() {
    let f = SmartFixture()
    let e = f.env(neverClean: ["~/Library/Caches"])
    #expect(ProtectionRules.refusal(for: f.home + "/Library/Caches/x", in: e) == nil)
}

@Test func symlinkedAncestorRefused() {
    let f = SmartFixture()
    f.make("Library")
    f.t.symlink("home/Library/Caches", to: "/")
    #expect(f.check(f.home + "/Library/Caches/System") != nil)
    // A symlink to an innocuous directory is still refused.
    f.make("real/x")
    f.t.symlink("home/link", to: f.home + "/real")
    #expect(f.check(f.home + "/link/x") != nil)
    // A symlink at the leaf is fine: the deleter removes the link itself.
    f.t.symlink("home/real/leaf", to: "/")
    #expect(f.check(f.home + "/real/leaf") == nil)
}

@Test func appleComponentsNeedAllowlist() {
    let f = SmartFixture()
    for n in ["com.apple.Safari", "com.apple.WebKit.Networking", "com.apple.bird", "GeoServices", "com.apple.dt.Xcode",
              "com.apple.iconservices.store"] { f.make("Library/Caches/" + n) }
    let c = f.home + "/Library/Caches/"
    for ok in ["com.apple.Safari", "com.apple.WebKit.Networking", "GeoServices", "com.apple.dt.Xcode",
               "com.apple.iconservices.store"] { #expect(f.check(c + ok) == nil, "\(ok)") }
    #expect(f.check(c + "com.apple.bird") == .appleSystem)
    #expect(f.check(c + "COM.APPLE.BIRD") == .appleSystem)
    #expect(ProtectionRules.appleAllowlist.contains("com.apple.WebKit.*"))
    for n in ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver", "com.apple.idleassetsd"] {
        #expect(ProtectionRules.appleAllowlist.contains(n), "\(n)")
    }
}

@Test func appleMailOnlyForMailDownloads() {
    let f = SmartFixture()
    f.make("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/x")
    f.make("Library/Containers/com.apple.mail/Data/Documents")
    let m = f.home + "/Library/Containers/com.apple.mail"
    #expect(f.check(m + "/Data/Library/Mail Downloads/x") == nil)
    #expect(f.check(m + "/Data/Library/Mail Downloads") == nil)
    #expect(f.check(m + "/Data/Documents") == .appleSystem)
    #expect(f.check(m) == .appleSystem)
}

@Test func protectedAppRefused() {
    let f = SmartFixture()
    f.make("Library/Caches/com.1password.1password"); f.make("Library/Caches/com.example.app")
    #expect(f.check(f.home + "/Library/Caches/com.1password.1password") == .protectedApp)
    #expect(f.check(f.home + "/Library/Caches/com.example.app") == nil)
    #expect(ProtectionRules.protectedBundlePrefixes.contains("com.1password"))
}

@Test func personalDataRefused() {
    let f = SmartFixture()
    for rel in ["Library/Mail/V10", "Library/Keychains", "Library/Messages/Attachments", "Library/Calendars",
                "Library/Mobile Documents", "Pictures/X.photoslibrary/database", "Library/Safari/LocalStorage",
                "Library/Application Support/Google/Chrome/Default/History",
                "Library/Application Support/Google/Chrome/Default/Cache",
                "Library/Application Support/Google/Chrome/Default/Code Cache/js",
                "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"] { f.make(rel) }
    f.make("Library/Safari"); f.t.file("home/Library/Safari/History.db")
    for rel in ["Library/Mail/V10", "Library/Keychains", "Library/Messages/Attachments", "Library/Calendars",
                "Library/Mobile Documents", "Pictures/X.photoslibrary/database", "Library/Safari/LocalStorage",
                "Library/Safari/History.db", "Library/Application Support/Google/Chrome/Default/History"] {
        #expect(f.check(f.home + "/" + rel) == .personalData, "\(rel)")
    }
    let chrome = f.home + "/Library/Application Support/Google/Chrome/Default"
    #expect(f.check(chrome + "/Cache") == nil)
    #expect(f.check(chrome + "/Code Cache/js") == nil)
    #expect(f.check(f.home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads") == nil)
}

@Test func privateIsRefusedOutsideAllowlist() {
    #expect(ProtectionRules.refusal(for: "/private/var/db/uuidtext/x", context: .smartClean, in: env) != nil)
    #expect(ProtectionRules.refusal(for: "/tmp/x", context: .smartClean, in: env) == .criticalRoot)
    #expect(ProtectionRules.refusal(for: "/var/tmp/x", context: .smartClean, in: env) == .criticalRoot)
    // The test machine's own user folder is allowed in both spellings.
    let f = SmartFixture()                               // lives under the user's $TMPDIR
    f.make("Library/Caches/com.example.app")
    #expect(f.check(f.home + "/Library/Caches/com.example.app") == nil)
}

@Test func environmentDecodesWithoutNeverClean() throws {
    let json = #"{"home":"/Users/me","appBundle":"/A.app","mountPoints":["/"],"timeMachineMounts":[]}"#
    let e = try JSONDecoder().decode(ProtectionEnvironment.self, from: Data(json.utf8))
    #expect(e.neverClean == [])
    let withList = ProtectionEnvironment(home: "/h", appBundle: "/a", mountPoints: [], timeMachineMounts: [],
                                         neverClean: ["~/x"])
    let round = try JSONDecoder().decode(ProtectionEnvironment.self, from: JSONEncoder().encode(withList))
    #expect(round == withList)
}
