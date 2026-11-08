import Darwin
import Foundation

/// Finds build leftovers inside project folders (spec §6.5, mole's `purge`)
/// and decides which of them must be kept.
public enum ProjectArtifacts {
    /// `~`-relative folders searched whenever they exist.
    static let namedRoots = ["Projects", "Developer", "Development", "Code", "Work", "dev", "src", "GitHub",
                             "Repos", "Workspace", "www"]
    /// Top-level home folders never searched for markers.
    private static let excludedHomeFolders: Set<String> = ["Library", "Movies", "Music", "Pictures", "Public", "Applications"]
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

    /// Why `a` must be kept, in order: it contains a `.git`; it holds git-tracked
    /// files (a timeout or git error counts as tracked); a process works inside
    /// the project (`cwds == nil`: unknown, so yes); or it is a `node_modules`
    /// edited by hand (§6.5).
    public static func keepReason(_ a: ProjectArtifact, cwds: [String]?) -> SkipReason? {
        if containsGit(a.path) { return .containsGit }
        if hasTrackedFiles(a) { return .gitTracked }
        guard let cwds else { return .projectInUse }
        if cwds.contains(where: { PathUtil.isInside($0, orEqualTo: a.projectRoot) }) { return .projectInUse }
        if (a.path as NSString).lastPathComponent == "node_modules", locallyPatched(a.path) { return .locallyPatched }
        return nil
    }

    private static func containsGit(_ dir: String) -> Bool {
        guard case .success(let names) = CleanEngine.list(dir) else { return false }
        if names.contains(".git") { return true }
        return names.contains { isRealDirectory(dir + "/" + $0) && containsGit(dir + "/" + $0) }
    }

    /// `.package-lock.json` missing, or older than a file directly inside `node_modules`.
    private static func locallyPatched(_ dir: String) -> Bool {
        var lock = stat()
        guard lstat(dir + "/.package-lock.json", &lock) == 0 else { return true }
        guard case .success(let names) = CleanEngine.list(dir) else { return true }
        return names.contains { name in
            var st = stat()
            guard name != ".package-lock.json", lstat(dir + "/" + name, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
            return (st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec) > (lock.st_mtimespec.tv_sec, lock.st_mtimespec.tv_nsec)
        }
    }

    private static let gitPath = "/usr/bin/git"

    /// `git ls-files` lists something under the artifact. Inside a repository a
    /// timeout, a non-zero exit or a missing git all answer true (keep); outside
    /// any repository nothing can be tracked.
    private static func hasTrackedFiles(_ a: ProjectArtifact) -> Bool {
        guard insideRepository(a.projectRoot) else { return false }
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["-C", a.projectRoot, "ls-files", "-z", "--", a.path]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
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
