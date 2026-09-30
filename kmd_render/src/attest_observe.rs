//! Focal, default-off ETW observation of ATTEST. No functional response channel.
use core::{
    cell::Cell,
    ffi::c_void,
    ptr,
    sync::atomic::{AtomicU64, Ordering},
};
use helios_kmd_logic::attest_observation::{read_status, Event};
use helios_protocol::HeliosEscapeP06ProductionCarrier;
use wdk_sys::GUID;
const PROVIDER: GUID = GUID {
    Data1: 0x7b8bf667,
    Data2: 0x80a2,
    Data3: 0x4e27,
    Data4: [0xbf, 0xf8, 0x8a, 0x67, 0xab, 0x47, 0xc6, 0xac],
};
#[repr(C)]
struct Descriptor {
    id: u16,
    version: u8,
    channel: u8,
    level: u8,
    opcode: u8,
    task: u16,
    keyword: u64,
}
#[repr(C)]
struct Data {
    pointer: u64,
    size: u32,
    reserved: u32,
}
const DESC: Descriptor = Descriptor {
    id: 1,
    version: 1,
    channel: 0,
    level: 4,
    opcode: 0,
    task: 0,
    keyword: 1,
};
const _: () = assert!(core::mem::size_of::<Descriptor>() == 16);
const _: () = assert!(core::mem::size_of::<Data>() == 16);
type Enable =
    unsafe extern "system" fn(*const GUID, u32, u8, u64, u64, *const c_void, *const c_void);
extern "system" {
    fn EtwRegister(
        provider: *const GUID,
        callback: Option<Enable>,
        context: *const c_void,
        handle: *mut u64,
    ) -> i32;
    fn EtwUnregister(handle: u64) -> i32;
    fn EtwEventEnabled(handle: u64, descriptor: *const Descriptor) -> u8;
    fn EtwWrite(
        handle: u64,
        descriptor: *const Descriptor,
        activity: *const GUID,
        count: u32,
        data: *const Data,
    ) -> i32;
    fn PsGetCurrentProcessId() -> *mut c_void;
    fn PsGetCurrentThreadId() -> *mut c_void;
}
static HANDLE: AtomicU64 = AtomicU64::new(0);
static INSTANCE: AtomicU64 = AtomicU64::new(0);
static FREQUENCY: AtomicU64 = AtomicU64::new(0);
static CALL: AtomicU64 = AtomicU64::new(1);
static SEQUENCE: AtomicU64 = AtomicU64::new(1);
static FAILURES: AtomicU64 = AtomicU64::new(0);
static EPOCH: AtomicU64 = AtomicU64::new(0);
unsafe extern "system" fn enabled(
    _source: *const GUID,
    control: u32,
    _level: u8,
    _any: u64,
    _all: u64,
    _filter: *const c_void,
    _context: *const c_void,
) {
    if control == 1 {
        EPOCH.fetch_add(1, Ordering::Relaxed);
    }
}
fn clock() -> u64 {
    // SAFETY: performance counter accepts a null optional frequency pointer.
    unsafe { wdk_sys::ntddk::KeQueryPerformanceCounter(ptr::null_mut()).QuadPart as u64 }
}
pub(crate) fn initialize() {
    // SAFETY: DriverEntry executes at PASSIVE; local frequency output is valid.
    let (instance, frequency) = unsafe {
        let mut f = core::mem::zeroed();
        let q = wdk_sys::ntddk::KeQueryPerformanceCounter(&mut f);
        (q.QuadPart as u64, f.QuadPart as u64)
    };
    INSTANCE.store(instance, Ordering::Relaxed);
    FREQUENCY.store(frequency, Ordering::Relaxed);
    let mut handle = 0;
    // SAFETY: GUID is static, callback is resident and uses only atomics; no context pointer.
    let status = unsafe { EtwRegister(&PROVIDER, Some(enabled), ptr::null(), &mut handle) };
    if status >= 0 {
        HANDLE.store(handle, Ordering::Release);
    }
    // Registration failure leaves observation off and does not change driver initialization.
}
pub(crate) fn shutdown() {
    let h = HANDLE.swap(0, Ordering::AcqRel);
    if h != 0 {
        // SAFETY: initialization failure or driver unload at PASSIVE, DDIs are quiescent.
        let _ = unsafe { EtwUnregister(h) };
    }
}
pub(crate) struct Call {
    instance: u64,
    call: u64,
    pid: u32,
    tid: u32,
    version: u32,
    handle: u64,
    id: [u8; 16],
    epoch: u64,
    branch: Cell<u32>,
    local: Cell<u32>,
    registration: u64,
}
pub(crate) fn begin(buf: &[u8]) -> Option<Call> {
    let h = HANDLE.load(Ordering::Acquire);
    // SAFETY: registration stays alive until quiescent unload; descriptor is static POD.
    if h == 0 || unsafe { EtwEventEnabled(h, &DESC) } == 0 {
        return None;
    }
    if buf.len() < core::mem::size_of::<HeliosEscapeP06ProductionCarrier>() {
        return None;
    }
    let r: HeliosEscapeP06ProductionCarrier = bytemuck::pod_read_unaligned(
        &buf[..core::mem::size_of::<HeliosEscapeP06ProductionCarrier>()],
    );
    if r.op != helios_protocol::HELIOS_P06_PRODUCTION_ATTEST_HANDLE {
        return None;
    }
    // SAFETY: these APIs return scalar caller PID/TID, not object addresses.
    let (pid, tid) = unsafe {
        (
            PsGetCurrentProcessId() as usize as u32,
            PsGetCurrentThreadId() as usize as u32,
        )
    };
    let call = Call {
        instance: INSTANCE.load(Ordering::Relaxed),
        call: CALL.fetch_add(1, Ordering::Relaxed),
        pid,
        tid,
        version: r.expected_record_version,
        handle: r.user_handle,
        id: r.carrier_id,
        epoch: EPOCH.load(Ordering::Relaxed),
        branch: Cell::new(0),
        local: Cell::new(r.status),
        registration: h,
    };
    call.phase(1, r.status, Some(buf), 0);
    Some(call)
}
impl Call {
    pub(crate) fn classified(&self, branch: u32, local: u32, status: i32) {
        self.branch.set(branch);
        self.phase(2, local, None, status);
    }
    pub(crate) fn local(&self) -> u32 {
        self.local.get()
    }
    pub(crate) fn phase(&self, phase: u32, local: u32, buffer: Option<&[u8]>, status: i32) {
        self.local.set(local);
        let event = Event {
            instance: self.instance,
            call: self.call,
            qpc: clock(),
            sequence: SEQUENCE.fetch_add(1, Ordering::Relaxed),
            pid: self.pid,
            tid: self.tid,
            phase,
            branch: self.branch.get(),
            version: self.version,
            handle: self.handle,
            id: self.id,
            local,
            buffer: buffer.and_then(read_status),
            external: status as u32,
            failures: FAILURES.load(Ordering::Relaxed),
            epoch: self.epoch,
            frequency: FREQUENCY.load(Ordering::Relaxed),
        }
        .encode();
        let data = Data {
            pointer: event.as_ptr() as u64,
            size: event.len() as u32,
            reserved: 0,
        };
        // SAFETY: the bounded stack payload and descriptor live through synchronous EtwWrite;
        // no pointer is serialized. ETW consumes these bytes before this function returns.
        let status = unsafe { EtwWrite(self.registration, &DESC, ptr::null(), 1, &data) };
        if status < 0 {
            FAILURES.fetch_add(1, Ordering::Relaxed);
        }
    }
}
