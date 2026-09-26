import re
import subprocess
import tempfile
import unittest
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
VENUS = ROOT / ".fullstack/work/venus-protocol-base"
MESA_DEFINES = ROOT / "icd/mesa/src/virtio/venus-protocol/vn_protocol_driver_defines.h"


class VenusGeneratorContractTests(unittest.TestCase):
    def generate(self, out, renderer=False):
        command = [
            "python3", str(VENUS / "vn_protocol.py"),
            "--srcdir", str(VENUS), "--outdir", str(out),
            "--banner", str(VENUS / "templates/banner.in"),
        ]
        if renderer:
            command.append("--renderer")
        subprocess.run(command, cwd=VENUS, check=True, capture_output=True, text=True)

    def test_candidate_generator_emits_the_mesa_dgc_wire_opcodes(self):
        mesa = MESA_DEFINES.read_text()
        expected = {
            name: int(value, 0)
            for name, value in re.findall(
                r"VK_COMMAND_TYPE_(vk\w+)_EXT\s*=\s*(0x[0-9a-fA-F]+|\d+)", mesa
            )
            if 350 <= int(value, 0) <= 361
        }
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            self.generate(out)
            generated_path = out / "vn_protocol_driver_defines.h"
            generated = generated_path.read_text()
            observed = {
                name: int(value, 0)
                for name, value in re.findall(
                    r"VK_COMMAND_TYPE_(vk\w+)_EXT\s*=\s*(0x[0-9a-fA-F]+|\d+)", generated
                )
            }
            self.assertEqual({k: expected[k] for k in sorted(expected)}, {k: observed.get(k) for k in sorted(expected)})
            driver_headers = list(out.glob("vn_protocol_driver_*.h"))
            self.assertTrue(driver_headers)
            dgc_driver = out / "vn_protocol_driver_device_generated_commands.h"
            self.assertTrue(dgc_driver.is_file(), "DGC device calls need a dedicated generated group")
            driver_text = "\n".join(path.read_text() for path in driver_headers)
            # Generated client entry points and server dispatch declarations must
            # both cover the extension, not only its wire opcode numbers.
            for command in (
                "vkCmdPreprocessGeneratedCommandsEXT",
                "vkCmdExecuteGeneratedCommandsEXT",
            ):
                with self.subTest(command=command):
                    self.assertIn(command, driver_text)
            # Device-scope EXT DGC commands require object/dispatch generation
            # too; merely adding wire opcode enum values is insufficient.
            for command in (
                "vkGetGeneratedCommandsMemoryRequirementsEXT",
                "vkCreateIndirectCommandsLayoutEXT",
                "vkUpdateIndirectExecutionSetShaderEXT",
            ):
                with self.subTest(command=command):
                    self.assertIn(command, driver_text)
            self.generate(out, renderer=True)
            renderer_headers = list(out.glob("vn_protocol_renderer_*.h"))
            self.assertTrue(renderer_headers)
            dgc_renderer = out / "vn_protocol_renderer_device_generated_commands.h"
            self.assertTrue(dgc_renderer.is_file(), "renderer DGC declarations must be generated independently")
            renderer = "\n".join(path.read_text() for path in renderer_headers)
            for command in (
                "vkGetGeneratedCommandsMemoryRequirementsEXT",
                "vkCmdPreprocessGeneratedCommandsEXT",
                "vkCmdExecuteGeneratedCommandsEXT",
                "vkCreateIndirectCommandsLayoutEXT",
                "vkUpdateIndirectExecutionSetShaderEXT",
            ):
                with self.subTest(renderer_command=command):
                    self.assertIn(command, renderer)

            clean = out / "clean"
            clean.mkdir()
            self.generate(clean)
            self.generate(clean, renderer=True)
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            expected = {p.name: digest(p) for p in out.glob("vn_protocol_*.h")}
            observed = {p.name: digest(p) for p in clean.glob("vn_protocol_*.h")}
            self.assertEqual(expected, observed, "generated client/renderer files must be deterministic")

    def test_candidate_dgc_empty_union_selectors_match_mesa(self):
        def empty_cases(path):
            text = path.read_text()
            match = re.search(
                r"vn_sizeof_VkIndirectCommandsTokenDataEXT\([^)]*\)\s*\{(.*?)\n}",
                text,
                re.S,
            )
            self.assertIsNotNone(match, str(path))
            body = match.group(1)
            marker = "case VK_INDIRECT_COMMANDS_TOKEN_TYPE_EXECUTION_SET_EXT:"
            self.assertIn(marker, body)
            body = body.split(marker, 1)[1].split("default:", 1)[0]
            return set(re.findall(r"case (VK_INDIRECT_COMMANDS_TOKEN_TYPE_[A-Z0-9_]+):", body))

        mesa_header = ROOT / "icd/mesa/src/virtio/venus-protocol/vn_protocol_driver_device_generated_commands.h"
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            self.generate(out)
            candidate_header = out / "vn_protocol_driver_device_generated_commands.h"
            self.assertEqual(empty_cases(mesa_header), empty_cases(candidate_header))

    def test_complete_generated_client_profile_matches_mesa(self):
        result = subprocess.run(
            ["python3", str(ROOT / "tools/fullstack/compare_venus_profile.py")],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        profile = json.loads(result.stdout)
        self.assertEqual("PASS", profile["status"])
        self.assertEqual(7750, profile["client_functions"]["candidate_count"])
        self.assertEqual(465, profile["wire_opcodes"]["candidate_count"])
        self.assertEqual(202, profile["extensions"]["candidate_count"])
        self.assertEqual([], profile["client_functions"]["unclassified_body_differences"])
        categorized = profile["client_functions"]["categorized_differences"]
        self.assertEqual(692, categorized["fail_closed_decoder"]["count"])
        self.assertEqual(101, categorized["zero_initialized_reply_size"]["count"])
        self.assertEqual(101, categorized["fail_closed_reply_opcode"]["count"])
        self.assertEqual({}, profile["wire_opcodes"]["differences"])
        self.assertEqual({}, profile["extensions"]["differences"])
        self.assertTrue(profile["protocol_details"]["match"])

    def test_profile_classification_does_not_hide_wire_body_changes(self):
        spec = __import__("importlib.util").util.spec_from_file_location(
            "compare_venus_profile", ROOT / "tools/fullstack/compare_venus_profile.py"
        )
        module = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertIsNone(module.classify_decoder_hardening(
            "if (bad) { vn_cs_decoder_set_fatal(dec); return; } payload++;",
            "assert(!bad); payload--;",
        ))
        self.assertIsNone(module.classify_sizeof_initialization(
            "size_t n = {0}; n += changed_payload_size();",
            "size_t n; n += payload_size();",
        ))
        self.assertIsNone(module.classify_reply_hardening(
            "if (command_type != VK_CMD) { vn_cs_decoder_set_fatal(dec); return 0; } payload++;",
            "assert(command_type == VK_CMD); payload--;",
        ))

    def test_dgc_preprocess_and_execute_have_generated_renderer_dispatch(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            self.generate(out, renderer=True)
            source = "\n".join(
                path.read_text() for path in out.glob("vn_protocol_renderer_*.h")
            )
            for name in (
                "vkCmdPreprocessGeneratedCommandsEXT",
                "vkCmdExecuteGeneratedCommandsEXT",
            ):
                self.assertIn(f"vn_decode_{name}_args_temp", source)
                self.assertIn(f"vn_replace_{name}_args_handle", source)
                self.assertIn(f"vn_dispatch_{name}", source)


if __name__ == "__main__":
    unittest.main()
