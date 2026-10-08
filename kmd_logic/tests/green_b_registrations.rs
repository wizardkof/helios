use helios_kmd_logic::green_b_registrations::{Refusal, RegistrationTable};
use helios_kmd_logic::production_carrier::ProductionState;

fn id(byte: u8) -> [u8; 16] {
    [byte; 16]
}

#[test]
fn before_during_after_publish_have_no_lost_wake_window() {
    let mut table = RegistrationTable::<3>::new();
    let mut state = ProductionState::EMPTY;
    let first = table.register(1, 0x41, id(1), 17, 0xa0, state).unwrap();
    assert!(!first.already_ready);
    state.publish_success(17);
    assert_eq!(
        table.events_to_signal(0x41, id(1), state).as_slice(),
        &[0xa0]
    );
    let second = table.register(2, 0x41, id(1), 17, 0xa1, state).unwrap();
    assert!(second.already_ready);
    assert!(table.unregister(1, first.token));
    assert!(table.unregister(2, second.token));
    assert_eq!(table.active(), 0);
}

#[test]
fn aggregate_event_allows_distinct_tokens_without_double_ownership() {
    let mut table = RegistrationTable::<3>::new();
    let state = ProductionState::EMPTY;
    let a = table.register(1, 0x41, id(1), 17, 0xa0, state).unwrap();
    let b = table.register(1, 0x42, id(2), 18, 0xa0, state).unwrap();
    assert_ne!(a.token, b.token);
    assert_eq!(table.events_to_signal(0x41, id(1), state).len(), 0);
    assert!(!table.unregister(2, a.token));
    assert!(table.unregister(1, a.token));
    assert!(table.unregister(1, b.token));
    assert!(!table.unregister(1, a.token));
}

#[test]
fn release_reuse_and_capacity_are_exact() {
    let mut table = RegistrationTable::<1>::new();
    let state = ProductionState::EMPTY;
    let old = table.register(1, 0x41, id(1), 17, 0xa0, state).unwrap();
    assert_eq!(
        table.register(1, 0x42, id(2), 17, 0xa1, state),
        Err(Refusal::Capacity)
    );
    assert_eq!(table.release_owner(1), 1);
    let new = table.register(1, 0x42, id(2), 17, 0xa1, state).unwrap();
    assert_ne!(old.token, new.token);
    let mut old_state = state;
    old_state.publish_error(17, 0x1200).unwrap();
    assert!(table.events_to_signal(0x41, id(1), old_state).is_empty());
    assert!(!table.unregister(1, old.token));
    assert!(table.unregister(1, new.token));
}
