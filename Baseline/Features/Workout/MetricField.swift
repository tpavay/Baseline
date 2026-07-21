import SwiftUI

/// A metric table cell with the **correct keyboard for its metric**, and no path where typed input is
/// lost or mangled:
/// - **Duration**: `.numberPad` only — no letters, no colon key (durations need `m:ss` but no iOS
///   keyboard offers digits+colon). Entry is **digit-cascade**, stopwatch/register-style: each digit
///   shifts in from the right (`1`→`0:01`, `0`→`0:10`, `3`→`1:03`, `0`→`10:30`). This sidesteps the old
///   free-text ambiguity entirely — there's no "bare number means minutes" convention to learn, and
///   nothing on the keypad can spell "inf" (the crash the adversarial review found).
/// - **Reps** (integer): `.numberPad`. **Load/distance** (decimal): `.decimalPad`. Free-text entry,
///   buffered so a value is committed on every keystroke (never lost to Complete-set/Complete-workout/
///   sheet-dismissal) but only reformatted on blur (so typing isn't mangled mid-entry).
struct MetricField: View {
    let metric: MetricType
    let unit: MetricUnit
    var placeholder = "—"
    var accessibilityName: String?
    @Binding var canonical: Double?
    var color: Color = BaselineColor.textHi

    @State private var text = ""
    @State private var syncedText = ""     // what the model last rendered — unchanged text never commits
    @State private var rawDigits = ""      // duration only — the cascade accumulator
    @State private var isReformatting = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(metric.isInteger || metric.isClockKind ? .numberPad : .decimalPad)
            .font(.body.weight(.semibold)).foregroundStyle(color)
            .multilineTextAlignment(.center)
            .accessibilityLabel(accessibilityName ?? "\(metric.label), \(unit.short)")
            .accessibilityHint("Enter \(metric.label.lowercased())")
            .focused($focused)
            .onAppear { if !focused { sync() } }
            .onChange(of: canonical) { if !focused { sync() } }   // external edits (agent, undo) refresh the cell
            .onChange(of: unit) { if !focused { sync() } }        // unit switch re-renders in the new unit
            .onChange(of: text) { old, new in
                if metric.isClockKind { handleCascade(old: old, new: new) }
                else if focused { commit() }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { if !metric.isClockKind { commit() }; sync() } }
            .onSubmit { if !metric.isClockKind { commit() }; sync() }
            .onDisappear { if !metric.isClockKind { commit() } }   // backstop for teardown mid-edit
    }

    // MARK: Free-text metrics (reps, load, distance)

    private func sync() {
        if metric.isClockKind {
            // The cascade counts in the *displayed* unit's seconds — identical to canonical for a
            // duration, seconds-per-km or per-mile for a pace.
            rawDigits = canonical
                .map { MetricConvert.fromCanonical($0, metric, to: unit) }
                .map { MetricFormat.cascadeDigits(fromSeconds: $0) } ?? ""
            text = canonical.map { MetricFormat.editText($0, metric, unit: unit) } ?? ""
        } else {
            text = canonical.map { MetricFormat.editText($0, metric, unit: unit) } ?? ""
        }
        syncedText = text
    }

    /// Parse the current text and write through if it changed. No reformatting here — while the field
    /// is focused the athlete's text is left exactly as typed; unparseable mid-typing states simply
    /// keep the last good value (blur snaps the text back to it).
    private func commit() {
        guard text != syncedText else { return }   // untouched — don't re-parse rounded display text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            canonical = nil
        } else if let parsed = MetricFormat.parse(trimmed, metric, unit: unit) {
            canonical = parsed
        }
    }

    // MARK: Duration (digit-cascade)

    /// Every keystroke is a digit (the keyboard has nothing else) except a paste, which can inject
    /// arbitrary text (e.g. a copied "10:30") — classification is `MetricFormat.cascadeEdit`, tested
    /// independently of this view.
    ///
    /// `guard focused` is required, not incidental: `sync()` also writes `text` (e.g. an agent edit
    /// arriving while this field is closed), and without the guard that write would be reinterpreted as
    /// a keystroke here and silently corrupt `canonical`. `sync()` only ever runs while unfocused, so
    /// this guard alone makes those writes invisible to cascade logic.
    private func handleCascade(old: String, new: String) {
        guard focused else { return }
        if isReformatting { isReformatting = false; return }   // our own programmatic rewrite — ignore

        rawDigits = MetricFormat.cascadeEdit(old: old, new: new, rawDigits: rawDigits)
        canonical = rawDigits.isEmpty ? nil
            : MetricConvert.toCanonical(MetricFormat.cascadeSeconds(rawDigits), metric, from: unit)
        let display = MetricFormat.cascadeDisplay(rawDigits)
        if text != display { isReformatting = true; text = display }
        syncedText = text
    }
}
