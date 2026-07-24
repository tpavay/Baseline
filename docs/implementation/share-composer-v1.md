# Share Composer v1

Baseline's post-workout share composer lets a completed workout produce two shareable artifacts.
Users can copy or share a clean text summary through the system share sheet.
Users can also render a Baseline-branded image card and send it through the system share sheet or save it to Photos.

The v1 image composer is intentionally image-only.
It uses Baseline colors, system fonts, and the Baseline wordmark.
The reusable composer view model stays SwiftUI-free, while the SwiftUI export canvas is rendered through `ImageRenderer`.

Fast-follows deferred from v1:

- Video export.
- Core Image filters.
- A custom camera-roll grid.
- Instagram Stories deep-link sharing.
- Save-workout finish-screen integration once that screen exists.
