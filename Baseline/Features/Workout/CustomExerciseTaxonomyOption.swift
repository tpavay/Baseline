import SwiftUI

struct CustomExerciseTaxonomyOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    let subtitle: String?
    let icon: Image
}
