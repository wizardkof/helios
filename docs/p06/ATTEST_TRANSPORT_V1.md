# P06 ATTEST transport v1

Implementation contract; runtime qualification remains pending.

## Scope and authority

Add command 0x0019 (capability) and 0x001a (ATTEST), both envelope
version 1. These identifiers are unallocated in the inspected protocol.
Do not change command 0x18/op9/600, global escape version 1, record v2/64,
or the section_attest decision, its order, UserMode access bits5 and RAII.

## Wire

Little endian, fixed width, 120 bytes, explicitly aligned8 on both ABIs.
No implicit padding. Both commands use the same envelope. Offsets:

| Offset | Field | Type |
|---:|---|---|
|0|header magic, command, global version, declared size|4 u32|
|16|transport_version (=1)|u32|
|20|operation (=command)|u32|
|24|request_id, fresh nonzero random128 for each call|16 bytes|
|40|user_handle (zero for query)|u64|
|48|carrier_id (zero for query)|16 bytes|
|64|expected_record_version (zero for query)|u32|
|68|reserved (=0)|u32|
|72|response_version (=1)|u32|
|76|response_size (=120)|u32|
|80|response_operation|u32|
|84|valid_marker (=0x41545431)|u32|
|88|response_id|16 bytes|
|104|accepted (0 or1)|u32|
|108|refusal_class (0..7)|u32|
|112|capabilities (=1: classified ATTEST v1)|u32|
|116|supported_record_version (=2)|u32|

Request builders zero all bytes then populate inputs. Output range72..120
must be zero on input, preventing accidental response reuse. Kernel checks
actual length exactly120, declared size120, magic/global version, command,
transport_version, operation, reserved, nonzero identity and zero outputs.
Query additionally requires zero handle/carrier/record inputs.
Unknown schema, malformed framing or unsupported operation returns transport
failure without a valid approval. Fully processed responses initialize every
byte and echo unchanged inputs plus the response fields above.

Query returns accepted0/class0 (no carrier decision), capability1 and record2.
ATTEST returns accepted1/class0 only for the existing accepted provenance
result; every existing semantic refusal returns accepted0/class1..7 with
STATUS_SUCCESS transport. Incompatible record version is class7. Unexpected
internal status/class combinations fail transport without valid approval.
Legacy op9 retains STATUS_INVALID_HANDLE refusals and historical RED.

## Consumer

Perform query and ATTEST on the same real adapter/device; no capability cache.
Use independent fresh nonzero request identities for each call. Identity is
correlation only, never authorization. Keep expected request separately from
mutable response. Require NTSTATUS exactly0, exact actual/declaration size,
all unchanged input fields, schema/op/identity/marker, capability1/record2,
and recognized output enums. Query must have accepted0/class0; ATTEST must
have (1,0) or (0,1..7). Import accepts only (1,0). Reject untouched, partial,
unknown, contradictory and stale replies. No fallback after E1 refusal and
no reopening HANDLE by name. Query is only required on E1 path; disabled E1
leaves legacy WDDM route unchanged. No global capability state to invalidate.

## Qualification and transitions

Tests exercise actual Rust response builder and C consumer validators,
query separately from ATTEST, all refusal classes, lengths/schema/identity,
reuse, sentinels, contradictions, unknown enums and concurrent independent
calls. Compile ABI assertions for x64 and x86.

Preserve old packages and qualify new Mesa/old .291 first through normal ICD
selection (safe E1 rejection and legacy WDDM). Then activate new KMD once,
qualify old Mesa/new KMD, select new Mesa and qualify final pair. Preserve
signed rollback and independent identity/desktop checks at each transition.
ETW is optional independent evidence; caller response is mandatory. Global
ETW state stays UNKNOWN unless independently resolved; no foreign trace stop.

Full accepted Green A matrix must run anew on final pair, including public
import/export, legacy/E1, all fixtures, lifetime/reuse, pending timeout0 and
controlled COMPLETE/ERROR. P06E1Test absent except controlled cases, restored
and independently checked. No Green B, blocking wait, fault5, end-to-end
SUCCESS_CONTROL or P09. Aggregate remains PARTIAL until complete.

Identity generation uses BCryptGenRandom system-preferred RNG, loaded from
System32, without a DLL-local sequence namespace. RNG failure/all-zero output
refuses before dispatch. Random identities have probabilistic uniqueness,
not an authorization or global uniqueness guarantee. API authority:
https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgenrandom
