import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "package_host_stack.py"
SPEC = importlib.util.spec_from_file_location("package_host_stack", MODULE_PATH)
package_host_stack = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(package_host_stack)


class PackageHostStackTests(unittest.TestCase):
    def test_rejects_qemu_without_renderer_dependency_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qemu = root / "qemu"
            renderer = root / "renderer.so"
            output = root / "package"
            qemu.write_bytes(b"qemu")
            renderer.write_bytes(b"renderer")
            with mock.patch.object(package_host_stack, "run", return_value=""):
                with self.assertRaisesRegex(ValueError, "does not dynamically require"):
                    package_host_stack.package(qemu, renderer, output)
            self.assertFalse(output.exists())

    def test_refuses_nonempty_output_to_preserve_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "package"
            output.mkdir()
            sentinel = output / "owner-data"
            sentinel.write_text("preserve", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "must be empty"):
                package_host_stack.package(root / "missing-qemu", root / "missing-renderer", output)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")


if __name__ == "__main__":
    unittest.main()
