import Darwin
import Foundation
import os

/// Measures the PRD 7.1 timing targets on a real device: shortcut trigger → editor
/// interactive, and Save tap → saved. Intervals appear under Points of Interest in
/// Instruments; each end is also logged with milliseconds so a Console filter on
/// subsystem `com.seednote.app`, category `Performance`, is enough for manual runs.
/// Only timings and entry types are recorded, never note content.
enum PerfTrace {
    private static let signposter = OSSignposter(subsystem: "com.seednote.app", category: .pointsOfInterest)
    private static let logger = Logger(subsystem: "com.seednote.app", category: "Performance")

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let label: String
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start: ContinuousClock.Instant
    }

    static func begin(_ name: StaticString, _ label: String) -> Interval {
        Interval(name: name, label: label, state: signposter.beginInterval(name, id: signposter.makeSignpostID()), start: .now)
    }

    static func end(_ interval: Interval, outcome: String = "done") {
        signposter.endInterval(interval.name, interval.state)
        let elapsed = interval.start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        var message = "\(interval.label) \(outcome) in \(Int(milliseconds.rounded())) ms"
        if let sinceLaunch = millisecondsSinceProcessStart() {
            message += " · \(sinceLaunch) ms since process start"
        }
        logger.notice("\(message, privacy: .public)")
    }

    /// Time since the kernel started this process. Close to the trigger time on a cold
    /// start; large on a warm start, which tells the two cases apart.
    private static func millisecondsSinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Int(((Date().timeIntervalSince1970 - started) * 1_000).rounded())
    }
}
