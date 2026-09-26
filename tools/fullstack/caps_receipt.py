#!/usr/bin/env python3
"""Validate and normalize an independent Windows D3D12 caps-probe receipt."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class CapsReceiptError(ValueError):
    pass


QUERY_IDS = tuple(f"F{i:02}" for i in range(1, 24)) + tuple(f"H{i:02}" for i in range(1, 43))
LAYOUT_HASH = re.compile(r"^[0-9a-f]{64}$")


def parse_receipt(
    receipt: dict[str, Any],
    expected_source_fingerprint: str,
    expected_adapter_luid: str,
    expected_architecture: str,
    expected_layouts: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
        raise CapsReceiptError("unsupported or missing receipt schema")
    if receipt.get("source_fingerprint") != expected_source_fingerprint:
        raise CapsReceiptError("source fingerprint mismatch")
    adapter = receipt.get("adapter")
    if not isinstance(adapter, dict) or not adapter.get("name"):
        raise CapsReceiptError("adapter identity is missing")
    if adapter.get("luid") != expected_adapter_luid:
        raise CapsReceiptError("adapter LUID mismatch")
    if expected_architecture not in ("x86", "x64"):
        raise CapsReceiptError("expected architecture must be x86 or x64")
    pointer_bits = 32 if expected_architecture == "x86" else 64
    if receipt.get("architecture") != expected_architecture or receipt.get("pointer_bits") != pointer_bits:
        raise CapsReceiptError("process architecture and pointer width disagree")

    observed = receipt.get("queries", {})
    if not isinstance(observed, dict):
        raise CapsReceiptError("queries must be an object")
    unknown = set(observed) - set(QUERY_IDS)
    if unknown:
        raise CapsReceiptError(f"unknown query identifiers: {sorted(unknown)}")

    normalized: dict[str, dict[str, Any]] = {}
    for query_id in QUERY_IDS:
        item = observed.get(query_id)
        if item is None:
            normalized[query_id] = {"status": "NOT_CHECKED"}
            continue
        if not isinstance(item, dict):
            raise CapsReceiptError(f"{query_id}: query record must be an object")
        state = item.get("status")
        if state == "NOT_CHECKED":
            normalized[query_id] = {"status": "NOT_CHECKED"}
            continue
        if state == "UNSUPPORTED":
            normalized[query_id] = {"status": "UNSUPPORTED", "reason": item.get("reason", "reported by runtime")}
            continue
        if state == "QUERY_FAILED":
            normalized[query_id] = {"status": "QUERY_FAILED", "hresult": item.get("hresult", "unknown")}
            continue
        if state != "QUERIED":
            raise CapsReceiptError(f"{query_id}: unknown query status {state!r}")

        struct_name = item.get("struct_name")
        layout = expected_layouts.get(struct_name)
        if not isinstance(layout, dict):
            raise CapsReceiptError(f"{query_id}: no pinned layout for {struct_name!r}")
        expected_size = layout.get("size")
        expected_hash = layout.get("layout_hash")
        if not isinstance(expected_size, int) or expected_size <= 0 or not LAYOUT_HASH.fullmatch(str(expected_hash)):
            raise CapsReceiptError(f"{query_id}: invalid expected layout manifest")
        if item.get("struct_size") != expected_size or item.get("payload_bytes", 0) < expected_size:
            raise CapsReceiptError(f"{query_id}: truncated or incompatible structure size")
        if item.get("layout_hash") != expected_hash:
            raise CapsReceiptError(f"{query_id}: layout fingerprint mismatch")
        if "value" not in item:
            raise CapsReceiptError(f"{query_id}: successful query has no value")
        normalized[query_id] = {
            "status": "QUERIED",
            "struct_name": struct_name,
            "struct_size": expected_size,
            "layout_hash": expected_hash,
            "value": item["value"],
        }

    return {
        "schema_version": 1,
        "source_fingerprint": expected_source_fingerprint,
        "adapter": {"name": adapter["name"], "luid": expected_adapter_luid},
        "architecture": expected_architecture,
        "pointer_bits": pointer_bits,
        "gpu_va_40bit_requirement": "REQUIRED" if pointer_bits == 64 else "NO_X86_GUARANTEE",
        "queries": normalized,
    }


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CapsReceiptError(f"truncated or invalid JSON input: {exc}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--layouts", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-fingerprint", required=True)
    parser.add_argument("--adapter-luid", required=True)
    parser.add_argument("--arch", choices=("x86", "x64"), required=True)
    args = parser.parse_args(argv)
    try:
        receipt = load_json(args.input)
        layouts = load_json(args.layouts) if args.layouts else receipt.get("layouts")
        if not isinstance(layouts, dict):
            raise CapsReceiptError("layout manifest is missing")
        result = parse_receipt(
            receipt,
            args.source_fingerprint,
            args.adapter_luid,
            args.arch,
            layouts,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    except CapsReceiptError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
