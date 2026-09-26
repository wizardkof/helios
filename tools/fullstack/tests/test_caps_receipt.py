import json
import tempfile
import unittest
from pathlib import Path

from tools.fullstack.caps_receipt import CapsReceiptError, load_json, parse_receipt

LAYOUTS = {"D3D12_OPTIONS": {"size": 48, "layout_hash": "a" * 64}}
BASE = {
    "schema_version": 1,
    "source_fingerprint": "b" * 64,
    "adapter": {"name": "Helios vGPU", "luid": "00000000:00000001"},
    "architecture": "x64",
    "pointer_bits": 64,
    "queries": {},
}


class CapsReceiptTests(unittest.TestCase):
    def test_expanded_fl122_manifest_covers_core_and_inherited_rows(self):
        root = Path(__file__).resolve().parents[3]
        manifest = json.loads((root / "docs/helios-fullstack-v1.0.1/config/fl122-expanded.json").read_text())
        self.assertEqual(len(manifest["core_requirements"]), 23)
        self.assertGreaterEqual(len(manifest["inherited_requirements"]), 30)
        self.assertTrue(all(row["runtime_status"] == "NOT_CHECKED" for row in manifest["core_requirements"] + manifest["inherited_requirements"]))

    def test_missing_query_is_not_checked_not_zero(self):
        result = parse_receipt(BASE, "b" * 64, "00000000:00000001", "x64", LAYOUTS)
        self.assertEqual(result["queries"]["F15"]["status"], "NOT_CHECKED")
        self.assertNotIn("value", result["queries"]["F15"])

    def test_explicit_zero_stays_an_observed_zero(self):
        receipt = BASE | {
            "queries": {
                "F15": {
                    "status": "QUERIED",
                    "struct_name": "D3D12_OPTIONS",
                    "struct_size": 48,
                    "payload_bytes": 48,
                    "layout_hash": "a" * 64,
                    "value": 0,
                }
            }
        }
        result = parse_receipt(receipt, "b" * 64, "00000000:00000001", "x64", LAYOUTS)
        self.assertEqual(result["queries"]["F15"]["value"], 0)
        self.assertEqual(result["queries"]["F15"]["status"], "QUERIED")

    def test_short_or_incompatible_struct_is_refused(self):
        receipt = BASE | {
            "queries": {
                "F15": {
                    "status": "QUERIED",
                    "struct_name": "D3D12_OPTIONS",
                    "struct_size": 44,
                    "payload_bytes": 44,
                    "layout_hash": "a" * 64,
                    "value": 1,
                }
            }
        }
        with self.assertRaises(CapsReceiptError):
            parse_receipt(receipt, "b" * 64, "00000000:00000001", "x64", LAYOUTS)

    def test_x86_does_not_inherit_the_x64_gpu_va_floor(self):
        receipt = BASE | {"architecture": "x86", "pointer_bits": 32}
        result = parse_receipt(receipt, "b" * 64, "00000000:00000001", "x86", LAYOUTS)
        self.assertEqual(result["gpu_va_40bit_requirement"], "NO_X86_GUARANTEE")

    def test_failed_query_remains_explicit_and_never_becomes_false_or_zero(self):
        receipt = BASE | {"queries": {"F23": {"status": "QUERY_FAILED", "hresult": "0x80004002"}}}
        result = parse_receipt(receipt, "b" * 64, "00000000:00000001", "x64", LAYOUTS)
        self.assertEqual(result["queries"]["F23"], {"status": "QUERY_FAILED", "hresult": "0x80004002"})

    def test_foreign_source_or_adapter_is_refused(self):
        with self.assertRaises(CapsReceiptError):
            parse_receipt(BASE, "c" * 64, "00000000:00000001", "x64", LAYOUTS)
        with self.assertRaises(CapsReceiptError):
            parse_receipt(BASE, "b" * 64, "00000000:00000002", "x64", LAYOUTS)

    def test_truncated_json_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "truncated.json"
            path.write_text('{"schema_version":1,"queries":', encoding="utf-8")
            with self.assertRaises(CapsReceiptError):
                load_json(path)


if __name__ == "__main__":
    unittest.main()
