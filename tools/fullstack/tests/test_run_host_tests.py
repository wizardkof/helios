import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "tools/fullstack/run-host-tests.sh"


class HostTestRunnerTests(unittest.TestCase):
    def _fake_cargo(self, directory: Path, exit_code: int) -> Path:
        log = directory / "cargo-args.log"
        script = directory / "cargo"
        script.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CARGO_ARGS_LOG\"\n"
            "case \"$*\" in *kmd_logic*|*protocol*|*win-mcp*) echo 'running 1 test';; esac\n"
            f"exit {exit_code}\n"
        )
        script.chmod(0o755)
        self.addCleanup(lambda: None)
        self.log = log
        return script

    def test_runner_uses_private_target_and_emits_pass_receipt(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".fullstack/artifacts") as td:
            temp = Path(td)
            cargo = self._fake_cargo(temp, 0)
            env = os.environ | {
                "HELIOS_CARGO": str(cargo),
                "CARGO_ARGS_LOG": str(temp / "args.log"),
                "HELIOS_ARTIFACTS_DIR": str(temp / "receipts"),
            }
            result = subprocess.run([str(RUNNER)], cwd=ROOT, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = (temp / "args.log").read_text()
            self.assertIn("kmd_logic/Cargo.toml", commands)
            self.assertIn("protocol/Cargo.toml", commands)
            self.assertIn("tools/win-mcp/Cargo.toml", commands)
            self.assertIn(str(ROOT / ".fullstack/build/linux/cargo"), result.stdout)
            receipt_path = next(line.split("=", 1)[1] for line in result.stdout.splitlines() if line.startswith("RECEIPT="))
            self.assertTrue(Path(receipt_path).is_relative_to(temp / "receipts"))
            receipt = json.loads(Path(receipt_path).read_text())
            self.assertEqual(receipt["result"], "PASS")
            self.assertEqual(receipt["source_root"], str(ROOT))

    def test_nonzero_cargo_result_fails_closed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".fullstack/artifacts") as td:
            temp = Path(td)
            cargo = self._fake_cargo(temp, 23)
            env = os.environ | {
                "HELIOS_CARGO": str(cargo),
                "CARGO_ARGS_LOG": str(temp / "args.log"),
                "HELIOS_ARTIFACTS_DIR": str(temp / "receipts"),
            }
            result = subprocess.run([str(RUNNER)], cwd=ROOT, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 23)
            receipt_path = next(line.split("=", 1)[1] for line in result.stdout.splitlines() if line.startswith("RECEIPT="))
            self.assertTrue(Path(receipt_path).is_relative_to(temp / "receipts"))
            receipt = json.loads(Path(receipt_path).read_text())
            self.assertEqual(receipt["result"], "FAIL")
            self.assertEqual(receipt["failed_exit_code"], 23)


if __name__ == "__main__":
    unittest.main()
