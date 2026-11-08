import AppKit
import CoreServices
import Darwin
import MacleanCore
import os

/// The live system behind Smart Clean (spec §6.3, §6.6): NSWorkspace and
/// LaunchServices for apps, libproc (`ProcessProbes`) for processes. Not unit
/// tested; the manual checklist covers it. Make one per check run: it caches
/// the app-name index and the open-files snapshot.
struct LiveCleanProbes: CleanProbes {
    let home: String
    /// App name → bundle id for `.app` bundles in the install roots, built on first use.
    private let appNames = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
    /// One open-files snapshot per probe instance (one check run); `.some(nil)` = it failed.
    private let openSnapshot = OSAllocatedUnfairLock<[String]??>(initialState: nil)

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    var now: Date { Date() }

    /// Exact match, or a running app whose id has `bundleID.` as a prefix (helpers).
    func isRunning(bundleID: String) -> Bool? {
        runningBundleIDs().contains { $0 == bundleID || $0.hasPrefix(bundleID + ".") }
    }

    func isOpen(path: String) -> Bool? {
        let snapshot = openSnapshot.withLock { cached in
            if let cached { return cached }
            let taken = ProcessProbes.openPaths()
            cached = .some(taken)
            return taken
        }
        return snapshot.map { ProcessProbes.pathsOpen(under: path, in: $0) }
    }

    func isProcessRunning(name: String) -> Bool? { ProcessProbes.processNames()?.contains(name) }

    /// A bundle-id folder whose app LaunchServices knows, else an installed or
    /// running app with the folder's name.
    func bundleID(appSupportFolder: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: appSupportFolder) != nil
            || launchServicesKnows(appSupportFolder) {
            return appSupportFolder
        }
        let names = appNames.withLock { cached in
            if let cached { return cached }
            var map: [String: String] = [:]
            for app in InstalledApps.apps(searchRoots: InstalledApps.defaultSearchRoots(home: home)) ?? []
            where map[app.name] == nil {
                map[app.name] = app.bundleID
            }
            cached = map
            return map
        }
        if let id = names[appSupportFolder] { return id }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == appSupportFolder }?.bundleIdentifier
    }

    /// Bundles in the install roots, plus running apps, plus every candidate id
    /// LaunchServices has an app for (on any volume), plus user LaunchAgent labels.
    func installedBundleIDs() -> Set<String>? {
        var extra = Set(runningBundleIDs())
        extra.formUnion(candidateIDs().filter(launchServicesKnows))
        extra.formUnion(launchAgentLabels())
        return InstalledApps.bundleIDs(searchRoots: InstalledApps.defaultSearchRoots(home: home), extra: extra)
    }

    func projectArtifacts(roots: [String]) -> [ProjectArtifact] {
        ProjectArtifacts.find(roots: roots, deadline: .now + .seconds(10))
    }

    func workingDirectories() -> [String]? { ProcessProbes.workingDirectories() }

    func securityToolInstalled() -> Bool {
        CleanCatalog.securityToolFolders.contains { path in
            var st = stat()
            return lstat(path, &st) == 0
        }
    }

    // MARK: - Helpers

    private func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    private func launchServicesKnows(_ bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue()
        else { return false }
        return CFArrayGetCount(urls) > 0
    }

    /// LaunchServices can't list every app, so it is asked about each id a
    /// leftover or helper rule could offer: the bundle-id names in the leftover
    /// folders and the owners of the privileged helpers.
    private func candidateIDs() -> Set<String> {
        let fm = FileManager.default
        var ids: Set<String> = []
        for folder in ["Caches", "Logs", "Containers", "Application Support", "Saved Application State"] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(home)/Library/\(folder)")) ?? [] {
                let id = name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name
                if id.split(separator: ".").count >= 3 { ids.insert(id) }
            }
        }
        let helpers = "/Library/PrivilegedHelperTools"
        for name in (try? fm.contentsOfDirectory(atPath: helpers)) ?? [] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(helpers)/\(name)"), options: .mappedIfSafe)
            else { continue }
            ids.formUnion(CleanEngine.helperOwnerIDs(data))
        }
        return ids
    }

    /// `Label` of every `~/Library/LaunchAgents/*.plist`.
    private func launchAgentLabels() -> [String] {
        let dir = "\(home)/Library/LaunchAgents"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            name.hasSuffix(".plist") ? PlistReader.string("Label", atPath: "\(dir)/\(name)") : nil
        }
    }
}
