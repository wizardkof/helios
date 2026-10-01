# Independent provider state snapshot

Run `provider-state.exe > provider-state.json` in the guest only when execution is authorized. This utility calls only `EnumerateTraceGuidsEx` for ETW state. It does not register, enable, disable, start or stop providers/sessions, or invoke the driver. No guest execution was performed during implementation.

Exit codes: 0 = OFF, 1 = ENABLED, 2 = ABSENT, 3 = FAILED or UNKNOWN. Only OFF means a registered provider with zero enabling sessions in this snapshot. ABSENT is not OFF. Failed enumeration leaves registration count null. An unregistered pre-enabled instance is recognized by flag 2 and never counted as registered; its active sessions still mean ENABLED. Unknown flags or inconsistent enable records prevent OFF classification. JSON reports raw per-instance flags, EnableCount and per-session IsEnabled/LoggerId/Level/EnableProperty/keywords.

A successful GUID-list exclusion establishes ABSENT at list-query time; a listed provider's subsequent failed details query establishes FAILED, including disappearance during the two queries. The output records UTC FILETIME and QPC query bounds. This is a point-in-time snapshot; it does not assert no later enablement or prove the identity of the binary registering that GUID.

Build and tests from diagnostic worktree root:

```sh
g++ -std=c++17 -Wall -Wextra -Werror tools/p06-attest-observer/test_provider_state.cpp -o tools/p06-attest-observer/test_provider_state
tools/p06-attest-observer/test_provider_state
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static tools/p06-attest-observer/provider_state.cpp -ladvapi32 -o tools/p06-attest-observer/provider-state.exe
```

Portable parser tests cover OFF, ENABLED, pre-enable, unknown flags, truncation, invalid chain/counts, absence and multiple registrations. `provider-state-red.txt`, `provider-state-green.txt`, `provider-state-build.txt` and `provider-state.sha256` are receipts. The native test invokes the parser on binary fixtures, not ETW. Windows API execution remains NOT RUN.

API contract references: [EnumerateTraceGuidsEx](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enumeratetraceguidsex), [TRACE_PROVIDER_INSTANCE_INFO](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/ns-evntrace-trace_provider_instance_info), [TRACE_ENABLE_INFO](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/ns-evntrace-trace_enable_info).
