"""Read-only analyzer checks against the simulator's exported synthetic store."""
from pathlib import Path
import importlib.util
import hashlib
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("snapshot_analysis", ROOT / "scripts/analyze_snapshot.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SnapshotAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = (ROOT / "dist/synthetic-demo.csstore").read_bytes()

    def report(self):
        versions = [(26, 2, 0), (26, 0, 0), (18, 5, 0)]
        return {"storeSummary":{"sha256":hashlib.sha256(self.data).hexdigest()}, "catalogSource":"Read-only cache registrations",
            "device":{"osVersion":"26.6.2", "osBuild":"DEMO-NOT-A-DEVICE", "architecture":"arm64"},
            "applications":[], "bundleFacts":[{
                "bundleID":f"org.forcelegacyui.sample.{index}",
                "bundlePath":f"/private/var/containers/Bundle/Application/00000000-0000-4000-8000-00000000000{index}/Sample{index}.app",
                "sdk":dict(zip(("major", "minor", "patch"), sdk))
            } for index, sdk in enumerate(versions)]}

    def test_independent_sdk_fields_are_observed_without_authorizing(self):
        output = module.Store(self.data).report(self.report())
        self.assertEqual(len(output["readOnlyObservations"]), 3)
        for row in output["readOnlyObservations"]:
            self.assertEqual(row["candidateIdentityOffsets"], [12, 16])
            self.assertEqual(row["candidateSDKOffsets"], [32])
            self.assertEqual(row["candidateBundleNameOffsets"], [68])
            self.assertEqual(row["candidatePlaceholderOffsets"], [72])
        group = output["executableSDKColumnConsensus"][0]
        self.assertTrue(group["enoughIndependentWitnesses"])
        self.assertEqual(group["sharedSDKOffsetCandidates"], [32])
        self.assertFalse(output["profileGenerated"])
        self.assertFalse(output["liveWriteAuthorized"])

    def test_stale_capture_and_invalid_sdk_are_rejected(self):
        report = self.report(); report["storeSummary"]["sha256"] = "0"*64
        with self.assertRaisesRegex(ValueError, "SHA-256 differ"): module.Store(self.data).report(report)
        report = self.report(); report["bundleFacts"][0]["sdk"]["major"] = True
        with self.assertRaisesRegex(ValueError, "Invalid SDK"): module.Store(self.data).report(report)

    def test_duplicate_evidence_is_not_three_independent_apps(self):
        report = self.report(); report["bundleFacts"].append(report["bundleFacts"][0])
        group = module.Store(self.data).report(report)["executableSDKColumnConsensus"][0]
        self.assertTrue(group["duplicateRecordIdentities"])
        self.assertFalse(group["enoughIndependentWitnesses"])

    def test_cache_decoded_values_are_not_independent_witnesses(self):
        report = self.report(); report["applications"] = [{**fact, "reportedSDK":fact["sdk"]} for fact in report.pop("bundleFacts")]
        output = module.Store(self.data).report(report)
        self.assertEqual(output["readOnlyObservations"], [])
        self.assertEqual(output["executableSDKColumnConsensus"], [])

if __name__ == "__main__": unittest.main()
