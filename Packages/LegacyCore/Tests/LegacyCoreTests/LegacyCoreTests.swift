import XCTest
@testable import LegacyCore

final class LegacyCoreTests: XCTestCase {
    let fixture = DemoFixture.make()
    let validator = SyntheticStoreValidator()
    let profile = DemoFixture.profile
    let device = DemoFixture.device

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func plan(_ data: Data? = nil, id: String = "org.forcelegacyui.sample.0") throws -> PreparedPlan {
        try SDKPlanner.prepare(data: data ?? fixture.data, profile: profile, device: device,
                               targets: [id: .legacy], validator: validator)
    }
    func testHashAndSDKParsing() {
        XCTAssertEqual(sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SDKVersion(string: "26.6.2"), SDKVersion(26, 6, 2))
        for value in ["", "26..2", "26.6.2.1", "-1", "100", "0", "18a"] { XCTAssertNil(SDKVersion(string: value)) }
    }
    func testReadAndCrossValidateSyntheticStore() throws {
        let store = try CSStore(data: fixture.data)
        XCTAssertEqual(store.summary.bundleRecordSizes, [160: 3])
        XCTAssertFalse(store.summary.containsCompatibilityKeyString)
        let records = try store.applications(profile: profile, device: device)
        XCTAssertEqual(try store.crossValidate(records, catalog: fixture.catalog), 3)
    }
    func testEveryTruncationFailsSafely() {
        for length in stride(from: 0, to: fixture.data.count, by: 7) {
            XCTAssertThrowsError(try CSStore(data: Data(fixture.data.prefix(length))))
        }
    }
    func testInvalidPointersAndExcessiveCountsAreRejected() {
        for offset in [24, 96] {
            var data = fixture.data; data.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try CSStore(data: data))
        }
        var unknown = fixture.data; unknown[4] = 3
        XCTAssertThrowsError(try CSStore(data: unknown))
    }
    func testExactBuildAndArchitectureAreRequired() {
        for wrong in [DeviceIdentity(osVersion: "26.6.1", osBuild: device.osBuild, architecture: "arm64", model: "test"),
                      DeviceIdentity(osVersion: "26.6.2", osBuild: "another-build", architecture: "arm64", model: "test"),
                      DeviceIdentity(osVersion: "26.6.2", osBuild: device.osBuild, architecture: "x86_64", model: "test")] {
            XCTAssertThrowsError(try profile.validate(for: wrong))
        }
    }
    func testImportedProfileCannotAuthorizeLiveWrites() {
        XCTAssertThrowsError(try WriteAuthorization.reviewedLive(profile: profile, device: device))
        XCTAssertTrue(ReviewedLayouts.profiles.isEmpty)
    }
    func testSDKMismatchBlocksProfileValidation() throws {
        let store = try CSStore(data: fixture.data)
        let records = try store.applications(profile: profile, device: device)
        let wrong = fixture.catalog.map { InstalledApplication(bundleID: $0.bundleID, name: $0.name, bundlePath: $0.bundlePath, reportedSDK: .legacy) }
        XCTAssertThrowsError(try store.crossValidate(records, catalog: wrong))
        XCTAssertThrowsError(try store.crossValidate(records, catalog: Array(fixture.catalog.prefix(2))))
    }
    func testOnlySDKAndChecksumChange() throws {
        let draft = try plan()
        XCTAssertEqual(draft.changes.count, 1)
        XCTAssertNotEqual(draft.original, draft.candidate)
        for i in draft.original.indices where draft.original[i] != draft.candidate[i] {
            XCTAssertTrue(draft.patches.contains { $0.range.contains(i) })
        }
        try validator.validate(draft.candidate)
        XCTAssertEqual(try CSStore(data: draft.candidate).applications(profile: profile, device: device).first?.sdk, .legacy)
    }
    func testMissingAppAndNoOpAreRejected() {
        XCTAssertThrowsError(try plan(id: "missing.app"))
        XCTAssertThrowsError(try SDKPlanner.prepare(data: fixture.data, profile: profile, device: device,
            targets: [fixture.catalog[0].id: fixture.catalog[0].reportedSDK!], validator: validator))
    }
    func testApplyBackupAndRestorePreserveUnrelatedLaterChange() throws {
        let root = try temporaryRoot(), file = root.appendingPathComponent("test.csstore"), backups = root.appendingPathComponent("Backups")
        try fixture.data.write(to: file)
        let first = try TransactionEngine.apply(plan(), to: file, backups: backups,
            authorization: .appOwned(directory: root), validator: validator)
        XCTAssertEqual(first.status, .applied)
        let changed = try Data(contentsOf: file)
        let other = try plan(changed, id: "org.forcelegacyui.sample.1")
        _ = try TransactionEngine.apply(other, to: file, backups: backups, authorization: .appOwned(directory: root), validator: validator)
        let restore = try TransactionEngine.restorationPlan(backup: first, current: Data(contentsOf: file), profile: profile, device: device, validator: validator)
        _ = try TransactionEngine.apply(restore, to: file, backups: backups, authorization: .appOwned(directory: root), validator: validator)
        let apps = try CSStore(data: Data(contentsOf: file)).applications(profile: profile, device: device)
        XCTAssertEqual(apps[0].sdk, fixture.catalog[0].reportedSDK)
        XCTAssertEqual(apps[1].sdk, .legacy)
    }
    func testStalePreviewCannotWrite() throws {
        let root = try temporaryRoot(), file = root.appendingPathComponent("test.csstore")
        let draft = try plan(); var changed = fixture.data; changed[7] ^= 1; try changed.write(to: file)
        XCTAssertThrowsError(try TransactionEngine.apply(draft, to: file, backups: root.appendingPathComponent("Backups"),
            authorization: .appOwned(directory: root), validator: validator))
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
    func testSymlinkAndDirectoryEscapeAreRejected() throws {
        let root = try temporaryRoot(), file = root.appendingPathComponent("test.csstore"), link = root.appendingPathComponent("link.csstore")
        try fixture.data.write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TransactionEngine.readSnapshot(link))
        let other = root.appendingPathComponent("Other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertThrowsError(try TransactionEngine.apply(plan(), to: file, backups: root.appendingPathComponent("Backups"),
            authorization: .appOwned(directory: other), validator: validator))
    }
    func testCorruptBackupIsReported() throws {
        let root = try temporaryRoot(), file = root.appendingPathComponent("test.csstore"), backups = root.appendingPathComponent("Backups")
        try fixture.data.write(to: file)
        let entry = try TransactionEngine.apply(plan(), to: file, backups: backups, authorization: .appOwned(directory: root), validator: validator)
        try Data("damaged".utf8).write(to: entry.directory.appendingPathComponent("original.csstore"))
        XCTAssertThrowsError(try BackupRepository.list(backups))
    }
    func testVerificationFailureRollsBack() throws {
        final class FailOnce: StoreValidator {
            var calls = 0
            func validate(_ data: Data) throws {
                calls += 1
                if calls == 2 { throw LegacyError.invalid("Injected post-write failure") }
                try SyntheticStoreValidator().validate(data)
            }
            func repairingChecksum(_ data: Data) throws -> Data { try SyntheticStoreValidator().repairingChecksum(data) }
        }
        let root = try temporaryRoot(), file = root.appendingPathComponent("test.csstore"), backups = root.appendingPathComponent("Backups")
        try fixture.data.write(to: file)
        XCTAssertThrowsError(try TransactionEngine.apply(plan(), to: file, backups: backups,
            authorization: .appOwned(directory: root), validator: FailOnce()))
        XCTAssertEqual(try Data(contentsOf: file), fixture.data)
        XCTAssertEqual(try BackupRepository.list(backups).first?.status, .rolledBack)
    }
    func testChecksumRepairCannotModifyOtherFields() {
        struct BadValidator: StoreValidator {
            func validate(_ data: Data) throws { }
            func repairingChecksum(_ data: Data) throws -> Data { var result = data; result[50] ^= 1; return result }
        }
        XCTAssertThrowsError(try SDKPlanner.prepare(data: fixture.data, profile: profile, device: device,
            targets: [fixture.catalog[0].id: .legacy], validator: BadValidator()))
    }
}
