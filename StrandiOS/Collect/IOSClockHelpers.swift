import Foundation
import WhoopProtocol
import WhoopStore

enum IOSClockCorrelation {
    static func clockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
        guard parsed.ok, parsed.crcOK != false,
              let device = parsed.parsed["clock"]?.intValue else { return nil }
        return ClockRef(device: device, wall: wall)
    }
}

enum IOSClockPolicy {
    static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = 2) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }
}

struct IOSRawCaptureWindow {
    static let minSeconds: TimeInterval = 1
    static let maxSeconds: TimeInterval = 300
    static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minSeconds), maxSeconds)
    }

    private var deadline: TimeInterval?

    func isActive(at time: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return time <= deadline
    }

    mutating func open(at time: TimeInterval, duration: TimeInterval) {
        deadline = time + Self.clamp(duration)
    }

    mutating func close() {
        deadline = nil
    }
}

enum IOSPrunePolicy {
    static let keepWindowSeconds = 24 * 3600
    static let maxUnsyncedBytes = 50 * 1024 * 1024
}
