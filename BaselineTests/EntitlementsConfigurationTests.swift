import Foundation
import Testing

/// Guards the per-configuration entitlements split. A wrong App Attest environment never fails a
/// build - the `match AppStore` profiles permit both values - and only surfaces on a real device
/// talking to Apple's servers, so the checked-in files are asserted on directly.
///
/// The rules encoded here come from Apple's App Attest documentation:
/// - An app that omits `com.apple.developer.devicecheck.appattest-environment` uses the sandbox
///   during development; setting it to `production` opts a development build into the real
///   servers and pollutes that device's unresettable risk metrics.
/// - "After distributing your app through TestFlight, the App Store, or the Apple Developer
///   Enterprise Program, your app ignores the entitlement you set and uses the production
///   environment." Staging ships through TestFlight, so it stays on `production`; `development`
///   there would be an inert value that misdescribes the build.
struct EntitlementsConfigurationTests {

    private static let appAttestEnvironmentKey = "com.apple.developer.devicecheck.appattest-environment"

    @Test("Debug builds attest against the App Attest sandbox")
    func debugUsesSandboxEnvironment() throws {
        let entitlements = try Self.entitlements(named: "Baseline-Debug")
        #expect(entitlements[Self.appAttestEnvironmentKey] as? String == "development")
    }

    /// Both distribution configs share this file. Neither may move to `development`: Release is an
    /// App Store build and Staging is a TestFlight build, and Apple forces production on both.
    @Test("Staging and Release attest against the App Attest production environment")
    func distributionUsesProductionEnvironment() throws {
        let entitlements = try Self.entitlements(named: "Baseline")
        #expect(entitlements[Self.appAttestEnvironmentKey] as? String == "production")
    }

    /// The App Attest environment is the only key that legitimately differs between the two files.
    /// Anything else added to one and forgotten in the other silently changes a build's
    /// capabilities, so drift fails here rather than in App Store upload validation.
    @Test("The two entitlements files differ only in the App Attest environment")
    func filesAgreeOnEveryOtherEntitlement() throws {
        let debug = try Self.entitlements(named: "Baseline-Debug")
        let distribution = try Self.entitlements(named: "Baseline")

        #expect(
            Set(debug.keys) == Set(distribution.keys),
            "entitlement keys differ: \(Set(debug.keys).symmetricDifference(Set(distribution.keys)))"
        )
        for key in debug.keys where key != Self.appAttestEnvironmentKey {
            let debugValue = debug[key].map { String(describing: $0) }
            let distributionValue = distribution[key].map { String(describing: $0) }
            #expect(debugValue == distributionValue, "\(key) differs between the entitlements files")
        }
    }

    /// XcodeGen owns the wiring; the .xcodeproj is regenerated on every build, so `project.yml` is
    /// the only durable record that Debug gets the sandbox file at all.
    @Test("project.yml points the Debug configuration at the sandbox entitlements file")
    func projectSpecWiresTheDebugOverride() throws {
        let spec = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(spec.contains("CODE_SIGN_ENTITLEMENTS: Baseline/Baseline-Debug.entitlements"))
        #expect(spec.contains("CODE_SIGN_ENTITLEMENTS: Baseline/Baseline.entitlements"))
    }

    private static func entitlements(named name: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("Baseline/\(name).entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any], "\(name).entitlements is not a dictionary")
    }

    /// The entitlements files are build inputs rather than bundled resources, so the test reaches
    /// the checked-in sources through its own compile-time location, as `AppStoreValidationTests`
    /// does for the app icon.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BaselineTests
            .deletingLastPathComponent()  // repository root
    }
}
