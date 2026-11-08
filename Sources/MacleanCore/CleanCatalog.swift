import Darwin
import Foundation

/// The v1 Smart Clean catalog: every row of spec §6.2 and §6.2a, in §6.2a's
/// rule order (first match wins):
/// 1. protection (in the engine);
/// 2. specific rows: browsers, developer rows (package caches inside
///    `~/Library/Caches` included), Mail Downloads, plus the rows that overlap
///    nothing (info, installers, Trash);
/// 3. leftovers of removed apps;
/// 4. window state;
/// 5. the generic app-cache and log sweeps;
/// then the system-wide rows.
public enum CleanCatalog {
    public static let rules: [CleanRule] =
        browsers + developer + mail + info + installers + trash + leftovers + windowState
            + appCaches + logs + system

    private typealias R = CleanRule

    // MARK: Browsers

    private static let browserCacheDirs = "{*/,}{Cache,Code Cache,GPUCache,ShaderCache}"
    private static let chromium: [(id: String, folder: String, bundle: String)] = [
        ("chrome", "Google/Chrome", "com.google.Chrome"),
        ("edge", "Microsoft Edge", "com.microsoft.edgemac"),
        ("brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"),
        ("arc", "Arc/User Data", "company.thebrowser.Browser"),
        ("vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"),
        ("opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
    ]
    private static let browserReason = "Browser cache, rebuilt automatically"

    private static let browsers: [R] =
        [R(id: "browser.safari", category: .browsers, pattern: "~/Library/Caches/com.apple.Safari", unit: .folder,
           ageTiers: [(0, .safe)], owner: .bundleID("com.apple.Safari"), reason: browserReason)]
        + chromium.flatMap { b in
            // Profile data lives in Application Support; the disk caches also under ~/Library/Caches.
            [("", "~/Library/Application Support"), (".caches", "~/Library/Caches")].map {
                R(id: "browser.\(b.id)\($0.0)", category: .browsers, pattern: "\($0.1)/\(b.folder)/\(browserCacheDirs)",
                  unit: .folder, ageTiers: [(0, .safe)], owner: .bundleID(b.bundle), reason: browserReason)
            }
        }
        + [R(id: "browser.firefox", category: .browsers, pattern: "~/Library/Caches/Firefox/Profiles/*/cache2",
             unit: .folder, ageTiers: [(0, .safe)], owner: .bundleID("org.mozilla.firefox"), reason: browserReason)]

    // MARK: Developer

    private static let packageCaches: [(id: String, pattern: String)] = [
        ("npm", "~/.npm/_cacache"),
        ("yarn", "~/Library/Caches/Yarn"),
        ("pnpm", "~/Library/Caches/pnpm/metadata*"),
        ("pip", "~/Library/Caches/pip"),
        ("pip-xdg", "~/.cache/pip"),
        ("cargo", "~/.cargo/registry/cache"),
        ("rustup", "~/.rustup/downloads"),
        ("swiftpm", "~/Library/Caches/org.swift.swiftpm"),
        ("cocoapods", "~/Library/Caches/CocoaPods"),
        ("xdg-tools", "~/.cache/{typescript,electron,node-gyp}"),
        ("go", "~/go/pkg/mod/cache/download"),
    ]
    private static let packageReason = "Package cache; downloaded again when needed"

    private static let developer: [R] = [
        R(id: "dev.derivedData", category: .developer, pattern: "~/Library/Developer/Xcode/DerivedData",
          unit: .eachChild, ageTiers: [(14, .safe), (0, .review)], owner: .bundleID("com.apple.dt.Xcode"),
          special: .derivedData, reason: "Xcode build data, rebuilt on the next build"),
        R(id: "dev.deviceSupport", category: .developer,
          pattern: "~/Library/Developer/Xcode/{iOS,macOS,watchOS,tvOS,visionOS} DeviceSupport", unit: .eachChild,
          ageTiers: [(0, .review)], special: .keepNewest(2),
          reason: "Device symbols; copied again when that device connects"),
        R(id: "dev.simulatorCaches", category: .developer, pattern: "~/Library/Developer/CoreSimulator/Caches",
          unit: .eachChild, ageTiers: [(0, .safe)], owner: .bundleID("com.apple.iphonesimulator"),
          reason: "Simulator cache, rebuilt automatically"),
        R(id: "dev.simulatorLogs", category: .developer, pattern: "~/Library/Logs/CoreSimulator",
          unit: .eachChild, ageTiers: [(0, .safe)], owner: .bundleID("com.apple.iphonesimulator"),
          reason: "Simulator logs"),
    ] + packageCaches.map {
        R(id: "dev.pkg.\($0.id)", category: .developer, pattern: $0.pattern, unit: .folder,
          ageTiers: [(0, .review)], reason: packageReason)
    } + [
        // `.eachChild`, not the folder: each download is its own item so that partial
        // (`*.incomplete`) downloads, which Homebrew may still be writing, are excluded.
        R(id: "dev.pkg.homebrew", category: .developer, pattern: "~/Library/Caches/Homebrew/downloads",
          unit: .eachChild, ageTiers: [(0, .review)], exclude: ["*.incomplete"], reason: packageReason),
        // The Gradle daemon runs as `java`: any running JVM keeps these.
        R(id: "dev.pkg.gradle", category: .developer, pattern: "~/.gradle/{daemon,workers,notifications}",
          unit: .folder, ageTiers: [(0, .review)], owner: .processName("java"),
          reason: "Gradle daemon files; recreated on the next build"),
        R(id: "dev.projectArtifacts", category: .projectLeftovers, pattern: "", unit: .folder,
          ageTiers: [(30, .safe), (7, .review)], special: .projectArtifacts,
          reason: "Build output, rebuilt on the next build"),
    ]

    // MARK: Mail, info, installers, Trash

    private static let mail: [R] = [
        R(id: "mail.downloads", category: .mailAttachments,
          pattern: "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", unit: .eachChild,
          ageTiers: [(30, .review)], owner: .bundleID("com.apple.mail"),
          reason: "Attachments Mail saved when you opened them; the originals stay in your mail"),
    ]

    private static let info: [R] = [
        ("iosBackups", "~/Library/Application Support/MobileSync/Backup"),
        ("xcodeArchives", "~/Library/Developer/Xcode/Archives"),
        ("docker", "~/Library/Containers/com.docker.docker"),
        ("orbstack", "~/.orbstack"),
        ("maven", "~/.m2/repository"),
        ("gradleCaches", "~/.gradle/caches"),
        ("ollama", "~/.ollama/models"),
        ("lmStudio", "~/.cache/lm-studio"),
        ("simulatorDevices", "~/Library/Developer/CoreSimulator/Devices"),
    ].map {
        R(id: "info.\($0.0)", category: .largeData, pattern: $0.1, unit: .folder, ageTiers: [(0, .info)],
          reason: "Large data Smart Clean doesn't delete; use the map to review it")
    }

    private static let installers: [R] = [
        R(id: "installer.macOS", category: .oldInstallers, pattern: "/Applications/Install macOS*.app",
          unit: .folder, ageTiers: [(14, .review)], requiresAdmin: true, special: .macOSInstaller,
          reason: "Installer for a different macOS version"),
        R(id: "installer.downloads", category: .oldInstallers, pattern: "~/Downloads/*.{dmg,pkg}", unit: .folder,
          ageTiers: [(30, .review)], special: .downloadsInstaller, reason: "Installer image"),
    ]

    /// Each item, grouped under one Trash section by the UI. Always permanent.
    private static let trash: [R] = [
        R(id: "trash", category: .trash, pattern: "~/.Trash", unit: .eachChild, ageTiers: [(0, .review)],
          reason: "In the Trash"),
    ]

    // MARK: Leftovers and window state

    private static let leftoverReason = "Left behind by an app that is no longer installed"
    private static let leftovers: [R] = [
        ("caches", "~/Library/Caches", CleanRule.Unit.eachChild, CleanRule.Owner.childNameIfBundleID),
        ("logs", "~/Library/Logs", .eachChild, .childNameIfBundleID),
        ("savedState", "~/Library/Saved Application State/*.savedState", .folder, .childNameIfBundleID),
        ("containers", "~/Library/Containers", .eachChild, .childNameIfBundleID),
        ("appSupport", "~/Library/Application Support", .eachChild, .none),
    ].map {
        R(id: "leftover.\($0.0)", category: .removedApps, pattern: $0.1, unit: $0.2, ageTiers: [(30, .review)],
          owner: $0.3, special: .removedAppLeftover, reason: leftoverReason)
    }

    /// Claims every `*.savedState`; the owner is the stripped name when it is a bundle id.
    private static let windowState: [R] = [
        R(id: "windowState", category: .windowState, pattern: "~/Library/Saved Application State/*.savedState",
          unit: .folder, ageTiers: [(30, .review)], owner: .childNameIfBundleID,
          reason: "Saved window positions; the app reopens with fresh windows"),
    ]

    // MARK: Generic sweeps

    private static let cacheReason = "Cache, rebuilt automatically"
    private static let appCaches: [R] = [
        R(id: "cache.app", category: .appCaches, pattern: "~/Library/Caches", unit: .eachChild,
          ageTiers: [(3, .safe)], owner: .childNameIfBundleID, reason: cacheReason),
        R(id: "cache.other", category: .appCaches, pattern: "~/Library/Caches", unit: .eachChild,
          ageTiers: [(7, .safe)], reason: cacheReason),
        R(id: "cache.container", category: .appCaches, pattern: "~/Library/Containers/*/Data/Library/Caches",
          unit: .eachChild, ageTiers: [(3, .safe)], owner: .containerBundleID, reason: cacheReason),
        R(id: "cache.electron", category: .appCaches,
          pattern: "~/Library/Application Support/*/{Cache,Code Cache,GPUCache,DawnCache,GrShaderCache,Crashpad/completed}",
          unit: .folder, ageTiers: [(0, .safe)], owner: .appSupportFolder, reason: cacheReason),
    ]

    private static let logReason = "Old log files"
    private static let logs: [R] = [
        R(id: "logs.diagnostics", category: .logs, pattern: "~/Library/Logs/DiagnosticReports", unit: .eachChild,
          ageTiers: [(7, .safe)], reason: "Old crash and diagnostic reports"),
        R(id: "logs.user", category: .logs, pattern: "~/Library/Logs", unit: .eachChild, ageTiers: [(7, .safe)],
          reason: logReason),
    ]

    // MARK: System-wide (§6.2a)

    /// The current user's Darwin cache folder (`…/C`), in its `/private` form.
    private static let darwinCacheDir: String? = {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(Int32(_CS_DARWIN_USER_CACHE_DIR), &buf, buf.count) > 0 else { return nil }
        var dir = String(cString: buf)
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        if dir.hasPrefix("/var/") { dir = "/private" + dir }
        return dir
    }()

    /// EDR/MDM vendor folders (Maclean's own list). While any exists, the Darwin
    /// GPU cache rows are skipped: these tools may watch or rely on those caches.
    public static let securityToolFolders: [String] = [
        "/Library/Application Support/CrowdStrike",
        "/Library/Application Support/JAMF",
        "/Library/Application Support/Microsoft/Defender",
        "/Library/Application Support/SentinelOne",
        "/opt/cisco",
    ]

    private static let system: [R] = [
        R(id: "sys.logs.diagnostics", category: .systemLogs, pattern: "/Library/Logs/DiagnosticReports",
          unit: .eachChild, ageTiers: [(7, .safe)], requiresAdmin: true, reason: "Old crash and diagnostic reports"),
        R(id: "sys.logs", category: .systemLogs, pattern: "/Library/Logs", unit: .eachChild, ageTiers: [(7, .safe)],
          requiresAdmin: true, reason: logReason),
        R(id: "sys.varLog", category: .systemLogs, pattern: "/private/var/log", unit: .eachChild,
          ageTiers: [(7, .safe)], fileFilter: ["*.log", "*.log.*", "*.gz", "*.bz2"], requiresAdmin: true,
          requireNotOpen: true, reason: logReason),
        R(id: "sys.unifiedLog", category: .systemLogs,
          pattern: "/private/var/db/diagnostics/{Persist,Special,HighVolume}", unit: .eachChild,
          ageTiers: [(7, .review)], fileFilter: ["*"], requiresAdmin: true,
          reason: "Older unified log history; Console loses entries older than this"),
        R(id: "sys.memoryViolations", category: .systemLogs,
          pattern: "/private/var/db/reportmemoryexception/MemoryLimitViolations", unit: .eachChild,
          ageTiers: [(30, .safe)], requiresAdmin: true, reason: "Old memory-limit reports"),
        R(id: "sys.cache.iconservices", category: .systemCaches, pattern: "/Library/Caches/com.apple.iconservices.store",
          unit: .folder, ageTiers: [(7, .review)], requiresAdmin: true, reason: "Icon cache, rebuilt automatically"),
        R(id: "sys.cache.app", category: .systemCaches, pattern: "/Library/Caches", unit: .eachChild,
          ageTiers: [(7, .review)], owner: .childNameIfBundleID, exclude: ["com.apple.*"], requiresAdmin: true,
          reason: cacheReason),
        R(id: "sys.cache.other", category: .systemCaches, pattern: "/Library/Caches", unit: .eachChild,
          ageTiers: [(7, .review)], exclude: ["com.apple.*"], requiresAdmin: true, reason: cacheReason),
    ] + (darwinCacheDir.map { dir in
        ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver"].map {
            R(id: "sys.darwin.\($0.dropFirst("com.apple.".count))", category: .systemCaches, pattern: "\(dir)/\($0)",
              unit: .folder, ageTiers: [(1, .safe)], special: .skipIfSecurityTool,
              reason: "Graphics shader cache, rebuilt automatically")
        }
    } ?? []) + [
        R(id: "sys.idleassets", category: .systemCaches,
          pattern: "/private/var/folders/*/*/T/com.apple.idleassetsd/CFNetworkDownload_*.tmp", unit: .folder,
          ageTiers: [(7, .safe)], fileFilter: ["*"], requiresAdmin: true, requireNotOpen: true,
          reason: "Unfinished wallpaper and screen saver download"),
        R(id: "sys.launchDaemons", category: .systemServices, pattern: "/Library/LaunchDaemons/*.plist",
          unit: .folder, ageTiers: [(0, .review)], exclude: ["com.apple.*"], requiresAdmin: true,
          special: .launchdOrphan, reason: "Background service whose program no longer exists"),
        R(id: "sys.launchAgents", category: .systemServices, pattern: "/Library/LaunchAgents/*.plist",
          unit: .folder, ageTiers: [(0, .review)], exclude: ["com.apple.*"], requiresAdmin: true,
          special: .launchdOrphan, reason: "Background service whose program no longer exists"),
        R(id: "sys.helperTools", category: .systemServices, pattern: "/Library/PrivilegedHelperTools",
          unit: .eachChild, ageTiers: [(0, .review)], exclude: ["com.apple.*"], requiresAdmin: true,
          special: .launchdOrphan, reason: "Helper tool of an app that is no longer installed"),
    ]
}
