import Testing
@testable import Baseline

/// AC-3/AC-6: the pure BPM/zone/state → strings mapping (visual + VoiceOver). A live BPM appears only
/// for `.streaming`; every other state maps to an explicit reason, never a stale number.
struct LiveHeartRatePresentationTests {

    private let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)

    private func streaming(_ bpm: Int) -> LiveHeartRateDisplayState {
        .streaming(bpm: bpm, zone: model.zone(forBPM: bpm), position: model.position(forBPM: bpm))
    }

    private func sensorOff(_ bpm: Int) -> LiveHeartRateDisplayState {
        .sensorOff(bpm: bpm, zone: model.zone(forBPM: bpm), position: model.position(forBPM: bpm))
    }

    // MARK: - AC-3: BPM + zone strings

    @Test func bpmTextShowsNumberForAnyReadingAndPlaceholderOtherwise() {
        // A reading exists in streaming AND flagged sensor-off (the number is real, just untrusted).
        #expect(LiveHeartRatePresentation.bpmText(streaming(152)) == "152")
        #expect(LiveHeartRatePresentation.bpmText(sensorOff(150)) == "150")
        // The non-reading states never show a fabricated number.
        #expect(LiveHeartRatePresentation.bpmText(.noSignal) == "--")
        #expect(LiveHeartRatePresentation.bpmText(.connecting) == "--")
        #expect(LiveHeartRatePresentation.bpmText(.disconnected) == "--")
    }

    @Test func statTextAndDurationFormat() {
        #expect(LiveHeartRatePresentation.statText(148) == "148")
        #expect(LiveHeartRatePresentation.statText(nil) == "--")
        #expect(LiveHeartRatePresentation.durationText(0) == "0:00")
        #expect(LiveHeartRatePresentation.durationText(1458) == "24:18")   // 24:18
        #expect(LiveHeartRatePresentation.durationText(65) == "1:05")
        #expect(LiveHeartRatePresentation.durationText(3661) == "1:01:01") // rolls to h:mm:ss
        #expect(LiveHeartRatePresentation.durationText(-30) == "0:00")     // clamps negatives
    }

    @Test func zoneTextIsZLabelAndTitle() {
        // Karvonen bands (max 190, resting 50): Z3 floor 148, Z4 floor 162 → 152 BPM is Z3.
        #expect(LiveHeartRatePresentation.zoneText(streaming(152)) == "Z3 · Aerobic")
        #expect(LiveHeartRatePresentation.zoneText(streaming(168)) == "Z4 · Threshold")
        #expect(LiveHeartRatePresentation.zoneText(streaming(122)) == "Z1 · Recovery")
        #expect(LiveHeartRatePresentation.zoneText(.noSignal) == nil)
    }

    @Test func zoneTextForZoneMatchesTitles() {
        #expect(LiveHeartRatePresentation.zoneText(.z3) == "Z3 · Aerobic")
        #expect(LiveHeartRatePresentation.zoneText(.z5) == "Z5 · Max")
    }

    // MARK: - AC-4 surfacing: status strings + symbols per state

    @Test func statusTextIsNilWhileStreamingAndSetOtherwise() {
        #expect(LiveHeartRatePresentation.statusText(streaming(152)) == nil)
        #expect(LiveHeartRatePresentation.statusText(.noSignal) != nil)
        #expect(LiveHeartRatePresentation.statusText(sensorOff(150)) != nil)
        #expect(LiveHeartRatePresentation.statusText(.connecting) != nil)
        #expect(LiveHeartRatePresentation.statusText(.reconnecting) != nil)
        #expect(LiveHeartRatePresentation.statusText(.disconnected) != nil)
        // Distinct copy per non-streaming state.
        let texts = [LiveHeartRateDisplayState.noSignal, sensorOff(150), .connecting, .reconnecting, .disconnected]
            .compactMap(LiveHeartRatePresentation.statusText)
        #expect(Set(texts).count == 5)
    }

    @Test func statusSymbolIsNilWhileStreaming() {
        #expect(LiveHeartRatePresentation.statusSymbol(streaming(152)) == nil)
        #expect(LiveHeartRatePresentation.statusSymbol(.disconnected) != nil)
    }

    // MARK: - AC-6: accessibility

    @Test func accessibilityValueSpeaksBPMAndZoneWhenStreaming() {
        #expect(LiveHeartRatePresentation.accessibilityValue(streaming(152)) == "152 beats per minute, Z3 Aerobic")
        #expect(LiveHeartRatePresentation.accessibilityValue(.noSignal) == "No signal")
        #expect(LiveHeartRatePresentation.accessibilityValue(.disconnected) == "Disconnected")
    }

    @Test func spectrumAccessibilityValueIncludesTargetWhenSet() {
        let single = LiveHeartRatePresentation.spectrumAccessibilityValue(streaming(152), targetZones: 4...4)
        #expect(single == "Current zone Z3 Aerobic, 152 beats per minute. Target Z4 Threshold")

        let range = LiveHeartRatePresentation.spectrumAccessibilityValue(streaming(152), targetZones: 1...2)
        #expect(range == "Current zone Z3 Aerobic, 152 beats per minute. Target Z1 to Z2")

        let noTarget = LiveHeartRatePresentation.spectrumAccessibilityValue(streaming(152), targetZones: nil)
        #expect(noTarget == "Current zone Z3 Aerobic, 152 beats per minute")

        let noLive = LiveHeartRatePresentation.spectrumAccessibilityValue(.noSignal, targetZones: 3...3)
        #expect(noLive == "No live zone. Target Z3 Aerobic")

        // A flagged sensor-off reading still names the current zone + BPM in the spoken summary.
        let flagged = LiveHeartRatePresentation.spectrumAccessibilityValue(sensorOff(150), targetZones: nil)
        #expect(flagged == "Current zone Z3 Aerobic, 150 beats per minute")
    }

    @Test func targetZonesTextClampsAndCollapses() {
        #expect(LiveHeartRatePresentation.targetZonesText(3...3) == "Target Z3 Aerobic")
        #expect(LiveHeartRatePresentation.targetZonesText(1...2) == "Target Z1 to Z2")
        #expect(LiveHeartRatePresentation.targetZonesText(0...2) == "Target Z1 to Z2")   // clamps low
        #expect(LiveHeartRatePresentation.targetZonesText(4...9) == "Target Z4 to Z5")   // clamps high
        #expect(LiveHeartRatePresentation.targetZonesText(7...9) == nil)                 // fully out of range
    }
}
