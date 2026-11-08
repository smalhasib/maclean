import Foundation
import Testing
@testable import MacleanCore

private func git(_ dir: String, _ args: String...) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir, "-c", "commit.gpgsign=false"] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "git \(args) failed")
}

private func initRepo(_ dir: String) {
    git(dir, "init", "-q")
    git(dir, "config", "user.name", "Test")
    git(dir, "config", "user.email", "test@example.com")
}

private func setMtime(_ path: String, secondsAgo: Double) {
    let t = timeval(tv_sec: Int(Date().timeIntervalSince1970 - secondsAgo), tv_usec: 0)
    var times = [t, t]
    precondition(utimes(path, &times) == 0)
}

private func artifact(_ t: TempDir, _ project: String, _ name: String) -> ProjectArtifact {
    ProjectArtifact(path: t.url("\(project)/\(name)"), project: project, projectRoot: t.url(project))
}

private func found(_ t: TempDir) -> [String] {
    ProjectArtifacts.find(roots: [t.path], deadline: nil).map { $0.path.replacingOccurrences(of: t.path + "/", with: "") }
}

@Suite struct ProjectArtifactsTests {
    @Test func nodeModulesBesidePackageJsonFound() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/node_modules/x/index.js")
        t.file("bare/node_modules/x/index.js")
        let r = ProjectArtifacts.find(roots: [t.path], deadline: nil)
        #expect(r == [ProjectArtifact(path: t.url("app/node_modules"), project: "app", projectRoot: t.url("app"))])
    }

    @Test func targetNeedsCargoOrPom() {
        let t = TempDir()
        t.file("rust/Cargo.toml"); t.dir("rust/target")
        t.file("js/package.json"); t.dir("js/target")
        t.dir("alone/target")
        #expect(found(t) == ["rust/target"])
    }

    @Test func buildNeedsMarker() {
        let t = TempDir()
        t.file("web/package.json"); t.dir("web/build"); t.dir("web/dist")
        t.dir("plain/build")
        t.file("py/pyproject.toml"); t.dir("py/build")
        #expect(found(t) == ["web/build", "web/dist"])
    }

    @Test func outermostOnly() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/node_modules/x/package.json")
        t.dir("app/node_modules/x/node_modules/y")
        #expect(found(t) == ["app/node_modules"])
    }

    @Test func gitTrackedArtifactKept() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js"); t.file("app/node_modules/x.js")
        initRepo(t.url("app"))
        git(t.url("app"), "add", "package.json", "dist/a.js")
        git(t.url("app"), "commit", "-q", "-m", "init")
        #expect(ProjectArtifacts.keepReason(artifact(t, "app", "dist"), cwds: []) == .gitTracked)
        // No install record, so the keep check falls through to the local-patch rule.
        #expect(ProjectArtifacts.keepReason(artifact(t, "app", "node_modules"), cwds: []) == .locallyPatched)
    }

    @Test func untrackedArtifactInRepoNotKept() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js")
        initRepo(t.url("app"))
        git(t.url("app"), "add", "package.json")
        git(t.url("app"), "commit", "-q", "-m", "init")
        #expect(ProjectArtifacts.keepReason(artifact(t, "app", "dist"), cwds: []) == nil)
    }

    @Test func artifactWithGitInsideKept() {
        let t = TempDir()
        t.file("app/package.json"); t.dir("app/node_modules/dep/.git")
        #expect(ProjectArtifacts.keepReason(artifact(t, "app", "node_modules"), cwds: []) == .containsGit)
    }

    @Test func projectInUseKept() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js")
        let a = artifact(t, "app", "dist")
        #expect(ProjectArtifacts.keepReason(a, cwds: [t.url("app/src")]) == .projectInUse)
        #expect(ProjectArtifacts.keepReason(a, cwds: nil) == .projectInUse)
        #expect(ProjectArtifacts.keepReason(a, cwds: [t.url("other")]) == nil)
    }

    @Test func locallyPatchedNodeModulesKept() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/node_modules/x/index.js")
        let a = artifact(t, "app", "node_modules")
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == .locallyPatched)      // no install record
        t.file("app/node_modules/.package-lock.json")
        setMtime(t.url("app/node_modules/.package-lock.json"), secondsAgo: 100)
        setMtime(t.url("app/node_modules/x/index.js"), secondsAgo: 200)
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == nil)
        t.file("app/node_modules/x/index.js", bytes: 1)                           // edited after the install
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == .locallyPatched)
    }

    @Test func scopedPackageFilePatchDetected() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/node_modules/@s/pkg/lib.js")
        t.file("app/node_modules/.package-lock.json")
        setMtime(t.url("app/node_modules/.package-lock.json"), secondsAgo: 100)
        setMtime(t.url("app/node_modules/@s/pkg/lib.js"), secondsAgo: 200)
        let a = artifact(t, "app", "node_modules")
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == nil)
        setMtime(t.url("app/node_modules/@s/pkg/lib.js"), secondsAgo: 10)
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == .locallyPatched)
    }

    @Test func otherInstallRecordsCount() {
        for record in [".yarn-integrity", ".yarn-state.yml", ".modules.yaml"] {
            let t = TempDir()
            t.file("app/package.json"); t.file("app/node_modules/x/index.js")
            t.file("app/node_modules/\(record)")
            setMtime(t.url("app/node_modules/\(record)"), secondsAgo: 100)
            setMtime(t.url("app/node_modules/x/index.js"), secondsAgo: 200)
            #expect(ProjectArtifacts.keepReason(artifact(t, "app", "node_modules"), cwds: []) == nil, "\(record)")
        }
    }

    @Test func gitFailureMeansTracked() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js")
        initRepo(t.url("app"))
        git(t.url("app"), "add", "package.json")
        git(t.url("app"), "commit", "-q", "-m", "init")
        try! Data("garbage".utf8).write(to: URL(fileURLWithPath: t.url("app/.git/index")))
        #expect(ProjectArtifacts.keepReason(artifact(t, "app", "dist"), cwds: []) == .gitTracked)
    }

    @Test func gitInvocationIsHardened() {
        let inherited = ["PATH": "/usr/bin", "GIT_DIR": "/x", "GIT_WORK_TREE": "/y", "GIT_INDEX_FILE": "/z",
                         "GIT_CONFIG": "/c", "GIT_CONFIG_COUNT": "1", "GIT_EXEC_PATH": "/e", "HOME": "/h"]
        let (args, env) = ProjectArtifacts.gitInvocation(root: "/r", artifact: "/r/dist", inherited: inherited)
        let cIndex = args.firstIndex(of: "-C")!
        let before = Array(args[..<cIndex])
        for opt in ["core.fsmonitor=false", "core.hooksPath=/dev/null", "core.untrackedCache=false", "protocol.allow=never"] {
            #expect(before.contains(opt))
        }
        #expect(before.contains("--literal-pathspecs"))
        #expect(Array(args[cIndex...]) == ["-C", "/r", "ls-files", "-z", "--", "/r/dist"])
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_EXEC_PATH"] {
            #expect(env[k] == nil, "\(k)")
        }
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func maliciousRepoConfigDoesNotRunCode() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js")
        initRepo(t.url("app"))
        git(t.url("app"), "add", "package.json", "dist/a.js")
        git(t.url("app"), "commit", "-q", "-m", "init")
        let marker = t.url("marker")
        let script = t.url("hook.sh")
        try! "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: script, atomically: true, encoding: .utf8)
        _ = Darwin.chmod(script, 0o755)
        git(t.url("app"), "config", "core.fsmonitor", script)
        // Control: an unhardened git command does run the script.
        git(t.url("app"), "status")
        #expect(FileManager.default.fileExists(atPath: marker), "control: fsmonitor should fire on plain git status")
        try! FileManager.default.removeItem(atPath: marker)

        let r = ProjectArtifacts.keepReason(artifact(t, "app", "dist"), cwds: [])
        #expect(r == .gitTracked)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func depthLimitSix() {
        let t = TempDir()
        t.file("a/b/c/d/e/f/package.json"); t.dir("a/b/c/d/e/f/node_modules")        // depth 6
        t.file("a/b/c/d/e/f/g/package.json"); t.dir("a/b/c/d/e/f/g/node_modules")    // depth 7
        #expect(found(t) == ["a/b/c/d/e/f/node_modules"])
    }

    @Test func prunesGitLibraryAndTrash() {
        let t = TempDir()
        for p in [".git/x", "Library/x", ".Trash/x"] { t.file("\(p)/package.json"); t.dir("\(p)/node_modules") }
        #expect(found(t).isEmpty)
    }

    @Test func searchRootsDetectMarkerFolders() {
        let t = TempDir()
        t.file("home/stuff/app/package.json")
        t.file("home/Movies/clip/package.json")
        t.file("home/.hidden/app/package.json")
        t.file("home/docs/notes.txt")
        t.dir("home/Work"); t.dir("home/extra")
        let r = ProjectArtifacts.searchRoots(home: t.url("home"), extra: ["/somewhere"])
        #expect(r == [t.url("home/Work"), t.url("home/stuff"), "/somewhere"])
    }

    @Test func searchRootsNeverDiscoverTCCFolders() {
        let t = TempDir()
        for name in ["Desktop", "Documents", "Downloads"] { t.file("home/\(name)/app/package.json") }
        t.file("home/stuff/package.json")
        #expect(ProjectArtifacts.searchRoots(home: t.url("home"), extra: []) == [t.url("home/stuff")])
        // Still searched when added in Settings.
        #expect(ProjectArtifacts.searchRoots(home: t.url("home"), extra: [t.url("home/Documents")])
            == [t.url("home/stuff"), t.url("home/Documents")])
    }

    @Test func gitRunsOnlyWhenRealGitInstalled() {
        let t = TempDir()
        t.file("app/package.json"); t.file("app/dist/a.js")
        initRepo(t.url("app"))
        git(t.url("app"), "add", "package.json")
        git(t.url("app"), "commit", "-q", "-m", "init")
        let a = artifact(t, "app", "dist")
        // No real git (only the shim, which would raise the install dialog): kept as tracked.
        #expect(ProjectArtifacts.keepReason(a, cwds: [], gitInstalled: { false }) == .gitTracked)
        // A real git: it runs and finds nothing tracked.
        #expect(ProjectArtifacts.keepReason(a, cwds: [], gitInstalled: { true }) == nil)
        // Outside any repository git isn't needed.
        let u = TempDir()
        u.file("app/package.json"); u.file("app/dist/a.js")
        #expect(ProjectArtifacts.keepReason(artifact(u, "app", "dist"), cwds: [], gitInstalled: { false }) == nil)
    }

    @Test func realGitDetection() {
        let clt = "/Library/Developer/CommandLineTools/usr/bin/git"
        #expect(ProjectArtifacts.realGitInstalled(developerDir: "/Applications/Xcode.app/Contents/Developer",
                                                  exists: { $0 == "/Applications/Xcode.app/Contents/Developer" }))
        #expect(ProjectArtifacts.realGitInstalled(developerDir: nil, exists: { $0 == clt }))
        // xcode-select failed, or names a folder that's gone, and no CLT git.
        #expect(!ProjectArtifacts.realGitInstalled(developerDir: nil, exists: { _ in false }))
        #expect(!ProjectArtifacts.realGitInstalled(developerDir: "/gone", exists: { _ in false }))
    }

    @Test func containsGitKeepsOnTimeoutOrUnlistable() {
        let t = TempDir()
        t.file("app/dist/a.js")
        #expect(!ProjectArtifacts.containsGit(t.url("app/dist"), deadline: .now + .seconds(2)))
        #expect(ProjectArtifacts.containsGit(t.url("app/dist"), deadline: .now - .seconds(1)))
        #expect(ProjectArtifacts.containsGit(t.url("app/missing"), deadline: .now + .seconds(2)))
    }
}

@Suite struct ProjectArtifactsEngineTests {
    private func run(_ t: TempDir, _ a: [ProjectArtifact], daysOld: Double, cwds: [String]? = [])
        async -> CleanReport {
        t.dir("home")
        let env = ProtectionEnvironment(home: t.url("home"), appBundle: "/Applications/Maclean.app",
                                        mountPoints: ["/"], timeMachineMounts: [], neverClean: [])
        var probes = FakeProbes(now: Date().addingTimeInterval(daysOld * 86400))
        probes.artifacts = a
        probes.cwds = cwds
        let rules = CleanCatalog.rules.filter { $0.id == "dev.projectArtifacts" }
        return await CleanEngine(rules: rules, home: t.url("home"), environment: env, probes: probes).run()
    }

    private func project(_ t: TempDir) -> ProjectArtifact {
        t.file("home/Work/maclean/package.json"); t.file("home/Work/maclean/node_modules/x/i.js", bytes: 100)
        t.file("home/Work/maclean/node_modules/.package-lock.json")
        return ProjectArtifact(path: t.url("home/Work/maclean/node_modules"), project: "maclean",
                               projectRoot: t.url("home/Work/maclean"))
    }

    @Test func ageTiers() async {
        let t = TempDir(); let a = project(t)
        let old = await run(t, [a], daysOld: 40)
        #expect(old.candidates.map(\.tier) == [.safe])
        #expect(old.candidates.first?.displayName == "maclean — node_modules")
        #expect(old.candidates.first?.reason.contains("last touched 40 days ago") == true)
        #expect(old.candidates.first?.category == .projectLeftovers)
        #expect(old.candidates.first?.group == "maclean")
        #expect(await run(t, [a], daysOld: 10).candidates.map(\.tier) == [.review])
        let young = await run(t, [a], daysOld: 3)
        #expect(young.candidates.isEmpty)
        #expect(young.skipped == [SkippedItem(path: a.path, reason: .recent)])
    }

    @Test func youngArtifactSkippedWithoutKeepChecks() async {
        // cwds nil would be .projectInUse, but the age gate comes first.
        let t = TempDir(); let a = project(t)
        let r = await run(t, [a], daysOld: 3, cwds: nil)
        #expect(r.skipped == [SkippedItem(path: a.path, reason: .recent)])
    }

    @Test func keepReasonsBecomeSkipped() async {
        let t = TempDir(); let a = project(t)
        let busy = await run(t, [a], daysOld: 40, cwds: [t.url("home/Work/maclean/src")])
        #expect(busy.skipped == [SkippedItem(path: a.path, reason: .projectInUse)])
        let unknown = await run(t, [a], daysOld: 40, cwds: nil)
        #expect(unknown.skipped.map(\.reason) == [.projectInUse])
    }

    @Test func protectedArtifactNeverOffered() async {
        let t = TempDir(); t.file("home/Work/p/package.json"); t.dir("home/Work/p/node_modules")
        let a = ProjectArtifact(path: t.url("home/Library"), project: "p", projectRoot: t.url("home"))
        t.dir("home/Library")
        let r = await run(t, [a], daysOld: 40)
        #expect(r.candidates.isEmpty)
        #expect(r.skipped == [SkippedItem(path: a.path, reason: .protected(.criticalRoot))], "\(r.skipped)")
    }
}
