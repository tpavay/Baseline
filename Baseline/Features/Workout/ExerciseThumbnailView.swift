import SwiftUI

struct ExerciseThumbnailView: View {
    let definition: ExerciseDefinition
    var size: CGFloat = 44

    @Environment(\.exerciseMediaClient) private var mediaClient
    @State private var model = ExerciseThumbnailModel()

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(BaselineColor.surface)
            .frame(width: size, height: size)
            .overlay {
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else {
                    Image(systemName: definition.category.glyph)
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(BaselineColor.textMid)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .task(id: definition.media?.publishedThumbnailPath) {
                await model.load(path: definition.media?.publishedThumbnailPath, using: mediaClient)
            }
            .accessibilityHidden(true)
    }
}
