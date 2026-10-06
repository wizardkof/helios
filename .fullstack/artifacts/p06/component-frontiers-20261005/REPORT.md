# P06 — component frontiers after frozen .312

Status: NATIVE_PREFLIGHT=PASS; reservation and product dispatch NOT_RUN.

Authority: owner attachment d044f41d-90af-463f-a5b0-42cbc4079a56. Isolated source branch `p06/component-frontiers-20261005`, base `5e9f1d686ff58f60a1747aa4595d393b65c0b336`. Frozen .312 HEAD `654391bc9c63cc770013d1508b76909604e4c663`, fingerprint `f61fadb62dc75dde787755344ea4585d9ee84ce2bce50ae3db84b4dbd14ed543`, historical product run `37356930190` attempt 1 remain unchanged.

## Historical evidence and bounds

.312 retains Python PASS, 9/9 native DXVK PASS, producer Release/Debug PASS, driver Release/Debug PASS, Compatibility PASS. Loaders failed on the short header include; both Mesa architectures failed serializing WindowsPath; OpenCL was cancelled by the job's 3h limit with unavailable job log (BlobNotFound); duration cause remains NOT_PROVEN. Package NOT_RUN_DEPENDENCY_FAILURE. The previous 19 historical/control original archives remain separately preserved.

The only tracked `probe_common.h` is `tools/fullstack/probe_common.h`, blob `8c49b6772f6c59828f543a7d55d5c4d1b0c2e836`, matching the file. Windows native run `37390745827` reproduces the exact C1083 using the complete checkout. Its negative-control receipt is PASS and archive roundtrip PASS; initial shell inherited the expected nonzero native exit, so the job itself was FAIL. Subsequent control now extracts historical source and returns zero only after asserting the expected refusal. Production dependency becomes `#include "fullstack/probe_common.h"`, without a second header authority.

Both native MSYS2 architectures in `37390745827` reproduced historical setup exit 2 and passed import-order-only setup/compile/reconfigure/recompile (all exit 0). The real wrap has `diff_files` and applies a patch whose compiled executable validates its effect. Production change loads mesonmain before wrap/Path; external DirectoryLock redirect is retained unchanged. Early controls refused export of fixture hidden `.wraplock` files; fixture execution is now outside the exported receipt directory. Those failures remain historical control failures, not product evidence.

Run `37390745827` native watchdog control PASS (4/4): exit0, nonzero37, timeout with descendant, successful parent with surviving descendant. Job Object accounting requires zero active processes after cleanup. Run `37391235389` repeats watchdog PASS; phase control emits seven PASS transitions and a preserved native failure37 receipt, but its test step exits1 before final summary. Independent review identified inherited negative LASTEXITCODE and startup receipt handling; source fixes and diagnostic control are prepared. Full native preflight is still pending.

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
