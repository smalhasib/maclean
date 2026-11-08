import Foundation
import Testing
@testable import Maclean

/// The start screen's disk rows follow real free space. Writes a real 300 MB
/// file in the temp folder, so it needs that much room (it skips below 2 GB free).
@Suite struct StartModelTests {
    @MainActor private func startupFree(_ model: StartModel) -> Int64? {
        model.volumes.first { $0.entry.scanPath == "/" }?.capacity?.freeIncludingPurgeable
    }

    /// Polls the main actor until `condition` holds or `seconds` pass.
    @MainActor private func wait(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test @MainActor func freeSpaceFollowsADelete() async throws {
        let model = StartModel(defaults: UserDefaults(suiteName: "start-\(UUID().uuidString)")!)
        let loaded = await wait(seconds: 10) { startupFree(model) != nil }
        try #require(loaded, "startup disk never listed")
        let baseline = try #require(startupFree(model))
        try #require(baseline > 2_000_000_000, "not enough free space to run")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("start-model-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let size: Int64 = 300_000_000
        try Data(count: Int(size)).write(to: file)
        model.refresh()
        let dropped = await wait(seconds: 10) { (startupFree(model) ?? baseline) < baseline - size / 2 }
        try #require(dropped, "free space didn't drop after writing the file")

        try FileManager.default.removeItem(at: file)
        NotificationCenter.default.post(name: .macleanDidDelete, object: nil)
        let recovered = await wait(seconds: 10) { (startupFree(model) ?? 0) > baseline - size / 2 }
        #expect(recovered, "the start screen still shows the old free space after a delete")
    }
}
