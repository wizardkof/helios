# Canonical Windows build and offline qualification

Owner policy effective 2026-10-04:

```text
CANONICAL_BUILD_BACKEND=GITHUB_ACTIONS
LOCAL_VM_ROLE=DEPLOY_AND_RUNTIME_ONLY
LOCAL_PRODUCT_BUILDS=DISABLED_BY_DEFAULT
GITHUB_ACTIONS_USED_FOR_FUTURE_CANDIDATES=YES
PUBLICATION=NO
```

Future candidates use clean GitHub Actions checkouts. Local WinBoat product
compilation and build-toolchain installation/repair require explicit authorization.
`HELIOS_ALLOW_LOCAL_PRODUCT_BUILD=1` is an implementation escape hatch for that
authorization, not standing permission. Diagnostics, installer/verifier, CDB/WinDbg
and runtime probes remain appropriate on the VM. No VM operation occurred during
this migration.

## Source identity and qualification order

1. Consult the monotonic ledger when a new product source delta is actually frozen;
   never allocate a number merely to migrate infrastructure. An unreserved source
   cannot pass `candidate_version.py verify --portable`. Different source cannot
   reuse `.300` or `.303`.
2. Verify exact requested and already qualified observed toolchain identities,
   including MSVC, SDK/WDK product/component QFE, LLVM, Rust/cargo, Python,
   Meson/Ninja, Vulkan SDK, cargo-make, host/private rust-script and producer-specific
   dependencies. Directory `10.0.26100.0` alone is not SDK/WDK QFE proof. Preserve
   requested SDK `10.0.26100.2454` separately from the historical qualified observed
   SDK inventory `10.1.26100.6901,10.1.26100.7705` and WDK `10.1.26100.2454`.
   Missing pins and unavailable exact tool versions STOP; no latest fallback.
3. Prove `HOST_RUST_SCRIPT_PRE=0.36.0`, `WDK_PRIVATE_RUST_SCRIPT=0.30.0`,
   `HOST_RUST_SCRIPT_POST=0.36.0`, unchanged host executable hash and actual
   producer dispatch. WDK install/cache stay private. Each configuration uses a
   fresh invocation audit; Release history cannot qualify Debug. Validated controls
   persist through `GITHUB_ENV` because workflow steps are separate processes.
4. Fingerprint every product checkout before and after production, with exact
   equality. External build/cache/lock directories keep generated files and Meson
   `.wraplock` outside SOURCE_ROOTS while preserving Meson's lock semantics.
5. Run existing registry and candidate lock regressions, native PS5.1 state schema,
   packaged decoder controls, DXVK `cs_failure` plus all eight queue/reentry controls
   before Release. Missing fixtures are failure, not reduced test coverage.
6. Build/qualify Release KMD, four x64/x86 UMDs, INF/CAT and PDBs. Validate exact
   version, PE architecture, signatures/CAT membership, PDB GUID/age, hashes and
   source fingerprint. Debug runs only after Release PASS, with separate outputs
   and the same validation. Package waits for both and all component producers.
7. Assemble final signed bytes. Validate provenance/input identities, payload hashes,
   setup/container digest, ZIP/setup equality, extraction round-trip, signatures,
   INF/CAT and version coherence. Run the eight native schema cases on scripts
   extracted from the **final setup**, preserving module-path isolation for PS5.1.
   Only then may the workflow write `FINAL_PACKAGE=PASS`.

## Artifacts and publication

Retain Release/Debug payloads, separate PDB/symbol bundles, final ZIP/setup,
manifests, fingerprints, exact tool versions/path/hash receipts, per-file provenance,
regression and native schema outputs, SHA256SUMS and qualification report as CI
artifacts (90-day workflow retention). Preserve failure evidence independently;
runner console output is not the sole receipt. Distinguish run ID, attempt,
configuration, source fingerprint and payload hashes. Standard artifact names stay
compatible with downstream consumers; they are scoped to distinct workflow runs.

Build qualification never publishes a GitHub Release, public tag or external
upload. Workflow repository permission is read-only; publication requires a separate
explicit owner instruction. A source-identical `.303` reproduction, if authorized,
is `CI_REPRODUCTION_303`, with separate receipt/artifact identities and no overwrite.

## Local deployment and evidence boundary

A future CI package can advance to WinBoat only with `FINAL_PACKAGE=PASS`:
install → reboot if required → provisioning → static verification → runtime.
Offline CI evidence does not prove DWM/RDP rendering or fault causality.

Historical `.299` rollback and all local receipts remain intact. `.300` is frozen,
deploy blocked. `.303` remains Release/Debug/offline PASS, 69/69 and schema 8/8;
deploy PARTIAL, post-reboot verification incomplete.

```text
BLACK_SCREEN_FIXED=NOT_PROVEN
DEVICE_LOSS_ORIGIN=NOT_PROVEN
DEADLOCK_IN_ORIGINAL_CAPTURE=NOT_PROVEN
SSH_POST_REBOOT_CAUSE=NOT_PROVEN
EXTRA_CONTAINER_RESTART_CAUSE=NOT_PROVEN
```

## Current implementation boundary

The migration changes are unreserved source, prepared in the isolated worktree
`.fullstack/work/p06-ci-canonical-20261004` and applied to the current workspace
against the preserved dirty baseline, without a candidate reservation. No native CI dispatch/build, VM action,
new version reservation, Git publication or public release was executed.
Portable tests and source review are not native qualification. The qualified DXVK
overlay is intentionally not copied into a different fork identity; it must be
integrated with its authoritative source receipt at the next source freeze. The
historical bootstrap manifest omitted CMake. Its exact generator version 3.31.6
was recovered from five hash-matching qualified package provenance caches and
is pinned for OpenCL/loaders; the recovery receipt is retained in this report. Current hosted runners
may also lack the required exact pins; that is a STOP, never authority to relax them.

See the [report](../.fullstack/artifacts/p06/ci-canonical-20261004/REPORT.md).


## OpenCL producer deadline and phase preservation

OpenCL retains its exact product commands, source/tool pins, patches, sccache
policy and HELIOS_BUILD_JOBS. The Windows hosted job allows360 minutes; the
producer allows at most330 and uses an absolute cutoff initialized before
bootstrap, leaving collection/upload/roundtrip margin. Increasing the hard
limit is operational preservation, not evidence that more time fixes duration.

Invoke-OpenCLBudget gates its child until Windows Job Object ownership, saves
stdout/stderr and atomic producer-budget.json, preserves nonzero exits, and
returns TIMEOUT/failure124 after terminating the full process tree. Accounting
must reach zero active processes. Build-OpenCL requires ReceiptDir and records
seven atomic phase transitions with UTC times, native exit, public source
identities and last command. Existing always() collection and artifact transport
remain authoritative, including after producer failure.

Final native control37391739888 qualifies zero/nonzero/timeout/descendant cleanup
and phase receipts without a CLVK build. The frozen .312 duration cause remains
NOT_PROVEN. See the component-frontiers implementation report.
