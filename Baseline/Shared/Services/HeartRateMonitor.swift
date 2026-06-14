import CoreBluetooth
import Foundation
import Observation

/// Spike-level CoreBluetooth service: connect a BLE Heart Rate strap (e.g. Polar H10),
/// stream R-R intervals, and compute a running RMSSD.
///
/// Deliberately **not** `@MainActor`. CoreBluetooth delivers every callback on the main queue
/// (the manager is created with `queue: nil`), and this object is only created and read from
/// SwiftUI (the main actor) — so every access is effectively main-thread. Keeping it
/// non-isolated means we never send a non-`Sendable` CoreBluetooth object (`CBPeripheral`,
/// `CBService`, …) across an actor boundary, which is what trips Swift 6 strict concurrency.
/// If CoreBluetooth is ever moved onto a background queue, revisit isolation. Parsing + RMSSD
/// live in the pure `HRV` namespace so they stay testable without hardware.
@Observable
final class HeartRateMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Status: String {
        case bluetoothOff = "Bluetooth is off"
        case unauthorized = "Bluetooth not authorized"
        case idle         = "Idle"
        case scanning     = "Scanning for strap…"
        case connecting   = "Connecting…"
        case connected    = "Connected"
    }

    private(set) var status: Status = .idle
    private(set) var deviceName: String?
    private(set) var currentHR: Int = 0
    private(set) var rrIntervals: [Double] = []   // cleaned R-R (ms) for this reading
    private(set) var rmssd: Double?
    private(set) var lnRmssd: Double?

    var isRunning: Bool { status == .scanning || status == .connecting || status == .connected }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private let hrService = CBUUID(string: "180D")
    @ObservationIgnored private let hrMeasurement = CBUUID(string: "2A37")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)   // nil → main queue
    }

    func start() {
        rrIntervals = []; rmssd = nil; lnRmssd = nil; currentHR = 0; deviceName = nil
        guard central.state == .poweredOn else { return }
        status = .scanning
        central.scanForPeripherals(withServices: [hrService])
    }

    func stop() {
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        status = .idle
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

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    if status == .bluetoothOff { status = .idle }
        case .poweredOff:   status = .bluetoothOff
        case .unauthorized: status = .unauthorized
        default:            status = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceName = peripheral.name
        status = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = .connected
        peripheral.discoverServices([hrService])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if status != .idle { status = .idle }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == hrService }) else { return }
        peripheral.discoverCharacteristics([hrMeasurement], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == hrMeasurement }) else { return }
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        ingest(data)
    }
}
