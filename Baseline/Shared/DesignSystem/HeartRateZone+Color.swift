import SwiftUI

/// Design-system color for each live heart-rate zone, low (blue) → high (red).
///
/// This is the compile-checked counterpart to `HeartRateZone.colorToken` (a Slice-1 *string* name,
/// kept only as documentation): an exhaustive `switch` means adding a sixth zone is a build error
/// until its color is chosen, rather than a silent runtime miss from a stringly-typed lookup. The
/// `HeartRateZone` enum itself stays SwiftUI-free (Foundation only); this mapping lives with the
/// design tokens it resolves.
extension HeartRateZone {
    var color: Color {
        switch self {
        case .z1: BaselineColor.zoneBlue
        case .z2: BaselineColor.zoneGreen
        case .z3: BaselineColor.zoneAmber
        case .z4: BaselineColor.zoneOrange
        case .z5: BaselineColor.zoneRed
        }
    }
}
