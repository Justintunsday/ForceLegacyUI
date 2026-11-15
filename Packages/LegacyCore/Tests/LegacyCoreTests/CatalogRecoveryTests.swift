import XCTest
@testable import LegacyCore

final class CatalogRecoveryTests: XCTestCase {
    private let configured = "group.org.forcelegacyui.app"
    private let bundleID = "org.forcelegacyui.app.TEAM123"

    func testConfiguredGroupUsesRuntimeAccessEvenWithoutEntitlementReader() {
        let result = AppGroupResolution.resolve(configured: configured, bundleID: bundleID,
            reportedGroups: [], accessibleGroups: [configured])
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.selected, configured)
    }
    func testRewrittenSigningGroupIsResolved() {
        let renamed = configured + ".TEAM123"
        let result = AppGroupResolution.resolve(configured: configured, bundleID: bundleID,
            reportedGroups: [renamed], accessibleGroups: [renamed])
        XCTAssertEqual(result.state, .renamed)
        XCTAssertEqual(result.selected, renamed)
    }
    func testTeamPrefixRewriteIsResolved() {
        let renamed = "group.TEAM123.org.forcelegacyui.app"
        let result = AppGroupResolution.resolve(configured: configured, bundleID: bundleID,
            reportedGroups: [renamed], accessibleGroups: [renamed])
        XCTAssertEqual(result.state, .renamed)
        XCTAssertEqual(result.selected, renamed)
    }
    func testUnrelatedSharedGroupIsNeverChosen() {
        let unrelated = "group.com.example.sidestore.shared"
        let result = AppGroupResolution.resolve(configured: configured, bundleID: bundleID,
            reportedGroups: [unrelated], accessibleGroups: [unrelated])
        XCTAssertEqual(result.state, .missing)
        XCTAssertNil(result.selected)
    }
    func testAmbiguousRewritesAreRejected() {
        let first = configured + ".FIRST", second = configured + ".SECOND"
        let result = AppGroupResolution.resolve(configured: configured, bundleID: "org.example.custom",
            reportedGroups: [first, second], accessibleGroups: [first, second])
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertNil(result.selected)
    }
    func testReportedGroupWithoutRuntimePermissionIsRejected() {
        let result = AppGroupResolution.resolve(configured: configured, bundleID: bundleID,
            reportedGroups: [configured], accessibleGroups: [])
        XCTAssertEqual(result.state, .missing)
        XCTAssertNil(result.selected)
    }
    func testInvalidAndWildcardGroupsAreExcluded() {
        let values = [configured + ".*", configured + "/Caches", configured + "..bad", configured + "."]
        let candidates = AppGroupResolution.candidates(configured: configured, bundleID: bundleID, reportedGroups: values)
        XCTAssertTrue(values.allSatisfy { !candidates.contains($0) })
    }
    func testUnknownLayoutStillPermitsReadOnlyRegistrationInventory() throws {
        let fixture = DemoFixture.make()
        let registrations = try CSStore(data: fixture.data).discoverRegistrations()
        XCTAssertEqual(registrations.map(\.bundleID), fixture.catalog.map(\.bundleID))
        XCTAssertEqual(registrations.map(\.bundlePath), fixture.catalog.map(\.bundlePath))
        XCTAssertTrue(registrations.allSatisfy { $0.reportedSDK == nil && $0.applicationType == "Cache registration (read-only)" })
        XCTAssertTrue(ReviewedLayouts.liveWriteDigests.isEmpty)
    }
    func testCacheFallbackDoesNotInventAnSDK() throws {
        let fixture = DemoFixture.make()
        let store = try CSStore(data: fixture.data)
        let records = try store.applications(profile: DemoFixture.profile, device: DemoFixture.device)
        var changed = fixture.data
        for record in records { changed.replaceSubrange(record.sdkOffset..<(record.sdkOffset + 24), with: Data(repeating: 255, count: 24)) }
        let registrations = try CSStore(data: changed).discoverRegistrations()
        XCTAssertEqual(registrations.count, 3)
        XCTAssertTrue(registrations.allSatisfy { $0.reportedSDK == nil })
    }
    func testCacheFallbackRejectsARecordWithoutRepeatedIdentity() throws {
        let fixture = DemoFixture.make()
        let store = try CSStore(data: fixture.data)
        let unit = try XCTUnwrap(store.tables["Bundle"]?.values.first)
        var changed = fixture.data
        changed.replaceSubrange((unit.body + DemoFixture.profile.identifier)..<(unit.body + DemoFixture.profile.identifier + 4), with: [0, 0, 0, 0])
        changed.replaceSubrange((unit.body + DemoFixture.profile.duplicateIdentifier)..<(unit.body + DemoFixture.profile.duplicateIdentifier + 4), with: [0, 0, 0, 0])
        XCTAssertEqual(try CSStore(data: changed).discoverRegistrations().count, 2)
    }
}
