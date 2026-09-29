# P06 E1 WDK symbol and typed ABI audit

Audit mode: source and generator inspection only. No local Windows WDK build was
attempted. The KMD build imports `wdk_sys::ntddk::*`; `wdk-sys` generates that
module from WDK Base headers via `Config::bindgen_header_contents([ApiSubset::Base])`.
For WDM, `wdk-build` selects `ntifs.h`, `ntddk.h`, and `ntstrsafe.h` (see the pinned
`windows-drivers-rs` checkout at `crates/wdk-build/src/lib.rs::base_headers` and
`crates/wdk-sys/build.rs::generate_base`). The generated OUT_DIR files and an
installed WDK are absent in this Linux checkout. Symbol provenance is therefore
the pinned header-generation path; exact target compilation remains
`PENDING_WINDOWS_CI`.

All listed calls run from the PASSIVE-level Escape path or final AdapterContext
drop at PASSIVE. The highest documented API ceiling below is APC_LEVEL. KMD's
escape entry asserts PASSIVE before dispatch, and AdapterContext drop documents
RemoveDevice/PASSIVE.

| Symbol used by E1 | `wdk_sys` binding / expected C signature | Contract used here |
|---|---|---|
| `ZwCreateSection` | `ntddk::ZwCreateSection(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PLARGE_INTEGER, ULONG, ULONG, HANDLE) -> NTSTATUS` | PASSIVE; kernel handle is private; close every returned handle |
| `MmMapViewInSystemSpace` | `ntddk::MmMapViewInSystemSpace(PVOID, PVOID*, PSIZE_T) -> NTSTATUS` | <= APC_LEVEL; E1 calls at PASSIVE |
| `MmUnmapViewInSystemSpace` | `ntddk::MmUnmapViewInSystemSpace(PVOID) -> NTSTATUS` | <= APC_LEVEL; every failure is returned or recorded |
| `ZwClose` | `ntddk::ZwClose(HANDLE) -> NTSTATUS` | PASSIVE; close status checked; handle has `OBJ_KERNEL_HANDLE` |
| `ObReferenceObjectByHandle` | `ntddk::ObReferenceObjectByHandle(HANDLE, ACCESS_MASK, POBJECT_TYPE, KPROCESSOR_MODE, PVOID*, POBJECT_HANDLE_INFORMATION) -> NTSTATUS` | PASSIVE; handle is kernel-created and access is limited to read/query |
| `ObfDereferenceObject` | `ntddk::ObfDereferenceObject(PVOID) -> VOID` | E1 pairs it once with a successful object reference |
| `SeCaptureSubjectContext` | `ntddk::SeCaptureSubjectContext(PSECURITY_SUBJECT_CONTEXT) -> VOID` | PASSIVE; `SubjectContextGuard` always calls release |
| `SeQuerySubjectContextToken` | WDK macro, not an imported function binding. Its documented selection is applied to fields of the typed WDK `SECURITY_SUBJECT_CONTEXT`: `ClientToken` when present, otherwise `PrimaryToken` | Used once under the captured context; capture holds token references. No lock/unlock API is called |
| `SeQueryInformationToken` | `ntddk::SeQueryInformationToken(PACCESS_TOKEN, TOKEN_INFORMATION_CLASS, PVOID*) -> NTSTATUS` | PASSIVE; returned paged-pool information is freed with `ExFreePool` |
| `SeReleaseSubjectContext` | `ntddk::SeReleaseSubjectContext(PSECURITY_SUBJECT_CONTEXT) -> VOID` | Paired once with successful capture, on every return path |
| `RtlCreateSecurityDescriptor` | `ntddk::RtlCreateSecurityDescriptor(PISECURITY_DESCRIPTOR, ULONG) -> NTSTATUS` | Called at PASSIVE on caller-stack typed storage |
| `RtlCreateAcl` | `ntddk::RtlCreateAcl(PACL, ULONG, ULONG) -> NTSTATUS` | Called at PASSIVE; ACL storage and computed size are bounded |
| `RtlAddAccessAllowedAce` | `ntddk::RtlAddAccessAllowedAce(PACL, ULONG, ACCESS_MASK, PSID) -> NTSTATUS` | `< DISPATCH_LEVEL`; called at PASSIVE; requestor ACE grants only `SECTION_MAP_READ | SECTION_QUERY`; every status checked |
| `RtlSetDaclSecurityDescriptor` | `ntddk::RtlSetDaclSecurityDescriptor(PISECURITY_DESCRIPTOR, BOOLEAN, PACL, BOOLEAN) -> NTSTATUS` | Called at PASSIVE with `DaclPresent=TRUE` and a non-null ACL |
| `RtlSetOwnerSecurityDescriptor` | `ntddk::RtlSetOwnerSecurityDescriptor(PISECURITY_DESCRIPTOR, PSID, BOOLEAN) -> NTSTATUS` | Called at PASSIVE with the well-known LocalSystem SID S-1-5-18 |
| `RtlValidSid`, `RtlLengthSid`, `RtlCopySid` | `ntddk::RtlValidSid(PSID) -> BOOLEAN`; `RtlLengthSid(PSID) -> ULONG`; `RtlCopySid(ULONG, PSID, PSID) -> NTSTATUS` | Called at PASSIVE; lengths are checked before copy |
| `RtlInitUnicodeString` | `ntddk::RtlInitUnicodeString(PUNICODE_STRING, PCWSTR) -> VOID` over typed `UNICODE_STRING` | Called at PASSIVE; source is NUL-terminated caller-stack UTF-16 |
| `ExFreePool` | `ntddk::ExFreePool(PVOID) -> VOID` | Releases only the successful `SeQueryInformationToken` allocation |
| `KeWaitForSingleObject`, `KeSetEvent` | `ntddk::KeWaitForSingleObject(PVOID, KWAIT_REASON, KPROCESSOR_MODE, BOOLEAN, PLARGE_INTEGER) -> NTSTATUS`; `KeSetEvent(PKEVENT, KPRIORITY, BOOLEAN) -> LONG` | PASSIVE serialization wait; wait result checked; event restored by guard |
| `core::sync::atomic::fence(Ordering::SeqCst)` | Rust core primitive, not a WDK binding | CPU/compiler ordering around the shared-record sequence field |

No local extern declarations or replica definitions exist for WDK structures.
`OBJECT_ATTRIBUTES`, `UNICODE_STRING`, `LARGE_INTEGER`, `SECURITY_DESCRIPTOR`,
`SECURITY_SUBJECT_CONTEXT`, and `TOKEN_USER` are `wdk_sys` generated types. `ACL`
is used only as opaque storage passed to WDK routines; no ACL fields are read or
written. Section APIs use the opaque `PVOID` section object and typed sizes; there
is no copied section-object structure. The only fixed byte SID is the canonical
well-known LocalSystem SID, S-1-5-18; the requestor SID is copied from the live
captured caller token.

`SeLockSubjectContext` / `SeUnlockSubjectContext` are not called: one token
information query is made under the captured references. The Microsoft contract
requires explicit locking when multiple queries need a mutually consistent
snapshot; this implementation does not make multiple queries.

References: [wdk-build pinned source](https://github.com/microsoft/windows-drivers-rs/blob/36558802149bc92455bf5719fe77f3a829d8580f/crates/wdk-build/src/lib.rs),
[SeCaptureSubjectContext](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-secapturesubjectcontext),
[SeQueryInformationToken](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-sequeryinformationtoken),
[ZwCreateSection](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwcreatesection),
[MmMapViewInSystemSpace](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/nf-ntddk-mmmapviewinsystemspace),
[ObReferenceObjectByHandle](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-obreferenceobjectbyhandle),
[RtlAddAccessAllowedAce](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-rtladdaccessallowedace),
[object lifetime](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/life-cycle-of-an-object).
