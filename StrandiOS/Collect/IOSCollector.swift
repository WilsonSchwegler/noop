import Foundation
import WhoopProtocol
import WhoopStore

protocol IOSStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}

extension WhoopStore: IOSStoreWriting {}

struct IOSCollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    var maxPreClockFrames: Int

    static let `default` = IOSCollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

@MainActor
final class IOSCollector {
    private let store: IOSStoreWriting
    private let concreteStore: WhoopStore?
    private let deviceId: String
    private let policy: IOSCollectorPolicy
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval
    private let onStoreFlush: () -> Void

    var clockRef: ClockRef?

    private var rawCapture = IOSRawCaptureWindow()
    private var buffer: [[UInt8]] = []
    private var standardHR: [HRSample] = []
    private var standardRR: [RRInterval] = []
    private var batchStartedAt: TimeInterval
    private var standardBatchStartedAt: TimeInterval

    init(store: IOSStoreWriting,
         deviceId: String,
         policy: IOSCollectorPolicy = .default,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         onStoreFlush: @escaping () -> Void = {}) {
        self.store = store
        self.concreteStore = store as? WhoopStore
        self.deviceId = deviceId
        self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.now = now
        self.monotonic = monotonic
        self.onStoreFlush = onStoreFlush
        self.batchStartedAt = monotonic()
        self.standardBatchStartedAt = self.batchStartedAt
    }

    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let concreteStore else { return nil }
        return try? await concreteStore.storageStats()
    }

    func latestHRSampleTs() async -> Int? {
        guard let concreteStore else { return nil }
        return try? await concreteStore.latestHRSampleTs(deviceId: deviceId)
    }

    @discardableResult
    func prune() async -> Int {
        guard let concreteStore else { return 0 }
        return (try? await concreteStore.pruneRaw(
            now: now(),
            keepWindowSeconds: IOSPrunePolicy.keepWindowSeconds,
            maxUnsyncedBytes: IOSPrunePolicy.maxUnsyncedBytes
        )) ?? 0
    }

    func ingest(_ frame: [UInt8]) {
        buffer.append(frame)
        if clockRef == nil && buffer.count > policy.maxPreClockFrames {
            buffer.removeFirst(buffer.count - policy.maxPreClockFrames)
        }
        guard clockRef != nil else { return }
        if buffer.count >= policy.maxFrames || monotonic() - batchStartedAt >= policy.maxInterval {
            Task { @MainActor in await self.flush() }
        }
    }

    func flush() async {
        guard let ref = clockRef, !buffer.isEmpty else { return }
        let frames = buffer
        buffer.removeAll(keepingCapacity: true)

        let streams = extractStreams(
            frames.map { parseFrame($0) },
            deviceClockRef: ref.device,
            wallClockRef: ref.wall
        )
        do {
            try await store.insert(streams, deviceId: deviceId)
        } catch {
            buffer.insert(contentsOf: frames, at: 0)
            return
        }
        onStoreFlush()

        batchStartedAt = monotonic()
        guard enableRawCapture || rawCapture.isActive(at: monotonic()) else { return }

        let wall = now()
        let timestamps = streams.hr.map(\.ts) + streams.rr.map(\.ts)
            + streams.events.map(\.ts) + streams.battery.map(\.ts)
        let meta = RawBatchMeta(
            batchId: UUID().uuidString,
            deviceId: deviceId,
            clockRef: ref,
            capturedAt: wall,
            startTs: timestamps.min() ?? wall,
            endTs: timestamps.max() ?? wall,
            frameCount: frames.count,
            byteSize: frames.reduce(0) { $0 + $1.count }
        )
        try? await store.enqueueRawBatch(meta, frames: frames)
    }

    func ingestStandardHR(hr: Int, rr: [Int], at ts: Int) {
        if hr >= 30, hr <= 220 {
            standardHR.append(HRSample(ts: ts, bpm: hr))
        }
        for interval in rr where interval >= 250 && interval <= 3000 {
            standardRR.append(RRInterval(ts: ts, rrMs: interval))
        }
        let standardAge = monotonic() - standardBatchStartedAt
        if standardHR.count + standardRR.count >= 30 || standardAge >= policy.maxInterval {
            Task { @MainActor in await self.flushStandardHR() }
        }
    }

    func flushStandardHR() async {
        guard !standardHR.isEmpty || !standardRR.isEmpty else { return }
        let hr = standardHR
        let rr = standardRR
        standardHR.removeAll(keepingCapacity: true)
        standardRR.removeAll(keepingCapacity: true)
        do {
            try await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId)
            onStoreFlush()
            standardBatchStartedAt = monotonic()
        } catch {
            standardHR.insert(contentsOf: hr, at: 0)
            standardRR.insert(contentsOf: rr, at: 0)
        }
    }
}
