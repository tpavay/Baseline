import SwiftUI

/// A metric table cell that separates **committing** from **formatting**: every keystroke parses and
/// writes through to the model (so a value typed but never blurred is *never* lost — tapping the set
/// checkmark or Complete workout sees it), while the text is only re-formatted on blur (so typing
/// `10:00` isn't mangled per keystroke — the old live String binding turned "10:" into 10 seconds and
/// ate the colon). The binding is canonical (seconds/kg/meters); display/parse go through
/// `MetricFormat`, so a bare "10" in a duration field means 10 **minutes**.
struct MetricField: View {
    let metric: MetricType
    let unit: MetricUnit
    var placeholder = "—"
    @Binding var canonical: Double?
    var color: Color = BaselineColor.textHi

    @State private var text = ""
    @State private var syncedText = ""     // what the model last rendered — unchanged text never commits
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(metric.isDurationKind ? .numbersAndPunctuation : (metric.isInteger ? .numberPad : .decimalPad))
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onAppear { if !focused { sync() } }
            .onChange(of: canonical) { if !focused { sync() } }   // external edits (agent, undo) refresh the cell
            .onChange(of: unit) { if !focused { sync() } }        // unit switch re-renders in the new unit
            .onChange(of: text) { if focused { commit() } }       // live write-through — nothing typed is ever lost
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(); sync() } }
            .onSubmit { commit(); sync() }
            .onDisappear { commit() }                             // backstop for teardown mid-edit
    }

    private func sync() {
        text = canonical.map { MetricFormat.editText($0, metric, unit: unit) } ?? ""
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
}
