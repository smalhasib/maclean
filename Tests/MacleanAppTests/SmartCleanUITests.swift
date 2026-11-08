import AppKit
import Foundation
import Testing
@testable import MacleanCore
import struct MacleanCore.Measurement
@testable import Maclean

// Only the pure copy and selection helpers; the views aren't snapshot-tested.

private func candidate(_ path: String, _ category: CleanRule.Category, size: Int64?,
                       tier: CleanRule.Tier = .safe) -> CleanCandidate {
    let m = size.map {
        Measurement(size: $0, fileCount: 1, newest: Date(), inode: 1, device: 1, isDirectory: true, restricted: false)
    }
    return CleanCandidate(path: path, ruleID: "r", category: category, tier: tier, displayName: path, reason: "",
                          measurement: m, requiresAdmin: false, owner: nil)
}

@Test func cardLineUsesTotalAndTopThree() {
    let report = CleanReport(candidates: [
        candidate("/a", .appCaches, size: 10_000_000_000),
        candidate("/b", .logs, size: 5_000_000_000),
        candidate("/c", .developer, size: 2_000_000_000),
        candidate("/d", .trash, size: 1_000_000_000),
        candidate("/e", .largeData, size: 50_000_000_000, tier: .info),
    ])
    #expect(SmartCleanCopy.cardLine(report) == "18 GB can be cleaned")
    let top = SmartCleanCopy.breakdown(report)
    #expect(top == "App caches, Logs, Developer files")
    #expect(!top.contains("Trash"))
}

@Test func cardLineWithNothingMeasured() {
    #expect(SmartCleanCopy.cardLine(CleanReport()) == "Nothing to clean right now")
}

@Test func alertCopyPermanentAndAdmin() {
    let a = SmartCleanCopy.alert(count: 214, size: 12_100_000_000, mode: .permanent, needsAdmin: true)
    #expect(a.title == "Delete 214 items (12.1 GB)?")
    #expect(a.message.contains("deleted permanently"))
    #expect(a.message.contains("administrator password"))
}

@Test func alertCopyTrash() {
    let a = SmartCleanCopy.alert(count: 1, size: 1_000_000, mode: .trash, needsAdmin: false)
    #expect(a.title == "Delete 1 item (1 MB)?")
    #expect(a.message.contains("moved to the Trash"))
    #expect(!a.message.contains("administrator"))
}

@Test func everySkipReasonHasCopy() {
    let reasons: [SkipReason] = [
        .appRunning("com.google.Chrome"), .inUse, .ownerUnknown, .recent, .protected(.personalData), .noAccess,
        .neverClean, .macOSSystemCache, .installedCheckFailed, .containsGit, .gitTracked, .projectInUse,
        .locallyPatched, .sameOSInstaller, .categoryOff,
    ]
    for r in reasons { #expect(!SmartCleanCopy.skipReason(r).isEmpty) }
    #expect(SmartCleanCopy.skipReason(.noAccess).contains("Full Disk Access"))
    #expect(SmartCleanCopy.skipReason(.appRunning("com.google.Chrome")).contains("Chrome"))
    let refusals: [Refusal] = [.systemProtected, .volumeRoot, .libraryItself, .homeItself, .macleanItself, .timeMachine,
                               .unsafePath, .criticalRoot, .personalData, .neverClean, .protectedApp, .appleSystem]
    for p in refusals { #expect(!SmartCleanCopy.skipReason(.protected(p)).isEmpty) }
}

@Test func everyCategoryHasName() {
    for c in CleanRule.Category.allCases { #expect(!SmartCleanCopy.name(c).isEmpty) }
}

@Test func triStateMixed() {
    #expect(CategoryState.tri(["/a", "/b"], selected: ["/a"]) == .mixed)
    #expect(CategoryState.tri(["/a", "/b"], selected: ["/a", "/b", "/z"]) == .on)
    #expect(CategoryState.tri(["/a", "/b"], selected: ["/z"]) == .off)
    #expect(CategoryState.tri([], selected: ["/a"]) == .off)
}
