# SDD ledger — plan: /home/reliuz/.codex/attachments/834d7a2f-cae3-4e3a-8e72-72da458a079d/Texto colado.txt

Goal: diagnostic-only Helios/Mesa instrumentation to trace one wire fence through submit, pending, selected wait, event/blocking path, KMD event/drain, QEMU error, and guest VkResult; no drain_used fix before evidence.

## Workspaces
- Helios base: 1fe866c762c1bb1464891d7b1aac005949267c10, branch p06/diag-v5-20260927, worktree .fullstack/work/p06-diag-v5-20260927.
- Mesa base: 453662a55bee5f8441deccdd866aacdb1a63a3ff, branch p06/diag-v5-20260927-mesa, worktree .fullstack/work/mesa-p06-diag-v5-20260927.
- Main checkout dirty; preserve unchanged.

## 2026-09-27 publication ledger
- `MESA_DIAG_WORKTREE_STATUS=COMMITTED_CLEAN`; `HELIOS_DIAG_WORKTREE_STATUS=MODIFIED` (isolated source edits plus this ledger only).
- `DRAIN_USED_FIX_PRESENT=NO`; `DIAG_BUILD_BEHAVIORAL_FIXES=NONE`. Mesa keeps the pre-existing escape result rule (`status == 0`); `NT_SUCCESS` is emitted as diagnostic classification only. Wait limits, wait path, event matching and response mapping are unchanged.
- Re-run gates: `P06_V5_ABI_GATE=PASS` (protocol 16/16; V1/V2/V3/V4/V5 88/152/200/232/424; V4 prefix 0; V5 discriminator offset 232); `P06_KMD_LOGIC_GATE=PASS` (224/224); wait-result mapper `PASS`; MinGW reader syntax check `PASS` with the single known WDK `ScanLineOrdering` bitfield warning and no warnings from the probe.
- Mesa authority: parent `453662a55bee5f8441deccdd866aacdb1a63a3ff`, commit `95f69314112fc6a6e341aa4440404f728fafce51`, tree `4c62298c519a0e3873ba35c47c30ef2e5f242c3a`; pushed to `wizardkof/mesa-helios:p06/diag-v5-20260927-mesa` and independently verified.
- RUN3 `36270931813` obtained Mesa through `git submodule update --init icd/mesa`, using Helios's direct gitlink and `.gitmodules` canonical URL. Anonymous fetch of exact Mesa commit `95f69314112fc6a6e341aa4440404f728fafce51` from `https://github.com/winboat-org/mesa-helios.git` succeeded; `DIAG_MESA_CI_FETCH=PASS` for the proven RUN3 path. No `.gitmodules` or workflow change.
- `DIAG_WINDOWS_BUILD=NOT_RUN`; no local Windows build. Required GitHub Actions dispatch, package, deployment, V5 reader and fault transaction remain pending.

## Ordered gates
1. Baseline tests and source/path audit (in progress).
2. TDD protocol V5 append-only ABI and tests.
3. TDD KMD fixed atomic diagnostic snapshot and capture points; no behavior changes.
4. TDD Mesa env-gated diagnostic log and causal fence events; no timeout/order/result changes.
5. Linux protocol/KMD/Mesa focused tests, diagnostic-only commits, push authorized fork refs, required CI.
6. Build V5 valid-device reader; --once and --monitor gates.
7. Diagnostic package manifest/signing, transfer, install/verify; only reboot if installer returns 3010, never restart container.
8. One fault transaction with all diagnostic sources; stop at first missing causal boundary, no drain fix.

## Rulings

- 2026-09-27: Baseline Cargo suites passed (protocol 15/15, kmd_logic 222/222); focused TDD RED/GREEN was captured in the prior turn for the new ABI and observer helper.
- 2026-09-27: New complete suites pass after changes: protocol 16/16; kmd_logic 224/224. `p06_helios_wait_result_test.c` compiles and runs PASS. Valid-device escape reader syntax-check passes with MinGW; the only warning is the pinned WDK header bitfield warning (`ScanLineOrdering`), tolerated for the syntax-only cross-check.
- 2026-09-27: V5 ABI is 424 bytes with V4 prefix at offset 0 and discriminator at 232. The appended last_submit_previous_wire_fence identifies the preceding wire fence at the KMD submit snapshot so a producer fence can be selected without relying on last-global-submit. KMD atomic captures and QUERY_STATS V5 snapshot are implemented; Mesa gate logger and submit/pending/wait/register/event/blocking instrumentation are implemented in the separate Mesa worktree. Full Mesa/KMD Windows build and runtime gates remain pending.
- 2026-09-27: Current qualified win-mcp path exists and matches authorized SHA `a864e857de6833f7ae744d12f1a812e8d50baf71ef493979513858f68177fc35`; no remote invocation yet.
- 2026-09-27: Runtime host discovery proceeded read-only via the authorized win-mcp binary. `.fullstack/runtime/ssh-config` successfully queried the VM: Helios 22.22.288.0, ProblemCode 0, but session_id=0 and VM preflight shows no build toolchain. The build-slave alias `firstheberg2-win` does not resolve. No alias/IP substitution or scan was attempted. `HOST_BUILD=BLOCKED`; CI/package/deploy/V5 live reader/fault transaction remain NOT_RUN.
