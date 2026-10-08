//! Bounded, allocation-free ordering contract for accepted Green B bindings.
//! Object references and record writes remain the KMD's responsibility.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fence {
    pub epoch: u64,
    pub id: u64,
    pub ctx_id: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Success,
    Error(u32),
}
impl Outcome {
    pub const fn response_type(self) -> u32 {
        match self {
            Self::Success => 0,
            Self::Error(response) => response,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Phase {
    Free,
    Reserved,
    InFlight,
    ReadySuccess,
    ReadyError,
    Published,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Token {
    pub slot: usize,
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Publishable {
    pub token: Token,
    pub object_key: usize,
    pub carrier_id: [u8; 16],
    pub target: u64,
    pub fence: Fence,
    pub outcome: Outcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Refusal {
    Capacity,
    Invalid,
    Duplicate,
    GenerationExhausted,
}

#[derive(Clone, Copy)]
struct Slot {
    generation: u64,
    phase: Phase,
    object_key: usize,
    carrier_id: [u8; 16],
    target: u64,
    fence: Fence,
    outcome: Outcome,
}
impl Slot {
    const EMPTY: Self = Self {
        generation: 0,
        phase: Phase::Free,
        object_key: 0,
        carrier_id: [0; 16],
        target: 0,
        fence: Fence {
            epoch: 0,
            id: 0,
            ctx_id: 0,
        },
        outcome: Outcome::Success,
    };
}

pub struct BindingTable<const N: usize> {
    slots: [Slot; N],
}
impl<const N: usize> BindingTable<N> {
    pub const fn new() -> Self {
        Self {
            slots: [Slot::EMPTY; N],
        }
    }
    pub fn active(&self) -> usize {
        self.slots.iter().filter(|s| s.phase != Phase::Free).count()
    }
    pub fn phase(&self, token: Token) -> Option<Phase> {
        self.slot(token).map(|s| s.phase)
    }
    fn slot(&self, token: Token) -> Option<&Slot> {
        self.slots
            .get(token.slot)
            .filter(|s| s.generation == token.generation && s.phase != Phase::Free)
    }
    fn slot_mut(&mut self, token: Token) -> Option<&mut Slot> {
        self.slots
            .get_mut(token.slot)
            .filter(|s| s.generation == token.generation && s.phase != Phase::Free)
    }
    pub fn reserve(
        &mut self,
        object_key: usize,
        carrier_id: [u8; 16],
        target: u64,
    ) -> Result<Token, Refusal> {
        if object_key == 0 || carrier_id == [0; 16] || target == 0 {
            return Err(Refusal::Invalid);
        }
        if self.slots.iter().any(|s| {
            s.phase != Phase::Free
                && s.object_key == object_key
                && s.carrier_id == carrier_id
                && s.target == target
        }) {
            return Err(Refusal::Duplicate);
        }
        let (index, slot) = self
            .slots
            .iter_mut()
            .enumerate()
            .find(|(_, s)| s.phase == Phase::Free)
            .ok_or(Refusal::Capacity)?;
        let generation = slot
            .generation
            .checked_add(1)
            .ok_or(Refusal::GenerationExhausted)?;
        *slot = Slot {
            generation,
            phase: Phase::Reserved,
            object_key,
            carrier_id,
            target,
            ..Slot::EMPTY
        };
        Ok(Token {
            slot: index,
            generation,
        })
    }
    pub fn rollback(&mut self, token: Token) -> bool {
        let Some(slot) = self.slot_mut(token) else {
            return false;
        };
        if slot.phase != Phase::Reserved {
            return false;
        }
        slot.phase = Phase::Free;
        true
    }
    pub fn accept(&mut self, token: Token, fence: Fence) -> bool {
        if fence.epoch == 0 || fence.id == 0 || fence.ctx_id == 0 {
            return false;
        }
        let Some(slot) = self.slot_mut(token) else {
            return false;
        };
        if slot.phase != Phase::Reserved {
            return false;
        }
        slot.fence = fence;
        slot.phase = Phase::InFlight;
        true
    }
    pub fn ready(&mut self, token: Token, fence: Fence, outcome: Outcome) -> bool {
        let Some(slot) = self.slot_mut(token) else {
            return false;
        };
        if slot.phase != Phase::InFlight
            || slot.fence != fence
            || matches!(outcome, Outcome::Error(0))
        {
            return false;
        }
        slot.outcome = outcome;
        slot.phase = match outcome {
            Outcome::Success => Phase::ReadySuccess,
            Outcome::Error(_) => Phase::ReadyError,
        };
        true
    }
    pub fn next_publishable(&self) -> Option<Publishable> {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, s)| matches!(s.phase, Phase::ReadySuccess | Phase::ReadyError))
            .filter(|(_, s)| {
                !self.slots.iter().any(|lower| {
                    lower.phase != Phase::Free
                        && lower.object_key == s.object_key
                        && lower.carrier_id == s.carrier_id
                        && lower.target < s.target
                })
            })
            .min_by_key(|(_, s)| s.target)
            .map(|(index, s)| Publishable {
                token: Token {
                    slot: index,
                    generation: s.generation,
                },
                object_key: s.object_key,
                carrier_id: s.carrier_id,
                target: s.target,
                fence: s.fence,
                outcome: s.outcome,
            })
    }
    pub fn published(&mut self, token: Token) -> bool {
        let Some(slot) = self.slot_mut(token) else {
            return false;
        };
        if !matches!(slot.phase, Phase::ReadySuccess | Phase::ReadyError) {
            return false;
        }
        slot.phase = Phase::Published;
        slot.phase = Phase::Free;
        true
    }
    pub fn cancel_all(&mut self) -> usize {
        let count = self.active();
        for slot in &mut self.slots {
            slot.phase = Phase::Free;
        }
        count
    }
}
impl<const N: usize> Default for BindingTable<N> {
    fn default() -> Self {
        Self::new()
    }
}
