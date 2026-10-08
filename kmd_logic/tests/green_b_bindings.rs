use helios_kmd_logic::green_b_bindings::{BindingTable, Fence, Outcome, Phase};
use helios_kmd_logic::production_carrier::{Observe, ProductionState};

fn id(value: u8) -> [u8; 16] {
    [value; 16]
}
fn fence(number: u64) -> Fence {
    Fence {
        epoch: 3,
        id: number,
        ctx_id: 7,
    }
}

#[test]
fn capacity_and_rejected_enqueue_release_all_reservations() {
    let mut table = BindingTable::<2>::new();
    let a = table.reserve(0x41, id(1), 17).unwrap();
    let b = table.reserve(0x42, id(2), 18).unwrap();
    assert!(table.reserve(0x43, id(3), 19).is_err());
    assert_eq!(table.phase(a), Some(Phase::Reserved));
    assert!(table.rollback(a));
    assert!(table.rollback(b));
    assert_eq!(table.active(), 0);
    let newer = table.reserve(0x44, id(4), 20).unwrap();
    assert_ne!(newer, a);
}

#[test]
fn out_of_order_success_does_not_advance_unfinished_prefix() {
    let mut table = BindingTable::<4>::new();
    let a = table.reserve(0x41, id(1), 17).unwrap();
    let b = table.reserve(0x41, id(1), 18).unwrap();
    assert!(table.accept(a, fence(11)));
    assert!(table.accept(b, fence(12)));
    assert!(table.ready(b, fence(12), Outcome::Success));
    assert_eq!(table.next_publishable(), None);
    assert!(table.ready(a, fence(11), Outcome::Success));
    let mut state = ProductionState::EMPTY;
    let first = table.next_publishable().unwrap();
    assert_eq!(first.token, a);
    state.publish_success(first.target);
    assert!(table.published(first.token));
    assert_eq!(state.observe(18), Observe::Pending);
    let second = table.next_publishable().unwrap();
    assert_eq!(second.token, b);
    state.publish_success(second.target);
    assert!(table.published(second.token));
    assert_eq!(state.observe(18), Observe::Complete);
    assert_eq!(table.active(), 0);
}

#[test]
fn error_priority_and_stale_duplicate_are_exact() {
    let mut table = BindingTable::<2>::new();
    let a = table.reserve(0x41, id(1), 17).unwrap();
    let b = table.reserve(0x41, id(1), 18).unwrap();
    assert!(table.accept(a, fence(11)) && table.accept(b, fence(12)));
    assert!(!table.ready(a, fence(99), Outcome::Success));
    assert!(table.ready(b, fence(12), Outcome::Success));
    assert!(!table.ready(b, fence(12), Outcome::Success));
    assert!(table.ready(a, fence(11), Outcome::Error(0x1200)));
    let mut state = ProductionState::EMPTY;
    let first = table.next_publishable().unwrap();
    state
        .publish_error(first.target, first.outcome.response_type())
        .unwrap();
    assert!(table.published(first.token));
    let second = table.next_publishable().unwrap();
    state.publish_success(second.target);
    assert!(table.published(second.token));
    assert_eq!(state.observe(17), Observe::TerminalError(0x1200));
    assert_eq!(state.observe(18), Observe::TerminalError(0x1200));
    assert!(!table.ready(a, fence(11), Outcome::Success));
}

#[test]
fn old_carrier_and_reused_slot_cannot_cross_publish() {
    let mut table = BindingTable::<1>::new();
    let old = table.reserve(0x41, id(1), 17).unwrap();
    assert!(table.accept(old, fence(11)));
    assert!(table.ready(old, fence(11), Outcome::Success));
    assert!(table.published(old));
    let new = table.reserve(0x42, id(2), 17).unwrap();
    assert_ne!(old, new);
    assert!(!table.ready(old, fence(11), Outcome::Success));
    assert_eq!(table.phase(new), Some(Phase::Reserved));
}
