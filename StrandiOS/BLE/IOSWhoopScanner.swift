import CoreBluetooth
import Foundation
import WhoopProtocol
import WhoopStore

@MainActor
final class IOSWhoopScanner: NSObject, ObservableObject {
    @Published var bluetoothState = "Starting"
    @Published var connectionState = "Idle"
    @Published var deviceName: String?
    @Published var heartRate: Int?
    @Published var batteryPercent: Int?
    @Published var rrIntervals: [Int] = []
    @Published var isScanning = false
    @Published var isRefreshingMetrics = false
    @Published var metrics: IOSWhoopDeviceSnapshot = .empty
    @Published var logLines: [String] = []

    private static let whoop4Service = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    private static let cmdWriteChar = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6")
    private static let cmdNotifyChar = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6")
    private static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6")
    private static let dataNotifyChar = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6")
    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateChar = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryChar = CBUUID(string: "2A19")
    private static let restoreID = "com.noopapp.noop.ios.ble.central"
    private static let metricsRefreshDebounceSeconds: TimeInterval = 8
    private static let metricsRefreshIntervalSeconds: TimeInterval = 30 * 60

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var seq: UInt8 = 0
    private var connectHandshakeDone = false
    private var reassembler = Reassembler(family: .whoop4)
    private var store: WhoopStore?
    private var collector: IOSCollector?
    private var backfiller: IOSBackfiller?
    private var clockRef: ClockRef?
    private var backfilling = false
    private var backfillFrameQueue: [[UInt8]] = []
    private var backfillDraining = false
    private var backfillTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var metricsRefreshDebounce: DispatchWorkItem?
    private var metricsRefreshTask: Task<Void, Never>?
    private var metricsRefreshGeneration = 0
    private var storeBootstrapTask: Task<Void, Never>?
    private var lastScheduledMetricsRefreshAt: Date?
    private var lastLiveChartMergeAt: Date?
    private var appIsActive = true
    private var midnightFinalization: DispatchWorkItem?
    private var lastForegroundHistoryCatchUpAt: Date?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var intentionalDisconnect = false

    private let deviceId = "whoop-primary"
    private let finalizedDayKey = "noop.lastFinalizedMetricsDay"

    var canScan: Bool { central?.state == .poweredOn }
    var isConnected: Bool { peripheral?.state == .connected }
    var isBondReady: Bool { isConnected && commandCharacteristic != nil }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
        )
    }

    func start() {
        guard central.state == .poweredOn else {
            append("Bluetooth is not ready: \(bluetoothState)")
            return
        }
        intentionalDisconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopActiveConnectionForScan()
        isScanning = true
        connectionState = "Scanning"
        append("Looking for WHOOP")

        if reconnectConnectedWhoopIfAvailable(reason: "already connected") {
            return
        }

        central.scanForPeripherals(
            withServices: Self.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        armScanTimeout()
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempts = 0
        commandCharacteristic = nil
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        isScanning = false
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func requestBattery() {
        guard let peripheral, let characteristic = commandCharacteristic else {
            append("Battery request skipped: strap is not command-ready")
            return
        }
        sendCommand(26, payload: [0x00], to: characteristic, on: peripheral)
        append("Requested battery")
    }

    func buzz(loops: UInt8 = 1) {
        guard let peripheral, let characteristic = commandCharacteristic else {
            append("Buzz skipped: strap is not command-ready")
            return
        }
        sendCommand(79, payload: [2, loops, 0, 0, 0], to: characteristic, on: peripheral)
        append("Sent haptic buzz")
    }

    func armAlarm(at date: Date) {
        guard let peripheral, let characteristic = commandCharacteristic else {
            append("Alarm skipped: strap is not command-ready")
            return
        }
        let epoch = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendCommand(10, payload: Self.setClockPayload(), to: characteristic, on: peripheral)
        sendCommand(66, payload: Self.setAlarmPayload(epochSec: epoch), to: characteristic, on: peripheral)
        append("Armed strap alarm for \(date.formatted(date: .omitted, time: .shortened))")
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            prepareLocalStore()
            scheduleMidnightFinalization()
            finalizePreviousDayIfNeeded()
            Task { @MainActor in
                await collector?.flushStandardHR()
                await collector?.flush()
                catchUpHistoryIfNeeded(reason: "app resumed")
                refreshDeviceMetrics()
            }
        } else {
            Task { @MainActor in
                await collector?.flushStandardHR()
                await collector?.flush()
            }
        }
    }

    func refreshDeviceMetrics(date: Date = Date()) {
        metricsRefreshTask?.cancel()
        guard let store else {
            prepareLocalStore()
            if metrics == .empty {
                metrics.status = "Loading local WHOOP data"
            }
            return
        }
        metricsRefreshGeneration += 1
        let generation = metricsRefreshGeneration
        metricsRefreshTask = Task { @MainActor in
            await self.runMetricsRefresh(store: store, date: date, generation: generation, persistLog: true)
        }
    }

    func refreshDeviceMetricsNow(date: Date = Date()) async {
        metricsRefreshTask?.cancel()
        guard let store else {
            prepareLocalStore()
            if metrics == .empty {
                metrics.status = "Loading local WHOOP data"
            }
            return
        }
        metricsRefreshGeneration += 1
        let generation = metricsRefreshGeneration
        await runMetricsRefresh(store: store, date: date, generation: generation, persistLog: true)
    }

    func prepareLocalStore() {
        bootstrapStoreIfNeeded()
    }

    func recoveryScores(from start: Date, to end: Date) async -> [String: Double] {
        guard let store else { return [:] }
        let from = Self.dayString(start)
        let to = Self.dayString(end)
        do {
            var scores: [String: Double] = [:]
            let daily = try await store.dailyMetrics(deviceId: deviceId, from: from, to: to)
            for row in daily {
                if let recovery = row.recovery {
                    scores[row.day] = recovery <= 1.0 ? recovery * 100.0 : recovery
                }
            }
            let series = try await store.metricSeries(deviceId: deviceId, key: "recovery", from: from, to: to)
            for point in series {
                scores[point.day] = point.value <= 1.0 ? point.value * 100.0 : point.value
            }
            return scores
        } catch {
            append("Recovery calendar failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.insert("\(formatter.string(from: Date()))  \(line)", at: 0)
        if logLines.count > 40 {
            logLines.removeLast(logLines.count - 40)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func runMetricsRefresh(store: WhoopStore,
                                   date: Date,
                                   generation: Int,
                                   persistLog: Bool) async {
        isRefreshingMetrics = true
        defer {
            if generation == metricsRefreshGeneration {
                isRefreshingMetrics = false
            }
        }
        do {
            let refreshed = try await IOSWhoopDeviceMetrics.refresh(
                store: store,
                deviceId: deviceId,
                now: date
            )
            guard !Task.isCancelled, generation == metricsRefreshGeneration else { return }
            let merged = mergedWithLiveHeartRate(refreshed)
            metrics = merged
            if persistLog {
                await persistMetricSnapshot(merged, for: date, final: false)
            }
        } catch {
            guard !Task.isCancelled, generation == metricsRefreshGeneration else { return }
            metrics.status = "Metric refresh failed: \(error.localizedDescription)"
        }
    }

    private func persistMetricSnapshot(_ snapshot: IOSWhoopDeviceSnapshot,
                                       for date: Date,
                                       final: Bool) async {
        guard let store else { return }
        let day = Self.dayString(date)
        var rows: [MetricPoint] = [
            MetricPoint(day: day, key: "noop.snapshotUpdatedAt", value: Date().timeIntervalSince1970),
            MetricPoint(day: day, key: "noop.finalized", value: final ? 1 : 0),
            MetricPoint(day: day, key: "noop.sleepHours", value: snapshot.whoopSleepHours),
            MetricPoint(day: day, key: "noop.sleepEfficiency", value: snapshot.whoopSleepEfficiency),
            MetricPoint(day: day, key: "noop.exerciseMinutes", value: Double(snapshot.exerciseMinutes)),
            MetricPoint(day: day, key: "noop.steps", value: Double(snapshot.steps)),
            MetricPoint(day: day, key: "noop.activityPoints", value: Double(snapshot.activityPoints)),
        ]
        if let strain = snapshot.strain {
            rows.append(MetricPoint(day: day, key: "strain", value: strain))
        }
        if let recovery = snapshot.recovery {
            rows.append(MetricPoint(day: day, key: "recovery", value: recovery))
            if let adjusted = IOSStrainEstimator.recoveryAdjustedLoad(strain: snapshot.strain, recovery: recovery) {
                rows.append(MetricPoint(day: day, key: "noop.adjustedLoad", value: adjusted))
            }
        }
        if let calories = snapshot.calories {
            rows.append(MetricPoint(day: day, key: "noop.calories", value: calories))
        }
        if let restingHR = snapshot.restingHR {
            rows.append(MetricPoint(day: day, key: "noop.restingHR", value: Double(restingHR)))
        }
        if let hrv = snapshot.hrvRMSSD {
            rows.append(MetricPoint(day: day, key: "noop.hrvRMSSD", value: hrv))
        }
        if let sleepHRV = snapshot.sleepHRVRMSSD {
            rows.append(MetricPoint(day: day, key: "noop.sleepHRVRMSSD", value: sleepHRV))
        }
        if let spo2 = snapshot.sleepSpO2RawRatio {
            rows.append(MetricPoint(day: day, key: "noop.sleepSpO2RawRatio", value: spo2))
        }
        if let skinTemp = snapshot.sleepSkinTempRaw {
            rows.append(MetricPoint(day: day, key: "noop.sleepSkinTempRaw", value: skinTemp))
        }
        do {
            _ = try await store.upsertMetricSeries(rows, deviceId: deviceId)
            append(final ? "Finalized metrics log for \(day)" : "Updated metrics log for \(day)")
        } catch {
            append("Metrics log failed: \(error.localizedDescription)")
        }
    }

    private func discoverServices(on peripheral: CBPeripheral) {
        peripheral.discoverServices([
            Self.whoop4Service,
            Self.heartRateService,
            Self.batteryService,
        ])
    }

    private func armScanTimeout() {
        scanTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isScanning else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.intentionalDisconnect {
                self.connectionState = "Not Found"
                self.append("WHOOP not found. Close the official WHOOP app, keep the strap nearby, then scan again.")
            } else {
                self.connectionState = "Reconnecting"
                self.append("WHOOP not found yet; will keep trying")
                self.scheduleReconnect(reason: "scan timeout")
            }
        }
        scanTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
    }

    private func connect(to peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi: NSNumber?,
                         reason: String) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        self.peripheral = peripheral
        deviceName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        peripheral.delegate = self
        connectHandshakeDone = false
        reassembler = Reassembler(family: .whoop4)
        clockRef = nil
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        isScanning = false
        connectionState = "Connecting"
        let rssiText = rssi.map { ", RSSI \($0)" } ?? ""
        append("Found \(deviceName ?? peripheral.identifier.uuidString) (\(reason))\(rssiText)")
        central.connect(peripheral, options: nil)
    }

    private func stopActiveConnectionForScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        isScanning = false
        commandCharacteristic = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private static func looksLikeWhoop(name: String?, advertisementData: [String: Any]) -> Bool {
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if advertised.contains(whoop4Service) { return true }
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? name ?? ""
        if localName.uppercased().contains("WHOOP") { return true }
        return false
    }

    private static var scanServices: [CBUUID] {
        [whoop4Service, heartRateService]
    }

    private func reconnectConnectedWhoopIfAvailable(reason: String) -> Bool {
        guard central.state == .poweredOn else { return false }
        let connected = central.retrieveConnectedPeripherals(withServices: Self.scanServices)
        guard let peripheral = connected.first(where: { Self.looksLikeWhoop(name: $0.name, advertisementData: [:]) }) else {
            return false
        }
        connect(to: peripheral, advertisementData: [:], rssi: nil, reason: reason)
        return true
    }

    private func scheduleReconnect(reason: String) {
        guard !intentionalDisconnect else { return }
        guard central.state == .poweredOn else { return }
        guard peripheral?.state != .connected else { return }
        reconnectWorkItem?.cancel()

        reconnectAttempts += 1
        let delay = min(30.0, Double([2, 5, 10, 20, 30][min(reconnectAttempts - 1, 4)]))
        connectionState = "Reconnecting"
        append("WHOOP disconnected; reconnecting in \(Int(delay))s (\(reason))")

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.intentionalDisconnect, self.central.state == .poweredOn else { return }
            if self.reconnectConnectedWhoopIfAvailable(reason: "auto reconnect") {
                return
            }
            self.isScanning = true
            self.connectionState = "Reconnecting"
            self.central.scanForPeripherals(
                withServices: Self.scanServices,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            self.armScanTimeout()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func restore(_ restored: CBPeripheral) {
        peripheral = restored
        restored.delegate = self
        deviceName = restored.name
        connectHandshakeDone = false
        commandCharacteristic = nil
        reassembler = Reassembler(family: .whoop4)
        clockRef = nil
        bootstrapStoreIfNeeded()

        switch restored.state {
        case .connected:
            connectionState = "Restored"
            append("Restored connected \(restored.name ?? restored.identifier.uuidString)")
            discoverServices(on: restored)
        case .connecting:
            connectionState = "Restoring"
            append("Restoring \(restored.name ?? restored.identifier.uuidString)")
        case .disconnected, .disconnecting:
            connectionState = "Restoring"
            append("Reconnecting restored \(restored.name ?? restored.identifier.uuidString)")
            central.connect(restored, options: nil)
        @unknown default:
            connectionState = "Restoring"
            central.connect(restored, options: nil)
        }
    }

    private func bootstrapStoreIfNeeded() {
        guard store == nil else { return }
        guard storeBootstrapTask == nil else { return }
        storeBootstrapTask = Task { @MainActor in
            defer { self.storeBootstrapTask = nil }
            do {
                let path = try IOSStorePaths.defaultDatabasePath()
                let store = try await WhoopStore(path: path)
                try await store.upsertDevice(id: deviceId, mac: peripheral?.identifier.uuidString, name: deviceName ?? "WHOOP 4.0")
                self.store = store
                self.collector = IOSCollector(store: store, deviceId: deviceId, onStoreFlush: { [weak self] in
                    self?.scheduleMetricsRefresh()
                })
                self.backfiller = IOSBackfiller(store: store, deviceId: deviceId) { [weak self] trim, endData in
                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                }
                self.append("WHOOP store ready")
                self.finalizePreviousDayIfNeeded()
                self.refreshDeviceMetrics()
            } catch {
                self.append("Store setup failed: \(error.localizedDescription)")
            }
        }
    }

    private func bondWithBatteryCommand(_ characteristic: CBCharacteristic) {
        seq = seq &+ 1
        let frame = makeWhoop4CommandFrame(command: 26, seq: seq, payload: [0x00])
        append("Bonding with confirmed GET_BATTERY_LEVEL write")
        peripheral?.writeValue(Data(frame), for: characteristic, type: .withResponse)
    }

    private func runConnectHandshake(on peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        bootstrapStoreIfNeeded()
        append("Starting WHOOP sync handshake")
        sendCommand(35, payload: [0x00], to: characteristic, on: peripheral)
        sendCommand(76, payload: [0x00], to: characteristic, on: peripheral)
        sendCommand(10, payload: Self.setClockPayload(), to: characteristic, on: peripheral)
        sendCommand(11, payload: [], to: characteristic, on: peripheral)
        sendCommand(63, payload: [0x00], to: characteristic, on: peripheral)
        sendCommand(34, payload: [0x00], to: characteristic, on: peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.beginBackfill()
        }
    }

    private func requestHistorySoon(reason: String, delay: TimeInterval = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.catchUpHistoryIfNeeded(reason: reason)
        }
    }

    private func beginBackfill() {
        guard let peripheral, let characteristic = commandCharacteristic else { return }
        guard let backfiller else {
            append("Sync deferred: store is not ready")
            return
        }
        backfiller.begin()
        backfilling = true
        sendCommand(22, payload: [0x00], to: characteristic, on: peripheral, writeType: .withResponse)
        armBackfillTimeout()
        append("Historical sync requested from WHOOP")
    }

    private func catchUpHistoryIfNeeded(reason: String) {
        guard isBondReady else { return }
        let now = Date()
        if let lastForegroundHistoryCatchUpAt,
           now.timeIntervalSince(lastForegroundHistoryCatchUpAt) < 120 {
            return
        }
        lastForegroundHistoryCatchUpAt = now
        append("Checking WHOOP history after \(reason)")
        beginBackfill()
    }

    private func scheduleMetricsRefresh() {
        metricsRefreshDebounce?.cancel()
        let delay: TimeInterval
        if let last = lastScheduledMetricsRefreshAt {
            let elapsed = Date().timeIntervalSince(last)
            delay = max(Self.metricsRefreshDebounceSeconds, Self.metricsRefreshIntervalSeconds - elapsed)
        } else {
            delay = Self.metricsRefreshDebounceSeconds
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastScheduledMetricsRefreshAt,
               now.timeIntervalSince(last) < Self.metricsRefreshIntervalSeconds {
                self.scheduleMetricsRefresh()
                return
            }
            self.lastScheduledMetricsRefreshAt = now
            self.refreshDeviceMetrics()
        }
        metricsRefreshDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleMidnightFinalization() {
        midnightFinalization?.cancel()
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let delay = max(1, tomorrow.timeIntervalSince(now) + 2)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let finalMoment = tomorrow.addingTimeInterval(-1)
            self.finalizeMetricsDay(endingAt: finalMoment)
            self.refreshDeviceMetrics(date: Date())
            self.scheduleMidnightFinalization()
        }
        midnightFinalization = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finalizePreviousDayIfNeeded() {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) else { return }
        let day = Self.dayString(yesterday)
        guard UserDefaults.standard.string(forKey: finalizedDayKey) != day else { return }
        finalizeMetricsDay(endingAt: yesterday.addingTimeInterval(24 * 3600 - 1))
    }

    private func finalizeMetricsDay(endingAt date: Date) {
        guard let store else { return }
        let day = Self.dayString(date)
        Task { @MainActor in
            do {
                let snapshot = try await IOSWhoopDeviceMetrics.refresh(
                    store: store,
                    deviceId: self.deviceId,
                    now: date
                )
                await self.persistMetricSnapshot(snapshot, for: date, final: true)
                UserDefaults.standard.set(day, forKey: self.finalizedDayKey)
            } catch {
                self.append("Final metrics failed for \(day): \(error.localizedDescription)")
            }
        }
    }

    private func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        guard let peripheral, let characteristic = commandCharacteristic else { return }
        sendCommand(23, payload: [0x01] + endData, to: characteristic, on: peripheral, writeType: .withResponse)
        append("Acked WHOOP history chunk \(trim)")
    }

    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in
            while !backfillFrameQueue.isEmpty {
                let frame = backfillFrameQueue.removeFirst()
                await backfiller?.ingest(frame)
                if backfilling, backfiller?.isBackfilling == false {
                    exitBackfilling(reason: "complete")
                }
            }
            backfillDraining = false
            refreshDeviceMetrics()
        }
    }

    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    private func exitBackfilling(reason: String) {
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfilling = false
        append("Historical sync \(reason)")
        refreshDeviceMetrics()
    }

    private func handleHeartRateMeasurement(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let flags = bytes[0]
        var index = 1
        let hrIsUInt16 = (flags & 0x01) != 0
        if hrIsUInt16 {
            guard bytes.count >= 3 else { return }
            heartRate = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            index = 3
        } else {
            heartRate = Int(bytes[1])
            index = 2
        }

        let hasRR = (flags & 0x10) != 0
        guard hasRR else { return }
        var intervals: [Int] = []
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            intervals.append(Int((Double(raw) / 1024.0 * 1000.0).rounded()))
            index += 2
        }
        if !intervals.isEmpty {
            rrIntervals = Array((rrIntervals + intervals).suffix(20))
        }
        if let heartRate {
            let ts = Int(Date().timeIntervalSince1970)
            collector?.ingestStandardHR(hr: heartRate, rr: intervals, at: ts)
            mergeLiveHeartRate(bpm: heartRate, ts: ts)
        }
    }

    private func mergeLiveHeartRate(bpm: Int, ts: Int) {
        guard bpm >= 30, bpm <= 220 else { return }
        let sampleDate = Date(timeIntervalSince1970: TimeInterval(ts))
        guard Calendar.current.isDateInToday(sampleDate) else { return }
        mergeDailyHeartRateSample(bpm: bpm, ts: ts, into: &metrics)
        if let lastLiveChartMergeAt,
           sampleDate.timeIntervalSince(lastLiveChartMergeAt) < 5 {
            return
        }

        if metrics.todayHRSamples.last?.ts == ts {
            return
        }
        lastLiveChartMergeAt = sampleDate

        let nextId = (metrics.todayHRSamples.last?.id ?? -1) + 1
        metrics.todayHRSamples.append(IOSMetricHRSample(id: nextId, ts: ts, bpm: bpm))
        if metrics.todayHRSamples.count > 120_000 {
            metrics.todayHRSamples.removeFirst(metrics.todayHRSamples.count - 120_000)
        }
        metrics.latestSampleAt = sampleDate
        metrics.status = statusForLiveSample(sampleDate)
    }

    private func mergedWithLiveHeartRate(_ snapshot: IOSWhoopDeviceSnapshot) -> IOSWhoopDeviceSnapshot {
        guard let heartRate else { return snapshot }
        var merged = snapshot
        mergeLiveHeartRateIntoSnapshot(&merged, bpm: heartRate, ts: Int(Date().timeIntervalSince1970))
        return merged
    }

    private func mergeLiveHeartRateIntoSnapshot(_ snapshot: inout IOSWhoopDeviceSnapshot, bpm: Int, ts: Int) {
        guard bpm >= 30, bpm <= 220 else { return }
        let sampleDate = Date(timeIntervalSince1970: TimeInterval(ts))
        guard Calendar.current.isDateInToday(sampleDate) else { return }
        mergeDailyHeartRateSample(bpm: bpm, ts: ts, into: &snapshot)
        if snapshot.todayHRSamples.last?.ts != ts {
            let nextId = (snapshot.todayHRSamples.last?.id ?? -1) + 1
            snapshot.todayHRSamples.append(IOSMetricHRSample(id: nextId, ts: ts, bpm: bpm))
        }
        snapshot.latestSampleAt = max(snapshot.latestSampleAt ?? sampleDate, sampleDate)
        snapshot.status = statusForLiveSample(sampleDate)
    }

    private func mergeDailyHeartRateSample(bpm: Int, ts: Int, into snapshot: inout IOSWhoopDeviceSnapshot) {
        if snapshot.dailyHRSamples.last?.ts == ts {
            return
        }
        let nextId = (snapshot.dailyHRSamples.last?.id ?? -1) + 1
        snapshot.dailyHRSamples.append(IOSMetricHRSample(id: nextId, ts: ts, bpm: bpm))
        if snapshot.dailyHRSamples.count > 120_000 {
            snapshot.dailyHRSamples.removeFirst(snapshot.dailyHRSamples.count - 120_000)
        }
    }

    private func statusForLiveSample(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return seconds < 10 ? "WHOOP live data current" : "Last live sample \(Int(seconds)) s ago"
    }

    private func handleBatteryData(_ data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }
        if bytes.count == 1 {
            batteryPercent = Int(bytes[0])
            return
        }
        if let plausiblePercent = bytes.first(where: { $0 <= 100 && $0 >= 20 }) {
            batteryPercent = Int(plausiblePercent)
        } else {
            batteryPercent = Int(bytes[0])
        }
    }

    private func sendCommand(_ command: UInt8, payload: [UInt8], to characteristic: CBCharacteristic, on peripheral: CBPeripheral, writeType: CBCharacteristicWriteType = .withoutResponse) {
        seq = seq &+ 1
        let frame = makeWhoop4CommandFrame(command: command, seq: seq, payload: payload)
        peripheral.writeValue(Data(frame), for: characteristic, type: writeType)
    }

    private func handleCustomNotification(_ data: Data) {
        let bytes = [UInt8](data)
        for frame in reassembler.feed(bytes) {
            if clockRef == nil {
                let parsed = parseFrame(frame)
                if let ref = IOSClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                    clockRef = ref
                    collector?.clockRef = ref
                    backfiller?.clockRef = ref
                    append("Clock correlated")
                    if IOSClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall),
                       let peripheral, let characteristic = commandCharacteristic {
                        sendCommand(10, payload: Self.setClockPayload(), to: characteristic, on: peripheral)
                    }
                }
            }

            if let battery = batteryPercentFromCommandFrame(frame) {
                batteryPercent = battery
            }

            if backfilling {
                guard Self.isOffloadFrame(frame) else { continue }
                armBackfillTimeout()
                routeBackfillFrame(frame)
            } else {
                collector?.ingest(frame)
            }
        }
    }

    private func batteryPercentFromCommandFrame(_ frame: [UInt8]) -> Int? {
        let parsed = parseFrame(frame)
        for key in ["battery_level", "battery", "soc", "level"] {
            if let value = parsed.parsed[key]?.doubleValue, value >= 0, value <= 100 {
                return Int(value.rounded())
            }
        }
        return nil
    }

    private static func isOffloadFrame(_ frame: [UInt8]) -> Bool {
        guard frame.count > 4 else { return false }
        switch frame[4] {
        case 47, 48, 49, 50: return true
        default: return false
        }
    }

    private static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [
            UInt8(now & 0xFF),
            UInt8((now >> 8) & 0xFF),
            UInt8((now >> 16) & 0xFF),
            UInt8((now >> 24) & 0xFF),
            0, 0, 0, 0,
        ]
    }

    private static func setAlarmPayload(epochSec: UInt32) -> [UInt8] {
        [
            0x01,
            UInt8(epochSec & 0xFF),
            UInt8((epochSec >> 8) & 0xFF),
            UInt8((epochSec >> 16) & 0xFF),
            UInt8((epochSec >> 24) & 0xFF),
            0x00, 0x00,
        ]
    }

    private func makeWhoop4CommandFrame(command: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [35, seq, command] + payload
        let length = UInt16(inner.count + 4)
        let lenBytes = [UInt8(length & 0xFF), UInt8(length >> 8)]
        let trailer = crc32(inner)
        return [0xAA]
            + lenBytes
            + [crc8(lenBytes)]
            + inner
            + [
                UInt8(trailer & 0xFF),
                UInt8((trailer >> 8) & 0xFF),
                UInt8((trailer >> 16) & 0xFF),
                UInt8((trailer >> 24) & 0xFF),
            ]
    }
}

extension IOSWhoopScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown: bluetoothState = "Unknown"
        case .resetting: bluetoothState = "Resetting"
        case .unsupported: bluetoothState = "Unsupported"
        case .unauthorized: bluetoothState = "Unauthorized"
        case .poweredOff: bluetoothState = "Off"
        case .poweredOn:
            bluetoothState = "On"
            if peripheral == nil || peripheral?.state == .disconnected {
                _ = reconnectConnectedWhoopIfAvailable(reason: "Bluetooth restored")
            }
        @unknown default: bluetoothState = "Other"
        }
        append("Bluetooth \(bluetoothState)")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restored = peripherals.first(where: { Self.looksLikeWhoop(name: $0.name, advertisementData: [:]) }) ?? peripherals.first else {
            append("Bluetooth restore event had no peripherals")
            return
        }
        restore(restored)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard Self.looksLikeWhoop(name: peripheral.name, advertisementData: advertisementData) else { return }
        connect(to: peripheral, advertisementData: advertisementData, rssi: RSSI, reason: "advertisement")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempts = 0
        intentionalDisconnect = false
        connectionState = "Connected"
        append("Connected")
        bootstrapStoreIfNeeded()
        discoverServices(on: peripheral)
        requestHistorySoon(reason: "reconnect", delay: 3.0)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "Failed"
        append("Connect failed: \(error?.localizedDescription ?? "unknown error")")
        scheduleReconnect(reason: "connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        commandCharacteristic = nil
        connectionState = intentionalDisconnect ? "Disconnected" : "Reconnecting"
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfilling = false
        Task { @MainActor in
            await collector?.flushStandardHR()
            await collector?.flush()
            refreshDeviceMetrics()
        }
        append("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        scheduleReconnect(reason: error == nil ? "link dropped" : "link error")
    }
}

extension IOSWhoopScanner: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            append("Service discovery failed: \(error.localizedDescription)")
            return
        }
        peripheral.services?.forEach { service in
            switch service.uuid {
            case Self.whoop4Service:
                peripheral.discoverCharacteristics([
                    Self.cmdWriteChar,
                    Self.cmdNotifyChar,
                    Self.eventNotifyChar,
                    Self.dataNotifyChar,
                ], for: service)
            case Self.heartRateService:
                peripheral.discoverCharacteristics([Self.heartRateChar], for: service)
            case Self.batteryService:
                peripheral.discoverCharacteristics([Self.batteryChar], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            append("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case Self.cmdWriteChar:
                commandCharacteristic = characteristic
                bondWithBatteryCommand(characteristic)
                requestHistorySoon(reason: "command channel ready", delay: 1.0)
            case Self.cmdNotifyChar, Self.eventNotifyChar, Self.dataNotifyChar, Self.heartRateChar:
                peripheral.setNotifyValue(true, for: characteristic)
                append("Subscribed \(characteristic.uuid.uuidString)")
            case Self.batteryChar:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                append("Reading battery")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append("Write failed: \(error.localizedDescription)")
        } else {
            append("Confirmed write completed")
            if characteristic.uuid == Self.cmdWriteChar, let commandCharacteristic {
                runConnectHandshake(on: peripheral, characteristic: commandCharacteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append("Update failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.heartRateChar:
            handleHeartRateMeasurement(data)
        case Self.batteryChar:
            handleBatteryData(data)
        case Self.cmdNotifyChar, Self.eventNotifyChar, Self.dataNotifyChar:
            handleCustomNotification(data)
        default:
            break
        }
    }
}
