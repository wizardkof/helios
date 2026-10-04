import importlib.util
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("candidate_version.py")
SPEC = importlib.util.spec_from_file_location("candidate_version", MODULE_PATH)
candidate_version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate_version)


class CandidateVersionTests(unittest.TestCase):
    def test_numeric_order_handles_999_to_1000(self):
        self.assertLess(candidate_version.parse_version("22.22.999.0"),
                        candidate_version.parse_version("22.22.1000.0"))

    def test_candidate_version_requires_the_project_line(self):
        with self.assertRaises(ValueError):
            candidate_version.parse_version("22.23.293.0")

    def test_historical_292_advances_to_293(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            self._seed_292(root)
            (root / "metadata/candidate-history.json").write_text(json.dumps({
                "schemaVersion": 1,
                "observed": [{"version": "22.22.292.0", "status": "used"}],
            }), encoding="utf-8")
            (root / "kmd_render/driver-version.env").write_text(
                "HELIOS_KMD_VERSION=22.22.288.0\n", encoding="utf-8")
            self.assertEqual(candidate_version.next_version(root), "22.22.293.0")

    def test_version_set_rejects_kmd_umd_inf_or_package_divergence(self):
        good = {"kmd": "22.22.293.0", "umds": ["22.22.293.0"] * 4,
                "inf": "22.22.293.0", "package": "22.22.293.0"}
        candidate_version.validate_version_set(good)
        for key in ("kmd", "inf", "package"):
            bad = dict(good)
            bad[key] = "22.22.292.0"
            with self.subTest(key=key), self.assertRaises(ValueError):
                candidate_version.validate_version_set(bad)
        bad = dict(good)
        bad["umds"] = ["22.22.293.0"] * 3 + ["22.22.292.0"]
        with self.assertRaises(ValueError):
            candidate_version.validate_version_set(bad)

    def test_artifact_identity_rejects_replacement_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "identity.json"
            identity = {"version": "22.22.293.0", "component": "helios-umd",
                        "architecture": "x64", "configuration": "Release"}
            candidate_version.record_immutable_identity(path, identity, "a" * 64)
            candidate_version.record_immutable_identity(path, identity, "a" * 64)
            with self.assertRaises(ValueError):
                candidate_version.record_immutable_identity(path, identity, "b" * 64)

    def test_source_lock_rejects_different_component_pin(self):
        expected = {"helios": "h1", "mesa": "m1", "dxvk": "d1"}
        with self.assertRaises(ValueError):
            candidate_version.validate_source_lock(expected, {**expected, "mesa": "m2"})

    def test_failed_or_rolled_back_reservation_stays_occupied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            self._seed_292(root)
            candidate_version.reserve(root, "22.22.293.0", "source-a")
            candidate_version.reserve(root, "22.22.293.0", "source-a")
            history = json.loads((root / "metadata/candidate-history.json").read_text(encoding="utf-8"))
            self.assertEqual([row["status"] for row in history["observed"] if row["version"] == "22.22.293.0"],
                             ["reserved"])
            self.assertEqual(candidate_version.next_version(root),
                             "22.22.294.0")
            with self.assertRaises(ValueError):
                candidate_version.reserve(root, "22.22.293.0", "source-b")

    def test_source_change_keeps_old_number_reserved_and_allocates_next(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            self._seed_292(root)
            source = root / "kmd_render" / "candidate.rs"
            source.write_text("candidate a\n", encoding="utf-8")
            lock = candidate_version.reserve(root, "22.22.293.0")
            self.assertEqual(candidate_version.verify(root)["version"], "22.22.293.0")
            source.write_text("candidate b\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "source changed"):
                candidate_version.verify(root)
            self.assertEqual(candidate_version.next_version(root), "22.22.294.0")
            self.assertTrue(lock["reservationRef"].endswith("22.22.293.0"))

    def test_fingerprint_uses_clean_git_blobs_across_crlf_checkouts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            self._init_remote_repo(root)
            before = candidate_version.source_fingerprint(root)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "true"], check=True)
            for relative in ("kmd_render/driver-version.env", ".github/workflows/windows-stack.yml",
                             "tools/candidate_version.py", "icd/mesa/input.txt"):
                path = root / relative
                raw = path.read_bytes()
                normalized = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
                path.write_bytes(normalized)
                if relative == "icd/mesa/input.txt":
                    subprocess.run(["git", "-C", str(root / "icd/mesa"), "config",
                                    "core.autocrlf", "true"], check=True)
            self.assertEqual(candidate_version.source_fingerprint(root), before)

    def test_source_locked_candidate_verifies_in_fresh_ci_clone_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            self._seed_292(root)
            candidate_version.reserve(root, "22.22.293.0")
            subprocess.run(["git", "-C", str(root), "update-ref", "-d",
                            "refs/helios/candidate-reservations/22.22.293.0"], check=True)
            with self.assertRaisesRegex(ValueError, "local Git reservation ref is absent"):
                candidate_version.verify(root)
            self.assertEqual(candidate_version.verify(root, portable=True)["version"], "22.22.293.0")
            self.assertEqual(candidate_version.next_version(root), "22.22.294.0")

    def test_committed_snapshot_reproduces_fingerprint_and_lock_in_clean_clone(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "source"
            self._init_repo(root)
            self._configure_git(root)
            for directory in ("umd", "umd12", "umd_common", "kmd_logic", "protocol",
                              "installer", "packaging/windows", "ci/windows", "ci/patches", "tools/win-mcp"):
                (root / directory / "input.txt").write_text(directory + "\n", encoding="utf-8")
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/windows-stack.yml").write_text("name: test\n", encoding="utf-8")
            (root / "metadata/candidate-history.json").write_text(json.dumps({
                "schemaVersion": 1,
                "observed": [
                    {"version": "22.22.293.0", "status": "reserved"},
                    {"version": "22.22.294.0", "status": "reserved",
                     "sourceFingerprint": "f" * 64},
                ],
            }), encoding="utf-8")
            (root / "tools").mkdir(exist_ok=True)
            (root / "tools/candidate_version.py").write_bytes(MODULE_PATH.read_bytes())
            subprocess.run(["git", "-C", str(root), "add", "kmd_render", "umd", "umd12",
                            "umd_common", "kmd_logic", "protocol", "metadata/candidate-history.json",
                            "installer", "packaging/windows", "ci/windows", "ci/patches", "tools/win-mcp", "tools/candidate_version.py",
                            ".github/workflows/windows-stack.yml"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "source snapshot"], check=True)
            initial_fingerprint = candidate_version.source_fingerprint(root)
            lock = candidate_version.reserve(root, "22.22.295.0")
            self.assertEqual(lock["sourceFingerprint"], initial_fingerprint)

            subprocess.run(["git", "-C", str(root), "add", "kmd_render/driver-version.env",
                            "metadata/candidate-history.json", "metadata/candidate-reservation.json",
                            "tools/candidate_version.py"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "freeze candidate"], check=True)
            clone = base / "clean-clone"
            subprocess.run(["git", "clone", "-q", str(root), str(clone)], check=True)
            for name in ("icd/mesa", "dxvk-helios", "vkd3d-proton-helios"):
                subprocess.run(["git", "clone", "-q", str(root / name), str(clone / name)], check=True)

            self.assertEqual(candidate_version.source_fingerprint(clone), initial_fingerprint)
            self.assertEqual(candidate_version.verify(clone, portable=True)["reservationDigest"],
                             lock["reservationDigest"])
            self.assertEqual(candidate_version.next_version(clone), "22.22.296.0")

    def test_applied_clspv_patch_bytes_are_candidate_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            patch = root / "ci/patches/clspv/control.patch"
            patch.parent.mkdir(parents=True)
            patch.write_text("first compiler delta\n")
            before = candidate_version.source_fingerprint(root)
            patch.write_text("different compiler delta\n")
            self.assertNotEqual(before, candidate_version.source_fingerprint(root))

    def test_workflow_verifies_frozen_lock_without_per_job_reservation(self):
        workflow = (MODULE_PATH.parents[1] / ".github/workflows/windows-stack.yml").read_text(encoding="utf-8")
        self.assertIn("Verify-CandidateSource.ps1", workflow)
        self.assertNotIn("candidate_version.py reserve", workflow)
        self.assertNotIn("candidate_version.py next", workflow)

    def test_two_concurrent_branches_cannot_reserve_same_number_for_different_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._init_repo(root)
            self._seed_292(root)
            outcomes = []
            barrier = threading.Barrier(2)

            def reserve(source):
                barrier.wait()
                try:
                    candidate_version.reserve(root, "22.22.293.0", source)
                    outcomes.append("reserved")
                except ValueError:
                    outcomes.append("collision")

            threads = [threading.Thread(target=reserve, args=(name,)) for name in ("source-a", "source-b")]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertCountEqual(outcomes, ["reserved", "collision"])
            history = json.loads((root / "metadata/candidate-history.json").read_text(encoding="utf-8"))
            reservations = [row for row in history["observed"] if row["status"] == "reserved"]
            self.assertEqual(len(reservations), 1)
            self.assertEqual(candidate_version.next_version(root), "22.22.294.0")

    def test_remote_reservation_ref_atomically_blocks_a_different_clone(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            remote = base / "helios.git"
            self._init_remote_repo(source)
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "-C", str(source), "remote", "add", "origin", str(remote)], check=True)
            subprocess.run(["git", "-C", str(source), "push", "-q", "-u", "origin", "HEAD"], check=True)
            clone_a, clone_b = base / "clone-a", base / "clone-b"
            subprocess.run(["git", "clone", "-q", str(remote), str(clone_a)], check=True)
            subprocess.run(["git", "clone", "-q", str(remote), str(clone_b)], check=True)
            for clone in (clone_a, clone_b):
                for name in ("icd/mesa", "dxvk-helios", "vkd3d-proton-helios"):
                    subprocess.run(["git", "clone", "-q", str(source / name), str(clone / name)], check=True)
            self._configure_git(clone_a)
            self._configure_git(clone_b)
            (clone_b / "kmd_render/candidate.rs").write_text("different candidate\n", encoding="utf-8")

            reserved = candidate_version.reserve(clone_a, "22.22.293.0", remote="origin")
            self.assertEqual(reserved["version"], "22.22.293.0")
            with self.assertRaisesRegex(ValueError, "reserved remotely for a different source"):
                candidate_version.reserve(clone_b, "22.22.293.0", remote="origin")
            self.assertEqual(candidate_version.next_version(clone_b, remote="origin"), "22.22.294.0")
            self.assertEqual(candidate_version.verify(clone_a, remote="origin", require_remote=True)["version"],
                             "22.22.293.0")

    @classmethod
    def _init_remote_repo(cls, root):
        root.mkdir(parents=True)
        (root / "kmd_render").mkdir()
        (root / "kmd_render/driver-version.env").write_text(
            "HELIOS_KMD_VERSION=22.22.288.0\n", encoding="utf-8")
        (root / "metadata").mkdir()
        (root / "metadata/candidate-history.json").write_text(json.dumps({
            "schemaVersion": 1,
            "observed": [{"version": "22.22.292.0", "status": "built-and-observed"}],
        }), encoding="utf-8")
        (root / "tools").mkdir()
        (root / "tools/candidate_version.py").write_bytes(MODULE_PATH.read_bytes())
        for directory in ("umd", "umd12", "umd_common", "kmd_logic", "protocol", "installer",
                          "packaging/windows", "ci/windows", "ci/patches", "tools/win-mcp", ".github/workflows", "icd/mesa",
                          "dxvk-helios", "vkd3d-proton-helios"):
            path = root / directory
            path.mkdir(parents=True, exist_ok=True)
            (path / "input.txt").write_text(f"{directory}\n", encoding="utf-8")
        for directory in ("icd/mesa", "dxvk-helios", "vkd3d-proton-helios"):
            path = root / directory
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                            "user.email=test@example.invalid", "add", "input.txt"], check=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                            "user.email=test@example.invalid", "commit", "-qm", "seed component"], check=True)
        (root / ".github/workflows/windows-stack.yml").write_text("name: test\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        cls._configure_git(root)
        subprocess.run(["git", "-C", str(root), "add", "kmd_render", "metadata", "tools", "umd", "umd12",
                        "umd_common", "kmd_logic", "protocol", "installer", "packaging/windows", "ci/windows", "ci/patches",
                        "tools/win-mcp", ".github/workflows/windows-stack.yml"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "seed source"], check=True)

    @staticmethod
    def _configure_git(root):
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.invalid"], check=True)

    @staticmethod
    def _init_repo(root):
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "kmd_render").mkdir()
        (root / "metadata").mkdir()
        (root / "kmd_render/driver-version.env").write_text(
            "HELIOS_KMD_VERSION=22.22.288.0\n", encoding="utf-8")
        for name in ("umd", "umd12", "umd_common", "kmd_logic", "protocol", "installer",
                     "packaging/windows", "ci/windows", "ci/patches", "tools/win-mcp"):
            (root / name).mkdir(parents=True)
        for name in ("icd/mesa", "dxvk-helios", "vkd3d-proton-helios"):
            path = root / name
            path.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                            "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "seed"], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c",
                        "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "seed"], check=True)

    @staticmethod
    def _seed_292(root):
        (root / "metadata/candidate-history.json").write_text(json.dumps({
            "schemaVersion": 1,
            "observed": [{"version": "22.22.292.0", "status": "used"}],
        }), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
