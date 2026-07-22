import Foundation

enum CustomExercisePickerLogic {
    static func orderedSelection<Value: Hashable>(
        options: [Value],
        selectedIDs: Set<Value>,
        previousSelection: [Value]
    ) -> [Value] {
        let retained = previousSelection.filter(selectedIDs.contains)
        let additions = options.filter { selectedIDs.contains($0) && retained.contains($0) == false }
        return retained + additions
    }
}
