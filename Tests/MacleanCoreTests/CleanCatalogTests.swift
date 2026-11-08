import Foundation
import Testing
@testable import MacleanCore

private let home = "/Users/me"
private func rule(_ path: String) -> CleanRule? {
    CleanEngine.rule(matching: path, in: CleanCatalog.rules, home: home)
}

/// Strings only: nothing here touches the filesystem.
@Suite struct CleanCatalogTests {
    @Test func catalogMatchesSpecRows() throws {
        let cache = try #require(rule("/Users/me/Library/Caches/com.x.y"))
        #expect(cache.category == .appCaches)
        #expect(cache.ageTiers.map(\.days) == [3] && cache.ageTiers.map(\.tier) == [.safe])
        if case .childNameIfBundleID = cache.owner {} else { Issue.record("owner \(cache.owner)") }

        let plain = try #require(rule("/Users/me/Library/Caches/SomeTool"))
        #expect(plain.category == .appCaches && plain.ageTiers.map(\.days) == [7])

        let dd = try #require(rule("/Users/me/Library/Developer/Xcode/DerivedData/P-abc"))
        #expect(dd.category == .developer)
        if case .derivedData = dd.special {} else { Issue.record("special \(dd.special)") }
        #expect(dd.ageTiers.map(\.days) == [14, 0] && dd.ageTiers.map(\.tier) == [.safe, .review])

        let sysLog = try #require(rule("/Library/Logs/x"))
        #expect(sysLog.category == .systemLogs && sysLog.requiresAdmin)

        #expect(rule("/Users/me/.Trash/x")?.category == .trash)
        #expect(rule("/Users/me/Library/Caches/Yarn")?.category == .developer)
        #expect(rule("/Users/me/Library/Caches/com.apple.Safari")?.category == .browsers)
        #expect(rule("/Users/me/Library/Application Support/Google/Chrome/Default/Code Cache")?.category == .browsers)
        #expect(rule("/Users/me/Library/Application Support/Slack/GPUCache")?.category == .appCaches)
        #expect(rule("/Users/me/Library/Containers/com.x.y/Data/Library/Caches/z")?.category == .appCaches)
        #expect(rule("/Users/me/Library/Saved Application State/com.x.y.savedState")?.category == .windowState)
        #expect(rule("/Users/me/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1")?.category
                == .mailAttachments)
        #expect(rule("/Users/me/.m2/repository")?.category == .largeData)
        #expect(rule("/Users/me/Library/Developer/Xcode/iOS DeviceSupport/17.0")?.category == .developer)
        #expect(rule("/Users/me/Downloads/x.dmg")?.category == .oldInstallers)

        let varLog = try #require(rule("/private/var/log/system.log.0.gz"))
        #expect(varLog.category == .systemLogs && varLog.requireNotOpen)
        #expect(rule("/private/var/db/diagnostics/Persist/0001.tracev3")?.category == .systemLogs)
        #expect(rule("/Library/Caches/com.vendor.app")?.category == .systemCaches)
        #expect(rule("/Library/Caches/com.apple.iconservices.store")?.category == .systemCaches)
        #expect(rule("/Library/Caches/com.apple.other") == nil)
        #expect(rule("/Library/LaunchDaemons/com.vendor.helper.plist")?.category == .systemServices)
        #expect(rule("/private/var/folders/ab/cd/T/com.apple.idleassetsd/CFNetworkDownload_x.tmp")?.category
                == .systemCaches)
        // Homebrew partial downloads are excluded.
        #expect(rule("/Users/me/Library/Caches/Homebrew/downloads/x.incomplete") == nil)
        #expect(rule("/Users/me/Library/Caches/Homebrew/downloads/x.tar.gz")?.category == .developer)
    }

    @Test func darwinCacheRowsUseConfstrDir() throws {
        let metal = CleanCatalog.rules.filter { $0.pattern.hasSuffix("/com.apple.metal") }
        #expect(metal.count == 1)
        let r = try #require(metal.first)
        #expect(r.pattern.hasPrefix("/private/var/folders/") && !r.requiresAdmin && r.category == .systemCaches)
        #expect(CleanEngine.rule(matching: r.pattern, in: CleanCatalog.rules, home: home)?.id == r.id)
    }

    @Test func leftoversComeBeforeGenericSweeps() {
        let rules = CleanCatalog.rules
        let leftovers = rules.indices.filter { rules[$0].category == .removedApps }
        let sweeps = rules.indices.filter { [.appCaches, .logs].contains(rules[$0].category) }
        #expect(leftovers.count == 5)
        #expect(!sweeps.isEmpty)
        #expect(leftovers.max()! < sweeps.min()!)
        let windowState = rules.firstIndex { $0.category == .windowState }!
        #expect(leftovers.max()! < windowState && windowState < sweeps.min()!)
    }

    @Test func everySystemRowRequiresAdminExceptDarwinCache() {
        let system = CleanCatalog.rules.filter { $0.pattern.hasPrefix("/") }
        #expect(system.count > 10)
        let userOwned = system.filter { !$0.requiresAdmin }.map { ($0.pattern as NSString).lastPathComponent }
        #expect(userOwned.sorted() == ["com.apple.gpuarchiver", "com.apple.metal", "com.apple.metalfe"])
        #expect(CleanCatalog.rules.filter { $0.pattern.hasPrefix("~") }.allSatisfy { !$0.requiresAdmin })
    }

    @Test func neverOfferedSystemPathsHaveNoRule() {
        for p in ["/Library/Updates/x", "/private/var/db/uuidtext/x", "/private/var/vm/x",
                  "/Library/LaunchDaemons/com.apple.x.plist", "/System/Library/Caches/x", "/usr/local/x",
                  "/Library/Updates", "/macOS Install Data/x", "/private/var/db/diagnostics/x",
                  "/private/var/log/asl", "/Library/PrivilegedHelperTools/com.apple.x"] {
            #expect(rule(p) == nil, "\(p)")
        }
    }

    @Test func infoRowsAreFolderInfo() {
        let info = CleanCatalog.rules.filter { $0.category == .largeData }
        #expect(info.count == 9)
        for r in info {
            if case .folder = r.unit {} else { Issue.record("\(r.id) unit") }
            #expect(r.ageTiers.map(\.days) == [0] && r.ageTiers.map(\.tier) == [.info])
        }
    }

    @Test func idsAreUnique() {
        #expect(Set(CleanCatalog.rules.map(\.id)).count == CleanCatalog.rules.count)
    }
}
