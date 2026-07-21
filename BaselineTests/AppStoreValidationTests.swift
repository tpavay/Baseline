import Foundation
import ImageIO
import Testing

/// Guards the App Store submission blockers Xcode never warns about: a purpose string missing for
/// something the entitlements permit, an app icon that carries an alpha channel, and a privacy
/// manifest that omits a data type the app actually transmits. The purpose strings are read back
/// off the built host bundle rather than out of `project.yml`, so a broken generated Info.plist
/// cannot pass.
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

    /// The single-photo import fast path relays the athlete's normalized workout photo to the model
    /// provider, which the recognized-text-only durable path never did. If that declaration is ever
    /// dropped while the photo path remains, the failure should land here rather than at App Store
    /// review. Linked and tracking are pinned too: a silent flip to linked would change the answers
    /// owed to the App Store Connect privacy questionnaire.
    @Test("The privacy manifest declares transmitted workout photos")
    func privacyManifestDeclaresPhotos() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Baseline/PrivacyInfo.xcprivacy")
        let manifest = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url),
            format: nil
        ) as? [String: Any]
        let collected = try #require(
            manifest?["NSPrivacyCollectedDataTypes"] as? [[String: Any]],
            "PrivacyInfo.xcprivacy declares no collected data types"
        )
        let declared = collected.first(where: {
            $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypePhotosorVideos"
        })
        let photos = try #require(
            declared,
            "the workout-import fast path transmits photos but the manifest does not declare them"
        )
        #expect(photos["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
        #expect(photos["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        #expect(
            photos["NSPrivacyCollectedDataTypePurposes"] as? [String]
                == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        )
    }

    /// Neither the icon nor the privacy manifest is reachable as a bundled resource of the test
    /// target, so these tests reach the checked-in files through their own compile-time source
    /// location. The checked-in manifest is what XcodeGen copies into the app.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BaselineTests
            .deletingLastPathComponent()  // repository root
    }
}
