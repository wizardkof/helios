#!/usr/bin/env python3
"""Compare generated Venus client wire code against the pinned Mesa profile."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


FUNCTION = re.compile(
    r"(?m)^static inline\s+[^;{}]*?\b"
    r"(vn_(?:sizeof|encode|decode|submit|call|async)_[A-Za-z0-9_]+)"
    r"\s*\([^;{}]*?\)\s*\{"
)
OPCODE = re.compile(r"VK_COMMAND_TYPE_(vk\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)")
EXTENSION = re.compile(
    r'\{\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)\s*\}'
)


def files_digest(directory, pattern):
    digest = hashlib.sha256()
    for path in sorted(directory.glob(pattern)):
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def generated_functions(directory):
    functions = {}
    for path in sorted(directory.glob("vn_protocol_driver_*.h")):
        text = path.read_text(errors="strict")
        for match in FUNCTION.finditer(text):
            index = match.end()
            depth = 1
            while index < len(text) and depth:
                depth += (text[index] == "{") - (text[index] == "}")
                index += 1
            if depth:
                raise ValueError(f"unclosed generated function in {path}: {match.group(1)}")
            body = text[match.start():index]
            body = re.sub(r"/\*.*?\*/|//[^\n]*", "", body, flags=re.S)
            body = re.sub(r"\s+", " ", body).strip()
            name = match.group(1)
            if name in functions and functions[name] != body:
                raise ValueError(f"duplicate generated function differs: {name}")
            functions[name] = body
    return functions


def opcode_map(path):
    return {name: int(value, 0) for name, value in OPCODE.findall(path.read_text())}


def extension_map(path):
    text = path.read_text()
    match = re.search(r"_vn_info_extensions\[\d+\]\s*=\s*\{(.*?)\n};", text, re.S)
    if not match:
        raise ValueError(f"extension inventory missing from {path}")
    return {name: (int(number), int(version))
            for name, number, version in EXTENSION.findall(match.group(1))}


def git_head(path):
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def git_dirty_files(path):
    try:
        text = subprocess.check_output(
            ["git", "-C", str(path), "status", "--porcelain"], text=True
        )
        return [line[3:] for line in text.splitlines()]
    except (OSError, subprocess.CalledProcessError):
        return None


def protocol_details(path):
    text = path.read_text()
    maximum = re.search(r"#define VN_INFO_EXTENSION_MAX_NUMBER \((\d+)\)", text)
    wire = re.search(r"vn_info_wire_format_version\(void\)\s*\{\s*return (\d+);", text)
    xml = re.search(r"vn_info_vk_xml_version\(void\)\s*\{\s*return (.*?);", text, re.S)
    if not (maximum and wire and xml):
        raise ValueError(f"protocol profile details missing in {path}")
    return {
        "extension_max_number": int(maximum.group(1)),
        "wire_format_version": int(wire.group(1)),
        "vk_xml_version_expression": re.sub(r"\s+", " ", xml.group(1)).strip(),
    }


def classify_decoder_hardening(candidate_body, mesa_body):
    """Map only the candidate's exact fail-closed decoder substitutions to Mesa asserts."""
    mapped = re.sub(
        r"if \(!pnext\) \{ vn_cs_decoder_set_fatal\(dec\); return; \}",
        "assert(pnext);",
        candidate_body,
    )
    mapped = re.sub(
        r"if \((.*?)\) \{ vn_cs_decoder_set_fatal\(dec\); return; \}",
        lambda match: "assert(%s);" % re.sub(
            r"\s*!=\s*", " == ", match.group(1), count=1
        ),
        mapped,
    )
    mapped = re.sub(
        r"if \((.*?)\) vn_cs_decoder_set_fatal\(dec\);",
        r"if (\1) assert(false);",
        mapped,
    )
    mapped = re.sub(
        r"default: vn_cs_decoder_set_fatal\(dec\); break;",
        "default: assert(false); break;",
        mapped,
    )
    if mapped == mesa_body:
        return "fail_closed_decoder"
    return None


def classify_sizeof_initialization(candidate_body, mesa_body):
    """Recognize zero initialization added before a sizeof-only reply calculation."""
    mapped = re.sub(r" = \{0\};", ";", candidate_body)
    if mapped == mesa_body:
        return "zero_initialized_reply_size"
    return None


def classify_reply_hardening(candidate_body, mesa_body):
    """Recognize only wrong-reply-opcode fatal handling with a safe return."""
    mapped = re.sub(
        r"if \(command_type != (VK_COMMAND_TYPE_[A-Za-z0-9_]+)\) \{ vn_cs_decoder_set_fatal\(dec\); return (?:0|); \}",
        lambda match: "assert(command_type == %s);" % match.group(1),
        candidate_body,
    )
    if mapped == mesa_body:
        return "fail_closed_reply_opcode"
    return None


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-build", type=Path,
                        default=root / ".fullstack/build/linux/venus")
    parser.add_argument("--candidate-source", type=Path,
                        default=root / ".fullstack/work/venus-protocol-base")
    parser.add_argument("--mesa-generated", type=Path,
                        default=root / "icd/mesa/src/virtio/venus-protocol")
    parser.add_argument("--mesa-source", type=Path, default=root / "icd/mesa")
    args = parser.parse_args()

    candidate = args.candidate_build
    mesa = args.mesa_generated
    candidate_functions = generated_functions(candidate)
    mesa_functions = generated_functions(mesa)
    missing_functions = sorted(mesa_functions.keys() - candidate_functions.keys())
    extra_functions = sorted(candidate_functions.keys() - mesa_functions.keys())
    changed_functions = sorted(
        name for name in candidate_functions.keys() & mesa_functions.keys()
        if candidate_functions[name] != mesa_functions[name]
    )
    categorized_differences = {}
    unclassified_differences = []
    for name in changed_functions:
        candidate_body = candidate_functions[name]
        mesa_body = mesa_functions[name]
        category = None
        if name.startswith("vn_decode_"):
            category = classify_decoder_hardening(candidate_body, mesa_body)
            if category is None and name.endswith("_reply"):
                category = classify_reply_hardening(candidate_body, mesa_body)
        elif name.startswith("vn_sizeof_"):
            category = classify_sizeof_initialization(candidate_body, mesa_body)
        if category:
            categorized_differences.setdefault(category, []).append(name)
        else:
            unclassified_differences.append(name)

    candidate_opcodes = opcode_map(candidate / "vn_protocol_driver_defines.h")
    mesa_opcodes = opcode_map(mesa / "vn_protocol_driver_defines.h")
    opcode_differences = {
        name: {"candidate": candidate_opcodes.get(name), "mesa": mesa_opcodes.get(name)}
        for name in sorted(candidate_opcodes.keys() | mesa_opcodes.keys())
        if candidate_opcodes.get(name) != mesa_opcodes.get(name)
    }

    candidate_extensions = extension_map(candidate / "vn_protocol_driver_info.h")
    mesa_extensions = extension_map(mesa / "vn_protocol_driver_info.h")
    extension_differences = {
        name: {"candidate": candidate_extensions.get(name), "mesa": mesa_extensions.get(name)}
        for name in sorted(candidate_extensions.keys() | mesa_extensions.keys())
        if candidate_extensions.get(name) != mesa_extensions.get(name)
    }
    candidate_details = protocol_details(candidate / "vn_protocol_driver_info.h")
    mesa_details = protocol_details(mesa / "vn_protocol_driver_info.h")

    result = {
        "status": "PASS" if not (missing_functions or extra_functions or unclassified_differences
                                  or opcode_differences or extension_differences)
        and candidate_details == mesa_details else "DIFF",
        "comparison": "generated client wire function bodies after comments/whitespace normalization",
        "candidate": {
            "source_head": git_head(args.candidate_source),
            "source_tree": subprocess.check_output(
                ["git", "-C", str(args.candidate_source), "rev-parse", "HEAD^{tree}"],
                text=True,
            ).strip(),
            "dirty_files": git_dirty_files(args.candidate_source),
            "generated_headers_sha256": files_digest(candidate, "vn_protocol_driver_*.h"),
        },
        "mesa": {
            "source_head": git_head(args.mesa_source),
            "generated_headers_sha256": files_digest(mesa, "vn_protocol_driver_*.h"),
        },
        "client_functions": {
            "candidate_count": len(candidate_functions),
            "mesa_count": len(mesa_functions),
            "missing": missing_functions,
            "extra": extra_functions,
            "body_differences": changed_functions,
            "categorized_differences": {
                category: {"count": len(names), "functions": names}
                for category, names in sorted(categorized_differences.items())
            },
            "unclassified_body_differences": unclassified_differences,
        },
        "wire_opcodes": {
            "candidate_count": len(candidate_opcodes),
            "mesa_count": len(mesa_opcodes),
            "differences": opcode_differences,
            "dgc_nv_350_361_match": all(
                candidate_opcodes.get(name) == mesa_opcodes.get(name)
                for name in candidate_opcodes
                if 350 <= candidate_opcodes[name] <= 361
            ),
        },
        "extensions": {
            "candidate_count": len(candidate_extensions),
            "mesa_count": len(mesa_extensions),
            "differences": extension_differences,
        },
        "protocol_details": {
            "candidate": candidate_details,
            "mesa": mesa_details,
            "match": candidate_details == mesa_details,
        },
        "limits": [
            "does not compare host renderer dispatch behavior",
            "does not compare native C struct padding or Windows x86/x64 ABI",
            "does not prove Vulkan execution, GPU behavior, or Windows client compatibility",
        ],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] == "PASS" and result["protocol_details"]["match"] else 1


if __name__ == "__main__":
    sys.exit(main())
