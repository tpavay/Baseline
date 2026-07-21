import Foundation
import ImageIO
import Testing

/// Guards the two things App Store upload validation rejects a binary for and Xcode never warns
/// about: a purpose string missing for something the entitlements permit, and an app icon that
/// carries an alpha channel. The purpose strings are read back off the built host bundle rather
/// than out of `project.yml`, so a broken generated Info.plist cannot pass.
struct AppStoreValidationTests {

    /// `com.apple.developer.healthkit` is a single boolean entitlement that cannot be scoped to
    /// reads, so the validator demands the update string even though `HealthService` only reads.
    @Test("The app bundle declares both HealthKit purpose strings")
    func healthKitPurposeStrings() throws {
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(value?.isEmpty == false, "\(key) is missing from the built Info.plist")
        }
    }

    /// The share string has to explain "clearly and completely", so it must name the activity and
    /// characteristic data `HealthService` reads, not just sleep and heart rate.
    @Test("The Health read purpose string names every category read")
    func healthShareStringIsComplete() throws {
        let value = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String
        ).lowercased()
        for topic in ["sleep", "heart rate", "workout", "activity", "age", "biological sex"] {
            #expect(value.contains(topic), "purpose string does not mention \(topic)")
        }
    }

    /// Checks the source artwork, not a decoded `UIImage`: CoreUI hands back a premultiplied
    /// bitmap whatever the file holds, and the simulator's derived icon PNGs keep an alpha
    /// channel that the device build drops. The file is what `actool` bakes into `Assets.car`
    /// and what Apple's validator judges, so the file is what this asserts on.
    @Test("The 1024 marketing app icon carries no alpha channel")
    func appIconHasNoAlpha() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("Baseline/Assets.xcassets/AppIcon.appiconset/BaselineAppIcon_1024.png")
        #expect(FileManager.default.fileExists(atPath: url.path), "icon missing at \(url.path)")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(
            properties[kCGImagePropertyHasAlpha] as? Bool != true,
            "the app icon carries an alpha channel; App Store upload validation rejects that"
        )
    }

    /// The 1024 is also consumed outside the build, where nothing supplies a default colour space,
    /// so an untagged bitmap leaves the purple ramp unmanaged on wide-gamut displays. This is not a
    /// theoretical risk: the rescale that produced the current artwork lost the profile on save,
    /// because Pillow drops it unless it is passed back explicitly, and neither the build nor Xcode
    /// warned. Reads the file rather than a decoded image for the same reason `appIconHasNoAlpha`
    /// does - the file is what `actool` bakes into `Assets.car`.
    @Test("The 1024 marketing app icon is tagged sRGB")
    func appIconIsTaggedSRGB() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("Baseline/Assets.xcassets/AppIcon.appiconset/BaselineAppIcon_1024.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let profile = properties[kCGImagePropertyProfileName] as? String
        #expect(
            profile?.contains("sRGB") == true,
            "the app icon has no embedded sRGB profile (found \(profile ?? "none")); re-tag it as sRGB rather than converting, because the pixels are already sRGB"
        )
    }

    /// The icon is not a bundled resource of either target, so the test reaches the checked-in
    /// artwork through its own compile-time source location.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BaselineTests
            .deletingLastPathComponent()  // repository root
    }
}
