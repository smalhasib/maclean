import Foundation
import os

/// Performance harness (spec §8, §9). With `MACLEAN_TIMINGS=1` in the
/// environment each mark is emitted as an `os_signpost` event (subsystem
/// `org.maclean.Maclean`, category "PointsOfInterest") and as a line on stderr:
/// `[timing] hover 2.41 ms`. Without it, `mark` returns immediately.
///
/// Marks:
/// - `firstFrame`: result model created → first chart frame drawn.
/// - `layout`: computing `SunburstLayout` for a navigation.
/// - `hover`: mouse event timestamp → the frame showing the new highlight.
/// - `frame`: draw time of one animation frame.
/// - `frameInterval`: time between consecutive animation frames.
/// - `listUpdate`: a chart hover's model change → the end of the Core
///   Animation commit that carries the side list's SwiftUI update.
/// - `drillFPS`: frames per second over a whole drill animation (value is fps, not ms).
enum Timings {
    static let enabled: Bool = ProcessInfo.processInfo.environment["MACLEAN_TIMINGS"] == "1"
    private static let log = OSLog(subsystem: "org.maclean.Maclean", category: .pointsOfInterest)

    static func mark(_ name: StaticString, _ ms: Double) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: name, "%{public}.2f", ms)
        let label = "\(name)"
        let line = "[timing] \(label) \(String(format: "%.2f", ms))\(label == "drillFPS" ? " fps" : " ms")\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Marks `name` with the time from `start` to the end of the current run
    /// loop pass, after Core Animation (and SwiftUI with it) has committed:
    /// a one-shot before-waiting observer ordered after CA's commit observer.
    @MainActor static func markAtNextCommit(_ name: StaticString, since start: TimeInterval) {
        guard enabled else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in
            mark(name, (now - start) * 1000)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Monotonic seconds (same clock as `NSEvent.timestamp`).
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
