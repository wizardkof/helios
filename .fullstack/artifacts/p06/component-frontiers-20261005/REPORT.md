# P06 — component frontiers after frozen .312

Status: NATIVE_PREFLIGHT=PASS; COMPONENTS=PASS_5_OF_5; candidate22.22.313.0 frozen; single product run37392622277 attempt1 FAILURE; FINAL_PACKAGE=FAIL_BOTH_CONFIGURATIONS; no qualified final ZIP.

Authority: owner attachment d044f41d-90af-463f-a5b0-42cbc4079a56. Isolated source branch `p06/component-frontiers-20261005`, base `5e9f1d686ff58f60a1747aa4595d393b65c0b336`. Frozen .312 HEAD `654391bc9c63cc770013d1508b76909604e4c663`, fingerprint `f61fadb62dc75dde787755344ea4585d9ee84ce2bce50ae3db84b4dbd14ed543`, historical product run `37356930190` attempt 1 remain unchanged.

## Historical evidence and bounds

.312 retains Python PASS, 9/9 native DXVK PASS, producer Release/Debug PASS, driver Release/Debug PASS, Compatibility PASS. Loaders failed on the short header include; both Mesa architectures failed serializing WindowsPath; OpenCL was cancelled by the job's 3h limit with unavailable job log (BlobNotFound); duration cause remains NOT_PROVEN. Package NOT_RUN_DEPENDENCY_FAILURE. The previous 19 historical/control original archives remain separately preserved.

The only tracked `probe_common.h` is `tools/fullstack/probe_common.h`, blob `8c49b6772f6c59828f543a7d55d5c4d1b0c2e836`, matching the file. Windows native run `37390745827` reproduces the exact C1083 using the complete checkout. Its negative-control receipt is PASS and archive roundtrip PASS; initial shell inherited the expected nonzero native exit, so the job itself was FAIL. Subsequent control now extracts historical source and returns zero only after asserting the expected refusal. Production dependency becomes `#include "fullstack/probe_common.h"`, without a second header authority.

Both native MSYS2 architectures in `37390745827` reproduced historical setup exit 2 and passed import-order-only setup/compile/reconfigure/recompile (all exit 0). The real wrap has `diff_files` and applies a patch whose compiled executable validates its effect. Production change loads mesonmain before wrap/Path; external DirectoryLock redirect is retained unchanged. Early controls refused export of fixture hidden `.wraplock` files; fixture execution is now outside the exported receipt directory. Those failures remain historical control failures, not product evidence.

Run `37390745827` native watchdog control PASS (4/4): exit0, nonzero37, timeout with descendant, successful parent with surviving descendant. Job Object accounting requires zero active processes after cleanup. Run `37391235389` repeats watchdog PASS; phase control emits seven PASS transitions and a preserved native failure37 receipt, but its test step exits1 before final summary. Independent review identified inherited negative LASTEXITCODE and startup receipt handling; source fixes and diagnostic control subsequently passed in the final native preflight documented below.

## OpenCL preservation contract

Same CLVK pin, clspv patches, LLVM fetch revision, CMake flags, compiler, Ninja, sccache policy and HELIOS_BUILD_JOBS. Atomic phase records cover clone/submodules/patches/LLVM fetch/configure/build/stage, current phase and last native command, UTC transitions and public source identities.

The hosted job limit is six hours, with timeout-minutes default 360: [GitHub Actions limits](https://docs.github.com/en/enterprise-cloud%40latest/actions/reference/limits), [workflow timeout syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idtimeout-minutes). OpenCL job timeout becomes360 only for preservation margin; producer maximum is330 minutes and an absolute cutoff set before bootstrap subtracts bootstrap elapsed time. A gated child starts the unchanged producer only after Windows Job Object ownership. Timeout returns failure124, captures stdout/stderr and current phase, terminates all descendants and permits existing always() collection/seal/upload/roundtrip. More time is not a demonstrated duration fix.

## Verification so far

Portable suite: 76 tests, 72 PASS and 4 native Windows-only SKIP. Candidate-version: 15/15 PASS. Related-pattern scan bounded to affected CI/probe surfaces. Previously qualified Ninja/Count/SDK/Python code unchanged. DXVK `efafecc24dd1b3c07fca194af4424e6d7ac16c94`, Mesa `7d678f31c485b647eed81610491af61c0a0fac65`, vkd3d `9494617539385c6d2d9925984d55d3f9d3143d0d` unchanged.

WINBOAT_OPERATIONS=NOT_RUN; LOCAL_PRODUCT_BUILD=NOT_RUN; DEPLOY=NOT_RUN; REBOOT=NOT_RUN; RUNTIME=NOT_RUN; GITHUB_RELEASE_CREATED=NO.

HISTORICAL_310_ROOT_CAUSE, BLACK_SCREEN_FIXED, DEVICE_LOSS_ORIGIN, DEADLOCK_IN_ORIGINAL_CAPTURE, SSH_POST_REBOOT_CAUSE and EXTRA_CONTAINER_RESTART_CAUSE all remain NOT_PROVEN.

## Final preflight

Run `37391739888`, attempt1, HEAD `7a181d15e5120e8bf2a695dffe92f254784b3e5d`: all four native jobs SUCCESS. All four original archives API SHA-256/CRC/extracted bytes PASS; all four seal/upload/download/verify sequences PASS.

Loaders: historical exact C1083 RED PASS; corrected full eight x64 smoke probes PASS, including real D3D12 device-create and clear/readback compilation. Official SDK provides Vulkan import library; official pinned OpenCL loader export definitions create only its import library. No loader product or probe runtime is executed. Product x86 graphics compilation remains a separate pending candidate gate.

Mesa x64 UCRT64 and x86 MINGW32: exact archived Python3.14.7/Meson1.12.1 pins and selected Ninja PASS. Historical diff_file type pathlib.WindowsPath while sys.modules pathlib points to mesonbuild._pathlib without WindowsPath reproduces PicklingError and the diff_files→wraps→wrap_resolver→Environment→CoreData chain. Import-order-only and production wrappers use mesonbuild._pathlib._Path and pass setup/compile/reconfigure/recompile; real patched wrap executable PASS. Real Mesa setup saves coredata.dat and completes DirectX-Headers1.619.1 fallback. Locks are outside the entire checkout and thus all SOURCE_ROOTS. No full Mesa compilation outside candidate.

OpenCL: four native Windows Job Object controls PASS; exit37 preserved, timeout124 preserved with three active processes before cleanup and zero after; collection continues. All seven atomic phase-transition controls PASS, native failure37 phase receipt PASS, production scripts parse with zero errors. Control summary now PASS and job/roundtrip SUCCESS. Independent code review at the same HEAD PASS, no critical or important findings remaining.

Earlier control scaffolding failures are retained: fixture hidden-lock export, directory-name assertion, optional absent SDK x86 library, expected native exit leakage. One early incomplete control run was automatically cancelled by the existing branch concurrency policy when its corrected control started; this was not a product retry or manual candidate cancellation. The complete final preflight supersedes those controls only for current control qualification.

## New frozen candidate and one product execution

Remote ledger queried after all final controls/review PASS:22.22.313.0. Frozen HEAD `8be68221360e2ae59f92b8598da9ed3d5eb0ccb9`, fingerprint `6982a610df4ebd1d52998fe18ac35d81d43cfad97c0141c3198bdbef833904a1`, reservation `refs/helios/candidate-reservations/22.22.313.0`. Reservation source base is `a2628a357ff40daaf9699c0ca7b0ad11994f3fbf`; the freeze commit changes only the three version/reservation metadata files. Code delta since final native preflight NONE. Clean checkout and remote source lock PASS. Three component pins unchanged. Exact source preparation refused before reservation while clone submodules were uninitialized; initialization from official remotes and existing read-only object references closed that gate without builds or source changes.

One product dispatch `37392622277`, attempt1, `infrastructure_only=false`; every focal-control input false. Release build/qualification and native artifact roundtrip PASS; Debug build/qualification and native artifact roundtrip PASS; driver job SUCCESS. Native Python75PASS/1SKIP of76 and candidate15/15 PASS; native DXVK9/9 PASS; real host0.36/private-WDK0.30 producer executions exit0 in Release and Debug, exact pre/post frozen fingerprint PASS. Compatibility, Loaders, Mesa x64 and Mesa x86 product jobs SUCCESS with native artifact roundtrips PASS. Loaders contains all8 x64 and6 x86 graphics smoke probes; exact PE machine/size/hash independently verified. Both Mesa full builds and their DLL architecture/source/Ninja pre-post identities PASS. OpenCL product job SUCCESS: all7 phase receipts PASS, producer/supervisor exits0, CLVK/clspv/LLVM identities match pins, owned processes after cleanup0. Observed fetch LLVM385.166s and build8409.071s; old .312 duration cause remains NOT_PROVEN. All five components PASS with native roundtrips. Package Release and Debug automatically ran and failed independently as recorded below. Release original archive API digest/CRC/extracted bytes PASS, exact candidate identity and file map sizes/hashes PASS. Independent PE/PDB bytes match all five native symbol-audit rows. Strict Linux ordered verifier reports FAIL_ORDER_ONLY while the exact unordered file map and native Windows roundtrip PASS; this distinction is retained in product-artifact-verification.json. All component product results PASS; final package failures are recorded below. No retry, manual cancellation, package promotion, release, deploy, VM or runtime operation. Both Package jobs automatically ran after all five components passed; their failures and successful evidence preservation are retained separately.

## Terminal product execution and first Package failures

Run37392622277 attempt1 completed FAILURE. Exactly one workflow_dispatch exists on the frozen product branch; all focal-control inputs false, infrastructure_only=false. Driver and all five component jobs SUCCESS; both Package jobs FAILURE. Native Python75PASS/1SKIP of76, candidate15/15, native DXVK9/9, producer audits and Release/Debug PASS have their own .313 receipts. OpenCL all7 phases PASS, producer/supervisor exits0, actual CLVK/clspv/LLVM pins unchanged and owned processes after cleanup0. Fetch LLVM385.166s; build8409.071s. These are current measured phase times, not attribution of the lost .312 timeout cause.

First new failure: Package Release, Install Rust nightly, 2026-10-06T04:21:02.2750763Z. rustup requested https://static.rust-lang.org/dist/2026-07-14/channel-rust-nightly.toml and received HTTP503, exit1. Installer build/assembly/signing/final schema were NOT_RUN. Exact log and immutable first-failure API snapshot are preserved; no pin substitute, candidate edit or retry occurred.

Separate Package Debug failure: installer build and native input identity verification PASS, then Assemble-Package.ps1:190 at2026-10-06T04:22:52.3514235Z reports `INF DriverVer date is invalid: 10/06/2026`, exit1. The exact Debug INF contains DriverVer10/06/2026,22.22.313.0. The catch hides the inner exception; internal root cause remains NOT_PROVEN. Untyped format-array overload binding is only a static candidate requiring native control, not a proven cause or a change applied here. Test-signing, final extraction, native packaged schema and qualified runtime ZIP were not reached. No final installer/package acceptance is inferred from the earlier component PASS results.

Both failed Package jobs preserve PRIMARY_GATE_RESULT=failure separately from EVIDENCE_COLLECTION_RESULT=PASS and successful native upload/download/verify. Sixteen original product archives API digest/CRC/extracted bytes PASS; eight executed-job raw logs present; nine collection manifests independently verified; seven product exact identities/file sets/sizes/hashes PASS. Sixteen real native artifact roundtrips PASS. Strict Linux ordered verification remains FAIL_ORDER_ONLY for all7 product artifacts while exact unordered maps and the authoritative native Windows roundtrips PASS; no ordered-verifier result is promoted.

Archive count for this requested baseline and continuation:19 prior authority archives +11 new-control archives +16 product archives =46 originals preserved. Other historical candidate evidence remains separate and untouched. Frozen .310/.311/.312/.313 heads and tracked cleanliness rechecked; .310 head additionally matches its historical run metadata. Remote source lock after execution PASS. Root dirty working source and historical receipts were not rewritten.

Evidence: classification.json and STATUS.txt contain the exact requested fields; first-new-failure.json and package-debug-failure.json distinguish the failures; terminal-job-status.json preserves all steps; driver-qualification-verification.json, loaders-smoke-product-verification.json, mesa-product-verification.json and opencl-product-verification.json qualify actual component bytes/receipts; product-artifact-verification.json retains local ordered limitations; native-roundtrip-final-verification.json records all16 successful native checks; run-37392622277 retains original ZIPs, extracted bytes, raw job logs and full hash index. observation-limitations.json records the temporary empty step response, active-log404 and API502 independently from product results.

Delivery gate: no next reservation or product retry. LOCAL_PRODUCT_BUILD, WINBOAT_OPERATIONS, DEPLOY, REBOOT and RUNTIME remain NOT_RUN; GITHUB_RELEASE_CREATED=NO. BLACK_SCREEN_FIXED, DEVICE_LOSS_ORIGIN, DEADLOCK_IN_ORIGINAL_CAPTURE, SSH_POST_REBOOT_CAUSE, EXTRA_CONTAINER_RESTART_CAUSE and HISTORICAL_310_ROOT_CAUSE remain NOT_PROVEN.

## Exact delivery status

```text
CANDIDATE_312_STATUS=FROZEN_COMPONENT_FAILURE
DRIVER_312_RELEASE=PASS
DRIVER_312_DEBUG=PASS
COMPATIBILITY_312=PASS
LOADERS_312_ROOT_CAUSE=SHORT_INCLUDE_PROBE_COMMON_H_WITHOUT_TOOLS_FULLSTACK_INCLUDE_PATH
LOADERS_HEADER_RED_GREEN=PASS
LOADERS_SMOKE_COMPILE_CONTROL=PASS_8_X64
MESA_312_OBSERVED_FAILURE=WINDOWS_PATH_PICKLE
MESA_PICKLE_ROOT_CAUSE=MESON_ISOLATED_IMPORT_ORDER_PATHLIB_CLASS_IDENTITY
MESA_IMPORT_ORDER_RED_GREEN=PASS_BOTH_ARCHITECTURES
MESA_X64_SERIALIZATION_CONTROL=PASS
MESA_X86_SERIALIZATION_CONTROL=PASS
MESON_EXTERNAL_LOCK_POLICY=PASS
OPENCL_312_RESULT=CANCELLED_JOB_TIME_LIMIT_3H
OPENCL_312_DURATION_CAUSE=NOT_PROVEN
OPENCL_PHASE_RECEIPTS=PASS_7_OF_7_NATIVE_CONTROLS_AND_PRODUCT
OPENCL_TIMEOUT_HARNESS_CONTROL=PASS_4_OF_4
FINAL_PREFLIGHT_RUN_ID=37391739888
FINAL_PREFLIGHT_SHA=7a181d15e5120e8bf2a695dffe92f254784b3e5d
PORTABLE_TESTS=PASS_72_OF_76_WITH_4_WINDOWS_SKIP;CANDIDATE_15_OF_15
INDEPENDENT_REVIEW=PASS
NEW_CANDIDATE_VERSION=22.22.313.0
NEW_CANDIDATE_FINGERPRINT=6982a610df4ebd1d52998fe18ac35d81d43cfad97c0141c3198bdbef833904a1
NEW_HELIOS_SOURCE=8be68221360e2ae59f92b8598da9ed3d5eb0ccb9
PRODUCT_CI_RUN_ID=37392622277
PRODUCT_CI_ATTEMPT=1
PYTHON_GATE=PASS_75_OF_76_WITH_1_SKIP;CANDIDATE_15_OF_15
NATIVE_REGRESSIONS=PASS_9_OF_9
PRODUCER_AUDIT_RELEASE=PASS
PRODUCER_AUDIT_DEBUG=PASS
DRIVER_RELEASE=PASS
DRIVER_DEBUG=PASS
COMPATIBILITY=PASS
LOADERS=PASS
MESA_X64=PASS
MESA_X86=PASS
OPENCL=PASS
COMPONENTS=PASS_5_OF_5
PACKAGE_RELEASE=FAIL_RUSTUP_HTTP_503
PACKAGE_DEBUG=FAIL_INF_DRIVER_VER_DATE_PARSE_REFUSAL
PACKAGE_DEBUG_INTERNAL_ROOT_CAUSE=NOT_PROVEN
FINAL_PACKAGE=FAIL_BOTH_CONFIGURATIONS;NO_QUALIFIED_ZIP
FINAL_PACKAGED_SCHEMA=NOT_RUN
FINAL_PACKAGE_SIGNING=NOT_RUN
FINAL_PACKAGE_EXTRACTION=NOT_RUN
ARTIFACTS_PRESERVED=PASS_46_ORIGINAL_ARCHIVES_19_PRIOR_11_NEW_CONTROLS_16_PRODUCT
PRODUCT_JOB_LOGS=PASS_8_OF_8
EVIDENCE_COLLECTION=PASS
NATIVE_ARTIFACT_ROUNDTRIPS=PASS
LOCAL_ORDERED_ARTIFACT_VERIFIER=FAIL_ORDER_ONLY_7_PRODUCT_ARTIFACTS
EXACT_ARTIFACT_FILE_SET_SIZE_HASH=PASS
WINBOAT_OPERATIONS=NOT_RUN
LOCAL_PRODUCT_BUILD=NOT_RUN
DEPLOY=NOT_RUN
REBOOT=NOT_RUN
RUNTIME=NOT_RUN
GITHUB_RELEASE_CREATED=NO
HISTORICAL_310_ROOT_CAUSE=NOT_PROVEN
BLACK_SCREEN_FIXED=NOT_PROVEN
DEVICE_LOSS_ORIGIN=NOT_PROVEN
DEADLOCK_IN_ORIGINAL_CAPTURE=NOT_PROVEN
SSH_POST_REBOOT_CAUSE=NOT_PROVEN
EXTRA_CONTAINER_RESTART_CAUSE=NOT_PROVEN
```
