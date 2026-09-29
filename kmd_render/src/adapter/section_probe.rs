//! Diagnostic-only P06 section carrier lease.
//!
//! This is an adapter-lifetime bounded table, intentionally independent of
//! device/context teardown. It creates no submit association and has no path
//! from normal semaphore import, wait, or retirement code.

use core::ptr;
use core::sync::atomic::{AtomicU32, AtomicU64, Ordering};

use helios_kmd_logic::section_carrier::{self, Slot, State};
use helios_protocol::{
    HeliosP06SectionRecord, HELIOS_P06_SECTION_MAGIC, HELIOS_P06_SECTION_VERSION,
};
use wdk_sys::ntddk::{KeSetEvent, KeWaitForSingleObject};
use wdk_sys::{HANDLE, NTSTATUS, PVOID};

use super::AdapterContext;

pub(crate) const MAX_SLOTS: usize = section_carrier::MAX_PROBES;
const OBJ_CASE_INSENSITIVE: u32 = 0x40;
const OBJ_KERNEL_HANDLE: u32 = 0x200;
const PAGE_READWRITE: u32 = 0x04;
const SEC_COMMIT: u32 = 0x0800_0000;
const SECTION_ALL_ACCESS: u32 = 0x000F_001F;
const SECTION_MAP_READ: u32 = 0x0004;
const SECTION_QUERY: u32 = 0x0001;
const SECTION_READ_ACCESS: u32 = SECTION_MAP_READ | SECTION_QUERY;
const ACL_REVISION: u32 = 2;
const SECURITY_DESCRIPTOR_REVISION: u32 = 1;
const KERNEL_MODE: i8 = 0;
const SECTION_SYSTEM_SID: [u8; 12] = [1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0];
// TOKEN_INFORMATION_CLASS::TokenUser from ntifs.h / WDK.
const TOKEN_USER_INFORMATION_CLASS: i32 = 1;
const SID_AND_ATTRIBUTES_MAX: usize = 68;

static NEXT_PROBE_ID: AtomicU32 = AtomicU32::new(1);
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn diagnostic_result(status: NTSTATUS) -> u32 {
    use helios_protocol::*;
    if status >= 0 {
        HELIOS_P06_SECTION_STATUS_SUCCESS
    } else if status == wdk_sys::STATUS_NOT_FOUND {
        HELIOS_P06_SECTION_STATUS_NOT_FOUND
    } else if status == wdk_sys::STATUS_REVISION_MISMATCH {
        HELIOS_P06_SECTION_STATUS_STALE_GENERATION
    } else if status == wdk_sys::STATUS_INVALID_DEVICE_STATE {
        HELIOS_P06_SECTION_STATUS_INVALID_STATE
    } else {
        HELIOS_P06_SECTION_STATUS_FAILURE
    }
}

#[derive(Clone, Copy)]
pub(crate) struct SectionSlot {
    logic: Slot,
    object: usize,
    system_view: usize,
    name: [u16; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
    size: usize,
}

impl SectionSlot {
    pub(crate) const EMPTY: Self = Self {
        logic: Slot::EMPTY,
        object: 0,
        system_view: 0,
        name: [0; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
        size: 0,
    };
}

struct SubjectContextGuard(*mut wdk_sys::SECURITY_SUBJECT_CONTEXT);

impl Drop for SubjectContextGuard {
    fn drop(&mut self) {
        // SAFETY: SeCaptureSubjectContext initialized this context, and this
        // guard releases the captured token references exactly once.
        unsafe { wdk_sys::ntddk::SeReleaseSubjectContext(self.0) };
    }
}

struct TokenInformationGuard(PVOID);

impl Drop for TokenInformationGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: SeQueryInformationToken returns a pool allocation owned
            // by the caller, released once after the SID has been copied.
            unsafe { wdk_sys::ntddk::ExFreePool(self.0) };
        }
    }
}

fn capture_requestor_sid(storage: &mut [u64; 9]) -> Result<usize, (u64, NTSTATUS)> {
    let mut subject: wdk_sys::SECURITY_SUBJECT_CONTEXT = unsafe { core::mem::zeroed() };
    // SAFETY: PASSIVE_LEVEL DxgkDdiEscape caller; the context is stack-resident
    // and released by SubjectContextGuard on every exit.
    unsafe { wdk_sys::ntddk::SeCaptureSubjectContext(&mut subject) };
    let _subject_guard = SubjectContextGuard(&mut subject);
    // WDK's SeQuerySubjectContextToken macro selects the impersonation token
    // when present, otherwise the primary token. The typed binding exposes the
    // struct fields used by that documented macro expansion.
    let token = if !subject.ClientToken.is_null() {
        subject.ClientToken
    } else {
        subject.PrimaryToken
    };
    if token.is_null() {
        return Err((5, wdk_sys::STATUS_INVALID_HANDLE));
    }
    let mut token_user = ptr::null_mut();
    let status = unsafe {
        wdk_sys::ntddk::SeQueryInformationToken(
            token,
            TOKEN_USER_INFORMATION_CLASS,
            &mut token_user,
        )
    };
    if status < 0 {
        if !token_user.is_null() {
            unsafe { wdk_sys::ntddk::ExFreePool(token_user) };
        }
        return Err((6, status));
    }
    if token_user.is_null() {
        return Err((6, wdk_sys::STATUS_INVALID_ADDRESS));
    }
    let _token_user_guard = TokenInformationGuard(token_user);
    let sid = unsafe { (*(token_user as *const wdk_sys::TOKEN_USER)).User.Sid };
    if sid.is_null() || unsafe { wdk_sys::ntddk::RtlValidSid(sid) } == 0 {
        return Err((7, wdk_sys::STATUS_INVALID_PARAMETER));
    }
    let sid_len = unsafe { wdk_sys::ntddk::RtlLengthSid(sid) } as usize;
    if sid_len == 0 || sid_len > SID_AND_ATTRIBUTES_MAX || sid_len > core::mem::size_of_val(storage)
    {
        return Err((7, wdk_sys::STATUS_BUFFER_TOO_SMALL));
    }
    let status =
        unsafe { wdk_sys::ntddk::RtlCopySid(sid_len as u32, storage.as_mut_ptr() as PVOID, sid) };
    if status < 0 {
        return Err((7, status));
    }
    Ok(sid_len)
}

fn with_slots<R>(
    adapter: &AdapterContext,
    f: impl FnOnce(&mut [SectionSlot; MAX_SLOTS]) -> R,
) -> Result<R, NTSTATUS> {
    // SAFETY: DxgkDdiEscape calls this only at PASSIVE. The adapter-owned
    // synchronization event serializes the table while allowing page faults
    // and Object Manager work without raising IRQL.
    let wait_status = unsafe {
        KeWaitForSingleObject(
            adapter.p06_section_mutex.get() as PVOID,
            0,
            0,
            0,
            ptr::null_mut(),
        )
    };
    if wait_status < 0 {
        // PASSIVE wait failure means no table access is safe.
        return Err(wait_status);
    }
    struct ReleaseMutex<'a>(&'a AdapterContext);
    impl Drop for ReleaseMutex<'_> {
        fn drop(&mut self) {
            // SAFETY: this guard is constructed only after the adapter mutex
            // has been acquired, and runs on the same PASSIVE caller.
            unsafe { KeSetEvent(self.0.p06_section_mutex.get(), 0, 0) };
        }
    }
    let _release = ReleaseMutex(adapter);
    Ok(f(unsafe { &mut *adapter.p06_section_slots.get() }))
}

fn next_nonwrapping_id() -> Option<u32> {
    NEXT_PROBE_ID
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
        .ok()
        .filter(|id| *id != 0)
}

fn next_nonwrapping_generation() -> Option<u64> {
    NEXT_GENERATION
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |generation| {
            generation.checked_add(1)
        })
        .ok()
        .filter(|generation| *generation != 0)
}

fn slot_status(error: section_carrier::SlotError) -> NTSTATUS {
    match error {
        section_carrier::SlotError::Full | section_carrier::SlotError::GenerationExhausted => {
            wdk_sys::STATUS_INSUFFICIENT_RESOURCES
        }
        section_carrier::SlotError::InvalidId => wdk_sys::STATUS_NOT_FOUND,
        section_carrier::SlotError::StaleGeneration => wdk_sys::STATUS_REVISION_MISMATCH,
        section_carrier::SlotError::InvalidState => wdk_sys::STATUS_INVALID_DEVICE_STATE,
        section_carrier::SlotError::NonMonotonicSequence => wdk_sys::STATUS_INVALID_PARAMETER,
    }
}

fn discard_creating(
    adapter: &AdapterContext,
    index: usize,
    lease: section_carrier::Lease,
    cause: NTSTATUS,
) -> NTSTATUS {
    match with_slots(adapter, |slots| {
        if slots
            .get(index)
            .is_some_and(|slot| slot.logic.state == State::Creating)
        {
            section_carrier::fail_create_slot(&mut slots[index].logic, lease)
                .map_err(slot_status)?;
            slots[index].object = 0;
            slots[index].system_view = 0;
            slots[index].name = [0; helios_protocol::HELIOS_P06_SECTION_NAME_CAP];
            slots[index].size = 0;
            Ok(true)
        } else {
            Ok(false)
        }
    }) {
        Ok(Ok(true)) => cause,
        Ok(Ok(false)) => {
            unsafe { crate::diag::record_named_bytes(b"P06Cln", cause as u32) };
            wdk_sys::STATUS_INVALID_DEVICE_STATE
        }
        Ok(Err(cleanup_status)) | Err(cleanup_status) => {
            unsafe { crate::diag::record_named_bytes(b"P06Cln", cleanup_status as u32) };
            cleanup_status
        }
    }
}

fn create_security_descriptor(
    sd: &mut wdk_sys::SECURITY_DESCRIPTOR,
    acl_storage: &mut [u64; 32],
    requestor_sid: PVOID,
) -> NTSTATUS {
    // The owner is LocalSystem. The DACL grants full section access to
    // SYSTEM and only query/read-map/read-control to the captured caller SID.
    if requestor_sid.is_null() || unsafe { wdk_sys::ntddk::RtlValidSid(requestor_sid) } == 0 {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let sid_len = unsafe { wdk_sys::ntddk::RtlLengthSid(requestor_sid) } as usize;
    let system_ace_size = 8 + SECTION_SYSTEM_SID.len();
    let requestor_ace_size = 8 + sid_len;
    let acl_len = 8usize
        .checked_add(system_ace_size)
        .and_then(|n| n.checked_add(requestor_ace_size));
    let Some(acl_len) = acl_len.filter(|n| *n <= core::mem::size_of_val(acl_storage)) else {
        return wdk_sys::STATUS_BUFFER_TOO_SMALL;
    };
    // Let the generated WDK PACL signature determine the opaque pointer type;
    // ACL storage is byte-addressed and aligned by the u64 backing array.
    let acl = acl_storage.as_mut_ptr() as *mut _;
    let mut status = unsafe { wdk_sys::ntddk::RtlCreateAcl(acl, acl_len as u32, ACL_REVISION) };
    if status < 0 {
        return status;
    }
    status = unsafe {
        wdk_sys::ntddk::RtlAddAccessAllowedAce(
            acl,
            ACL_REVISION,
            SECTION_ALL_ACCESS,
            SECTION_SYSTEM_SID.as_ptr() as PVOID,
        )
    };
    if status < 0 {
        return status;
    }
    status = unsafe {
        wdk_sys::ntddk::RtlAddAccessAllowedAce(
            acl,
            ACL_REVISION,
            SECTION_READ_ACCESS,
            requestor_sid,
        )
    };
    if status < 0 {
        return status;
    }
    status = unsafe {
        wdk_sys::ntddk::RtlCreateSecurityDescriptor(
            sd as *mut _ as PVOID,
            SECURITY_DESCRIPTOR_REVISION,
        )
    };
    if status < 0 {
        return status;
    }
    status = unsafe {
        wdk_sys::ntddk::RtlSetOwnerSecurityDescriptor(
            sd as *mut _ as PVOID,
            SECTION_SYSTEM_SID.as_ptr() as PVOID,
            0,
        )
    };
    if status < 0 {
        return status;
    }
    unsafe { wdk_sys::ntddk::RtlSetDaclSecurityDescriptor(sd as *mut _ as PVOID, 1, acl, 0) }
}

fn create_backing_section(
    native_name: &[u16],
    requestor_sid: PVOID,
) -> Result<(PVOID, PVOID), (u64, NTSTATUS)> {
    let Some(native_len) = native_name.iter().position(|unit| *unit == 0) else {
        return Err((1, wdk_sys::STATUS_BUFFER_TOO_SMALL));
    };
    if native_len == 0 {
        return Err((1, wdk_sys::STATUS_BUFFER_TOO_SMALL));
    }
    let mut unicode: wdk_sys::UNICODE_STRING = unsafe { core::mem::zeroed() };
    unsafe { wdk_sys::ntddk::RtlInitUnicodeString(&mut unicode, native_name.as_ptr()) };
    let mut attributes: wdk_sys::OBJECT_ATTRIBUTES = unsafe { core::mem::zeroed() };
    attributes.Length = core::mem::size_of::<wdk_sys::OBJECT_ATTRIBUTES>() as u32;
    attributes.ObjectName = &mut unicode;
    attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE;
    let mut sd: wdk_sys::SECURITY_DESCRIPTOR = unsafe { core::mem::zeroed() };
    let mut acl = [0u64; 32];
    let status = create_security_descriptor(&mut sd, &mut acl, requestor_sid);
    if status < 0 {
        return Err((1, status));
    }
    attributes.SecurityDescriptor = &mut sd as *mut _ as PVOID;
    let mut maximum_size: wdk_sys::LARGE_INTEGER = unsafe { core::mem::zeroed() };
    maximum_size.QuadPart = 4096;
    let mut handle: HANDLE = ptr::null_mut();
    let status = unsafe {
        wdk_sys::ntddk::ZwCreateSection(
            &mut handle,
            SECTION_MAP_READ | SECTION_QUERY,
            &mut attributes,
            &mut maximum_size,
            PAGE_READWRITE,
            SEC_COMMIT,
            ptr::null_mut(),
        )
    };
    if status < 0 {
        if !handle.is_null() {
            let close_status = unsafe { wdk_sys::ntddk::ZwClose(handle) };
            if close_status < 0 {
                unsafe { crate::diag::record_named_bytes(b"P06Hnd", close_status as u32) };
                return Err((2, close_status));
            }
        }
        return Err((2, status));
    }
    let mut object: PVOID = ptr::null_mut();
    let status = unsafe {
        wdk_sys::ntddk::ObReferenceObjectByHandle(
            handle,
            SECTION_MAP_READ | SECTION_QUERY,
            ptr::null_mut(),
            KERNEL_MODE,
            &mut object,
            ptr::null_mut(),
        )
    };
    let close_status = unsafe { wdk_sys::ntddk::ZwClose(handle) };
    if close_status < 0 {
        unsafe { crate::diag::record_named_bytes(b"P06Hnd", close_status as u32) };
        if !object.is_null() {
            unsafe { wdk_sys::ntddk::ObfDereferenceObject(object) };
        }
        return Err((3, close_status));
    }
    if status < 0 || object.is_null() {
        // A successful reference should always return an object pointer; if a
        // malformed kernel response supplied one with failure, release it.
        if !object.is_null() {
            unsafe { wdk_sys::ntddk::ObfDereferenceObject(object) };
        }
        return Err((
            3,
            if status < 0 {
                status
            } else {
                wdk_sys::STATUS_INVALID_HANDLE
            },
        ));
    }
    let mut base: PVOID = ptr::null_mut();
    let mut view_size = 4096u64;
    let status =
        unsafe { wdk_sys::ntddk::MmMapViewInSystemSpace(object, &mut base, &mut view_size) };
    if status < 0
        || base.is_null()
        || view_size < core::mem::size_of::<HeliosP06SectionRecord>() as u64
    {
        let mut retain_object_reference = false;
        if !base.is_null() {
            let unmap_status = unsafe { wdk_sys::ntddk::MmUnmapViewInSystemSpace(base) };
            if unmap_status < 0 {
                unsafe { crate::diag::record_named_bytes(b"P06Unm", unmap_status as u32) };
                retain_object_reference = true;
            }
        }
        if !retain_object_reference {
            unsafe { wdk_sys::ntddk::ObfDereferenceObject(object) };
        }
        return Err((
            4,
            if status < 0 {
                status
            } else if base.is_null() {
                wdk_sys::STATUS_INVALID_ADDRESS
            } else {
                wdk_sys::STATUS_BUFFER_TOO_SMALL
            },
        ));
    }
    // The kernel handle itself is never returned. The name is the temporary
    // user-mode bootstrap; the retained object reference keeps the named
    // section alive until RELEASE even after ZwClose.
    Ok((object, base))
}

fn record_at(view: usize) -> *mut HeliosP06SectionRecord {
    view as *mut HeliosP06SectionRecord
}

fn write_record(view: usize, probe_id: u32, generation: u64, sequence: u64, value: u64) {
    let record = record_at(view);
    // SAFETY: the slot owns a mapped 4096-byte section view; the record is
    // aligned at its base and never crosses the mapped page.
    unsafe {
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).sequence),
            sequence.saturating_mul(2).saturating_sub(1),
        );
        core::sync::atomic::fence(Ordering::SeqCst);
        ptr::write_volatile(ptr::addr_of_mut!((*record).magic), HELIOS_P06_SECTION_MAGIC);
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).version),
            HELIOS_P06_SECTION_VERSION,
        );
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).size),
            core::mem::size_of::<HeliosP06SectionRecord>() as u32,
        );
        ptr::write_volatile(ptr::addr_of_mut!((*record).probe_id), probe_id);
        ptr::write_volatile(ptr::addr_of_mut!((*record).generation), generation);
        ptr::write_volatile(ptr::addr_of_mut!((*record).test_value), value);
        core::sync::atomic::fence(Ordering::SeqCst);
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).sequence),
            sequence.saturating_mul(2),
        );
    }
}

pub(crate) fn escape(
    adapter: &AdapterContext,
    buf: &mut [u8],
    hdr: &helios_protocol::HeliosEscapeHeader,
) -> NTSTATUS {
    use helios_protocol::*;
    let mut wire =
        match crate::ddi::escape::EscapeBuf::<HeliosEscapeP06SectionCarrier>::new(buf, hdr) {
            Ok(wire) => wire,
            Err(status) => return status,
        };
    let mut request = wire.read();
    let status = match request.op {
        HELIOS_P06_SECTION_CREATE => create(adapter, &mut request),
        HELIOS_P06_SECTION_PUBLISH => publish(adapter, &request),
        HELIOS_P06_SECTION_RELEASE => release(adapter, &request),
        HELIOS_P06_SECTION_QUERY => query(adapter, &mut request),
        _ => wdk_sys::STATUS_INVALID_PARAMETER,
    };
    request.reserved = diagnostic_result(status);
    wire.write_back(&request);
    crate::diag::record_named_bytes(b"P06SSt", status as u32);
    status
}

fn create(
    adapter: &AdapterContext,
    request: &mut helios_protocol::HeliosEscapeP06SectionCarrier,
) -> NTSTATUS {
    let Some(probe_id) = next_nonwrapping_id() else {
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let Some(generation) = next_nonwrapping_generation() else {
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let Some(names) = section_carrier::section_names::make::<
        { helios_protocol::HELIOS_P06_SECTION_NAME_CAP },
    >(probe_id, generation)
    else {
        return wdk_sys::STATUS_BUFFER_TOO_SMALL;
    };
    request.object_name = names.win32_name;
    let name_len = names.win32_name_len;
    let reserved = match with_slots(adapter, |slots| {
        let Some(index) = slots
            .iter()
            .position(|slot| slot.logic.state == State::Free)
        else {
            return None;
        };
        let lease = section_carrier::Lease {
            index,
            probe_id,
            generation,
        };
        if let Err(error) = section_carrier::start_create(&mut slots[index].logic, lease) {
            return Some(Err(error));
        }
        request.slot_index = index as u32;
        Some(Ok(index))
    }) {
        Ok(reserved) => reserved,
        Err(status) => return status,
    };
    let Some(index) = reserved else {
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let index = match index {
        Ok(index) => index,
        Err(error) => return slot_status(error),
    };
    let lease = section_carrier::Lease {
        index,
        probe_id,
        generation,
    };
    let mut requestor_sid = [0u64; 9];
    if let Err((stage, status)) = capture_requestor_sid(&mut requestor_sid) {
        request.sequence = stage;
        return discard_creating(adapter, index, lease, status);
    }
    let (object, view) = match create_backing_section(
        &names.native_name,
        requestor_sid.as_mut_ptr() as PVOID,
    ) {
        Ok(pair) => pair,
        Err((stage, status)) => {
            request.sequence = stage;
            return discard_creating(adapter, index, lease, status);
        }
    };
    write_record(view as usize, probe_id, generation, 0, request.test_value);
    let committed = with_slots(adapter, |slots| {
        let slot = &mut slots[index];
        section_carrier::acquire_live_slot(&mut slot.logic, lease).map_err(slot_status)?;
        slot.object = object as usize;
        slot.system_view = view as usize;
        slot.name = request.object_name;
        slot.size = 4096;
        Ok(())
    });
    let commit_status = match committed {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) | Err(status) => status,
    };
    if commit_status < 0 {
        let unmap_status = unsafe { wdk_sys::ntddk::MmUnmapViewInSystemSpace(view) };
        if unmap_status < 0 {
            unsafe { crate::diag::record_named_bytes(b"P06Unm", unmap_status as u32) };
        } else {
            unsafe { wdk_sys::ntddk::ObfDereferenceObject(object) };
        }
        return discard_creating(adapter, index, lease, commit_status);
    }
    request.probe_id = probe_id;
    request.generation = generation;
    request.sequence = 5;
    request.test_value = 4096;
    wdk_sys::STATUS_SUCCESS
}

fn publish(
    adapter: &AdapterContext,
    request: &helios_protocol::HeliosEscapeP06SectionCarrier,
) -> NTSTATUS {
    let result = with_slots(adapter, |slots| {
        let index = request.slot_index as usize;
        let Some(slot) = slots.get(index) else {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        };
        if slot.logic.state == State::Free {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        if slot.logic.generation != request.generation {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
        }
        if slot.logic.probe_id != request.probe_id {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        let lease = section_carrier::Lease {
            index,
            probe_id: request.probe_id,
            generation: request.generation,
        };
        section_carrier::publish_slot(
            &mut slots[index].logic,
            lease,
            request.sequence,
            request.test_value,
        )
        .map_err(slot_status)?;
        write_record(
            slots[index].system_view,
            request.probe_id,
            request.generation,
            request.sequence,
            request.test_value,
        );
        Ok(())
    });
    match result {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) => status,
        Err(status) => status,
    }
}

fn query(
    adapter: &AdapterContext,
    request: &mut helios_protocol::HeliosEscapeP06SectionCarrier,
) -> NTSTATUS {
    match with_slots(adapter, |slots| {
        let index = request.slot_index as usize;
        let Some(slot) = slots.get(index) else {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        };
        if slot.logic.state == State::Free {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        if slot.logic.generation != request.generation {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
        }
        if slot.logic.probe_id != request.probe_id {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        let lease = section_carrier::Lease {
            index,
            probe_id: request.probe_id,
            generation: request.generation,
        };
        let state = section_carrier::query_slot(&slots[index].logic, lease).map_err(slot_status)?;
        request.sequence = state.sequence;
        request.test_value = slots[index].size as u64;
        request.object_name = slots[index].name;
        Ok(())
    }) {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) => status,
        Err(status) => status,
    }
}

fn release(
    adapter: &AdapterContext,
    request: &helios_protocol::HeliosEscapeP06SectionCarrier,
) -> NTSTATUS {
    match with_slots(adapter, |slots| {
        let index = request.slot_index as usize;
        let Some(slot) = slots.get(index) else {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        };
        if slot.logic.state == State::Free {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        if slot.logic.generation != request.generation {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
        }
        if slot.logic.probe_id != request.probe_id {
            return Err(wdk_sys::STATUS_NOT_FOUND);
        }
        let lease = section_carrier::Lease {
            index,
            probe_id: request.probe_id,
            generation: request.generation,
        };
        section_carrier::begin_release_slot(&mut slots[index].logic, lease).map_err(slot_status)?;
        let unmap_status =
            unsafe { wdk_sys::ntddk::MmUnmapViewInSystemSpace(slots[index].system_view as PVOID) };
        if unmap_status < 0 {
            if let Err(error) = section_carrier::restore_live_slot(&mut slots[index].logic, lease) {
                unsafe { crate::diag::record_named_bytes(b"P06Rel", slot_status(error) as u32) };
            }
            return Err(unmap_status);
        }
        unsafe { wdk_sys::ntddk::ObfDereferenceObject(slots[index].object as PVOID) };
        section_carrier::finish_release_slot(&mut slots[index].logic, lease)
            .map_err(slot_status)?;
        slots[index] = SectionSlot::EMPTY;
        Ok(())
    }) {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) => status,
        Err(status) => status,
    }
}

pub(crate) unsafe fn release_all(adapter: &AdapterContext) {
    let removed = match with_slots(adapter, |slots| {
        let old = *slots;
        *slots = [SectionSlot::EMPTY; MAX_SLOTS];
        old
    }) {
        Ok(removed) => removed,
        Err(status) => {
            unsafe { crate::diag::record_named_bytes(b"P06Cln", status as u32) };
            return;
        }
    };
    for slot in removed {
        if slot.logic.state == State::Live || slot.logic.state == State::Releasing {
            let status =
                unsafe { wdk_sys::ntddk::MmUnmapViewInSystemSpace(slot.system_view as PVOID) };
            if status < 0 {
                // Preserve the reference if a failed unmap may leave the view.
                unsafe { crate::diag::record_named_bytes(b"P06Unm", status as u32) };
            } else {
                unsafe { wdk_sys::ntddk::ObfDereferenceObject(slot.object as PVOID) };
            }
        }
    }
}
