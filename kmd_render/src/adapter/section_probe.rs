//! P06 section carrier leases: frozen diagnostic v1 and explicit production v2.
//!
//! This is an adapter-lifetime bounded table, intentionally independent of
//! device/context teardown. It creates no submit association and has no path
//! from normal semaphore import, wait, or retirement code.

use bytemuck::Zeroable;
use core::ptr;
use core::sync::atomic::{AtomicU32, AtomicU64, Ordering};

use helios_kmd_logic::production_carrier::ProductionState;
use helios_kmd_logic::section_carrier::{self, BackingResources, Slot, State};
use helios_protocol::{
    HeliosP06ProductionSectionRecord, HeliosP06SectionRecord,
    HELIOS_P06_PRODUCTION_SECTION_VERSION, HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED,
    HELIOS_P06_SECTION_MAGIC, HELIOS_P06_SECTION_VERSION,
};
use wdk_sys::ntddk::{KeSetEvent, KeWaitForSingleObject};
use wdk_sys::{HANDLE, NTSTATUS, PVOID};

use super::section_attest;

use super::AdapterContext;

pub(crate) const MAX_SLOTS: usize = section_carrier::MAX_PROBES;
const MAX_PRODUCTION_EVENTS: usize = 16;
const MAX_ORPHAN_RESERVATIONS: usize = MAX_SLOTS * 2;
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
const SECTION_AUTHENTICATED_USERS_SID: [u8; 12] = [1, 1, 0, 0, 0, 0, 0, 5, 11, 0, 0, 0];
const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 2;
const SE_DACL_PROTECTED: u16 = 0x1000;
const PRODUCTION_NAME_ATTEMPTS: usize = 3;

extern "system" {
    fn BCryptGenRandom(algorithm: PVOID, buffer: *mut u8, len: u32, flags: u32) -> NTSTATUS;
}

fn random_carrier_id() -> Result<[u8; 16], NTSTATUS> {
    let mut id = [0u8; 16];
    // SAFETY: DxgkDdiEscape calls CREATE at PASSIVE_LEVEL; the system RNG
    // writes exactly 16 bytes to this stack buffer and needs no provider handle.
    let status = unsafe {
        BCryptGenRandom(
            ptr::null_mut(),
            id.as_mut_ptr(),
            id.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status < 0 {
        return Err(status);
    }
    if id.iter().all(|byte| *byte == 0) {
        return Err(wdk_sys::STATUS_INVALID_PARAMETER);
    }
    Ok(id)
}
// TOKEN_INFORMATION_CLASS::TokenUser from ntifs.h / WDK.
const TOKEN_USER_INFORMATION_CLASS: i32 = 1;
const SID_AND_ATTRIBUTES_MAX: usize = 68;

static NEXT_PROBE_ID: AtomicU32 = AtomicU32::new(1);
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);
#[derive(Clone, Copy)]
struct OrphanEntry {
    reserved: bool,
    resources: BackingResources,
}

struct OrphanRegistry {
    lock: AtomicU32,
    entries: core::cell::UnsafeCell<[OrphanEntry; MAX_ORPHAN_RESERVATIONS]>,
}

// SAFETY: access to entries is serialized by lock; lock holders only copy or
// update fixed-size values and never invoke WDK or Object Manager routines.
unsafe impl Sync for OrphanRegistry {}

static ORPHAN_REGISTRY: OrphanRegistry = OrphanRegistry {
    lock: AtomicU32::new(0),
    entries: core::cell::UnsafeCell::new(
        [OrphanEntry {
            reserved: false,
            resources: BackingResources::EMPTY,
        }; MAX_ORPHAN_RESERVATIONS],
    ),
};

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
    record_version: u32,
    production_id: [u8; 16],
    production: ProductionState,
    production_events: [usize; MAX_PRODUCTION_EVENTS],
    name: [u16; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
    native_name: [u16; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
    size: usize,
    orphan_reservation: usize,
}

impl SectionSlot {
    pub(crate) const EMPTY: Self = Self {
        logic: Slot::EMPTY,
        record_version: 0,
        production_id: [0; 16],
        production: ProductionState::EMPTY,
        production_events: [0; MAX_PRODUCTION_EVENTS],
        name: [0; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
        native_name: [0; helios_protocol::HELIOS_P06_SECTION_NAME_CAP],
        size: 0,
        orphan_reservation: usize::MAX,
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

pub(super) fn with_slots<R>(
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
        section_carrier::SlotError::ResourcesIncomplete
        | section_carrier::SlotError::ResourcesRemain => wdk_sys::STATUS_INVALID_DEVICE_STATE,
    }
}

struct OrphanLock;

impl OrphanLock {
    fn acquire() -> Self {
        // This lock is used only from PASSIVE_LEVEL escape/teardown paths and
        // protects a fixed-size copy/update; no WDK call is made while held.
        while ORPHAN_REGISTRY
            .lock
            .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            core::hint::spin_loop();
        }
        Self
    }
}

impl Drop for OrphanLock {
    fn drop(&mut self) {
        ORPHAN_REGISTRY.lock.store(0, Ordering::Release);
    }
}

fn reserve_orphan_slot() -> Option<usize> {
    let _guard = OrphanLock::acquire();
    // SAFETY: the registry lock provides exclusive access to this fixed table.
    let entries = unsafe { &mut *ORPHAN_REGISTRY.entries.get() };
    let index = entries.iter().position(|entry| !entry.reserved)?;
    entries[index] = OrphanEntry {
        reserved: true,
        resources: BackingResources::EMPTY,
    };
    Some(index)
}

fn store_orphan(index: usize, resources: BackingResources) {
    let _guard = OrphanLock::acquire();
    // SAFETY: the registry lock provides exclusive access to this fixed table.
    let entries = unsafe { &mut *ORPHAN_REGISTRY.entries.get() };
    if let Some(entry) = entries.get_mut(index).filter(|entry| entry.reserved) {
        entry.resources = resources;
    }
}

fn free_orphan_reservation(index: usize) {
    if index == usize::MAX {
        return;
    }
    let _guard = OrphanLock::acquire();
    // SAFETY: the registry lock provides exclusive access to this fixed table.
    let entries = unsafe { &mut *ORPHAN_REGISTRY.entries.get() };
    if let Some(entry) = entries.get_mut(index) {
        *entry = OrphanEntry {
            reserved: false,
            resources: BackingResources::EMPTY,
        };
    }
}

fn cleanup_backing_resources(resources: &mut BackingResources) -> NTSTATUS {
    if resources.system_view != 0 {
        // SAFETY: the lease owns this exact system-space view until unmap succeeds.
        let status =
            unsafe { wdk_sys::ntddk::MmUnmapViewInSystemSpace(resources.system_view as PVOID) };
        if status < 0 {
            return status;
        }
        resources.system_view = 0;
    }
    if resources.kernel_handle != 0 {
        // SAFETY: the lease owns this kernel handle until ZwClose succeeds.
        let status = unsafe { wdk_sys::ntddk::ZwClose(resources.kernel_handle as HANDLE) };
        if status < 0 {
            return status;
        }
        resources.kernel_handle = 0;
    }
    if resources.object != 0 {
        // SAFETY: the object reference was acquired for this lease and is
        // dereferenced only after its owned view and kernel handle are gone.
        unsafe { wdk_sys::ntddk::ObfDereferenceObject(resources.object as PVOID) };
        resources.object = 0;
    }
    wdk_sys::STATUS_SUCCESS
}

fn retry_orphans() {
    for index in 0..MAX_ORPHAN_RESERVATIONS {
        let resources = {
            let _guard = OrphanLock::acquire();
            // SAFETY: the registry lock provides exclusive access to this table.
            let entries = unsafe { &mut *ORPHAN_REGISTRY.entries.get() };
            let Some(entry) = entries.get_mut(index) else {
                continue;
            };
            if !entry.reserved || entry.resources.is_empty() {
                continue;
            }
            let resources = entry.resources;
            entry.resources = BackingResources::EMPTY;
            resources
        };
        let mut remaining = resources;
        let status = cleanup_backing_resources(&mut remaining);
        if status < 0 {
            store_orphan(index, remaining);
            unsafe { crate::diag::record_named_bytes(b"P06Orp", status as u32) };
        } else {
            free_orphan_reservation(index);
        }
    }
}

fn discard_creating(
    adapter: &AdapterContext,
    index: usize,
    lease: section_carrier::Lease,
    cause: NTSTATUS,
    request: &mut helios_protocol::HeliosEscapeP06SectionCarrier,
) -> NTSTATUS {
    match with_slots(adapter, |slots| {
        let Some(slot) = slots.get_mut(index) else {
            return Ok(false);
        };
        if slot.logic.state != State::Creating && slot.logic.state != State::Releasing {
            return Ok(false);
        }
        request.lease_flags = if slot.logic.resources.kernel_handle != 0 {
            helios_protocol::HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED
        } else {
            0
        };
        let cleanup_status = cleanup_backing_resources(&mut slot.logic.resources);
        request.lease_flags = if slot.logic.resources.kernel_handle != 0 {
            helios_protocol::HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED
        } else {
            0
        };
        if cleanup_status < 0 {
            if slot.logic.state == State::Creating {
                let resources = slot.logic.resources;
                section_carrier::retain_failed_create_slot(&mut slot.logic, lease, resources)
                    .map_err(slot_status)?;
            }
            unsafe { crate::diag::record_named_bytes(b"P06Cln", cleanup_status as u32) };
            return Ok(false);
        }
        if slot.logic.state == State::Creating {
            section_carrier::fail_create_slot(&mut slot.logic, lease).map_err(slot_status)?;
        } else {
            section_carrier::finish_release_slot(&mut slot.logic, lease).map_err(slot_status)?;
        }
        let reservation = slot.orphan_reservation;
        *slot = SectionSlot::EMPTY;
        free_orphan_reservation(reservation);
        Ok(true)
    }) {
        Ok(Ok(true)) => cause,
        Ok(Ok(false)) => {
            unsafe { crate::diag::record_named_bytes(b"P06Cln", cause as u32) };
            cause
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
    production: bool,
) -> NTSTATUS {
    // The owner is LocalSystem. The DACL grants full section access to
    // SYSTEM and only query/read-map/read-control to the captured caller SID.
    let reader_sid = if production {
        SECTION_AUTHENTICATED_USERS_SID.as_ptr() as PVOID
    } else {
        requestor_sid
    };
    if reader_sid.is_null() || unsafe { wdk_sys::ntddk::RtlValidSid(reader_sid) } == 0 {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let sid_len = unsafe { wdk_sys::ntddk::RtlLengthSid(reader_sid) } as usize;
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
        wdk_sys::ntddk::RtlAddAccessAllowedAce(acl, ACL_REVISION, SECTION_READ_ACCESS, reader_sid)
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
    status =
        unsafe { wdk_sys::ntddk::RtlSetDaclSecurityDescriptor(sd as *mut _ as PVOID, 1, acl, 0) };
    if status < 0 {
        return status;
    }
    if production {
        // SECURITY_DESCRIPTOR.Control is a documented WDK field. The kernel
        // RtlSetControlSecurityDescriptor has no supported kernel import lib;
        // set only the documented SE_DACL_PROTECTED bit on this newly built
        // absolute descriptor before ZwCreateSection receives it.
        sd.Control |= SE_DACL_PROTECTED;
    }
    wdk_sys::STATUS_SUCCESS
}

fn create_backing_section(
    native_name: &[u16],
    requestor_sid: PVOID,
    production: bool,
) -> Result<BackingResources, (u64, NTSTATUS, BackingResources)> {
    let Some(native_len) = native_name.iter().position(|unit| *unit == 0) else {
        return Err((1, wdk_sys::STATUS_BUFFER_TOO_SMALL, BackingResources::EMPTY));
    };
    if native_len == 0 {
        return Err((1, wdk_sys::STATUS_BUFFER_TOO_SMALL, BackingResources::EMPTY));
    }
    let mut unicode: wdk_sys::UNICODE_STRING = unsafe { core::mem::zeroed() };
    unsafe { wdk_sys::ntddk::RtlInitUnicodeString(&mut unicode, native_name.as_ptr()) };
    let mut attributes: wdk_sys::OBJECT_ATTRIBUTES = unsafe { core::mem::zeroed() };
    attributes.Length = core::mem::size_of::<wdk_sys::OBJECT_ATTRIBUTES>() as u32;
    attributes.ObjectName = &mut unicode;
    attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE;
    let mut sd: wdk_sys::SECURITY_DESCRIPTOR = unsafe { core::mem::zeroed() };
    let mut acl = [0u64; 32];
    let status = create_security_descriptor(&mut sd, &mut acl, requestor_sid, production);
    if status < 0 {
        return Err((1, status, BackingResources::EMPTY));
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
        return Err((
            2,
            status,
            BackingResources {
                kernel_handle: handle as usize,
                ..BackingResources::EMPTY
            },
        ));
    }
    let mut resources = BackingResources {
        kernel_handle: handle as usize,
        ..BackingResources::EMPTY
    };
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
    resources.object = object as usize;
    if status < 0 || object.is_null() {
        return Err((
            3,
            if status < 0 {
                status
            } else {
                wdk_sys::STATUS_INVALID_HANDLE
            },
            resources,
        ));
    }
    let mut base: PVOID = ptr::null_mut();
    let mut view_size = 4096u64;
    let status =
        unsafe { wdk_sys::ntddk::MmMapViewInSystemSpace(object, &mut base, &mut view_size) };
    if status < 0
        || base.is_null()
        || view_size < core::mem::size_of::<HeliosP06ProductionSectionRecord>() as u64
    {
        resources.system_view = base as usize;
        return Err((
            4,
            if status < 0 {
                status
            } else if base.is_null() {
                wdk_sys::STATUS_INVALID_ADDRESS
            } else {
                wdk_sys::STATUS_BUFFER_TOO_SMALL
            },
            resources,
        ));
    }
    resources.system_view = base as usize;
    Ok(resources)
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

pub(super) fn write_production_record(
    view: usize,
    carrier_id: [u8; 16],
    sequence: u64,
    state: ProductionState,
) {
    let record = view as *mut HeliosP06ProductionSectionRecord;
    // SAFETY: the live slot owns an aligned system mapping of a full page;
    // callers serialize all v2 writes under the adapter section mutex. An odd
    // sequence excludes readers until the complete record is published.
    unsafe {
        if sequence != 0 {
            ptr::write_volatile(ptr::addr_of_mut!((*record).sequence), sequence * 2 - 1);
            core::sync::atomic::fence(Ordering::SeqCst);
        }
        ptr::write_volatile(ptr::addr_of_mut!((*record).magic), HELIOS_P06_SECTION_MAGIC);
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).version),
            HELIOS_P06_PRODUCTION_SECTION_VERSION,
        );
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).size),
            core::mem::size_of::<HeliosP06ProductionSectionRecord>() as u32,
        );
        ptr::write_volatile(ptr::addr_of_mut!((*record).carrier_id), carrier_id);
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).completed_value),
            state.completed_value,
        );
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).terminal_error_value),
            state.terminal_error_value,
        );
        ptr::write_volatile(
            ptr::addr_of_mut!((*record).terminal_response_type),
            state.terminal_response_type,
        );
        ptr::write_volatile(ptr::addr_of_mut!((*record).reserved_tail), 0);
        core::sync::atomic::fence(Ordering::SeqCst);
        ptr::write_volatile(ptr::addr_of_mut!((*record).sequence), sequence * 2);
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
        HELIOS_P06_SECTION_CREATE => {
            let initial_value = request.test_value;
            create(
                adapter,
                &mut request,
                HELIOS_P06_SECTION_VERSION,
                initial_value,
                None,
            )
        }
        HELIOS_P06_SECTION_PUBLISH => publish(adapter, &request),
        HELIOS_P06_SECTION_RELEASE => release(adapter, &request, HELIOS_P06_SECTION_VERSION),
        HELIOS_P06_SECTION_QUERY => query(adapter, &mut request),
        _ => wdk_sys::STATUS_INVALID_PARAMETER,
    };
    request.reserved = diagnostic_result(status);
    wire.write_back(&request);
    crate::diag::record_named_bytes(b"P06SSt", status as u32);
    status
}

pub(crate) fn escape_production(
    adapter: &AdapterContext,
    buf: &mut [u8],
    hdr: &helios_protocol::HeliosEscapeHeader,
) -> NTSTATUS {
    use helios_protocol::*;
    let mut wire =
        match crate::ddi::escape::EscapeBuf::<HeliosEscapeP06ProductionCarrier>::new(buf, hdr) {
            Ok(wire) => wire,
            Err(status) => return status,
        };
    let mut request = wire.read();
    let status = match request.op {
        HELIOS_P06_PRODUCTION_CREATE => {
            let mut diagnostic = HeliosEscapeP06SectionCarrier::zeroed();
            diagnostic.hdr = request.hdr;
            diagnostic.op = HELIOS_P06_SECTION_CREATE;
            let mut status = wdk_sys::STATUS_OBJECT_NAME_COLLISION;
            let mut id = [0u8; 16];
            for _ in 0..PRODUCTION_NAME_ATTEMPTS {
                id = match random_carrier_id() {
                    Ok(id) => id,
                    Err(error) => {
                        status = error;
                        break;
                    }
                };
                status = create(
                    adapter,
                    &mut diagnostic,
                    HELIOS_P06_PRODUCTION_SECTION_VERSION,
                    request.value,
                    Some(id),
                );
                if status != wdk_sys::STATUS_OBJECT_NAME_COLLISION {
                    break;
                }
            }
            if status >= 0 {
                request.carrier_id = id;
            }
            request.generation = diagnostic.generation;
            request.slot_index = diagnostic.slot_index;
            request.lease_flags = diagnostic.lease_flags;
            request.object_name = diagnostic.object_name;
            request.native_name = diagnostic.native_name;
            status
        }
        HELIOS_P06_PRODUCTION_PUBLISH_SUCCESS | HELIOS_P06_PRODUCTION_PUBLISH_ERROR => {
            production_publish(adapter, &request)
        }
        HELIOS_P06_PRODUCTION_ATTEST_HANDLE => section_attest::attest(&mut request),
        HELIOS_P06_PRODUCTION_VALIDATE => wdk_sys::STATUS_NOT_SUPPORTED,
        HELIOS_P06_PRODUCTION_RELEASE => {
            let mut diagnostic = HeliosEscapeP06SectionCarrier::zeroed();
            let probe_id = match with_slots(adapter, |slots| {
                production_slot(slots, &request).map(|slot| slot.logic.probe_id)
            }) {
                Ok(Ok(id)) => id,
                Ok(Err(error)) | Err(error) => {
                    request.status = diagnostic_result(error);
                    wire.write_back(&request);
                    return error;
                }
            };
            diagnostic.probe_id = probe_id;
            diagnostic.generation = request.generation;
            diagnostic.slot_index = request.slot_index;
            release(adapter, &diagnostic, HELIOS_P06_PRODUCTION_SECTION_VERSION)
        }
        HELIOS_P06_PRODUCTION_QUERY => production_query(adapter, &mut request),
        HELIOS_P06_PRODUCTION_REGISTER_EVENT | HELIOS_P06_PRODUCTION_UNREGISTER_EVENT => {
            production_event(adapter, &request)
        }
        _ => wdk_sys::STATUS_INVALID_PARAMETER,
    };
    if request.op != HELIOS_P06_PRODUCTION_ATTEST_HANDLE {
        request.status = diagnostic_result(status);
    }
    wire.write_back(&request);
    status
}

fn production_slot<'a>(
    slots: &'a mut [SectionSlot; MAX_SLOTS],
    request: &helios_protocol::HeliosEscapeP06ProductionCarrier,
) -> Result<&'a mut SectionSlot, NTSTATUS> {
    let Some(slot) = slots.get_mut(request.slot_index as usize) else {
        return Err(wdk_sys::STATUS_NOT_FOUND);
    };
    if slot.logic.state != State::Live {
        return Err(wdk_sys::STATUS_NOT_FOUND);
    }
    if slot.logic.generation != request.generation {
        return Err(wdk_sys::STATUS_REVISION_MISMATCH);
    }
    if slot.production_id != request.carrier_id || request.carrier_id.iter().all(|byte| *byte == 0)
    {
        return Err(wdk_sys::STATUS_NOT_FOUND);
    }
    if slot.record_version != helios_protocol::HELIOS_P06_PRODUCTION_SECTION_VERSION {
        return Err(wdk_sys::STATUS_REVISION_MISMATCH);
    }
    Ok(slot)
}

fn production_publish(
    adapter: &AdapterContext,
    request: &helios_protocol::HeliosEscapeP06ProductionCarrier,
) -> NTSTATUS {
    if crate::diag::read_config_dword(crate::diag::knobs::P06_E1_TEST, 0) != 1 {
        return wdk_sys::STATUS_ACCESS_DENIED;
    }
    match with_slots(adapter, |slots| {
        let slot = production_slot(slots, request)?;
        if slot.logic.sequence >= (u64::MAX - 1) / 2 {
            return Err(wdk_sys::STATUS_INTEGER_OVERFLOW);
        }
        let mut next = slot.production;
        if request.op == helios_protocol::HELIOS_P06_PRODUCTION_PUBLISH_SUCCESS {
            if request.response_type != 0 {
                return Err(wdk_sys::STATUS_INVALID_PARAMETER);
            }
            next.publish_success(request.value);
        } else {
            if request.response_type != 0x1200 {
                return Err(wdk_sys::STATUS_INVALID_PARAMETER);
            }
            next.publish_error(request.value, request.response_type)
                .map_err(|_| wdk_sys::STATUS_INVALID_PARAMETER)?;
        }
        slot.logic.sequence += 1;
        write_production_record(
            slot.logic.resources.system_view,
            slot.production_id,
            slot.logic.sequence,
            next,
        );
        slot.production = next;
        for &event in slot.production_events.iter() {
            if event != 0 {
                // SAFETY: registration owns an event-object reference and
                // this PASSIVE writer holds the section table mutex.
                unsafe { KeSetEvent(event as *mut wdk_sys::KEVENT, 0, 0) };
            }
        }
        Ok(())
    }) {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) | Err(status) => status,
    }
}

fn production_event(
    adapter: &AdapterContext,
    request: &helios_protocol::HeliosEscapeP06ProductionCarrier,
) -> NTSTATUS {
    let Some(event) = crate::ddi::escape::reference_user_event(request.user_handle) else {
        return wdk_sys::STATUS_INVALID_HANDLE;
    };
    let result = with_slots(adapter, |slots| {
        let slot = production_slot(slots, request)?;
        if request.op == helios_protocol::HELIOS_P06_PRODUCTION_REGISTER_EVENT {
            if slot
                .production_events
                .iter()
                .any(|&entry| entry == event.as_ptr() as usize)
            {
                return Err(wdk_sys::STATUS_OBJECT_NAME_COLLISION);
            }
            let Some(empty) = slot.production_events.iter_mut().find(|entry| **entry == 0) else {
                return Err(wdk_sys::STATUS_INSUFFICIENT_RESOURCES);
            };
            *empty = event.as_ptr() as usize;
            Ok(true)
        } else {
            let Some(entry) = slot
                .production_events
                .iter_mut()
                .find(|entry| **entry == event.as_ptr() as usize)
            else {
                return Err(wdk_sys::STATUS_NOT_FOUND);
            };
            *entry = 0;
            Ok(false)
        }
    });
    let registered = matches!(result, Ok(Ok(true)));
    if !registered {
        // Drop the lookup reference; on UNREGISTER also drop the table's
        // reference after it has been removed under the section mutex.
        crate::ddi::escape::dereference_user_event(event);
        if matches!(result, Ok(Ok(false))) {
            crate::ddi::escape::dereference_user_event(event);
        }
    }
    match result {
        Ok(Ok(_)) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) | Err(status) => status,
    }
}

fn release_production_events(slot: &mut SectionSlot) {
    for entry in slot.production_events.iter_mut() {
        if let Some(event) = core::ptr::NonNull::new(*entry as *mut wdk_sys::KEVENT) {
            crate::ddi::escape::dereference_user_event(event);
            *entry = 0;
        }
    }
}

fn production_query(
    adapter: &AdapterContext,
    request: &mut helios_protocol::HeliosEscapeP06ProductionCarrier,
) -> NTSTATUS {
    match with_slots(adapter, |slots| {
        let slot = production_slot(slots, request)?;
        request.object_name = slot.name;
        request.native_name = slot.native_name;
        request.lease_flags = if slot.logic.resources.kernel_handle != 0 {
            helios_protocol::HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED
        } else {
            0
        };
        Ok(())
    }) {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) | Err(status) => status,
    }
}

fn create(
    adapter: &AdapterContext,
    request: &mut helios_protocol::HeliosEscapeP06SectionCarrier,
    record_version: u32,
    initial_value: u64,
    production_id: Option<[u8; 16]>,
) -> NTSTATUS {
    retry_orphans();
    let Some(probe_id) = next_nonwrapping_id() else {
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let Some(generation) = next_nonwrapping_generation() else {
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let names = match production_id {
        Some(id) => helios_kmd_logic::section_names::make_production::<
            { helios_protocol::HELIOS_P06_SECTION_NAME_CAP },
        >(&id),
        None => helios_kmd_logic::section_names::make::<
            { helios_protocol::HELIOS_P06_SECTION_NAME_CAP },
        >(probe_id, generation),
    };
    let Some(names) = names else {
        return wdk_sys::STATUS_BUFFER_TOO_SMALL;
    };
    request.object_name = names.win32_name;
    request.native_name = names.native_name;
    request.lease_flags = 0;
    request.probe_id = probe_id;
    request.generation = generation;
    let orphan_reservation = match reserve_orphan_slot() {
        Some(reservation) => reservation,
        None => return wdk_sys::STATUS_INSUFFICIENT_RESOURCES,
    };
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
        slots[index].name = names.win32_name;
        slots[index].native_name = names.native_name;
        slots[index].record_version = record_version;
        slots[index].production_id = production_id.unwrap_or([0; 16]);
        slots[index].size = 4096;
        slots[index].orphan_reservation = orphan_reservation;
        Some(Ok(index))
    }) {
        Ok(reserved) => reserved,
        Err(status) => {
            free_orphan_reservation(orphan_reservation);
            return status;
        }
    };
    let Some(index) = reserved else {
        free_orphan_reservation(orphan_reservation);
        return wdk_sys::STATUS_INSUFFICIENT_RESOURCES;
    };
    let index = match index {
        Ok(index) => index,
        Err(error) => {
            free_orphan_reservation(orphan_reservation);
            return slot_status(error);
        }
    };
    let lease = section_carrier::Lease {
        index,
        probe_id,
        generation,
    };
    let mut requestor_sid = [0u64; 9];
    if production_id.is_none() {
        if let Err((stage, status)) = capture_requestor_sid(&mut requestor_sid) {
            request.sequence = stage;
            return discard_creating(adapter, index, lease, status, request);
        }
    }
    let resources = match create_backing_section(
        &names.native_name,
        requestor_sid.as_mut_ptr() as PVOID,
        production_id.is_some(),
    ) {
        Ok(resources) => resources,
        Err((stage, status, resources)) => {
            request.sequence = stage;
            request.lease_flags = if resources.kernel_handle != 0 {
                HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED
            } else {
                0
            };
            let _ = with_slots(adapter, |slots| {
                slots[index].logic.resources = resources;
            });
            return discard_creating(adapter, index, lease, status, request);
        }
    };
    let view = resources.system_view as PVOID;
    if record_version == HELIOS_P06_PRODUCTION_SECTION_VERSION {
        write_production_record(
            view as usize,
            production_id.unwrap_or([0; 16]),
            0,
            ProductionState {
                completed_value: initial_value,
                ..ProductionState::EMPTY
            },
        );
    } else {
        write_record(view as usize, probe_id, generation, 0, initial_value);
    }
    let committed = with_slots(adapter, |slots| {
        let slot = &mut slots[index];
        slot.logic.resources = resources;
        if record_version == HELIOS_P06_PRODUCTION_SECTION_VERSION {
            slot.production.completed_value = initial_value;
        }
        section_carrier::acquire_live_slot(&mut slot.logic, lease).map_err(slot_status)?;
        Ok(())
    });
    let commit_status = match committed {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) | Err(status) => status,
    };
    if commit_status < 0 {
        let _ = with_slots(adapter, |slots| slots[index].logic.resources = resources);
        return discard_creating(adapter, index, lease, commit_status, request);
    }
    request.lease_flags = HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED;
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
        if slot.record_version != HELIOS_P06_SECTION_VERSION {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
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
            slots[index].logic.resources.system_view,
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
        if slot.record_version != HELIOS_P06_SECTION_VERSION {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
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
        request.native_name = slots[index].native_name;
        request.lease_flags = if slots[index].logic.resources.kernel_handle != 0 {
            HELIOS_P06_SECTION_LEASE_KERNEL_HANDLE_RETAINED
        } else {
            0
        };
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
    record_version: u32,
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
        if slot.record_version != record_version {
            return Err(wdk_sys::STATUS_REVISION_MISMATCH);
        }
        let lease = section_carrier::Lease {
            index,
            probe_id: request.probe_id,
            generation: request.generation,
        };
        section_carrier::begin_release_slot(&mut slots[index].logic, lease).map_err(slot_status)?;
        release_production_events(&mut slots[index]);
        let cleanup_status = cleanup_backing_resources(&mut slots[index].logic.resources);
        if cleanup_status < 0 {
            unsafe { crate::diag::record_named_bytes(b"P06Rel", cleanup_status as u32) };
            return Err(cleanup_status);
        }
        section_carrier::finish_release_slot(&mut slots[index].logic, lease)
            .map_err(slot_status)?;
        let reservation = slots[index].orphan_reservation;
        slots[index] = SectionSlot::EMPTY;
        free_orphan_reservation(reservation);
        Ok(())
    }) {
        Ok(Ok(())) => wdk_sys::STATUS_SUCCESS,
        Ok(Err(status)) => status,
        Err(status) => status,
    }
}

pub(crate) unsafe fn release_all(adapter: &AdapterContext) {
    let status = with_slots(adapter, |slots| {
        for slot in slots.iter_mut() {
            if slot.logic.state == State::Free {
                continue;
            }
            release_production_events(slot);
            let cleanup_status = cleanup_backing_resources(&mut slot.logic.resources);
            if cleanup_status < 0 {
                store_orphan(slot.orphan_reservation, slot.logic.resources);
                unsafe { crate::diag::record_named_bytes(b"P06Cln", cleanup_status as u32) };
            } else {
                free_orphan_reservation(slot.orphan_reservation);
            }
            *slot = SectionSlot::EMPTY;
        }
    });
    if let Err(status) = status {
        unsafe { crate::diag::record_named_bytes(b"P06Cln", status as u32) };
    }
}

/// Classified transport shares the exact legacy provenance decision and RAII.
/// Only a fully classified result changes transport status; op9 is untouched.
pub(crate) fn escape_attest_transport(
    buf: &mut [u8], hdr: &helios_protocol::HeliosEscapeHeader,
) -> NTSTATUS {
    use helios_protocol::attest_transport::{AttestTransport, ATTEST};
    let actual = buf.len();
    let mut wire = match crate::ddi::escape::EscapeBuf::<AttestTransport>::new(buf, hdr) {
        Ok(wire) => wire, Err(status) => return status,
    };
    let request = wire.read();
    if !request.valid_request(actual) {
        crate::ddi::escape::ESCAPE_BAD_HEADER.fetch_add(1, core::sync::atomic::Ordering::Relaxed);
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let mut class = 0;
    if request.operation == ATTEST {
        let mut decision = helios_protocol::HeliosEscapeP06ProductionCarrier::zeroed();
        decision.op = helios_protocol::HELIOS_P06_PRODUCTION_ATTEST_HANDLE;
        decision.user_handle = request.user_handle;
        decision.carrier_id = request.carrier_id;
        decision.expected_record_version = request.expected_record_version;
        decision.status = u32::MAX;
        let status = section_attest::attest(&mut decision);
        class = decision.status;
        if !((status == wdk_sys::STATUS_SUCCESS && class == 0)
            || (status == wdk_sys::STATUS_INVALID_HANDLE && (1..=7).contains(&class))) {
            return wdk_sys::STATUS_UNSUCCESSFUL;
        }
    }
    match request.complete(class) {
        Some(response) => { wire.write_back(&response); wdk_sys::STATUS_SUCCESS }
        None => wdk_sys::STATUS_UNSUCCESSFUL,
    }
}
