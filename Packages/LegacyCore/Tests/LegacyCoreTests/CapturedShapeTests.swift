import XCTest
@testable import LegacyCore

/// All bytes/identities are synthetic. No phone snapshot is included in the repository or CI.
final class CapturedShapeTests: XCTestCase {
    let device = DeviceIdentity(osVersion: "26.6.2", osBuild: "23G90", architecture: "arm64", model: "Synthetic shape test")
    let validator = SyntheticStoreValidator()
    func profile() throws -> LayoutProfile {
        try XCTUnwrap(RuntimeLayoutCandidates.candidates(for: device).first { $0.recordSize == 572 })
    }
    func facts(_ fixture: DemoFixture) -> [BundleSDKObservation] {
        fixture.catalog.map { BundleSDKObservation(bundleID: $0.bundleID, bundlePath: $0.bundlePath, sdk: $0.reportedSDK!,
            infoSHA256: sha256(Data("info-\($0.bundleID)".utf8)), loadCommandsSHA256: sha256(Data("headers-\($0.bundleID)".utf8))) }
    }
    func put32(_ value: UInt32, in data: inout Data, at offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset+4), with: $0) }
    }
    func test572CandidateIsBoundToCapturedOSBuildAndArchitecture() throws {
        let candidate = try profile()
        XCTAssertEqual(candidate.sdk, 64); XCTAssertEqual(candidate.placeholder, 564)
        XCTAssertEqual(candidate.bundleName, 320); XCTAssertEqual(candidate.name, 112)
        for other in [DeviceIdentity(osVersion: "26.6.2", osBuild: "other", architecture: "arm64", model: "test"),
                      DeviceIdentity(osVersion: "26.6.1", osBuild: "23G90", architecture: "arm64", model: "test"),
                      DeviceIdentity(osVersion: "26.6.2", osBuild: "23G90", architecture: "arm64e", model: "test")] {
            XCTAssertFalse(RuntimeLayoutCandidates.candidates(for: other).contains { $0.recordSize == 572 })
        }
        XCTAssertTrue(ReviewedLayouts.profiles.isEmpty); XCTAssertTrue(ReviewedLayouts.liveWriteDigests.isEmpty)
    }
    func testOneWitnessExplainsCandidateValuesButCannotAuthorizeWriting() throws {
        let candidate = try profile(), fixture = DemoFixture.make(profile: candidate)
        let one = Array(facts(fixture).prefix(1)); var log = ""
        let readOnly = try XCTUnwrap(RuntimeLayoutCandidates.inspectReadOnly(data: fixture.data, device: device,
            observations: one, validator: validator, log: &log))
        XCTAssertEqual(readOnly.records.count, 3); XCTAssertEqual(readOnly.profile, candidate)
        XCTAssertTrue(log.contains("do not authorize writes"))
        XCTAssertNil(try RuntimeLayoutCandidates.correlate(data: fixture.data, device: device,
            observations: one, validator: validator, log: &log))
        XCTAssertThrowsError(try SDKSnapshotEvidence.validate(data: fixture.data, profile: candidate, device: device,
            observations: one, validator: validator))
        XCTAssertNil(try RuntimeLayoutCandidates.inspectReadOnly(data: fixture.data, device: device,
            observations: [], validator: validator, log: &log))
    }
    func testReadOnlyCandidateStillRejectsWrongSDKOrAmbiguousColumn() throws {
        let candidate = try profile(), fixture = DemoFixture.make(profile: candidate), fact = facts(fixture)[0]
        let wrong = BundleSDKObservation(bundleID: fact.bundleID, bundlePath: fact.bundlePath, sdk: .legacy,
            infoSHA256: fact.infoSHA256, loadCommandsSHA256: fact.loadCommandsSHA256)
        XCTAssertThrowsError(try ReadOnlyLayoutEvidence.validate(data: fixture.data, profile: candidate, device: device,
            observations: [wrong], validator: validator))
        let unit = try XCTUnwrap(CSStore(data: fixture.data).tables["Bundle"]?[1])
        var data = fixture.data
        data.replaceSubrange((unit.body+400)..<(unit.body+424), with: fact.sdk.bytes)
        data = SyntheticStoreValidator.repair(data)
        XCTAssertThrowsError(try ReadOnlyLayoutEvidence.validate(data: data, profile: candidate, device: device,
            observations: [fact], validator: validator))
    }
    func testNullPlaceholdersAndDotlessIdentitiesAreExcludedButMalformedPathsFail() throws {
        let candidate = try profile(), fixture = DemoFixture.make(profile: candidate)
        let store = try CSStore(data: fixture.data), unit = try XCTUnwrap(store.tables["Bundle"]?[1])
        var data = fixture.data
        put32(0, in: &data, at: unit.body+candidate.placeholder)
        XCTAssertEqual(try CSStore(data: data).applications(profile: candidate, device: device).count, 2)
        XCTAssertThrowsError(try ReadOnlyLayoutEvidence.validate(data: SyntheticStoreValidator.repair(data), profile: candidate,
            device: device, observations: facts(fixture), validator: validator))
        data = fixture.data
        let nameKey = try BoundedBytes(data: data).u32(unit.body+candidate.name)
        put32(nameKey, in: &data, at: unit.body+candidate.identifier)
        put32(nameKey, in: &data, at: unit.body+candidate.duplicateIdentifier)
        XCTAssertEqual(try CSStore(data: data).applications(profile: candidate, device: device).count, 2)
        data = fixture.data
        put32(nameKey, in: &data, at: unit.body+candidate.placeholder)
        XCTAssertThrowsError(try CSStore(data: data).applications(profile: candidate, device: device))
    }
    func test572SyntheticPlanChangesOnlyOneSDKAndChecksumAfterFullEvidence() throws {
        let candidate = try profile(), fixture = DemoFixture.make(profile: candidate)
        let proof = try SDKSnapshotEvidence.validate(data: fixture.data, profile: candidate, device: device,
            observations: facts(fixture), validator: validator)
        let plan = try SDKPlanner.prepare(data: fixture.data, profile: candidate, device: device,
            targets: [fixture.catalog[0].bundleID:.legacy], validator: validator)
        let source = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/InternalDaemon/04BA7A11-12F4-4567-89AB-0123456789AB/Library/Caches/com.apple.LaunchServices-1-v2.csstore")
        _ = try WriteAuthorization.validatedSingleApp(plan: plan, evidence: proof, source: source)
        let record = try XCTUnwrap(CSStore(data: fixture.data).applications(profile: candidate, device: device).first)
        for offset in fixture.data.indices where fixture.data[offset] != plan.candidate[offset] {
            XCTAssertTrue((6..<8).contains(offset) || (record.sdkOffset..<(record.sdkOffset+24)).contains(offset))
        }
        XCTAssertEqual(try CSStore(data: plan.candidate).applications(profile: candidate, device: device).first?.sdk, .legacy)
    }
}
