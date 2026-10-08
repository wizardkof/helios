import json
import re
import unittest
from pathlib import Path
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("acquire_package_rust", ROOT / "ci/windows/acquire_package_rust.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)

class RustupPinIntegrationTests(unittest.TestCase):
    def test_all_production_checkers_use_shared_rustup_identity(self):
        module = (ROOT / "ci/windows/CIToolchainOptions.psm1").read_text()
        native = (ROOT / "ci/windows/Assert-CIToolchain.ps1").read_text()
        component = (ROOT / "ci/windows/Assert-ComponentToolchain.ps1").read_text()
        pins = json.loads((ROOT / "ci/windows/ci-toolchain-pins.json").read_text())
        self.assertEqual(pins["rust"]["rustupVersion"], "1.29.1")
        self.assertIn("Test-CIRustupIdentity", (ROOT / "ci/windows/CIToolchainReceipts.psm1").read_text())
        self.assertIn("New-CICheckOptions -Definition $tool", native)
        self.assertIn("New-CICheckOptions -Definition $check", component)
        self.assertIn("rustupVersion=$pins.rust.rustupVersion", component)
        self.assertIn("ContainsKey('rustupVersion')", module)
        self.assertIn("ContainsKey('pattern')", module)

    def test_strictmode_preflight_runs_before_provisioning_and_keeps_evidence(self):
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/windows-stack.yml").read_text())
        steps = workflow["jobs"]["driver"]["steps"]
        preflight = next(i for i, step in enumerate(steps) if step.get("id") == "rustup_strictmode_preflight")
        self.assertLess(preflight, next(i for i, step in enumerate(steps) if "Install-PinnedGit.ps1" in step.get("run", "")))
        self.assertLess(preflight, next(i for i, step in enumerate(steps) if step.get("name") == "Ensure Windows Driver Kit is installed"))
        for step in steps[preflight + 1:]:
            condition = step.get("if", "")
            if "success() || inputs.infrastructure_only" in condition or "always() && inputs.infrastructure_only" in condition:
                self.assertIn("steps.rustup_strictmode_preflight.outcome == 'success'", condition, step.get("name"))
        evidence = next(step for step in steps if step.get("id") == "collect_evidence")
        self.assertEqual(evidence.get("if"), "always()")

    def test_package_acquirer_uses_same_identity_contract_and_keeps_streams(self):
        source = (ROOT / "ci/windows/acquire_package_rust.py").read_text()
        self.assertIn("rustup_identity_matches", source)
        self.assertIn("capture_output=True", source)
        self.assertIn("version.stdout + ('\\n' if version.stdout and version.stderr else '') + version.stderr", source)

    def test_python_identity_is_one_exact_line_with_rustup_metadata(self):
        valid = "info: pre\r\nrustup 1.29.1 (d95a37b6a 2026-08-13)\r\ninfo: rustc 1.99.0"
        self.assertTrue(PACKAGE.rustup_identity_matches(valid, "1.29.1"))
        for invalid in ("info: rustup 1.29.1", "x rustup 1.29.1", "rustup 1.29.10",
                        "rustup 1.29.1-custom", "rustup 1.29.1.0", "rustup 1.29.1+custom",
                        "rustup 1.29.1\nrustup 1.29.1", "rustup 1.29.0\nrustup 1.29.1"):
            self.assertFalse(PACKAGE.rustup_identity_matches(invalid, "1.29.1"), invalid)

if __name__ == "__main__":
    unittest.main()
