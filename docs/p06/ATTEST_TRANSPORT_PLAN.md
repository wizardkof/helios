# P06 ATTEST transport implementation plan

Execution: inline, under the owner's full implementation authorization.
Spec: ATTEST_TRANSPORT_V1.md.

- [ ] Protocol: add actual response builder/validator tests first; capture RED;
  implement fixed120 wire, constants, framing and response construction.
  Run protocol tests including ABI assertions.
- [ ] KMD: add device-scoped command dispatch reusing section_attest verbatim;
  map only fully classified results to completed new transport. Preserve op9.
  Test all classes and malformed requests; build Release/Debug with qualified
  Windows toolchain. Commit contract/KMD separately.
- [ ] Mesa: test real C request/response helpers first; use independent expected
  copy and fresh per-call identity. Query then attest without cache on E1 path.
  Preserve denial cleanup/public error and legacy path. Commit Mesa separately.
- [ ] Publish Mesa fork and verify reachability; commit Helios pairing then
  publish Helios fork. Build both Mesa ABIs, preserve full artifacts/digests.
- [ ] Qualify signed KMD transformation and rollback; compatibility B on old
  KMD, then activate new KMD, compatibility A, then final pair C. Verify actual
  images and desktop readiness; each transition has a bounded recovery plan.
- [ ] Runtime both ABIs: received capability, genuine, classified refusal,
  Vulkan denial; then complete accepted negative and Green A matrices.
- [ ] Independently verify cleanup, knob restoration and health. Report each
  combination/candidate separately and preserve all downstream gate states.

Review focus: exact provided length vs declared size; repeated response IDs;
query succeeds with untouched buffer; unexpected internal failures; concurrent
calls on distinct devices. These require direct tests before acceptance.
