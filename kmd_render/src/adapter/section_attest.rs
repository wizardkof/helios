//! One-shot provenance check of the caller's current Section HANDLE. No slot
//! lookup, producer lease, mapping, or retained publication reference.

use core::{ptr, slice};
use helios_kmd_logic::production_carrier_provenance::{
    self as policy, Ace, AceType, Metadata, ObjectKind, Refusal,
};
use helios_protocol::*;
use wdk_sys::{HANDLE, NTSTATUS, PVOID};

const USER_MODE: i8 = 1;
const KERNEL_MODE: i8 = 0;
const OBJ_KERNEL_HANDLE: u32 = 0x200;
const OBJECT_TYPE_INFORMATION: i32 = 2;
const SE_DACL_PROTECTED: u16 = 0x1000;

#[repr(C)]
struct PublicObjectTypeInformation {
    type_name: wdk_sys::UNICODE_STRING,
    reserved: [u32; 22],
}
const _: () = assert!(core::mem::size_of::<PublicObjectTypeInformation>() == 104);

extern "system" {
    fn ObOpenObjectByPointer(
        object: PVOID,
        attributes: u32,
        access_state: PVOID,
        desired_access: u32,
        object_type: PVOID,
        access_mode: i8,
        out_handle: *mut HANDLE,
    ) -> NTSTATUS;
    fn ZwQueryObject(
        handle: HANDLE,
        information_class: i32,
        information: PVOID,
        information_len: u32,
        return_len: *mut u32,
    ) -> NTSTATUS;
    fn ObQueryNameString(
        object: PVOID,
        information: PVOID,
        information_len: u32,
        return_len: *mut u32,
    ) -> NTSTATUS;
    fn ObGetObjectSecurity(object: PVOID, security: *mut PVOID, allocated: *mut u8) -> NTSTATUS;
    fn ObReleaseObjectSecurity(security: PVOID, allocated: u8);
    fn RtlGetOwnerSecurityDescriptor(
        security: PVOID,
        owner: *mut PVOID,
        defaulted: *mut u8,
    ) -> NTSTATUS;
    fn RtlGetDaclSecurityDescriptor(
        security: PVOID,
        present: *mut u8,
        dacl: *mut PVOID,
        defaulted: *mut u8,
    ) -> NTSTATUS;
    fn RtlGetAce(acl: PVOID, index: u32, ace: *mut PVOID) -> NTSTATUS;
}

struct ObjectRef(PVOID);
impl Drop for ObjectRef {
    fn drop(&mut self) {
        // SAFETY: constructed only after one successful ObReferenceObjectByHandle.
        unsafe { wdk_sys::ntddk::ObDereferenceObjectDeferDelete(self.0) };
    }
}

struct KernelHandle(HANDLE);
impl Drop for KernelHandle {
    fn drop(&mut self) {
        // SAFETY: constructed only after successful ObOpenObjectByPointer.
        let status = unsafe { wdk_sys::ntddk::ZwClose(self.0) };
        if status < 0 {
            crate::diag::record_named_bytes(b"P06AtCl", status as u32);
        }
    }
}

struct ObjectSecurity {
    descriptor: PVOID,
    allocated: u8,
}
impl Drop for ObjectSecurity {
    fn drop(&mut self) {
        // SAFETY: ObGetObjectSecurity supplied this exact descriptor/flag pair.
        unsafe { ObReleaseObjectSecurity(self.descriptor, self.allocated) };
    }
}

fn classified(request: &mut HeliosEscapeP06ProductionCarrier, code: u32) -> NTSTATUS {
    request.status = code;
    wdk_sys::STATUS_INVALID_HANDLE
}

fn name_in_buffer<'a>(buffer: &'a [u64; 64]) -> Option<&'a [u16]> {
    // Both PUBLIC_OBJECT_TYPE_INFORMATION and OBJECT_NAME_INFORMATION begin
    // with UNICODE_STRING. The queried name must lie wholly in our buffer.
    // SAFETY: the aligned query buffer begins with UNICODE_STRING in both
    // documented query result structures.
    let name = unsafe { &*(buffer.as_ptr() as *const wdk_sys::UNICODE_STRING) };
    if name.Buffer.is_null() || name.Length == 0 || name.Length % 2 != 0 {
        return None;
    }
    let start = name.Buffer as usize;
    let base = buffer.as_ptr() as usize;
    let end = start.checked_add(name.Length as usize)?;
    if start < base || end > base + core::mem::size_of_val(buffer) {
        return None;
    }
    // SAFETY: the checked UTF-16 slice is entirely within the initialized
    // query buffer and lives no longer than that buffer.
    Some(unsafe { slice::from_raw_parts(name.Buffer as *const u16, name.Length as usize / 2) })
}

fn sid_bytes<'a>(sid: PVOID) -> Option<&'a [u8]> {
    // SAFETY: SID pointers come from the held Object Manager descriptor or
    // a validated ACE; RtlValidSid rejects malformed SID headers.
    if sid.is_null() || unsafe { wdk_sys::ntddk::RtlValidSid(sid) } == 0 {
        return None;
    }
    // SAFETY: RtlValidSid accepted this SID pointer.
    let len = unsafe { wdk_sys::ntddk::RtlLengthSid(sid) } as usize;
    if len < 12 || len > 68 {
        return None;
    }
    // SAFETY: RtlValidSid checked the SID supplied by the Object Manager;
    // caller keeps its security descriptor reference through policy use.
    Some(unsafe { slice::from_raw_parts(sid as *const u8, len) })
}

fn security_metadata<'a>(security: PVOID) -> Option<(&'a [u8], [Ace<'a>; 2], bool)> {
    let mut owner: PVOID = ptr::null_mut();
    let mut defaulted = 0u8;
    // SAFETY: security is held by ObjectSecurity; output pointers are valid.
    if unsafe { RtlGetOwnerSecurityDescriptor(security, &mut owner, &mut defaulted) } < 0 {
        return None;
    }
    let owner = sid_bytes(owner)?;
    let mut present = 0u8;
    let mut dacl: PVOID = ptr::null_mut();
    // SAFETY: security is held by ObjectSecurity; output pointers are valid.
    if unsafe { RtlGetDaclSecurityDescriptor(security, &mut present, &mut dacl, &mut defaulted) }
        < 0
        || present == 0
        || dacl.is_null()
    {
        return None;
    }
    let acl = dacl as *const wdk_sys::ACL;
    // SAFETY: RtlGetDaclSecurityDescriptor supplied an Object Manager ACL.
    if unsafe { (*acl).AceCount } != 2 {
        return None;
    }
    let empty = Ace {
        kind: AceType::Other,
        sid: &[],
        mask: 0,
        flags: 0,
    };
    let mut aces = [empty; 2];
    for (index, output) in aces.iter_mut().enumerate() {
        let mut entry: PVOID = ptr::null_mut();
        // SAFETY: index is below AceCount and RtlGetAce validates the ACL.
        if unsafe { RtlGetAce(dacl, index as u32, &mut entry) } < 0 || entry.is_null() {
            return None;
        }
        let header = entry as *const u8;
        // SAFETY: every ACE begins with a four-byte ACE_HEADER.
        let (kind, flags, size) = unsafe {
            (
                *header,
                *header.add(1),
                ptr::read_unaligned(header.add(2) as *const u16) as usize,
            )
        };
        if size < 20 {
            return None;
        }
        // SAFETY: ACCESS_ALLOWED_ACE has mask at +4 and SID at +8. Other
        // ACE types are classified and refused without dereferencing a SID.
        if kind != 0 {
            return None;
        }
        // SAFETY: an accepted access-allowed ACE has at least 20 bytes, so
        // the four-byte mask and SID start lie within this ACE.
        let mask = unsafe { ptr::read_unaligned(header.add(4) as *const u32) };
        // SAFETY: the checked ACE has at least a 12-byte SID at offset 8.
        let sid_header = unsafe { header.add(8) };
        // SAFETY: a SID's subauthority count is its second byte, within the
        // bounded ACE. Bound the full SID before asking RtlValidSid to read it.
        let count = unsafe { *sid_header.add(1) } as usize;
        if 8usize.checked_add(count.checked_mul(4)?)? > size - 8 {
            return None;
        }
        let sid = sid_bytes(sid_header as PVOID)?;
        if sid.len() > size - 8 {
            return None;
        }
        *output = Ace {
            kind: AceType::Allow,
            sid,
            mask,
            flags,
        };
    }
    let descriptor = security as *const wdk_sys::SECURITY_DESCRIPTOR;
    // SAFETY: a held Object Manager security descriptor has the documented
    // SECURITY_DESCRIPTOR header; only its Control bitmask is read.
    let protected = unsafe { (*descriptor).Control & SE_DACL_PROTECTED != 0 };
    Some((owner, aces, protected))
}

fn refusal_code(refusal: Refusal) -> u32 {
    match refusal {
        Refusal::WrongObjectType => HELIOS_P06_ATTEST_WRONG_OBJECT_TYPE,
        Refusal::WrongName => HELIOS_P06_ATTEST_WRONG_OBJECT_NAME,
        Refusal::CarrierIdMismatch | Refusal::InvalidIdentity | Refusal::WrongRecord => {
            HELIOS_P06_ATTEST_CARRIER_ID_MISMATCH
        }
        Refusal::WrongOwner => HELIOS_P06_ATTEST_WRONG_OWNER,
        Refusal::WrongDacl => HELIOS_P06_ATTEST_WRONG_DACL,
    }
}

pub(super) fn attest(request: &mut HeliosEscapeP06ProductionCarrier) -> NTSTATUS {
    if request.expected_record_version != HELIOS_P06_PRODUCTION_SECTION_VERSION {
        return classified(request, HELIOS_P06_ATTEST_UNSUPPORTED_VERSION);
    }
    if request.user_handle == 0 || request.user_handle > usize::MAX as u64 {
        return classified(request, HELIOS_P06_ATTEST_INVALID_HANDLE);
    }
    let mut object: PVOID = ptr::null_mut();
    // SAFETY: escape runs synchronously in the caller process at PASSIVE;
    // UserMode checks this caller HANDLE for the required Section read right.
    let status = unsafe {
        wdk_sys::ntddk::ObReferenceObjectByHandle(
            request.user_handle as usize as HANDLE,
            policy::READER_ACCESS,
            ptr::null_mut(),
            USER_MODE,
            &mut object,
            ptr::null_mut(),
        )
    };
    if status < 0 || object.is_null() {
        return classified(request, HELIOS_P06_ATTEST_INVALID_HANDLE);
    }
    let object = ObjectRef(object);
    let mut kernel_handle: HANDLE = ptr::null_mut();
    // SAFETY: the referenced object is held; a temporary kernel HANDLE keeps
    // ZwQueryObject tied to this exact object even if caller recycles its HANDLE.
    let status = unsafe {
        ObOpenObjectByPointer(
            object.0,
            OBJ_KERNEL_HANDLE,
            ptr::null_mut(),
            0,
            ptr::null_mut(),
            KERNEL_MODE,
            &mut kernel_handle,
        )
    };
    if status < 0 || kernel_handle.is_null() {
        return classified(request, HELIOS_P06_ATTEST_WRONG_OBJECT_TYPE);
    }
    let kernel_handle = KernelHandle(kernel_handle);
    let mut type_buffer = [0u64; 64];
    let mut returned = 0u32;
    // SAFETY: this kernel HANDLE references object.0; the aligned output
    // buffer exceeds the documented PUBLIC_OBJECT_TYPE_INFORMATION header.
    let status = unsafe {
        ZwQueryObject(
            kernel_handle.0,
            OBJECT_TYPE_INFORMATION,
            type_buffer.as_mut_ptr() as PVOID,
            core::mem::size_of_val(&type_buffer) as u32,
            &mut returned,
        )
    };
    let section_name: [u16; 7] = [83, 101, 99, 116, 105, 111, 110];
    if status < 0 || name_in_buffer(&type_buffer) != Some(section_name.as_slice()) {
        return classified(request, HELIOS_P06_ATTEST_WRONG_OBJECT_TYPE);
    }
    let mut name_buffer = [0u64; 64];
    // SAFETY: object.0 stays referenced; ObQueryNameString writes only within
    // the supplied fixed buffer or returns a failure we reject.
    let status = unsafe {
        ObQueryNameString(
            object.0,
            name_buffer.as_mut_ptr() as PVOID,
            core::mem::size_of_val(&name_buffer) as u32,
            &mut returned,
        )
    };
    if status < 0 {
        return classified(request, HELIOS_P06_ATTEST_WRONG_OBJECT_NAME);
    }
    let Some(name) = name_in_buffer(&name_buffer) else {
        return classified(request, HELIOS_P06_ATTEST_WRONG_OBJECT_NAME);
    };
    let mut descriptor: PVOID = ptr::null_mut();
    let mut allocated = 0u8;
    // SAFETY: object.0 is referenced; the successful pair is released by guard.
    let status = unsafe { ObGetObjectSecurity(object.0, &mut descriptor, &mut allocated) };
    if status < 0 || descriptor.is_null() {
        return classified(request, HELIOS_P06_ATTEST_WRONG_DACL);
    }
    let security = ObjectSecurity {
        descriptor,
        allocated,
    };
    let Some((owner, aces, protected)) = security_metadata(security.descriptor) else {
        return classified(request, HELIOS_P06_ATTEST_WRONG_DACL);
    };
    let metadata = Metadata {
        kind: ObjectKind::Section,
        name_utf16: name,
        owner_sid: owner,
        dacl_present: true,
        dacl: Some(&aces),
        dacl_protected: protected,
    };
    match policy::attest(
        &metadata,
        &request.carrier_id,
        request.expected_record_version,
        &request.carrier_id,
        HELIOS_P06_PRODUCTION_SECTION_VERSION,
    ) {
        Ok(()) => {
            request.status = HELIOS_P06_ATTEST_SUCCESS;
            wdk_sys::STATUS_SUCCESS
        }
        Err(refusal) => classified(request, refusal_code(refusal)),
    }
}
