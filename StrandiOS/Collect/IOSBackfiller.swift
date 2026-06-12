import Foundation
import TrackerProtocol
import TrackerStore

protocol IOSBackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension TrackerStore: IOSBackfillStoreWriting {}

@MainActor
final class IOSBackfiller {
    typealias Extractor = ([ParsedFrame], Int, Int) -> Streams

    private let store: IOSBackfillStoreWriting
    private let deviceId: String
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let enableRawCapture: Bool
    private let extract: Extractor

    var clockRef: ClockRef?
    private(set) var isBackfilling = false

    private var chunk: [[UInt8]] = []
    private var chunkOpen = false

    init(store: IOSBackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.extract = extract
    }

    func begin() {
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
    }

    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }

    private static func endData(from frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 25 else { return nil }
        return Array(frame[17..<25])
    }

    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Self.endData(from: endFrame) else { return }
        let frames = chunk
        chunk.removeAll(keepingCapacity: true)

        if !frames.isEmpty {
            let ref = clockRef ?? {
                let now = Int(Date().timeIntervalSince1970)
                return ClockRef(device: now, wall: now)
            }()
            let decoded = extract(frames.map { parseFrame($0) }, ref.device, ref.wall)
            do {
                try await store.insert(decoded, deviceId: deviceId)
            } catch {
                return
            }

            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: Int(unix),
                    endTs: Int(unix),
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count }
                )
                do {
                    try await store.enqueueRawBatch(meta, frames: frames)
                } catch {
                    return
                }
            }
        }

        do {
            try await store.setCursor("strap_trim", Int(trim))
        } catch {
            return
        }
        ackTrim(trim, endData)
    }
}
