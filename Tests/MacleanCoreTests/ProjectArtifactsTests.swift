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
        // Untracked in a repo: free to go.
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
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == nil)
        t.file("app/node_modules/patched.js")                                     // newer than the record
        #expect(ProjectArtifacts.keepReason(a, cwds: []) == .locallyPatched)
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
        #expect(await run(t, [a], daysOld: 10).candidates.map(\.tier) == [.review])
        let young = await run(t, [a], daysOld: 3)
        #expect(young.candidates.isEmpty)
        #expect(young.skipped == [SkippedItem(path: a.path, reason: .recent)])
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
        let a = ProjectArtifact(path: t.url("home/Library/node_modules"), project: "p", projectRoot: t.url("home/Library"))
        t.dir("home/Library/node_modules")
        let r = await run(t, [a], daysOld: 40)
        #expect(r.candidates.isEmpty)
        #expect(r.skipped.count == 1)
    }
}
