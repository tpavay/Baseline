# Share Composer v1

Baseline's post-workout share composer lets a completed workout produce two shareable artifacts.
Users can copy or share a clean text summary through the system share sheet.
Users can also render a Baseline-branded image card and send it through the system share sheet or save it to Photos.

The v1 image composer is intentionally image-only.
It uses Baseline colors, system fonts, and the Baseline wordmark.
The reusable composer view model stays SwiftUI-free, while the SwiftUI export canvas is rendered through `ImageRenderer`.

The only entry point in v1 is the "Share workout" button on the completed-workout screen (`WorkoutView` in its completed mode), which appears once the current log is complete and its finish instant is known.
Saving the card is the one path that needs a permission: it requests add-only Photos authorization, covered by `NSPhotoLibraryAddUsageDescription` in `project.yml`.
Baseline deliberately does not declare `NSPhotoLibraryUsageDescription` - it never reads the library here, and add-only keeps the prompt honest.

Fast-follows deferred from v1:

- Video export.
- Core Image filters.
- A custom camera-roll grid.
- Instagram Stories deep-link sharing.
- Save-workout finish-screen integration once that screen exists.
