# P06 ATTEST ETW observer

This collector observes the dedicated diagnostic provider. Collection completeness does not establish ATTEST success or user-mode copyback.

## Build and local decoder checks

```sh
python3 -m unittest discover -s tools/p06-attest-observer -v
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -municode -static tools/p06-attest-observer/collector.cpp -ladvapi32 -o tools/p06-attest-observer/collector.exe
```

`test-red.txt` preserves nine initial assertion failures before decoder implementation. `test-green.txt` preserves subsequent results. `compile.txt` is the compiler receipt; empty output with successful command exit is expected. Windows ETW runtime qualification is NOT RUN by this local build.

## Windows usage (elevated collector)

Parent directory must already exist; run directory must be new. Session name includes PID and monotonic start tick. Maximum lifetime is 600 seconds; optional duration is 1..600 seconds.

```text
collector.exe --selftest C:\p06\synthetic-new 30
python qualify_selftest.py C:\p06\synthetic-new
collector.exe --capture C:\p06\actual-new 600
```

Wait for `ready.json` before issuing the separately authorized request. Readiness requires a delivered private handshake event through ProcessTrace, then successful enablement of the selected provider. A heartbeat provider is never written to `events.jsonl`. `--selftest` enables only the separate test provider and emits five events with known values; it never enables or emits the real provider. `--capture` never emits test records. After requests finish, create an empty `stop` file inside the run directory. The collector disables the provider, stops the session and drains ProcessTrace before writing `summary.json`. Decode:

```text
python decode.py C:\p06\actual-new --expected-calls 1
```

All event records are flushed to `events.jsonl` with raw bytes, descriptor ID/version and ETW PID/TID/timestamp. Summary records actual ETW session loss counters; failed statistics retrieval produces null. Missing, malformed, duplicate, incomplete or dropped data is NOT_PROVEN, never evidence that the branch was absent. Global sequence continuity is checked across all collected provider records, independent of callback delivery order; a nonzero initial sequence is valid. Expected call count must describe the entire enabled provider scope. Other sessions enabling the same provider may prevent a clean enable epoch; mixed epochs are rejected. Cumulative producer write failures are conservatively rejected, even if historical.

## Fixed 128-byte schema (little endian)

Real provider: `7b8bf667-80a2-4e27-bff8-8a67ab47c6ac`. Event ID 1, version 1, level 4, keyword 1. Test provider: `239f86a1-41b7-4a93-a891-637b2e8144fa`. Readiness-only provider: `4d4a6219-63aa-4cb7-ab90-51527ae40d32`.

| Offset | Field |
|---|---|
| 0,4,8 | u32 magic 0x314f4150, schema 1, size 128 |
| 12 | u32 phase: ENTRY 1, BRANCH 2, ATTEST_RETURN 3, WRITE_BACK 4, DDI_RETURN 5 |
| 16,24,32,40 | u64 observer instance, call ID, QPC, global event sequence |
| 48,52,56,60 | u32 PID, TID, branch, requested version |
| 64 | u64 user handle |
| 72 | 16 bytes carrier ID |
| 88,92,96,100 | u32 local status, buffer status, NTSTATUS, flags (bit 0 = buffer status valid) |
| 104,112,120 | u64 cumulative failed writes, enable epoch, QPC frequency |

Payload excludes kernel pointers. Invalid buffer status is preserved with its validity flag; consumers must not interpret it as actual output. DDI_RETURN records the return-site value, not subsequent dxgkrnl handling.

## Receipt correlation

Decoder reports `diagnostic_space=REAL_PROVIDER`, `SYNTHETIC`, or `UNKNOWN`. Synthetic captures may be complete but always retain actual `branch_conclusion=NOT_PROVEN`. Header PID/TID are retained separately from payload identity; no undocumented equality assumption is made. Unknown flags, zero instance/call/PID/TID/frequency/epoch, missing buffer validity at phases 4/5, changing branch/local-status/NTSTATUS at phases 2–5, and decreasing per-call QPC reject completeness. Different local and actual buffer status is recorded as an observation, not a capture error.

Normalize each immediate harness receipt to one JSONL object with fields:

```json
{"run_id":"run-name","case_id":"case-name","architecture":"x64","source_sha":"40 hex characters","pid":123,"tid":456,"requested_version":4,"user_handle":1234,"carrier_id_hex":"32 hex characters","qpc_before":1000,"qpc_after":2000,"qpc_frequency":10000000}
```

Manifest is JSON with `run_id`, `architecture` (`x64` or `x86`), exact `source_sha` and `cases` (array of unique case IDs). Preserve executable and package hashes as additional manifest fields. Values must come from the immediate harness receipt and sealed execution manifest, not be inferred from expected kernel outcomes. QPC frequency must be recorded by the harness. The 600-byte request has carrier ID at offset 24, requested version at 72 and user handle at 80. Wrapper PID/TID and QPC window correlate the actual call.

```text
python decode.py RUN_DIRECTORY --expected-calls N > observation.json
python correlate.py observation.json receipts.jsonl manifest.json
```

Correlation requires exactly one full call matching every identity field and entirely inside the immediate QPC window. Duplicate cases, reused calls, missing or ambiguous matches, unmatched provider calls, provenance mismatches and synthetic/incomplete captures remain NOT_PROVEN. Output lists observed branch and statuses at every phase, including local/buffer divergence, without comparing them to expected outcomes. Source SHA is manifest provenance, not a claim that ETW itself identifies the binary.
