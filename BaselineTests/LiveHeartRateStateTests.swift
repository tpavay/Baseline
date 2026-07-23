import Foundation
import Testing
@testable import Baseline

/// A hand-driven `LiveHeartRateProviding` fake: every live field is set directly, so the resolver can
/// be exercised through every state without CoreBluetooth, a `HeartRateMonitor`, or `Date()`-based
/// freshness. `currentBPM`/`currentZone`/`sensorContact` mirror `HeartRateMonitor`'s derivation.
@MainActor
private final class StubLiveHeartRateProvider: LiveHeartRateProviding {
    var freshSample: HeartRateSample?
    var latestSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status
    var zoneModel: HeartRateZoneModel
    var averageBPM: Int?
    var maxBPM: Int?
    var sessionElapsed: TimeInterval = 0
    var zoneTime = ZoneTimeAccumulator()

    var currentBPM: Int? { freshSample?.bpm }
    var currentZone: HeartRateZone? { freshSample.map { zoneModel.zone(forBPM: $0.bpm) } }
    var sensorContact: HeartRateSample.SensorContact? { freshSample?.sensorContact }

    init(freshSample: HeartRateSample? = nil,
         latestSample: HeartRateSample? = nil,
         connectionStatus: BluetoothManager.Status = .idle,
         zoneModel: HeartRateZoneModel = HeartRateZoneModel(maxHR: 190, restingHR: 50)) {
        self.freshSample = freshSample
        self.latestSample = latestSample
        self.connectionStatus = connectionStatus
        self.zoneModel = zoneModel
    }
}

private func sample(_ bpm: Int, _ contact: HeartRateSample.SensorContact = .detected) -> HeartRateSample {
    HeartRateSample(bpm: bpm, sensorContact: contact, receivedAt: Date(timeIntervalSince1970: 0))
}

/// AC-4: the pure state resolver. Freshness precedes connection status (a stale sample is never a
/// live number), sensor-off is surfaced, and connecting / reconnecting / disconnected are distinct.
@MainActor
struct LiveHeartRateStateTests {

    private let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)

    // MARK: - Streaming carries bpm + zone + position

    @Test func streamingCarriesBPMZoneAndPosition() {
        let provider = StubLiveHeartRateProvider(freshSample: sample(152), latestSample: sample(152),
                                                 connectionStatus: .connected, zoneModel: model)
        let state = LiveHeartRateStateResolver.resolve(provider)
        #expect(state == .streaming(bpm: 152,
                                    zone: model.zone(forBPM: 152),
                                    position: model.position(forBPM: 152)))
        #expect(state.isLive)
    }

    // MARK: - Stale → no-signal, never a BPM

    @Test func staleSampleResolvesToNoSignalNotABPM() {
        // A real prior reading is present but not fresh; the resolver must not surface it as live.
        let provider = StubLiveHeartRateProvider(freshSample: nil, latestSample: sample(150),
                                                 connectionStatus: .connected, zoneModel: model)
        let state = LiveHeartRateStateResolver.resolve(provider)
        #expect(state == .noSignal)
        #expect(!state.isLive)
        if case .streaming = state { Issue.record("stale sample was presented as live") }
    }

    // MARK: - Sensor off

    @Test func lostContactResolvesToSensorOffCarryingTheReading() {
        let provider = StubLiveHeartRateProvider(freshSample: sample(138, .notDetected),
                                                 latestSample: sample(138, .notDetected),
                                                 connectionStatus: .connected, zoneModel: model)
        let state = LiveHeartRateStateResolver.resolve(provider)
        // Sensor-off still carries the (flagged) reading so the HUD can show the number + a warning.
        #expect(state == .sensorOff(bpm: 138,
                                    zone: model.zone(forBPM: 138),
                                    position: model.position(forBPM: 138)))
        #expect(state.showsNumber)
        #expect(state.bpm == 138)
        #expect(!state.isLive)   // shown, but not a trusted live reading
    }

    @Test func unsupportedContactStillStreams() {
        // A strap that doesn't advertise the contact feature is not "off" — it just streams.
        let provider = StubLiveHeartRateProvider(freshSample: sample(140, .unsupported),
                                                 latestSample: sample(140, .unsupported),
                                                 connectionStatus: .connected, zoneModel: model)
        #expect(LiveHeartRateStateResolver.resolve(provider).isLive)
    }

    // MARK: - Connecting vs reconnecting vs disconnected are distinct

    @Test func firstConnectResolvesToConnecting() {
        let provider = StubLiveHeartRateProvider(freshSample: nil, latestSample: nil,
                                                 connectionStatus: .connecting, zoneModel: model)
        #expect(LiveHeartRateStateResolver.resolve(provider) == .connecting)
    }

    @Test func reconnectAfterASampleResolvesToReconnecting() {
        // A sample arrived earlier this run (latestSample set), then the link dropped and is
        // re-establishing — distinct from a cold connect.
        let provider = StubLiveHeartRateProvider(freshSample: nil, latestSample: sample(150),
                                                 connectionStatus: .connecting, zoneModel: model)
        #expect(LiveHeartRateStateResolver.resolve(provider) == .reconnecting)
    }

    @Test func scanningMapsLikeConnecting() {
        let cold = StubLiveHeartRateProvider(connectionStatus: .scanning, zoneModel: model)
        #expect(LiveHeartRateStateResolver.resolve(cold) == .connecting)
        let warm = StubLiveHeartRateProvider(latestSample: sample(150), connectionStatus: .scanning, zoneModel: model)
        #expect(LiveHeartRateStateResolver.resolve(warm) == .reconnecting)
    }

    @Test func idleOffAndUnauthorizedResolveToDisconnected() {
        for status: BluetoothManager.Status in [.idle, .bluetoothOff, .unauthorized] {
            let provider = StubLiveHeartRateProvider(connectionStatus: status, zoneModel: model)
            #expect(LiveHeartRateStateResolver.resolve(provider) == .disconnected)
        }
    }

    /// The three not-live-but-something states are mutually distinct (no two collapse).
    @Test func nonStreamingStatesAreDistinct() {
        let connecting = LiveHeartRateStateResolver.resolve(
            StubLiveHeartRateProvider(connectionStatus: .connecting, zoneModel: model))
        let reconnecting = LiveHeartRateStateResolver.resolve(
            StubLiveHeartRateProvider(latestSample: sample(150), connectionStatus: .connecting, zoneModel: model))
        let disconnected = LiveHeartRateStateResolver.resolve(
            StubLiveHeartRateProvider(connectionStatus: .idle, zoneModel: model))
        let noSignal = LiveHeartRateStateResolver.resolve(
            StubLiveHeartRateProvider(latestSample: sample(150), connectionStatus: .connected, zoneModel: model))
        #expect(Set([connecting, reconnecting, disconnected, noSignal]).count == 4)
    }

    /// Honesty guard: no connection status paired with a stale/absent fresh sample ever yields a live
    /// BPM. Freshness is the gate, checked before connection status.
    @Test func noStaleStateIsEverLive() {
        let statuses: [BluetoothManager.Status] = [.connected, .connecting, .scanning, .idle, .bluetoothOff, .unauthorized]
        for status in statuses {
            let provider = StubLiveHeartRateProvider(freshSample: nil, latestSample: sample(150),
                                                     connectionStatus: status, zoneModel: model)
            #expect(!LiveHeartRateStateResolver.resolve(provider).isLive)
        }
    }
}
