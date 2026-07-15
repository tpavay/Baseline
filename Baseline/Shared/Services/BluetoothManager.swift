import CoreBluetooth
import Foundation
import Observation

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID          // peripheral.identifier
    let name: String
    var rssi: Int
}

/// App-wide Bluetooth service: discovers BLE Heart-Rate straps, remembers the chosen one (so it
/// reconnects by identifier without a blind scan), and streams R-R intervals during a reading.
/// Shared via the environment and used by both the Devices screen and `ReadingSession`.
///
/// Not `@MainActor`: CoreBluetooth delivers callbacks on the main queue (created with
/// `queue: nil`) and this is only touched from the main actor, so we never send a non-Sendable
/// CB object across actors (which trips Swift 6 strict concurrency). Actions requested before
/// the central is powered on are deferred and run from `centralManagerDidUpdateState`.
@Observable
final class BluetoothManager: NSObject {

    enum Status: String {
        case bluetoothOff = "Bluetooth is off"
        case unauthorized = "Bluetooth not authorized"
        case idle         = "Idle"
        case scanning     = "Scanning…"
        case connecting   = "Connecting…"
        case connected    = "Connected"
    }

    // Device management
    private(set) var status: Status = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var connectedDeviceID: UUID?
    private(set) var connectedDeviceName: String?
    private(set) var savedDeviceID: UUID?
    private(set) var savedDeviceName: String?

    // Reading capture
    private(set) var currentHR: Int = 0
    private(set) var rrIntervals: [Double] = []
    private(set) var rmssd: Double?
    private(set) var lnRmssd: Double?
    private(set) var batteryLevel: Int?

    // Live monitoring (workout heart-rate zones) — additive, independent of the reading path.
    private(set) var liveSample: HeartRateSample?
    @ObservationIgnored var onLiveSample: ((HeartRateSample) -> Void)?
    @ObservationIgnored private var liveActive = false

    // Created lazily: instantiating CBCentralManager triggers the system Bluetooth
    // permission prompt, so it must not exist until the athlete initiates a scan/reading.
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var hrCharacteristic: CBCharacteristic?
    @ObservationIgnored private var intent: Intent = .idle
    @ObservationIgnored private var streaming = false
    @ObservationIgnored private var readingActive = false
    @ObservationIgnored private let hrService = CBUUID(string: "180D")
    @ObservationIgnored private let hrMeasurement = CBUUID(string: "2A37")
    @ObservationIgnored private let batteryService = CBUUID(string: "180F")
    @ObservationIgnored private let batteryLevelChar = CBUUID(string: "2A19")
    @ObservationIgnored private let savedKey = "bluetooth.savedDeviceID"
    @ObservationIgnored private let savedNameKey = "bluetooth.savedDeviceName"

    // Device Information Service (0x180A) — provenance for the raw-data export.
    @ObservationIgnored private let deviceInfoService = CBUUID(string: "180A")
    @ObservationIgnored private let dis: [CBUUID: String] = [
        CBUUID(string: "2A29"): "manufacturer", CBUUID(string: "2A24"): "model",
        CBUUID(string: "2A26"): "firmware", CBUUID(string: "2A25"): "serial",
        CBUUID(string: "2A27"): "hardware",
    ]
    @ObservationIgnored private(set) var deviceInfo: [String: String] = [:]

    // Polar Measurement Data (PMD) service — raw 130 Hz single-lead ECG (24-bit µV samples).
    @ObservationIgnored private let pmdService = CBUUID(string: "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8")
    @ObservationIgnored private let pmdControlUUID = CBUUID(string: "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8")
    @ObservationIgnored private let pmdDataUUID = CBUUID(string: "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8")
    @ObservationIgnored private var pmdControl: CBCharacteristic?
    @ObservationIgnored private var ecgSamples: [Int32] = []   // µV, in order at 130 Hz
    /// Start ECG @ 130 Hz, 14-bit: [start, ECG, rate-TLV(130), resolution-TLV(14)].
    @ObservationIgnored private let pmdStartECG: [UInt8] = [0x02, 0x00, 0x00, 0x01, 0x82, 0x00, 0x01, 0x01, 0x0E, 0x00]

    private enum Intent { case idle, scan, reading, live }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        savedDeviceID = defaults.string(forKey: savedKey).flatMap(UUID.init)
        savedDeviceName = defaults.string(forKey: savedNameKey)
    }

    /// Create the central on first use — this is the moment iOS shows the Bluetooth prompt.
    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let created = CBCentralManager(delegate: self, queue: nil)
        central = created
        return created
    }

    // MARK: - Devices screen

    func startScanning() {
        intent = .scan
        discovered = []
        _ = ensureCentral()
        execute()
    }

    func stopScanning() {
        if intent == .scan { intent = .idle }
        central?.stopScan()
        if status == .scanning { status = connectedDeviceID == nil ? .idle : .connected }
        if !readingActive { disconnect() }   // drop a status-only connection on leave
    }

    func select(_ device: DiscoveredDevice) {
        saveDevice(device.id, name: device.name)
        connectByID(device.id, stream: false)
    }

    func forgetDevice() {
        saveDevice(nil, name: nil)
        disconnect()
    }

    // MARK: - Reading capture

    func startReadingCapture() {
        currentHR = 0; rrIntervals = []; rmssd = nil; lnRmssd = nil
        ecgSamples = []
        readingActive = true
        streaming = true
        intent = .reading
        _ = ensureCentral()
        execute()
    }

    func stopReadingCapture() {
        readingActive = false
        streaming = false
        intent = .idle
        if let pmdControl, let peripheral {                       // stop the ECG stream
            peripheral.writeValue(Data([0x03, 0x00]), for: pmdControl, type: .withResponse)
        }
        disconnect()
    }

    // MARK: - Live monitoring (workout heart-rate)

    /// Begin streaming live BPM from the saved strap for workout zones. Subscribes to the standard
    /// HR characteristic only — no PMD/ECG and no R-R/HRV math, so the reading path is untouched.
    func startLiveMonitoring() {
        liveSample = nil
        liveActive = true
        streaming = true
        intent = .live
        _ = ensureCentral()
        execute()
    }

    /// Stop live streaming and drop the connection. The reading path is unaffected.
    func stopLiveMonitoring() {
        liveActive = false
        streaming = false
        intent = .idle
        liveSample = nil
        disconnect()
    }

    /// Subscribe to HR notifications for live monitoring — deliberately *without* starting the PMD
    /// ECG stream (that is reading-only, gated on `readingActive`).
    private func subscribeLive() {
        guard streaming, let hrCharacteristic, let peripheral else { return }
        peripheral.setNotifyValue(true, for: hrCharacteristic)
    }

    /// Parse a live `0x2A37` payload into a `HeartRateSample`, publish it, and notify any observer.
    private func ingestLive(_ data: Data) {
        guard let sample = HeartRateSample.parse(data) else { return }
        liveSample = sample
        onLiveSample?(sample)               // invoked on the main queue; see LiveHeartRateSource
    }

    // MARK: - Core (deferred until powered on)

    private func execute() {
        guard let central, central.state == .poweredOn else { return }
        switch intent {
        case .scan:
            startScanNow()
            if connectedDeviceID == nil, let id = savedDeviceID {
                connectByID(id, stream: false)   // reflect the saved strap's live status
            }
        case .reading:
            if let id = connectedDeviceID, id == savedDeviceID, peripheral != nil {
                subscribe()
            } else if let id = savedDeviceID {
                connectByID(id, stream: true)
            } else {
                startScanNow()                    // no saved strap → first found is saved
            }
        case .live:
            if let id = connectedDeviceID, id == savedDeviceID, peripheral != nil {
                subscribeLive()                   // reuse the live connection, HR notifications only
            } else if let id = savedDeviceID {
                connectByID(id, stream: true)
            } else {
                startScanNow()                    // no saved strap → first found is saved
            }
        case .idle:
            break
        }
    }

    private func startScanNow() {
        status = .scanning
        central?.scanForPeripherals(withServices: [hrService])
    }

    private func connectByID(_ id: UUID, stream: Bool) {
        streaming = stream
        if let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            startScanNow()   // not known to the system yet → find it via scan
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = .connecting
        central?.connect(p)
    }

    private func subscribe() {
        guard streaming, let hrCharacteristic, let peripheral else { return }
        peripheral.setNotifyValue(true, for: hrCharacteristic)
        // Already-connected path: the PMD data channel is notifying from connect, so start ECG now.
        if let pmdControl { peripheral.writeValue(Data(pmdStartECG), for: pmdControl, type: .withResponse) }
    }

    private func disconnect() {
        if let hrCharacteristic, let peripheral { peripheral.setNotifyValue(false, for: hrCharacteristic) }
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        hrCharacteristic = nil
        pmdControl = nil
        connectedDeviceID = nil
        connectedDeviceName = nil
        if status == .connected || status == .connecting { status = .idle }
    }

    private func saveDevice(_ id: UUID?, name: String?) {
        savedDeviceID = id
        savedDeviceName = name
        let defaults = UserDefaults.standard
        if let id { defaults.set(id.uuidString, forKey: savedKey) } else { defaults.removeObject(forKey: savedKey) }
        if let name { defaults.set(name, forKey: savedNameKey) } else { defaults.removeObject(forKey: savedNameKey) }
    }

    private func ingest(_ data: Data) {
        let parsed = HRV.parseMeasurement(data)
        currentHR = parsed.hr
        let clean = HRV.cleaned(parsed.rrMs)
        guard !clean.isEmpty else { return }
        rrIntervals.append(contentsOf: clean)
        rmssd = HRV.rmssd(rrIntervals)
        lnRmssd = HRV.lnRmssd(rrIntervals)
    }
}

// MARK: - HeartSignalSource

extension BluetoothManager: HeartSignalSource {
    var captureStatus: String { status.rawValue }
    var hasSignal: Bool { !rrIntervals.isEmpty }
}

// MARK: - LiveHeartRateSource

extension BluetoothManager: LiveHeartRateSource {
    var connectionStatus: Status { status }
}

// MARK: - CoreBluetooth delegates

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    execute()                       // run any deferred intent
        case .poweredOff:   status = .bluetoothOff
        case .unauthorized: status = .unauthorized
        default:            status = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let device = DiscoveredDevice(id: peripheral.identifier,
                                      name: peripheral.name ?? "Heart-rate strap",
                                      rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[idx].rssi = device.rssi
        } else {
            discovered.append(device)
        }

        // Auto-connect only during a reading or live session: the saved strap, or the first found.
        guard intent == .reading || intent == .live else { return }
        if let saved = savedDeviceID {
            if peripheral.identifier == saved { central.stopScan(); connect(peripheral) }
        } else {
            central.stopScan()
            saveDevice(peripheral.identifier, name: peripheral.name)
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDeviceID = peripheral.identifier
        connectedDeviceName = peripheral.name
        status = .connected
        peripheral.discoverServices([hrService, batteryService, deviceInfoService, pmdService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectedDeviceID == peripheral.identifier else { return }
        connectedDeviceID = nil
        connectedDeviceName = nil
        if status == .connected { status = .idle }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] {
            switch svc.uuid {
            case hrService:         peripheral.discoverCharacteristics([hrMeasurement], for: svc)
            case batteryService:    peripheral.discoverCharacteristics([batteryLevelChar], for: svc)
            case deviceInfoService: peripheral.discoverCharacteristics(Array(dis.keys), for: svc)
            case pmdService:        peripheral.discoverCharacteristics([pmdControlUUID, pmdDataUUID], for: svc)
            default:                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case hrMeasurement:
                hrCharacteristic = ch
                if streaming { peripheral.setNotifyValue(true, for: ch) }
            case batteryLevelChar:
                peripheral.readValue(for: ch)               // one-shot current level
                peripheral.setNotifyValue(true, for: ch)    // + updates if the strap pushes them
            case pmdControlUUID:
                pmdControl = ch
                peripheral.setNotifyValue(true, for: ch)    // control point uses Indicate
            case pmdDataUUID:
                peripheral.setNotifyValue(true, for: ch)    // raw ECG frames stream here
            default:
                if dis[ch.uuid] != nil { peripheral.readValue(for: ch) }   // device-info strings
            }
        }
    }

    // When the raw-ECG data channel is live, kick off the ECG stream (only during a reading).
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == pmdDataUUID, characteristic.isNotifying, readingActive, let pmdControl {
            peripheral.writeValue(Data(pmdStartECG), for: pmdControl, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case batteryLevelChar:
            batteryLevel = data.first.map(Int.init)
        case hrMeasurement:
            if intent == .live { ingestLive(data) } else { ingest(data) }
        case pmdDataUUID:
            parsePMDFrame([UInt8](data))
        case pmdControlUUID:
            break                                            // start/stop acknowledgements — ignore
        default:
            if let key = dis[characteristic.uuid], let s = String(data: data, encoding: .utf8) {
                deviceInfo[key] = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Parse one PMD ECG frame: `[type][8-byte ns timestamp][frameType][3-byte 24-bit µV samples…]`.
    /// Only uncompressed ECG (type 0x00, frameType 0) is handled — that's what the H10 sends for ECG.
    private func parsePMDFrame(_ b: [UInt8]) {
        guard b.count >= 10, b[0] & 0x3F == 0x00 else { return }   // ECG measurement type
        let frameType = b[9] & 0x7F, compressed = b[9] & 0x80 != 0
        guard !compressed, frameType == 0 else { return }
        var i = 10
        while i + 3 <= b.count {
            let raw = Int32(b[i]) | (Int32(b[i + 1]) << 8) | (Int32(b[i + 2]) << 16)
            ecgSamples.append(raw >= 0x800000 ? raw - 0x1000000 : raw)   // sign-extend 24-bit
            i += 3
        }
    }

    /// The captured raw ECG as CSV (µV per line) with a provenance header — nil if none captured.
    func rawECGCSV() -> String? {
        guard !ecgSamples.isEmpty else { return nil }
        var header = "# source=chest-strap-ecg\n# device=\(connectedDeviceName ?? "")\n"
        for (k, v) in deviceInfo.sorted(by: { $0.key < $1.key }) { header += "# \(k)=\(v)\n" }
        header += "# battery=\(batteryLevel.map(String.init) ?? "")\n# ecgSampleRateHz=130\n# ecgSamples=\(ecgSamples.count)\necg_uv\n"
        return header + ecgSamples.map(String.init).joined(separator: "\n") + "\n"
    }
}
