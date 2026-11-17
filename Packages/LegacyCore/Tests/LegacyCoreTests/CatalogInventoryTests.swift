import XCTest
@testable import LegacyCore

final class CatalogInventoryTests: XCTestCase {
    let catalog = DemoFixture.make().catalog
    func cache(_ app: InstalledApplication) -> InstalledApplication {
        InstalledApplication(bundleID: app.bundleID, name: app.name, bundlePath: app.bundlePath,
                             reportedSDK: nil, applicationType: "Cache registration (read-only)")
    }
    func testOneNativeRecordDoesNotSuppressOtherCacheRegistrations() throws {
        let result = try CatalogInventory.reconcile(native: Array(catalog.prefix(1)), registrations: catalog.map(cache))
        XCTAssertEqual(result.applications.count, 3)
        XCTAssertEqual(result.addedFromCache, 2); XCTAssertEqual(result.filledMissingPaths, 0)
        XCTAssertEqual(result.applications[0], catalog[0])
        XCTAssertNil(result.applications[1].reportedSDK); XCTAssertNil(result.applications[2].reportedSDK)
    }
    func testAnEmptyNativePathCanUseAnObservedCachePathWithoutPromotingItsSDK() throws {
        let incomplete = InstalledApplication(bundleID: catalog[0].bundleID, name: "Observed name", bundlePath: "", reportedSDK: .legacy)
        let result = try CatalogInventory.reconcile(native: [incomplete], registrations: [catalog[0]])
        XCTAssertEqual(result.filledMissingPaths, 1); XCTAssertEqual(result.applications[0].bundlePath, catalog[0].bundlePath)
        XCTAssertEqual(result.applications[0].name, incomplete.name); XCTAssertNil(result.applications[0].reportedSDK)
        XCTAssertTrue(result.applications[0].applicationType.contains("Cache"))
    }
    func testConflictingUUIDsAndDuplicateIdentitiesAreExcluded() throws {
        let a = catalog[0]
        let other = InstalledApplication(bundleID: a.bundleID, name: a.name,
            bundlePath: a.bundlePath.replacingOccurrences(of: "000000000000", with: "000000000009"), reportedSDK: a.reportedSDK)
        for (native, registrations) in [([other], [cache(a)]), ([a,a], [cache(a)]), ([a], [cache(a),cache(a)])] {
            let result = try CatalogInventory.reconcile(native: native, registrations: registrations)
            XCTAssertEqual(result.excludedConflicts, 1); XCTAssertTrue(result.applications.isEmpty)
        }
    }
    func testSpellingAliasesPreserveNativeFactsAndOutOfScopeCachePathsAreIgnored() throws {
        let a = catalog[0]
        let folded = InstalledApplication(bundleID: a.bundleID, name: "Cache spelling",
            bundlePath: a.bundlePath.replacingOccurrences(of: "Sample0.app", with: "sample0.app"), reportedSDK: nil)
        let invalid = InstalledApplication(bundleID: "org.example.unrelated", name: "Unrelated",
            bundlePath: "/private/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000000/Other.app", reportedSDK: .legacy)
        let result = try CatalogInventory.reconcile(native: [a], registrations: [folded,invalid])
        XCTAssertEqual(result.applications, [a]); XCTAssertEqual(result.excludedConflicts, 0)
    }
    func testEmptyNativeCatalogNeverTurnsCacheSDKValuesIntoNativeWitnesses() throws {
        let result = try CatalogInventory.reconcile(native: [], registrations: catalog)
        XCTAssertEqual(result.applications.map(\.bundleID), catalog.map(\.bundleID))
        XCTAssertTrue(result.applications.allSatisfy { $0.reportedSDK == nil })
        XCTAssertEqual(result.addedFromCache, 3)
        XCTAssertThrowsError(try CatalogInventory.reconcile(native: Array(repeating: catalog[0], count: 10001), registrations: []))
    }
}
