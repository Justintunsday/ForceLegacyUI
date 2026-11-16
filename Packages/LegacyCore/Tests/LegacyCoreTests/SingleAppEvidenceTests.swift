import XCTest
@testable import LegacyCore

final class SingleAppEvidenceTests: XCTestCase {
    let fixture = DemoFixture.make(), validator = SyntheticStoreValidator()
    let source = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/InternalDaemon/04BA7A11-12F4-4567-89AB-0123456789AB/Library/Caches/com.apple.LaunchServices-1-v2.csstore")
    var facts: [BundleSDKObservation] {
        fixture.catalog.map { BundleSDKObservation(bundleID: $0.bundleID, bundlePath: $0.bundlePath, sdk: $0.reportedSDK!,
            infoSHA256: sha256(Data("info-\($0.bundleID)".utf8)), loadCommandsSHA256: sha256(Data("headers-\($0.bundleID)".utf8))) }
    }
    func evidence(_ observations: [BundleSDKObservation]? = nil, data: Data? = nil) throws -> SDKSnapshotEvidence {
        try .validate(data: data ?? fixture.data, profile: DemoFixture.profile, device: DemoFixture.device,
                      observations: observations ?? facts, validator: validator)
    }
    func plan(_ data: Data? = nil, targets: [String: SDKVersion]? = nil) throws -> PreparedPlan {
        try SDKPlanner.prepare(data: data ?? fixture.data, profile: DemoFixture.profile, device: DemoFixture.device,
                               targets: targets ?? [fixture.catalog[0].id: .legacy], validator: validator)
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testIndependentEvidenceAllowsExactlyOneSnapshotBoundPlan() throws {
        let plan = try plan(), proof = try evidence()
        let auth = try WriteAuthorization.validatedSingleApp(plan: plan, evidence: proof, source: source)
        try auth.validate(url: source, plan: plan)
        XCTAssertThrowsError(try auth.validate(url: source.deletingLastPathComponent().appendingPathComponent("com.apple.LaunchServices-2-v2.csstore"), plan: plan))
        let batch = try self.plan(targets: [fixture.catalog[0].id:.legacy, fixture.catalog[1].id:.legacy])
        XCTAssertThrowsError(try WriteAuthorization.validatedSingleApp(plan: batch, evidence: proof, source: source))
        XCTAssertThrowsError(try auth.validate(url: source, plan: batch))
    }
    func testStaleSnapshotAndUnobservedSelectedAppCannotAuthorize() throws {
        let proof = try evidence(), altered = try plan(targets: [fixture.catalog[1].id:.legacy]).candidate
        XCTAssertThrowsError(try WriteAuthorization.validatedSingleApp(plan: plan(altered), evidence: proof, source: source))
        XCTAssertThrowsError(try evidence(Array(facts.prefix(2))))
        XCTAssertThrowsError(try evidence(facts + [facts[0]]))
    }
    func testSDKPathAndMetadataFingerprintsMustMatch() throws {
        let original = facts[0]
        for bad in [
            BundleSDKObservation(bundleID: original.bundleID, bundlePath: original.bundlePath, sdk: .legacy, infoSHA256: original.infoSHA256, loadCommandsSHA256: original.loadCommandsSHA256),
            BundleSDKObservation(bundleID: original.bundleID, bundlePath: original.bundlePath+"/../Other.app", sdk: original.sdk, infoSHA256: original.infoSHA256, loadCommandsSHA256: original.loadCommandsSHA256),
            BundleSDKObservation(bundleID: original.bundleID, bundlePath: original.bundlePath, sdk: original.sdk, infoSHA256: "unchecked", loadCommandsSHA256: original.loadCommandsSHA256)
        ] { XCTAssertThrowsError(try evidence([bad] + Array(facts.dropFirst()))) }
    }
    func testDuplicateSDKTripleDoesNotSelectAnArbitraryColumn() throws {
        let store = try CSStore(data: fixture.data), unit = try XCTUnwrap(store.tables["Bundle"]?.values.first)
        var data = fixture.data
        data.replaceSubrange((unit.body+100)..<(unit.body+124), with: data.subdata(in: (unit.body+32)..<(unit.body+56)))
        data = SyntheticStoreValidator.repair(data)
        XCTAssertThrowsError(try evidence(data: data))
    }
    func testLivePathPolicyRejectsDiagnosticsTraversalAndNestedContainers() throws {
        XCTAssertTrue(LiveStorePolicy.storePath(source.path))
        XCTAssertTrue(LiveStorePolicy.storePath(source.path.replacingOccurrences(of: "InternalDaemon", with: "System")))
        for path in [source.path.replacingOccurrences(of: "/com.apple.LaunchServices", with: "/SystemDataOnly-com.apple.LaunchServices"),
                     source.path.replacingOccurrences(of: "04BA7A11-12F4-4567-89AB-0123456789AB", with: "unverified"),
                     source.path.replacingOccurrences(of: "/Library/Caches", with: "/Other/Library/Caches"),
                     source.path.replacingOccurrences(of: "/Library/Caches", with: "/Library/../Library/Caches")] {
            XCTAssertFalse(LiveStorePolicy.storePath(path))
        }
    }
    func testWritableOpenProbeDoesNotChangeAByte() throws {
        let root = try root(), file = root.appendingPathComponent("store.csstore")
        try fixture.data.write(to: file)
        try TransactionEngine.probeWritable(file, expected: fixture.data)
        XCTAssertEqual(try Data(contentsOf: file), fixture.data)
        XCTAssertThrowsError(try TransactionEngine.probeWritable(file, expected: plan().candidate))
    }
    func testReceiptPersistsLayoutAndIndependentEvidenceForRestoreAndRecovery() throws {
        let root = try root(), file = root.appendingPathComponent("fixture.csstore"), plan = try plan()
        try fixture.data.write(to: file)
        let seed = try TransactionEngine.apply(plan, to: file, backups: root.appendingPathComponent("Seed"),
                                               authorization: .appOwned(directory: root), validator: validator)
        let entry = try BackupRepository.create(plan: plan, source: source, identity: seed.receipt.identity,
                                                root: root.appendingPathComponent("Evidence"), bundleEvidence: facts)
        try BackupRepository.setStatus(.applied, directory: entry.directory)
        let loaded = try BackupRepository.load(entry.directory)
        XCTAssertEqual(loaded.receipt.layout, DemoFixture.profile)
        XCTAssertEqual(loaded.receipt.bundleEvidence, facts)
        let undo = try TransactionEngine.restorationPlan(backup: loaded, current: plan.candidate, profile: DemoFixture.profile,
                                                        device: DemoFixture.device, validator: validator)
        let auth = try WriteAuthorization.validatedRestoration(plan: undo, backup: loaded, observations: facts, source: source, validator: validator)
        try auth.validate(url: source, plan: undo)
        var changed = facts
        changed[0] = BundleSDKObservation(bundleID: facts[0].bundleID, bundlePath: facts[0].bundlePath, sdk: facts[0].sdk,
                                          infoSHA256: sha256(Data("updated Info.plist".utf8)), loadCommandsSHA256: facts[0].loadCommandsSHA256)
        XCTAssertThrowsError(try WriteAuthorization.validatedRestoration(plan: undo, backup: loaded, observations: changed, source: source, validator: validator))
        try BackupRepository.setStatus(.needsRecovery, directory: entry.directory)
        let recovery = try WriteAuthorization.validatedRecovery(backup: BackupRepository.load(entry.directory), profile: DemoFixture.profile,
            device: DemoFixture.device, observations: facts, source: source, validator: validator)
        try recovery.validate(url: source, plan: plan)
    }
    func testEvidenceZIPInteroperatesWithSystemUnzip() throws {
        let root = try root(), zip = root.appendingPathComponent("evidence.zip")
        let files = ["report.json":Data("{\"verified\":false}".utf8), "snapshot.csstore":fixture.data, "snapshot.sha256":Data(sha256(fixture.data).utf8)]
        try EvidenceArchive.make(files: files).write(to: zip)
        for (name, bytes) in files {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", zip.path, name]
            process.standardOutput = pipe; try process.run()
            let result = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); XCTAssertEqual(result, bytes)
        }
        XCTAssertThrowsError(try EvidenceArchive.make(files: ["../escape":Data()]))
        XCTAssertThrowsError(try EvidenceArchive.make(files: ["/absolute":Data()]))
    }

    func testCandidateSignaturesNeedActualThreeAppSDKCorrelation() throws {
        for shape in RuntimeLayoutCandidates.candidates(for: DemoFixture.device) {
            // Alternate synthetic shapes test the checker; these are not captured phone records.
            let shaped = DemoFixture.make(profile: shape)
            var log = ""
            let match = try RuntimeLayoutCandidates.correlate(data: shaped.data, device: DemoFixture.device,
                observations: facts, validator: validator, log: &log)
            XCTAssertEqual(match, shape)
            XCTAssertNil(try RuntimeLayoutCandidates.correlate(data: shaped.data, device: DemoFixture.device,
                observations: Array(facts.prefix(2)), validator: validator, log: &log))
            var changed = facts
            changed[0] = BundleSDKObservation(bundleID: facts[0].bundleID, bundlePath: facts[0].bundlePath, sdk: SDKVersion(26, 5),
                infoSHA256: facts[0].infoSHA256, loadCommandsSHA256: facts[0].loadCommandsSHA256)
            XCTAssertNil(try RuntimeLayoutCandidates.correlate(data: shaped.data, device: DemoFixture.device,
                observations: changed, validator: validator, log: &log))
        }
    }
    func testAByteCountOrUnsupportedOSCannotSelectCandidateOffsets() throws {
        let base = try XCTUnwrap(RuntimeLayoutCandidates.candidates(for: DemoFixture.device).first)
        let shifted = LayoutProfile(id: "synthetic-shifted", osVersion: base.osVersion, osBuild: base.osBuild,
            architectures: base.architectures, recordSize: base.recordSize, identifier: base.identifier,
            duplicateIdentifier: base.duplicateIdentifier, kind: base.kind, sdk: base.sdk+4, name: base.name,
            fallbackName: base.fallbackName, bundleName: base.bundleName, placeholder: base.placeholder, signer: base.signer,
            evidence: ["Synthetic shifted field; not a real layout"])
        var log = ""
        XCTAssertNil(try RuntimeLayoutCandidates.correlate(data: DemoFixture.make(profile: shifted).data,
            device: DemoFixture.device, observations: facts, validator: validator, log: &log))
        XCTAssertTrue(RuntimeLayoutCandidates.candidates(for: DeviceIdentity(osVersion: "27.1", osBuild: "other",
            architecture: "arm64", model: "test")).isEmpty)
    }
}
