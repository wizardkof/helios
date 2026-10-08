//! Allocation-free registration policy. The KMD holds one PASSIVE mutex over
//! this table, record condition checks, commit and event signaling.
use crate::production_carrier::{Observe, ProductionState};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Refusal {
    Capacity,
    Invalid,
    TokenExhausted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Registered {
    pub token: u64,
    pub already_ready: bool,
}

#[derive(Clone, Copy)]
struct Entry {
    token: u64,
    owner: usize,
    object_key: usize,
    carrier_id: [u8; 16],
    target: u64,
    event_key: usize,
}
impl Entry {
    const EMPTY: Self = Self {
        token: 0,
        owner: 0,
        object_key: 0,
        carrier_id: [0; 16],
        target: 0,
        event_key: 0,
    };
}

pub struct Events<const N: usize> {
    entries: [usize; N],
    len: usize,
}
impl<const N: usize> Events<N> {
    pub fn as_slice(&self) -> &[usize] {
        &self.entries[..self.len]
    }
    pub fn len(&self) -> usize {
        self.len
    }
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

pub struct RegistrationTable<const N: usize> {
    entries: [Entry; N],
    next_token: u64,
}
impl<const N: usize> RegistrationTable<N> {
    pub const fn new() -> Self {
        Self {
            entries: [Entry::EMPTY; N],
            next_token: 1,
        }
    }
    pub fn active(&self) -> usize {
        self.entries.iter().filter(|e| e.token != 0).count()
    }
    pub fn register(
        &mut self,
        owner: usize,
        object_key: usize,
        carrier_id: [u8; 16],
        target: u64,
        event_key: usize,
        state: ProductionState,
    ) -> Result<Registered, Refusal> {
        if owner == 0 || object_key == 0 || carrier_id == [0; 16] || target == 0 || event_key == 0 {
            return Err(Refusal::Invalid);
        }
        let Some(entry) = self.entries.iter_mut().find(|entry| entry.token == 0) else {
            return Err(Refusal::Capacity);
        };
        let Some(next) = self.next_token.checked_add(1) else {
            return Err(Refusal::TokenExhausted);
        };
        let token = self.next_token;
        self.next_token = next;
        *entry = Entry {
            token,
            owner,
            object_key,
            carrier_id,
            target,
            event_key,
        };
        Ok(Registered {
            token,
            already_ready: state.observe(target) != Observe::Pending,
        })
    }
    pub fn unregister(&mut self, owner: usize, token: u64) -> bool {
        let Some(entry) = self
            .entries
            .iter_mut()
            .find(|entry| entry.token == token && entry.owner == owner && token != 0)
        else {
            return false;
        };
        *entry = Entry::EMPTY;
        true
    }
    pub fn release_owner(&mut self, owner: usize) -> usize {
        let mut count = 0;
        for entry in &mut self.entries {
            if entry.owner == owner && entry.token != 0 {
                *entry = Entry::EMPTY;
                count += 1;
            }
        }
        count
    }
    pub fn events_to_signal(
        &self,
        object_key: usize,
        carrier_id: [u8; 16],
        state: ProductionState,
    ) -> Events<N> {
        let mut events = Events {
            entries: [0; N],
            len: 0,
        };
        for entry in &self.entries {
            if entry.token != 0
                && entry.object_key == object_key
                && entry.carrier_id == carrier_id
                && state.observe(entry.target) != Observe::Pending
                && !events.as_slice().contains(&entry.event_key)
            {
                events.entries[events.len] = entry.event_key;
                events.len += 1;
            }
        }
        events
    }
}
impl<const N: usize> Default for RegistrationTable<N> {
    fn default() -> Self {
        Self::new()
    }
}
