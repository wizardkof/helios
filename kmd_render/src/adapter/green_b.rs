//! Green B ownership and PASSIVE publication. No test knob gates this path.
//! Lock order: section mutex -> transport lock. DPC uses only immutable batch
//! tokens and atomics; it never takes the section mutex or releases objects.
use super::{section_attest, section_probe, AdapterContext};
use crate::{irql::PassiveLevel, virtio::gpu::DeviceOwner};
use alloc::alloc::{alloc_zeroed, dealloc, Layout};
use core::{
    cell::UnsafeCell,
    ptr,
    sync::atomic::{AtomicU32, AtomicU64, Ordering},
};
use helios_kmd_logic::production_carrier::{Observe, ProductionState};
use helios_protocol::{green_b::*, *};
use wdk_sys::ntddk::{KeSetEvent, MmMapViewInSystemSpace, MmUnmapViewInSystemSpace};
use wdk_sys::{NTSTATUS, PVOID};
const N: usize = MAX_BINDINGS as usize;
const R: usize = MAX_REGISTRATIONS as usize;
const PREPARED: u32 = 1;
const INFLIGHT: u32 = 2;
const READY: u32 = 3;
const CANCEL_RESPONSE: u32 = 0x1200;
static ASSOCIATED: AtomicU64 = AtomicU64::new(0);
static ROLLED_BACK: AtomicU64 = AtomicU64::new(0);
static OUTCOMES: AtomicU64 = AtomicU64::new(0);
static PUBLISHED: AtomicU64 = AtomicU64::new(0);
static WAKES: AtomicU64 = AtomicU64::new(0);
static REFUSALS: AtomicU64 = AtomicU64::new(0);

/// Independently retained, attested Section object and system view. Destruction
/// is exclusively PASSIVE; neither producer lease nor user HANDLE owns it.
struct Section {
    object: section_attest::ObjectRef,
    view: usize,
    id: [u8; 16],
}
impl Section {
    fn acquire(handle: u64, id: [u8; 16]) -> Option<Self> {
        let object = section_attest::reference_attested(handle, id)?;
        let mut view = ptr::null_mut();
        let mut size = 4096u64;
        // SAFETY: exact attested Section reference is held at PASSIVE. The
        // system view is independent of every producer/importer user mapping.
        let status = unsafe { MmMapViewInSystemSpace(object.0, &mut view, &mut size) };
        if status < 0 || view.is_null() {
            return None;
        }
        let result = Self {
            object,
            view: view as usize,
            id,
        };
        if size < 64 || result.snapshot().is_none() {
            None
        } else {
            Some(result)
        }
    }
    fn snapshot(&self) -> Option<(u64, ProductionState)> {
        // SAFETY: owned system mapping has at least 64 bytes. All kernel writers
        // use the adapter section mutex; sequence validation also fails closed
        // against inconsistent diagnostic/foreign bytes.
        let r = unsafe { ptr::read_volatile(self.view as *const HeliosP06ProductionSectionRecord) };
        if r.magic != HELIOS_P06_SECTION_MAGIC
            || r.version != 2
            || r.size != 64
            || r.carrier_id != self.id
            || r.sequence & 1 != 0
            || r.reserved_tail != 0
            || (r.terminal_response_type == 0) != (r.terminal_error_value == 0)
        {
            return None;
        }
        Some((
            r.sequence,
            ProductionState {
                completed_value: r.completed_value,
                terminal_error_value: r.terminal_error_value,
                terminal_response_type: r.terminal_response_type,
            },
        ))
    }
    fn key(&self) -> usize {
        self.object.0 as usize
    }
}
impl Drop for Section {
    fn drop(&mut self) {
        // SAFETY: uniquely owned successful system mapping; only PASSIVE cleanup
        // constructs/drops Section. ObjectRef drops after the view is unmapped.
        let status = unsafe { MmUnmapViewInSystemSpace(self.view as PVOID) };
        if status < 0 {
            crate::diag::record_named_bytes(b"E1BUnmap", status as u32);
        }
    }
}
struct Payload {
    section: Option<Section>,
    target: u64,
}
struct Binding {
    phase: AtomicU64,
    generation: AtomicU64,
    epoch: AtomicU64,
    fence: AtomicU64,
    ctx: AtomicU32,
    response: AtomicU32,
    payload: UnsafeCell<Payload>,
}
impl Binding {
    fn phase(&self) -> u32 {
        self.phase.load(Ordering::Acquire) as u32
    }
    fn set_phase(&self, g: u64, phase: u32) {
        self.phase
            .store((g << 32) | phase as u64, Ordering::Release);
    }
}
struct Registration {
    token: u64,
    owner: usize,
    section: Option<Section>,
    target: u64,
    event: usize,
}
struct Broker {
    bindings: [Binding; N],
    registrations: UnsafeCell<[Registration; R]>,
    next_token: AtomicU64,
    terminal: AtomicU32,
}
// SAFETY: mutable payload/registration access is serialized by section mutex;
// DPC accesses only atomics whose release/acquire edges protect token identity.
unsafe impl Sync for Broker {}

fn broker(adapter: &AdapterContext) -> Option<&Broker> {
    let p = adapter.green_b_broker.load(Ordering::Acquire) as *const Broker;
    if p.is_null() {
        None
    } else {
        // SAFETY: allocated at first QUERY under section mutex, never freed until
        // transport and HPD worker have stopped on final adapter destruction.
        Some(unsafe { &*p })
    }
}
fn ensure(adapter: &AdapterContext) -> Option<&Broker> {
    if broker(adapter).is_none() {
        if adapter.hpd_stop.load(Ordering::Acquire) != 0 {
            return None;
        }
        // SAFETY: all-zero atomic integers, pointers and Option<Section> are
        // initialized explicitly below before publication. Allocation is at
        // PASSIVE from the driver's nonpaged allocator, no large stack value.
        let p = unsafe { alloc_zeroed(Layout::new::<Broker>()) } as *mut Broker;
        if p.is_null() {
            return None;
        }
        // SAFETY: uniquely owned raw allocation; initialize non-zero-valid
        // Option representations in-place without constructing a large Broker.
        unsafe {
            for i in 0..N {
                ptr::addr_of_mut!((*p).bindings[i].payload).write(UnsafeCell::new(Payload {
                    section: None,
                    target: 0,
                }));
            }
            for i in 0..R {
                (ptr::addr_of_mut!((*p).registrations) as *mut Registration)
                    .add(i)
                    .write(Registration {
                        token: 0,
                        owner: 0,
                        section: None,
                        target: 0,
                        event: 0,
                    });
            }
            (*p).next_token.store(1, Ordering::Relaxed);
        }
        adapter.green_b_broker.store(p as usize, Ordering::Release);
    }
    broker(adapter)
}

#[derive(Clone, Copy)]
pub(crate) struct Batch {
    adapter: usize,
    slots: [usize; MAX_TARGETS as usize],
    generations: [u64; MAX_TARGETS as usize],
    len: usize,
}
impl Batch {
    fn entries(&self, f: impl Fn(&Binding, u64)) {
        // SAFETY: adapter owns this transport and encloses every copied Batch;
        // broker persists through transport drop and is never reclaimed in DPC.
        let adapter = unsafe { &*(self.adapter as *const AdapterContext) };
        if let Some(b) = broker(adapter) {
            for i in 0..self.len {
                f(&b.bindings[self.slots[i]], self.generations[i]);
            }
        }
    }
    /// Called under transport lock BEFORE descriptor add can expose GPU work.
    pub(crate) fn associate(self, epoch: u64, fence: u64, ctx: u32) -> bool {
        let mut valid = true;
        // SAFETY: stable adapter and immutable tokens, as in entries().
        let a = unsafe { &*(self.adapter as *const AdapterContext) };
        let Some(b) = broker(a) else {
            return false;
        };
        for i in 0..self.len {
            let e = &b.bindings[self.slots[i]];
            valid &= e.generation.load(Ordering::Acquire) == self.generations[i]
                && e.phase() == PREPARED;
        }
        if !valid || epoch == 0 || fence == 0 || ctx == 0 {
            return false;
        }
        self.entries(|e, _| {
            e.epoch.store(epoch, Ordering::Relaxed);
            e.fence.store(fence, Ordering::Relaxed);
            e.ctx.store(ctx, Ordering::Relaxed);
            e.set_phase(e.generation.load(Ordering::Relaxed), INFLIGHT);
        });
        ASSOCIATED.fetch_add(1, Ordering::Relaxed);
        true
    }
    pub(crate) fn rollback_admission(self) {
        ROLLED_BACK.fetch_add(1, Ordering::Relaxed);
        self.entries(|e, g| {
            if e.generation.load(Ordering::Acquire) == g {
                let _ = e.phase.compare_exchange(
                    (g << 32) | INFLIGHT as u64,
                    (g << 32) | PREPARED as u64,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
            }
        });
    }
    /// Exact fence response only, including fatal transport cancellation.
    pub(crate) fn outcome(self, epoch: u64, fence: u64, ctx: u32, response: u32) {
        self.entries(|e, g| {
            if e.generation.load(Ordering::Acquire) == g
                && e.phase() == INFLIGHT
                && e.epoch.load(Ordering::Relaxed) == epoch
                && e.fence.load(Ordering::Relaxed) == fence
                && e.ctx.load(Ordering::Relaxed) == ctx
            {
                if e.phase
                    .compare_exchange(
                        (g << 32) | INFLIGHT as u64,
                        (g << 32) | 4,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    )
                    .is_ok()
                {
                    e.response.store(response, Ordering::Relaxed);
                    e.set_phase(g, READY);
                    OUTCOMES.fetch_add(1, Ordering::Relaxed);
                }
            }
        });
        // SAFETY: stable initialized adapter wake event, legal from DPC. No
        // Object Manager access, record write or blocking wait occurs here.
        unsafe {
            let a = &*(self.adapter as *const AdapterContext);
            KeSetEvent(a.hpd_event.get(), 0, 0);
        }
    }
}

pub(crate) struct Prepared<'a> {
    adapter: &'a AdapterContext,
    pub(crate) batch: Batch,
    admitted: bool,
}
impl Prepared<'_> {
    pub(crate) fn admit(&mut self) {
        self.admitted = true;
    }
}
impl Drop for Prepared<'_> {
    fn drop(&mut self) {
        if !self.admitted {
            let mut released = false;
            let _ = section_probe::with_slots(self.adapter, |_| {
                if let Some(b) = broker(self.adapter) {
                    for i in 0..self.batch.len {
                        let e = &b.bindings[self.batch.slots[i]];
                        if e.generation.load(Ordering::Acquire) == self.batch.generations[i]
                            && e.phase() == PREPARED
                        {
                            // SAFETY: section mutex; no descriptor was admitted for this token.
                            unsafe {
                                (*e.payload.get()).section.take();
                            }
                            e.phase.store(0, Ordering::Release);
                            released = true;
                        }
                    }
                }
            });
            if released {
                // SAFETY: failure cleanup runs at PASSIVE; adapter owns this
                // initialized event. A ready higher value may have waited on
                // the reservation just removed, so schedule another service.
                unsafe {
                    KeSetEvent(self.adapter.hpd_event.get(), 0, 0);
                }
            }
        }
    }
}
fn prepare<'a>(a: &'a AdapterContext, targets: &[E1Target]) -> Option<Prepared<'a>> {
    let mut prepared = Prepared {
        adapter: a,
        batch: Batch {
            adapter: a as *const _ as usize,
            slots: [0; 16],
            generations: [0; 16],
            len: 0,
        },
        admitted: false,
    };
    let ok = section_probe::with_slots(a, |_| {
        if a.hpd_stop.load(Ordering::Acquire) != 0 || a.hpd_thread.load(Ordering::Acquire) == 0 {
            return None;
        }
        let b = ensure(a)?;
        if b.terminal.load(Ordering::Acquire) != 0 {
            return None;
        }
        for target in targets {
            if target.carrier_handle == 0
                || target.target_value == 0
                || target.carrier_id == [0; 16]
            {
                return None;
            }
            let section = Section::acquire(target.carrier_handle, target.carrier_id)?;
            let (sequence, state) = section.snapshot()?;
            if state.observe(target.target_value) != Observe::Pending {
                return None;
            }
            let outstanding = b
                .bindings
                .iter()
                .filter(|e| {
                    if e.phase() == 0 {
                        return false;
                    }
                    // SAFETY: PASSIVE section mutex protects every payload read.
                    unsafe {
                        (&*e.payload.get()).section.as_ref().map(|s| s.key()) == Some(section.key())
                    }
                })
                .count() as u64;
            sequence.checked_add((outstanding + 1) * 2)?;
            let mut duplicate = false;
            for e in &b.bindings {
                if e.phase() != 0 {
                    // SAFETY: PASSIVE section mutex serializes all payload access.
                    let p = unsafe { &*e.payload.get() };
                    if p.section.as_ref().map(|s| s.key()) == Some(section.key()) {
                        if p.target == target.target_value
                            && prepared.batch.slots[..prepared.batch.len].contains(
                                &((e as *const _ as usize - b.bindings.as_ptr() as usize)
                                    / core::mem::size_of::<Binding>()),
                            )
                        {
                            duplicate = true;
                        } else if p.target >= target.target_value {
                            return None;
                        }
                    }
                }
            }
            if duplicate {
                continue;
            }
            let i = b.bindings.iter().position(|e| e.phase() == 0)?;
            let e = &b.bindings[i];
            let generation = e.generation.load(Ordering::Relaxed).checked_add(1)?;
            if generation > u32::MAX as u64 {
                return None;
            }
            // SAFETY: section mutex and Free entry exclude DPC/worker ownership.
            unsafe {
                *e.payload.get() = Payload {
                    section: Some(section),
                    target: target.target_value,
                };
            }
            e.generation.store(generation, Ordering::Relaxed);
            e.set_phase(generation, PREPARED);
            let n = prepared.batch.len;
            prepared.batch.slots[n] = i;
            prepared.batch.generations[n] = generation;
            prepared.batch.len += 1;
        }
        Some(())
    })
    .ok()
    .flatten()
    .is_some();
    if ok {
        Some(prepared)
    } else {
        None
    }
}

pub(crate) fn control(a: &AdapterContext, owner: DeviceOwner, buf: &mut [u8]) -> NTSTATUS {
    if buf.len() != 152 {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let request: E1Control = bytemuck::pod_read_unaligned(buf);
    if !request.valid_request(buf.len()) {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let result = section_probe::with_slots(a, |_| {
        if request.operation != CONTROL_UNREGISTER
            && (a.hpd_stop.load(Ordering::Acquire) != 0
                || a.hpd_thread.load(Ordering::Acquire) == 0)
        {
            return None;
        }
        let b = ensure(a)?;
        if request.operation != CONTROL_UNREGISTER && b.terminal.load(Ordering::Acquire) != 0 {
            return None;
        }
        match request.operation {
            CONTROL_QUERY => Some(0),
            CONTROL_REGISTER => {
                let section = Section::acquire(request.carrier_handle, request.carrier_id)?;
                let (_, state) = section.snapshot()?;
                let event = crate::ddi::escape::reference_user_event(request.event_handle)?;
                // SAFETY: section mutex exclusively owns registration mutation.
                let regs = unsafe { &mut *b.registrations.get() };
                let Some(r) = regs.iter_mut().find(|r| r.token == 0) else {
                    // SAFETY: PASSIVE drops the one newly acquired event ref.
                    crate::ddi::escape::dereference_user_event(event);
                    return None;
                };
                let token = b.next_token.load(Ordering::Relaxed);
                let Some(next) = token.checked_add(1) else {
                    // SAFETY: PASSIVE unwind of exact event reference.
                    crate::ddi::escape::dereference_user_event(event);
                    return None;
                };
                b.next_token.store(next, Ordering::Relaxed);
                *r = Registration {
                    token,
                    owner: owner.raw(),
                    section: Some(section),
                    target: request.target_value,
                    event: event.as_ptr() as usize,
                };
                if state.observe(request.target_value) != Observe::Pending {
                    // SAFETY: held event ref and serialized predicate+registration.
                    unsafe {
                        KeSetEvent(event.as_ptr(), 0, 0);
                    }
                }
                Some(token)
            }
            CONTROL_UNREGISTER => {
                // SAFETY: section mutex serializes event signal with unregister.
                let regs = unsafe { &mut *b.registrations.get() };
                let r = regs
                    .iter_mut()
                    .find(|r| r.token == request.registration_token && r.owner == owner.raw())?;
                drop_registration(r, false);
                Some(0)
            }
            _ => None,
        }
    })
    .ok()
    .flatten();
    let accepted = result.is_some() as u32;
    if accepted == 0 {
        REFUSALS.fetch_add(1, Ordering::Relaxed);
    }
    let Some(response) = request.complete(
        accepted,
        if accepted == 1 { 0 } else { 1 },
        result.unwrap_or(0),
        3,
        R as u32,
    ) else {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    };
    buf.copy_from_slice(bytemuck::bytes_of(&response));
    wdk_sys::STATUS_SUCCESS
}
fn drop_registration(r: &mut Registration, signal: bool) {
    if r.token != 0 {
        // SAFETY: PASSIVE mutex holder owns the event reference; signal occurs
        // before release and cannot race unregister's final dereference.
        unsafe {
            if signal {
                KeSetEvent(r.event as *mut _, 0, 0);
            }
            crate::ddi::escape::dereference_user_event(core::ptr::NonNull::new_unchecked(
                r.event as *mut _,
            ));
        }
        r.section.take();
        r.token = 0;
        r.owner = 0;
        r.event = 0;
    }
}
pub(crate) fn release_owner(a: &AdapterContext, owner: usize) {
    let _ = section_probe::with_slots(a, |_| {
        if let Some(b) = broker(a) {
            // SAFETY: section mutex exclusively owns registration mutation.
            for r in unsafe { &mut *b.registrations.get() } {
                if r.owner == owner {
                    drop_registration(r, true);
                }
            }
        }
    });
}
/// HPD's existing joined system thread is the PASSIVE continuation. Outcome
/// signals its event; periodic HPD timing is not a notification substitute.
pub(crate) fn service(a: &AdapterContext) {
    let _ = section_probe::with_slots(a, |_| {
        let Some(b) = broker(a) else {
            return;
        };
        let terminal = b
            .terminal
            .compare_exchange(1, 2, Ordering::AcqRel, Ordering::Acquire)
            .is_ok();
        if terminal {
            for e in &b.bindings {
                let phase = e.phase();
                if matches!(phase, PREPARED | INFLIGHT) {
                    let g = e.generation.load(Ordering::Acquire);
                    let previous = (g << 32) | phase as u64;
                    // Claim exact generation before writing response; a DPC
                    // which already claimed Completing owns that outcome.
                    if e.phase
                        .compare_exchange(
                            previous,
                            (g << 32) | 4,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        e.response.store(CANCEL_RESPONSE, Ordering::Relaxed);
                        e.set_phase(g, READY);
                    }
                }
            }
        }
        loop {
            let selected = b
                .bindings
                .iter()
                .enumerate()
                .find(|(_, e)| {
                    if e.phase() != READY {
                        return false;
                    }
                    // SAFETY: section mutex; ready payload owns its retained view.
                    let p = unsafe { &*e.payload.get() };
                    let Some(s) = p.section.as_ref() else {
                        return false;
                    };
                    !b.bindings.iter().any(|lower| {
                        if lower.phase() == 0 {
                            return false;
                        }
                        // SAFETY: all payload reads under the same section mutex.
                        let l = unsafe { &*lower.payload.get() };
                        l.target < p.target && l.section.as_ref().map(|v| v.key()) == Some(s.key())
                    })
                })
                .map(|(i, _)| i);
            let Some(i) = selected else {
                break;
            };
            let e = &b.bindings[i];
            // SAFETY: mutex excludes another publisher and all ref reclamation.
            let p = unsafe { &mut *e.payload.get() };
            let Some(s) = p.section.as_ref() else {
                break;
            };
            if let Some((sequence, mut state)) = s.snapshot() {
                let response = e.response.load(Ordering::Relaxed);
                if response == 0 {
                    state.publish_success(p.target);
                } else {
                    let _ = state.publish_error(p.target, response);
                }
                if let Some(next) = sequence.checked_add(2) {
                    section_probe::write_production_record(s.view, s.id, next / 2, state);
                    PUBLISHED.fetch_add(1, Ordering::Relaxed);
                    crate::diag::record_named_bytes(
                        b"E1BAss",
                        ASSOCIATED.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BRoll",
                        ROLLED_BACK.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BOut",
                        OUTCOMES.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BPub",
                        PUBLISHED.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BWake",
                        WAKES.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BRef",
                        REFUSALS.load(Ordering::Relaxed) as u32,
                    );

                    // PASSIVE receipts correlate the exact immutable admitted
                    // token with the record value. Never emitted from DPC.
                    crate::diag::record_named_bytes(
                        b"E1BGen",
                        e.generation.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(b"E1BCtx", e.ctx.load(Ordering::Relaxed));
                    crate::diag::record_named_bytes(
                        b"E1BFLo",
                        e.fence.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BFHi",
                        (e.fence.load(Ordering::Relaxed) >> 32) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BELo",
                        e.epoch.load(Ordering::Relaxed) as u32,
                    );
                    crate::diag::record_named_bytes(
                        b"E1BEHi",
                        (e.epoch.load(Ordering::Relaxed) >> 32) as u32,
                    );
                    crate::diag::record_named_bytes(b"E1BVLo", p.target as u32);
                    crate::diag::record_named_bytes(b"E1BVHi", (p.target >> 32) as u32);
                    crate::diag::record_named_bytes(b"E1BResp", response);

                    // SAFETY: same mutex serializes signals and registration drops.
                    for r in unsafe { &mut *b.registrations.get() } {
                        if r.token != 0
                            && r.section.as_ref().map(|v| v.key()) == Some(s.key())
                            && state.observe(r.target) != Observe::Pending
                        {
                            // SAFETY: retained event reference remains live.
                            unsafe {
                                KeSetEvent(r.event as *mut _, 0, 0);
                                WAKES.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                    }
                }
            }
            p.section.take();
            e.phase.store(0, Ordering::Release);
        }
        if terminal {
            // Cancel even consumers whose producers have not submitted yet.
            // A wake alone cannot mean COMPLETE. Publish terminal cancellation
            // where representable; otherwise re-arm is refused by terminal gate.
            // SAFETY: section mutex serializes all event and Section ownership.
            for r in unsafe { &mut *b.registrations.get() } {
                if r.token == 0 {
                    continue;
                }
                if let Some(section) = r.section.as_ref() {
                    if let Some((sequence, mut state)) = section.snapshot() {
                        if state.observe(r.target) == Observe::Pending {
                            if let Some(next) = sequence.checked_add(2) {
                                let _ = state.publish_error(r.target, CANCEL_RESPONSE);
                                section_probe::write_production_record(
                                    section.view,
                                    section.id,
                                    next / 2,
                                    state,
                                );
                            }
                        }
                    }
                }
                drop_registration(r, true);
            }
        }
    });
}
pub(crate) fn submit(
    passive: PassiveLevel,
    a: &AdapterContext,
    owner: DeviceOwner,
    buf: &mut [u8],
) -> NTSTATUS {
    if buf.len() < 112 {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let mut request: E1Submit = bytemuck::pod_read_unaligned(&buf[..112]);
    if request.target_count == 0
        || request.target_count > 16
        || buf.len() < 112 + request.target_count as usize * 32
    {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let mut targets = [E1Target {
        carrier_handle: 0,
        target_value: 0,
        carrier_id: [0; 16],
    }; 16];
    let count = request.target_count as usize;
    for i in 0..count {
        targets[i] = bytemuck::pod_read_unaligned(&buf[112 + i * 32..144 + i * 32]);
    }
    if !request.valid_request(buf.len(), &targets[..count]) {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let Some(mut prepared) = prepare(a, &targets[..count]) else {
        return wdk_sys::STATUS_INVALID_PARAMETER;
    };
    let stream = &buf[112 + count * 32..];
    let result = crate::virtio::ctrl::submit_venus_async_e1(
        passive,
        a,
        owner,
        request.ctx_id,
        request.ring_idx,
        stream,
        request.present_cookie,
        request.present_value32,
        prepared.batch,
    );
    match result {
        Ok(fence) => {
            prepared.admit();
            request.fence_id = fence;
            request.response_version = 1;
            request.response_size = 112;
            request.valid_marker = SUBMIT_VALID;
            request.response_status = 0;
            request.response_id = request.request_id;
            buf[..112].copy_from_slice(bytemuck::bytes_of(&request));
            wdk_sys::STATUS_SUCCESS
        }
        Err(_) => wdk_sys::STATUS_UNSUCCESSFUL,
    }
}
/// Final adapter destruction AFTER worker join and transport drop. Abort every
/// unpublished value with explicit terminal error, wake waiters, then release.
pub(crate) fn notify_device_loss(a: &AdapterContext) {
    if let Some(b) = broker(a) {
        b.terminal.store(1, Ordering::Release);
        // SAFETY: DPC-safe event store, stable adapter. No object reference,
        // mapping, record publication or registry access occurs in this stage.
        unsafe {
            KeSetEvent(a.hpd_event.get(), 0, 0);
        }
    }
}
pub(crate) fn abort_transport(a: &AdapterContext) {
    notify_device_loss(a);
    service(a);
}
/// StartDevice alone resets terminal state after the previous transport is
/// destroyed and all old registrations are canceled. Token counter is retained.
pub(crate) fn reset_transport(a: &AdapterContext) {
    let _ = section_probe::with_slots(a, |_| {
        if let Some(b) = broker(a) {
            b.terminal.store(0, Ordering::Release);
        }
    });
}

pub(crate) fn release_all(a: &AdapterContext) {
    abort_transport(a);
    let _ = section_probe::with_slots(a, |_| {
        let p = a.green_b_broker.swap(0, Ordering::AcqRel) as *mut Broker;
        if p.is_null() {
            return;
        }
        // SAFETY: final Drop after producer transport and joined HPD are gone;
        // no DPC/escape/worker may access this adapter-owned broker afterward.
        unsafe {
            for r in &mut *(*p).registrations.get() {
                drop_registration(r, true);
            }
            for e in &(*p).bindings {
                (*e.payload.get()).section.take();
            }
            ptr::drop_in_place(p);
            dealloc(p as *mut u8, Layout::new::<Broker>());
        }
    });
}

/// Only the SUBMIT_3D no-data success response can authorize publication.
pub(crate) fn completion_response(response: u32) -> u32 {
    if response == helios_protocol::VIRTIO_GPU_RESP_OK_NODATA {
        0
    } else if response == 0 || helios_protocol::resp_is_ok(response) {
        CANCEL_RESPONSE
    } else {
        response
    }
}
