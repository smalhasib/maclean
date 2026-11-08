import Darwin
import Foundation

/// Finds build leftovers inside project folders (spec §6.5, mole's `purge`)
/// and decides which of them must be kept.
public enum ProjectArtifacts {
    /// `~`-relative folders searched whenever they exist.
    static let namedRoots = ["Projects", "Developer", "Development", "Code", "Work", "dev", "src", "GitHub",
                             "Repos", "Workspace", "www"]
    /// Top-level home folders never searched for markers. Desktop, Documents and
    /// Downloads are TCC-protected: reading them could raise a system dialog, so
    /// they are searched only when added in Settings (R29).
    private static let excludedHomeFolders: Set<String> = ["Library", "Movies", "Music", "Pictures", "Public", "Applications",
                                                           "Desktop", "Documents", "Downloads"]
    private static let maxDepth = 6
    private static let pruned: Set<String> = [".git", "Library", ".Trash"]
    /// `SF_DATALESS`: a cloud-only placeholder.
    private static let dataless: UInt32 = 0x4000_0000

    private static let markerNames: Set<String> = [
        "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pom.xml", "build.gradle",
        "build.gradle.kts", "Gemfile", "composer.json", "pubspec.yaml", "Package.swift", "Makefile", "build.zig", ".git",
    ]

    /// Artifact name → markers one of which must sit beside it; nil = any project marker.
    private static let artifactMarkers: [String: Set<String>?] = {
        var m: [String: Set<String>?] = [:]
        for n in ["node_modules", ".gradle", ".next", ".nuxt", ".svelte-kit", ".angular", ".turbo", ".parcel-cache",
                  ".dart_tool", ".zig-cache", "zig-out", "__pycache__", ".pytest_cache", ".mypy_cache",
                  ".ruff_cache", ".tox", "coverage"] { m[n] = .some(nil) }
        m["target"] = ["Cargo.toml", "pom.xml"]
        m[".build"] = ["Package.swift"]
        for n in ["build", "dist"] { m[n] = ["package.json", "build.gradle", "build.gradle.kts", "pubspec.yaml", "CMakeLists.txt"] }
        m["Pods"] = ["Podfile"]
        for n in [".venv", "venv"] { m[n] = ["pyproject.toml", "requirements.txt"] }
        return m
    }()

    private static func isMarker(_ name: String) -> Bool {
        markerNames.contains(name) || name.hasSuffix(".xcodeproj")
    }

    // MARK: - Search roots

    /// The §6.5 named folders that exist, then top-level home folders with a
    /// marker within depth 2, then `extra`.
    public static func searchRoots(home: String, extra: [String]) -> [String] {
        var roots: [String] = []
        func add(_ p: String) { if !roots.contains(p) { roots.append(p) } }
        for name in namedRoots where isRealDirectory(home + "/" + name) { add(home + "/" + name) }
        if case .success(let names) = CleanEngine.list(home) {
            for name in names.sorted() where !name.hasPrefix(".") && !excludedHomeFolders.contains(name) {
                let path = home + "/" + name
                if isRealDirectory(path), !roots.contains(path), hasMarker(within: path, depth: 2) { add(path) }
            }
        }
        extra.forEach(add)
        return roots
    }

    /// A marker among `dir`'s entries (depth 1) or its subfolders' entries (depth 2).
    private static func hasMarker(within dir: String, depth: Int) -> Bool {
        guard case .success(let names) = CleanEngine.list(dir) else { return false }
        if names.contains(where: isMarker) { return true }
        guard depth > 1 else { return false }
        return names.contains { !pruned.contains($0) && isRealDirectory(dir + "/" + $0) && hasMarker(within: dir + "/" + $0, depth: depth - 1) }
    }

    // MARK: - Finding

    /// Artifacts in project folders at depth 0–6 below each root, outermost only.
    /// Never enters `.git`, `Library`, `.Trash`, symlinks or dataless folders.
    /// Stops early once `deadline` passes.
    public static func find(roots: [String], deadline: ContinuousClock.Instant?) -> [ProjectArtifact] {
        var found: [ProjectArtifact] = []
        var seen: Set<String> = []
        for root in roots { visit(root, depth: 0, deadline: deadline, found: &found, seen: &seen) }
        return found
    }

    private static func visit(_ dir: String, depth: Int, deadline: ContinuousClock.Instant?,
                              found: inout [ProjectArtifact], seen: inout Set<String>) {
        if let deadline, .now >= deadline { return }
        guard case .success(let names) = CleanEngine.list(dir) else { return }
        let present = Set(names)
        let hasAnyMarker = names.contains(where: isMarker)
        for name in names.sorted() {
            let path = dir + "/" + name
            guard isRealDirectory(path, allowDataless: false) else { continue }
            if let need = artifactMarkers[name] {
                let ok = need.map { !$0.isDisjoint(with: present) } ?? hasAnyMarker
                if ok {
                    if seen.insert(path).inserted {
                        found.append(ProjectArtifact(path: path, project: (dir as NSString).lastPathComponent, projectRoot: dir))
                    }
                    continue      // outermost only
                }
            }
            if depth < maxDepth, !pruned.contains(name) {
                visit(path, depth: depth + 1, deadline: deadline, found: &found, seen: &seen)
            }
        }
    }

    private static func isRealDirectory(_ path: String, allowDataless: Bool = true) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        return allowDataless || st.st_flags & dataless == 0
    }

    // MARK: - Keep checks

    /// Why `a` must be kept, in order: it contains a `.git` (or that couldn't be
    /// ruled out in time); it holds git-tracked files (a timeout, a git error or
    /// no real git counts as tracked); a process works inside the project
    /// (`cwds == nil`: unknown, so yes); or it is a `node_modules` edited by hand
    /// (§6.5). `gitInstalled` is asked before running git (see `realGitInstalled`).
    public static func keepReason(_ a: ProjectArtifact, cwds: [String]?,
                                  gitInstalled: () -> Bool = { liveGitInstalled }) -> SkipReason? {
        if containsGit(a.path, deadline: .now + containsGitBudget) { return .containsGit }
        if hasTrackedFiles(a, gitInstalled: gitInstalled) { return .gitTracked }
        guard let cwds else { return .projectInUse }
        if cwds.contains(where: { PathUtil.isInside($0, orEqualTo: a.projectRoot) }) { return .projectInUse }
        if (a.path as NSString).lastPathComponent == "node_modules", locallyPatched(a.path) { return .locallyPatched }
        return nil
    }

    /// How long the `.git` search below one artifact may take.
    static let containsGitBudget: Duration = .seconds(2)

    /// A `.git` anywhere below `dir`. A timeout or a folder that can't be listed
    /// answers true (keep): a repository can't be ruled out.
    static func containsGit(_ dir: String, deadline: ContinuousClock.Instant) -> Bool {
        if .now >= deadline { return true }
        guard case .success(let names) = CleanEngine.list(dir) else { return true }
        if names.contains(".git") { return true }
        return names.contains {
            isRealDirectory(dir + "/" + $0, allowDataless: false) && containsGit(dir + "/" + $0, deadline: deadline)
        }
    }

    /// Install records, one per package manager (npm, yarn, yarn berry, pnpm).
    private static let installRecords = [".package-lock.json", ".yarn-integrity", ".yarn-state.yml", ".modules.yaml"]

    /// No install record, or a file inside a package (down to
    /// `node_modules/@scope/pkg/file`) newer than the oldest record present.
    private static func locallyPatched(_ dir: String) -> Bool {
        var newestRecord: (Int, Int)?
        for name in installRecords {
            var st = stat()
            guard lstat(dir + "/" + name, &st) == 0 else { continue }
            let t = (st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec)
            if newestRecord == nil || t > newestRecord! { newestRecord = t }
        }
        guard let record = newestRecord else { return true }
        return containsNewerFile(dir, than: record, depth: 3)
    }

    /// A regular file newer than `record` within `depth` levels (top-level records excluded).
    private static func containsNewerFile(_ dir: String, than record: (Int, Int), depth: Int) -> Bool {
        guard depth > 0 else { return false }
        guard case .success(let names) = CleanEngine.list(dir) else { return true }
        for name in names where !(depth == 3 && installRecords.contains(name)) {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if (st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec) > record { return true }
            case S_IFDIR:
                if st.st_flags & dataless == 0, containsNewerFile(path, than: record, depth: depth - 1) { return true }
            default: break
            }
        }
        return false
    }

    /// The `git ls-files` argv and environment. A repository we found on disk is
    /// untrusted: its config must not be able to run code (`core.fsmonitor`,
    /// hooks), so config is pinned and the user/system config and `GIT_*`
    /// redirections are dropped.
    static func gitInvocation(root: String, artifact: String, inherited: [String: String])
        -> (arguments: [String], environment: [String: String]) {
        let args = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                    "-c", "core.untrackedCache=false", "-c", "protocol.allow=never", "--literal-pathspecs",
                    "-C", root, "ls-files", "-z", "--", artifact]
        var env = inherited.filter { key, _ in !key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return (args, env)
    }

    private static let gitPath = "/usr/bin/git"
    private static let cltGit = "/Library/Developer/CommandLineTools/usr/bin/git"

    /// Whether a real git is installed, so `/usr/bin/git` (a shim) won't raise
    /// the "install the command line developer tools" dialog (R29): the
    /// developer directory (`xcode-select -p`, nil if it failed) exists, or the
    /// Command Line Tools git does.
    static func realGitInstalled(developerDir: String?, exists: (String) -> Bool) -> Bool {
        if let developerDir, !developerDir.isEmpty, exists(developerDir) { return true }
        return exists(cltGit)
    }

    /// `realGitInstalled` for this Mac, asked once per process.
    public static let liveGitInstalled: Bool = realGitInstalled(developerDir: xcodeSelectPath(), exists: { path in
        var st = stat()
        return stat(path, &st) == 0
    })

    /// `xcode-select -p`'s output, or nil if it didn't exit 0 within 3 s. It never prompts.
    private static func xcodeSelectPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git ls-files` lists something under the artifact. Inside a repository a
    /// timeout, a non-zero exit or a missing (or shim-only) git all answer true
    /// (keep); outside any repository nothing can be tracked.
    private static func hasTrackedFiles(_ a: ProjectArtifact, gitInstalled: () -> Bool) -> Bool {
        guard insideRepository(a.projectRoot) else { return false }
        guard gitInstalled(), FileManager.default.isExecutableFile(atPath: gitPath) else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        let invocation = gitInvocation(root: a.projectRoot, artifact: a.path, inherited: ProcessInfo.processInfo.environment)
        p.arguments = invocation.arguments
        p.environment = invocation.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return true }
        try? out.fileHandleForWriting.close()
        let reader = Reader()
        let readDone = DispatchGroup()
        readDone.enter()
        DispatchQueue.global().async {
            reader.set(out.fileHandleForReading.readDataToEndOfFile())
            readDone.leave()
        }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return true
        }
        readDone.wait()
        return p.terminationStatus != 0 || !reader.data.isEmpty
    }

    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
        func set(_ d: Data) { lock.lock(); _data = d; lock.unlock() }
    }

    /// `dir` or an ancestor has a `.git`.
    private static func insideRepository(_ dir: String) -> Bool {
        var current = dir
        while true {
            var st = stat()
            if lstat(current + "/.git", &st) == 0 { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }
}
