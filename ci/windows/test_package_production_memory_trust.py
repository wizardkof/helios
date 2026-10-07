import unittest
import hashlib
from pathlib import Path


ROOT = Path(__file__).parents[2]


class PackageProductionMemoryTrustTests(unittest.TestCase):
    def test_audit_requires_explicit_verifier_and_never_mutates_a_persistent_store(self):
        audit = ROOT.joinpath("ci/windows/Audit-CIPackage.ps1").read_text(encoding="utf-8-sig")
        self.assertRegex(audit, r"\[Parameter\(Mandatory\)\]\[string\]\$Verifier")
        self.assertNotIn("Import-Certificate", audit)
        self.assertNotIn("Cert:\\CurrentUser\\Root", audit)
        self.assertNotRegex(audit, r"Remove-Item\s+\$store")
        self.assertIn("persistentStoreMutation", audit)
        self.assertIn("EXCLUSIVE_MEMORY_PEER", audit)

    def test_audit_binds_manifest_certificate_and_verifier_receipt_to_exact_bytes(self):
        audit = ROOT.joinpath("ci/windows/Audit-CIPackage.ps1").read_text(encoding="utf-8-sig")
        for required in (
            "manifest.signing.thumbprint",
            "manifest.signing.subject",
            "certificate/helios-ci-test.cer",
            "stateVerifyCount",
            "stateCloseCount",
            "signerDerMatch",
            "packageCertificateDerSha256",
            "Get-AuthenticodeSignature",
            "CryptCATAdminCalcHashFromFileHandle2",
        ):
            self.assertIn(required, audit)
        self.assertIn("CATALOG_MEMBER_VERIFY", audit)
        self.assertIn("AUTHENTICODE_VERIFY", audit)
        native = ROOT.joinpath("ci/windows/memory-trust/package_verify.cpp").read_bytes()
        gate = ROOT.joinpath("ci/windows/memory-trust/result_gate.h").read_bytes()
        self.assertEqual(hashlib.sha256(native).hexdigest(), "d8ccc0571583f056e1494c731862e89d27b23151efe0963104b28fc575c7bdb3")
        self.assertEqual(hashlib.sha256(gate).hexdigest(), "6dc0fb254ebec768ea2de881ef9c790730775654cab39161df33d9457af35a61")

    def test_verifier_build_is_pinned_and_output_is_outside_the_package(self):
        build = ROOT.joinpath("ci/windows/Build-PackageVerifier.ps1").read_text(encoding="utf-8-sig")
        for required in (
            "Initialize-HeliosBuild.ps1",
            "Import-VisualStudioEnvironment -Architecture x64",
            "/std:c++17",
            "/EHsc",
            "/W4",
            "/DUNICODE",
            "/D_UNICODE",
            "wintrust.lib",
            "crypt32.lib",
            "psapi.lib",
            "RUNNER_TEMP",
            "sourceSha256",
            "compilerPath",
            "compilerVersion",
            "/Bv @arguments",
            "compilerExitCode",
            "outputSha256",
            "outputSize",
            "peMachine",
        ):
            self.assertIn(required, build)
        assembly = ROOT.joinpath("ci/windows/Assemble-Package.ps1").read_text(encoding="utf-8-sig")
        self.assertNotIn("package-verify.exe", assembly)

    def test_package_workflow_uses_35_minutes_and_separate_success_gated_steps(self):
        import yaml

        workflow = yaml.safe_load(ROOT.joinpath(".github/workflows/windows-stack.yml").read_text())
        package = workflow["jobs"]["package"]
        self.assertEqual(package["timeout-minutes"], 35)
        self.assertEqual(workflow["jobs"]["package_production_integration_preflight"]["timeout-minutes"], 35)
        self.assertEqual(workflow["jobs"]["producer_audit_control"]["timeout-minutes"], 35)
        names = [step.get("name", "") for step in package["steps"]]
        for name in (
            "Independent final extraction",
            "Native Authenticode and catalog package audit",
            "Post-package toolchain",
            "Post-package source fingerprint",
            "Qualification report and final hash index",
            "Seal final Package artifact",
            "Upload final Package artifact",
            "Download final Package artifact",
            "Verify final Package artifact roundtrip",
        ):
            self.assertTrue(any(item.startswith(name) for item in names), name)
        self.assertNotIn("SIGNTOOL_EXECUTED", "\n".join(names))

    def test_workflow_step_references_are_real_and_seals_are_unique(self):
        import re
        import yaml
        workflow = yaml.safe_load(ROOT.joinpath(".github/workflows/windows-stack.yml").read_text())
        for name in ("package", "package_production_integration_preflight"):
            steps = workflow["jobs"][name]["steps"]
            ids = [s["id"] for s in steps if "id" in s]
            self.assertEqual(len(ids), len(set(ids)), name)
            for step in steps:
                for reference in re.findall(r"steps\.([A-Za-z0-9_]+)\.", str(step)):
                    self.assertIn(reference, ids, name)
            receipts = []
            for step in steps:
                run=step.get("run", "")
                if "artifact_roundtrip.py seal" in run:
                    receipts.extend(re.findall(r'--receipt "([^"]+)"', run))
            self.assertEqual(len(receipts), len(set(receipts)), name)

    def test_pre_reservation_has_two_authorities_and_no_lock_bypass(self):
        import yaml
        workflow = yaml.safe_load(ROOT.joinpath(".github/workflows/windows-stack.yml").read_text())
        job = workflow["jobs"]["package_production_integration_preflight"]
        text = str(job)
        self.assertNotIn("Write-CIFingerprint", text)
        self.assertNotIn("Verify-CandidateSource.ps1", text)
        checkouts = [s for s in job["steps"] if s.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        self.assertEqual(checkouts[1]["with"]["ref"], "d03d79ebec6d857d141469d197e11c04097c4d75")
        self.assertIn("PRE_RESERVATION_SOURCE_STABILITY=PASS", text)
        self.assertIn("--remote origin --require-remote", text)
        self.assertIn("INPUT_CANDIDATE_FINGERPRINT", text)
        self.assertNotIn("FINAL_PACKAGE=PASS", text)
        for name, item in workflow["jobs"].items():
            if name in ("driver", "mesa", "mesa_x86", "opencl", "loaders", "compatibility", "package"):
                self.assertIn("!inputs.package_production_integration_preflight", item["if"], name)
        ids = [s["id"] for s in job["steps"] if "id" in s]
        self.assertEqual(len(ids), len(set(ids)))
        seals = [s for s in job["steps"] if "artifact_roundtrip.py seal" in s.get("run", "")]
        self.assertEqual(len(seals), 2)

    def test_focused_preflight_is_separate_from_candidate_product_dispatch(self):
        import yaml

        workflow = yaml.safe_load(ROOT.joinpath(".github/workflows/windows-stack.yml").read_text())
        inputs = workflow["on"]["workflow_dispatch"]["inputs"]
        self.assertIn("package_production_integration_preflight", inputs)
        self.assertIn("inputs.package_production_integration_preflight", workflow["jobs"]["package_production_integration_preflight"]["if"])
        self.assertIn("37417032761", str(workflow["jobs"]["package_production_integration_preflight"]))
        self.assertIn("Audit-CIPackage.ps1", str(workflow["jobs"]["package_production_integration_preflight"]))


if __name__ == "__main__":
    unittest.main()
