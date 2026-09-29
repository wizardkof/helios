//! Host-testable ownership model for the diagnostic P06 section lease.

pub const MAX_PROBES: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Free,
    Creating,
    Live,
    Releasing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SlotError {
    Full,
    InvalidId,
    StaleGeneration,
    InvalidState,
    NonMonotonicSequence,
    GenerationExhausted,
    ResourcesIncomplete,
    ResourcesRemain,
}

/// Kernel resources owned by a section-carrier lease. `kernel_handle` keeps
/// the temporary Object Manager name alive; `object` and `system_view` provide
/// the KMD's independent object and mapped-view ownership.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BackingResources {
    pub kernel_handle: usize,
    pub object: usize,
    pub system_view: usize,
}

impl BackingResources {
    pub const EMPTY: Self = Self {
        kernel_handle: 0,
        object: 0,
        system_view: 0,
    };

    pub const fn is_empty(self) -> bool {
        self.kernel_handle == 0 && self.object == 0 && self.system_view == 0
    }

    pub const fn is_complete(self) -> bool {
        self.kernel_handle != 0 && self.object != 0 && self.system_view != 0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Slot {
    pub probe_id: u32,
    pub generation: u64,
    pub sequence: u64,
    pub value: u64,
    pub state: State,
    pub resources: BackingResources,
}

impl Slot {
    pub const EMPTY: Self = Self {
        probe_id: 0,
        generation: 0,
        sequence: 0,
        value: 0,
        state: State::Free,
        resources: BackingResources::EMPTY,
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Lease {
    pub index: usize,
    pub probe_id: u32,
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Counts {
    pub acquired: u32,
    pub released: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Resource {
    SlotLease = 0,
    SecurityBuffer = 1,
    SectionHandle = 2,
    ObjectReference = 3,
    SystemView = 4,
    HeaderInitialized = 5,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ResourceLedger {
    acquired: u8,
}

impl ResourceLedger {
    pub const EMPTY: Self = Self { acquired: 0 };

    pub fn acquire(&mut self, resource: Resource) {
        self.acquired |= 1 << (resource as u8);
    }

    pub fn unwind_reverse(&mut self) -> [Option<Resource>; 6] {
        let order = [
            Resource::HeaderInitialized,
            Resource::SystemView,
            Resource::ObjectReference,
            Resource::SectionHandle,
            Resource::SecurityBuffer,
            Resource::SlotLease,
        ];
        let mut released = [None; 6];
        let mut count = 0;
        for resource in order {
            let bit = 1 << (resource as u8);
            if self.acquired & bit != 0 {
                self.acquired &= !bit;
                released[count] = Some(resource);
                count += 1;
            }
        }
        released
    }

    pub fn is_empty(self) -> bool {
        self.acquired == 0
    }
}

impl Counts {
    pub const ZERO: Self = Self {
        acquired: 0,
        released: 0,
    };

    pub fn acquire(&mut self) {
        self.acquired = self.acquired.saturating_add(1);
    }

    pub fn release(&mut self) {
        self.released = self.released.saturating_add(1);
    }

    pub fn balanced(self) -> bool {
        self.acquired == self.released
    }
}

pub fn reserve(
    slots: &mut [Slot; MAX_PROBES],
    next_generation: &mut [u64; MAX_PROBES],
    probe_id: u32,
) -> Result<Lease, SlotError> {
    if probe_id == 0 {
        return Err(SlotError::InvalidId);
    }
    let index = slots
        .iter()
        .position(|slot| slot.state == State::Free)
        .ok_or(SlotError::Full)?;
    let generation = next_generation[index]
        .checked_add(1)
        .filter(|generation| *generation != 0)
        .ok_or(SlotError::GenerationExhausted)?;
    next_generation[index] = generation;
    let lease = Lease {
        index,
        probe_id,
        generation,
    };
    start_create(&mut slots[index], lease)?;
    Ok(lease)
}

pub fn start_create(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    if lease.probe_id == 0 || lease.generation == 0 {
        return Err(SlotError::InvalidId);
    }
    if slot.state != State::Free {
        return Err(SlotError::InvalidState);
    }
    *slot = Slot {
        probe_id: lease.probe_id,
        generation: lease.generation,
        sequence: 0,
        value: 0,
        state: State::Creating,
        resources: BackingResources::EMPTY,
    };
    Ok(())
}

pub fn acquire_live_slot(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Creating {
        return Err(SlotError::InvalidState);
    }
    if !slot.resources.is_complete() {
        return Err(SlotError::ResourcesIncomplete);
    }
    slot.state = State::Live;
    Ok(())
}

/// Keep partially acquired resources attached to a failed CREATE lease so a
/// later RELEASE or adapter teardown can retry cleanup without freeing the
/// slot or losing ownership.
pub fn retain_failed_create_slot(
    slot: &mut Slot,
    lease: Lease,
    resources: BackingResources,
) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Creating || resources.is_empty() {
        return Err(SlotError::InvalidState);
    }
    slot.resources = resources;
    slot.state = State::Releasing;
    Ok(())
}

pub fn fail_create_slot(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Creating {
        return Err(SlotError::InvalidState);
    }
    if !slot.resources.is_empty() {
        return Err(SlotError::ResourcesRemain);
    }
    *slot = Slot::EMPTY;
    Ok(())
}

pub fn begin_release_slot(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Live && slot.state != State::Releasing {
        return Err(SlotError::InvalidState);
    }
    slot.state = State::Releasing;
    Ok(())
}

pub fn restore_live_slot(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Releasing {
        return Err(SlotError::InvalidState);
    }
    slot.state = State::Live;
    Ok(())
}

pub fn finish_release_slot(slot: &mut Slot, lease: Lease) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Releasing {
        return Err(SlotError::InvalidState);
    }
    if !slot.resources.is_empty() {
        return Err(SlotError::ResourcesRemain);
    }
    *slot = Slot::EMPTY;
    Ok(())
}

pub fn publish_slot(
    slot: &mut Slot,
    lease: Lease,
    sequence: u64,
    value: u64,
) -> Result<(), SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Live {
        return Err(SlotError::InvalidState);
    }
    if sequence <= slot.sequence || sequence > u64::MAX / 2 {
        return Err(SlotError::NonMonotonicSequence);
    }
    slot.sequence = sequence;
    slot.value = value;
    Ok(())
}

pub fn query_slot(slot: &Slot, lease: Lease) -> Result<Slot, SlotError> {
    check_identity(slot, lease)?;
    if slot.state != State::Live {
        return Err(SlotError::InvalidState);
    }
    Ok(*slot)
}

pub fn acquire_live(slots: &mut [Slot; MAX_PROBES], lease: Lease) -> Result<(), SlotError> {
    let slot = exact_slot(slots, lease)?;
    acquire_live_slot(slot, lease)
}

pub fn fail_create(slots: &mut [Slot; MAX_PROBES], lease: Lease) -> Result<(), SlotError> {
    let slot = exact_slot(slots, lease)?;
    fail_create_slot(slot, lease)
}

pub fn begin_release(slots: &mut [Slot; MAX_PROBES], lease: Lease) -> Result<(), SlotError> {
    let slot = exact_slot(slots, lease)?;
    begin_release_slot(slot, lease)
}

pub fn finish_release(slots: &mut [Slot; MAX_PROBES], lease: Lease) -> Result<(), SlotError> {
    let slot = exact_slot(slots, lease)?;
    finish_release_slot(slot, lease)
}

pub fn publish(
    slots: &mut [Slot; MAX_PROBES],
    lease: Lease,
    sequence: u64,
    value: u64,
) -> Result<(), SlotError> {
    let slot = exact_slot(slots, lease)?;
    publish_slot(slot, lease, sequence, value)
}

pub fn query(slots: &[Slot; MAX_PROBES], lease: Lease) -> Result<Slot, SlotError> {
    let slot = exact_slot_ref(slots, lease)?;
    query_slot(slot, lease)
}

fn exact_slot(slots: &mut [Slot; MAX_PROBES], lease: Lease) -> Result<&mut Slot, SlotError> {
    let slot = slots.get_mut(lease.index).ok_or(SlotError::InvalidId)?;
    check_identity(slot, lease)?;
    Ok(slot)
}

fn exact_slot_ref(slots: &[Slot; MAX_PROBES], lease: Lease) -> Result<&Slot, SlotError> {
    let slot = slots.get(lease.index).ok_or(SlotError::InvalidId)?;
    check_identity(slot, lease)?;
    Ok(slot)
}

fn check_identity(slot: &Slot, lease: Lease) -> Result<(), SlotError> {
    if slot.state == State::Free {
        return Err(SlotError::InvalidId);
    }
    if slot.generation != lease.generation {
        return Err(SlotError::StaleGeneration);
    }
    if slot.probe_id != lease.probe_id {
        return Err(SlotError::InvalidId);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table() -> ([Slot; MAX_PROBES], [u64; MAX_PROBES]) {
        ([Slot::EMPTY; MAX_PROBES], [0; MAX_PROBES])
    }

    fn test_resources() -> BackingResources {
        BackingResources {
            kernel_handle: 1,
            object: 2,
            system_view: 3,
        }
    }

    #[test]
    fn create_transitions_and_partial_failures_return_slot_to_free() {
        let (mut slots, mut gens) = table();
        let lease = reserve(&mut slots, &mut gens, 4).unwrap();
        assert_eq!(slots[lease.index].state, State::Creating);
        fail_create(&mut slots, lease).unwrap();
        assert_eq!(slots[lease.index].state, State::Free);
        assert_eq!(gens[lease.index], lease.generation);
        let next = reserve(&mut slots, &mut gens, 5).unwrap();
        assert_eq!(next.index, lease.index);
        assert_ne!(next.generation, lease.generation);
        slots[next.index].resources = test_resources();
        acquire_live(&mut slots, next).unwrap();
        assert_eq!(query(&slots, next).unwrap().state, State::Live);
    }

    #[test]
    fn live_transition_requires_the_lease_to_own_its_kernel_handle() {
        let (mut slots, mut gens) = table();
        let lease = reserve(&mut slots, &mut gens, 41).unwrap();

        // The pre-fix CREATE path closed this handle before committing LIVE.
        assert_eq!(
            acquire_live(&mut slots, lease),
            Err(SlotError::ResourcesIncomplete)
        );

        slots[lease.index].resources = BackingResources {
            kernel_handle: 0x11,
            object: 0x22,
            system_view: 0x33,
        };
        acquire_live(&mut slots, lease).unwrap();
        let live = query(&slots, lease).unwrap();
        assert_eq!(live.resources.kernel_handle, 0x11);
        assert_eq!(live.resources.object, 0x22);
        assert_eq!(live.resources.system_view, 0x33);
    }

    #[test]
    fn failed_create_resources_keep_the_slot_reserved_until_cleanup() {
        let (mut slots, mut gens) = table();
        let lease = reserve(&mut slots, &mut gens, 42).unwrap();
        let resources = BackingResources {
            kernel_handle: 0x11,
            object: 0x22,
            system_view: 0,
        };
        retain_failed_create_slot(&mut slots[lease.index], lease, resources).unwrap();

        assert_eq!(slots[lease.index].state, State::Releasing);
        assert_eq!(slots[lease.index].resources, resources);
        assert_eq!(
            finish_release(&mut slots, lease),
            Err(SlotError::ResourcesRemain)
        );
        let other = reserve(&mut slots, &mut gens, 43).unwrap();
        assert_ne!(other.index, lease.index);

        slots[lease.index].resources = BackingResources::EMPTY;
        finish_release(&mut slots, lease).unwrap();
        let reused = reserve(&mut slots, &mut gens, 44).unwrap();
        assert_eq!(reused.index, lease.index);
        assert_ne!(reused.generation, lease.generation);
    }

    #[test]
    fn table_is_bounded_and_generation_exhaustion_fails_closed() {
        let (mut slots, mut gens) = table();
        for id in 1..=MAX_PROBES as u32 {
            reserve(&mut slots, &mut gens, id).unwrap();
        }
        assert_eq!(reserve(&mut slots, &mut gens, 90), Err(SlotError::Full));
        slots[0] = Slot::EMPTY;
        gens[0] = u64::MAX;
        assert_eq!(
            reserve(&mut slots, &mut gens, 91),
            Err(SlotError::GenerationExhausted)
        );
    }

    #[test]
    fn release_reuse_rejects_every_stale_operation_and_isolates_new_lease() {
        let (mut slots, mut gens) = table();
        let old = reserve(&mut slots, &mut gens, 7).unwrap();
        slots[old.index].resources = test_resources();
        acquire_live(&mut slots, old).unwrap();
        publish(&mut slots, old, 1, 0xA).unwrap();
        begin_release(&mut slots, old).unwrap();
        slots[old.index].resources = BackingResources::EMPTY;
        finish_release(&mut slots, old).unwrap();
        assert_eq!(query(&slots, old), Err(SlotError::InvalidId));
        assert_eq!(publish(&mut slots, old, 2, 0xB), Err(SlotError::InvalidId));
        assert_eq!(begin_release(&mut slots, old), Err(SlotError::InvalidId));
        let new = reserve(&mut slots, &mut gens, 8).unwrap();
        assert_eq!(new.index, old.index);
        assert_ne!(new.generation, old.generation);
        slots[new.index].resources = test_resources();
        acquire_live(&mut slots, new).unwrap();
        assert_eq!(query(&slots, old), Err(SlotError::StaleGeneration));
        assert_eq!(
            publish(&mut slots, old, 3, 0xC),
            Err(SlotError::StaleGeneration)
        );
        assert_eq!(
            begin_release(&mut slots, old),
            Err(SlotError::StaleGeneration)
        );
        assert_eq!(query(&slots, new).unwrap().probe_id, 8);
        publish(&mut slots, new, 1, 0xD).unwrap();
        assert_eq!(query(&slots, new).unwrap().sequence, 1);
        assert_eq!(query(&slots, new).unwrap().value, 0xD);
    }

    #[test]
    fn duplicate_release_and_nonmonotonic_publish_are_rejected() {
        let (mut slots, mut gens) = table();
        let lease = reserve(&mut slots, &mut gens, 3).unwrap();
        slots[lease.index].resources = test_resources();
        acquire_live(&mut slots, lease).unwrap();
        publish(&mut slots, lease, 1, 1).unwrap();
        assert_eq!(
            publish(&mut slots, lease, 1, 2),
            Err(SlotError::NonMonotonicSequence)
        );
        begin_release(&mut slots, lease).unwrap();
        begin_release(&mut slots, lease).unwrap();
        assert_eq!(
            finish_release(&mut slots, lease),
            Err(SlotError::ResourcesRemain)
        );
        slots[lease.index].resources = BackingResources::EMPTY;
        finish_release(&mut slots, lease).unwrap();
    }

    #[test]
    fn resource_counts_balance_for_each_create_failure_boundary() {
        let resources = [
            Resource::SlotLease,
            Resource::SecurityBuffer,
            Resource::SectionHandle,
            Resource::ObjectReference,
            Resource::SystemView,
            Resource::HeaderInitialized,
        ];
        for acquired_at in 0..=resources.len() {
            let mut ledger = ResourceLedger::EMPTY;
            for resource in resources.iter().copied().take(acquired_at) {
                ledger.acquire(resource);
            }
            let released = ledger.unwind_reverse();
            for index in 0..acquired_at {
                assert_eq!(released[index], Some(resources[acquired_at - index - 1]));
            }
            for item in released.iter().skip(acquired_at) {
                assert_eq!(*item, None);
            }
            assert!(ledger.is_empty(), "failure boundary {acquired_at}");
        }
    }
}
