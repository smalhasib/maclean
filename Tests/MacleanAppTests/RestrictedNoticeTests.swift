import Foundation
import Testing
@testable import Maclean

// The banner over a result that has folders it couldn't read.

private func notice(admin: Int = 0, stillNeeds: Int? = nil, privacy: Int = 0,
                    scannedWithAccess: Bool, accessNow: Bool) -> RestrictedNotice {
    RestrictedNotice.make(adminReadable: admin, stillNeedsAccess: stillNeeds, privacy: privacy,
                          scannedWithAccess: scannedWithAccess, accessNow: accessNow)
}

@Test func foldersMacOSBlocksEvenWithAccessOnNeverAskForARelaunch() {
    // The reported bug: access was on for the whole scan, so a relaunch can't open what is left
    // (system data under /Library and /private/var), yet the banner offered "Relaunch" every time.
    #expect(notice(privacy: 12, scannedWithAccess: true, accessNow: true) == .protectedByMacOS(count: 12))
    #expect(notice(privacy: 12, scannedWithAccess: true, accessNow: false) == .protectedByMacOS(count: 12))
}

@Test func accessGrantedAfterTheScanAsksForARelaunch() {
    #expect(notice(privacy: 3, scannedWithAccess: false, accessNow: true) == .relaunch)
}

@Test func noAccessAsksToGrantIt() {
    #expect(notice(privacy: 3, scannedWithAccess: false, accessNow: false) == .grantAccess(count: 3))
}

@Test func foldersAnAdministratorCanOpenOfferThePasswordRead() {
    #expect(notice(admin: 2, privacy: 5, scannedWithAccess: true, accessNow: true) == .readWithAdmin(count: 2))
}

@Test func afterThePasswordReadWhatRemainsCountsPrivacyAndRefusedFolders() {
    #expect(notice(admin: 0, stillNeeds: 2, privacy: 3, scannedWithAccess: true, accessNow: true)
            == .protectedByMacOS(count: 5))
    #expect(notice(admin: 0, stillNeeds: 2, privacy: 3, scannedWithAccess: false, accessNow: false)
            == .grantAccess(count: 5))
}

@Test func nothingBlockedShowsNothing() {
    #expect(notice(scannedWithAccess: true, accessNow: true) == RestrictedNotice.none)
}

@Test @MainActor func aSessionRemembersWhetherTheScanHadAccess() async {
    for access in [true, false] {
        let s = Scratch()
        s.file("a.bin", bytes: 4096)
        let session = ScanSession(rootPath: s.path)
        session.accessProbe = { access }
        session.start()
        while session.isScanning { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.scannedWithAccess == access)
    }
}
