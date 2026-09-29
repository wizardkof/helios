# P06 E1 section carrier error-path matrix

Scope: diagnostic section create, publish, query, release, and adapter teardown. The
section is not attached to a GPU submission, semaphore, wait, or retirement path.
Raw NTSTATUS is returned by the escape; `reserved` carries the coarse diagnostic
class and `sequence` carries the failing CREATE stage where applicable.

## CREATE

| Boundary | Acquired state | Failure result | Required unwind / final state |
|---|---|---|---|
| Allocate ID and generation | None | `STATUS_INSUFFICIENT_RESOURCES` on non-wrapping counter exhaustion | No slot/resource acquired |
| Reserve bounded slot | `Creating` lease | table full: `STATUS_INSUFFICIENT_RESOURCES`; wait failure: wait NTSTATUS | No backing object; reservation is absent or returned to `Free` |
| Capture subject context / query token SID | Slot lease; captured subject/token refs; token information pool buffer | stage 5/6/7 status | RAII releases token pool allocation and captured subject refs; slot returned to `Free` |
| Construct typed SD, ACL, and unique name | Slot lease; caller-stack SID/ACL/SD storage | stage 1 status | Caller-stack storage expires; slot returned to `Free` |
| `ZwCreateSection` | Slot lease; kernel handle on success | stage 2 status | Close any unexpected returned handle; record `P06Hnd` if close fails; slot returned to `Free` |
| `ObReferenceObjectByHandle` | Slot lease; section handle | stage 3 status | Always `ZwClose`; dereference any unexpected object on failure; record `P06Hnd` if close fails; slot returned to `Free` |
| `MmMapViewInSystemSpace` | Slot lease; object reference | stage 4 status | Unmap any unexpected returned view; dereference object only if unmap succeeds; on failure retain the reference and record `P06Unm`; slot returned to `Free` |
| Initialize mapped record and publish Live slot | Slot lease; object reference; system view | raw wait/serialization NTSTATUS | Unmap view; dereference object only if unmap succeeds; on failure retain the reference and record `P06Unm`; return slot reservation to `Free` |

Every successful `ZwCreateSection` handle is closed before CREATE returns. The
slot owns only the object reference and system view. The public name is a
bootstrap; a user handle can retain the section object after RELEASE.

## PUBLISH / QUERY

| Validation | Failure | Mutation |
|---|---|---|
| Slot index outside bounded table or `Free` | `STATUS_NOT_FOUND` | None |
| Generation differs at the supplied slot | `STATUS_REVISION_MISMATCH` | None |
| Probe ID differs | `STATUS_NOT_FOUND` | None |
| Slot not `Live` | `STATUS_INVALID_DEVICE_STATE` | None |
| Publish sequence is non-monotonic or cannot be doubled safely | `STATUS_INVALID_PARAMETER` | None |
| Valid publish | `STATUS_SUCCESS` | Seqlock record updated under adapter serialization |
| Valid query | `STATUS_SUCCESS` | Reply receives slot sequence, size, and name |

## RELEASE / TEARDOWN

| Boundary | Failure result | Required state/resource handling |
|---|---|---|
| Validate state/index | `NOT_FOUND` for out-of-range or free slot; `INVALID_DEVICE_STATE` unless `Live` | Do not detach or release any resource |
| Validate generation and probe ID | `REVISION_MISMATCH` for an occupied slot with another generation; `NOT_FOUND` for a different ID | Do not detach or release any resource |
| Mark `Releasing`, unmap system view | Return unmap NTSTATUS | Under the adapter serialization, restore the slot as `Live`; keep the object reference for a retry |
| Unmap succeeds | Continue | Dereference the retained section object exactly once |
| Close kernel handle | Not a RELEASE operation | `ZwClose` is checked in CREATE before the object reference/view become slot-owned; RELEASE owns no handle |
| Clear bounded slot | Serialization remains held through unmap and dereference | Mark `Free` only after the view and object reference have been released |
| Adapter teardown | Record named `P06Unm` on unmap failure | Dereference each object once only after successful unmap; retain the reference on failure so a possible live view cannot outlive its object; slots are no longer externally addressable |

The host-testable `kmd_logic::section_carrier::ResourceLedger` tests each CREATE
acquisition boundary (slot, stack security storage, section handle, object
reference, system view, initialized record) and reverse-order unwind. Its slot
tests cover reuse, stale PUBLISH/QUERY/RELEASE rejection, non-monotonic publish,
duplicate release, bounded exhaustion, and old/new value isolation. This model
does not replace the Windows compile or runtime probe.

KMD slot transitions call the same pure transition seam (`start_create`,
`acquire_live_slot`, `fail_create_slot`, `publish_slot`, `query_slot`,
`begin_release_slot`, `restore_live_slot`, and `finish_release_slot`) exercised by
the 229-test host logic crate. The resource ledger covers acquisition/unwind
boundaries; it does not simulate WDK call failures.
