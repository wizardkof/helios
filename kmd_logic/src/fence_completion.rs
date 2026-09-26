//! One terminal outcome for a KMD-issued AsyncVenus wire fence.
//! Methods run under the VirtioGpu device lock. The record lives in a fixed
//! table allocated at StartDevice and outlives waiter and event notification.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FenceIdentity {
    pub generation: u64,
    pub fence_id: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalState {
    Pending,
    Success,
    Error { response_type: u32 },
}

pub struct CompletionRecord {
    identity: Option<FenceIdentity>,
    state: TerminalState,
    consumers: u32,
}

impl CompletionRecord {
    pub const fn new() -> Self {
        Self { identity: None, state: TerminalState::Pending, consumers: 0 }
    }
    pub fn is_free(&self) -> bool { self.identity.is_none() }
    pub fn identity(&self) -> Option<FenceIdentity> { self.identity }
    pub fn state(&self) -> TerminalState { self.state }

    pub fn assign(&mut self, identity: FenceIdentity) -> bool {
        if self.identity.is_some() || identity.fence_id == 0 { return false; }
        self.identity = Some(identity);
        self.state = TerminalState::Pending;
        self.consumers = 0;
        true
    }

    pub fn abandon_pending(&mut self, identity: FenceIdentity) {
        if self.identity == Some(identity) && self.state == TerminalState::Pending && self.consumers == 0 {
            self.identity = None;
        }
    }

    pub fn add_consumer(&mut self, identity: FenceIdentity) -> bool {
        if self.identity != Some(identity) || self.consumers == u32::MAX { return false; }
        self.consumers += 1;
        true
    }

    pub fn release_consumer(&mut self, identity: FenceIdentity) -> bool {
        if self.identity != Some(identity) || self.consumers == 0 { return false; }
        self.consumers -= 1;
        self.release_success_without_consumers();
        true
    }

    pub fn complete(&mut self, identity: FenceIdentity, response_type: u32) -> bool {
        if self.identity != Some(identity) || self.state != TerminalState::Pending { return false; }
        self.state = terminal_from_async_response(response_type);
        self.release_success_without_consumers();
        true
    }

    fn release_success_without_consumers(&mut self) {
        if self.state == TerminalState::Success && self.consumers == 0 {
            self.identity = None;
        }
        // Error remains queryable for late and repeated waits until teardown.
    }
}

impl Default for CompletionRecord {
    fn default() -> Self { Self::new() }
}

/// Classify the response before either waiter is notified. `drain_used` calls
/// this through `CompletionRecord::complete`.
pub fn terminal_from_async_response(response_type: u32) -> TerminalState {
    if (0x1100..0x1200).contains(&response_type) {
        TerminalState::Success
    } else {
        TerminalState::Error { response_type }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ERR_UNSPEC: u32 = 0x1200;
    const OK_NODATA: u32 = 0x1100;
    fn id(generation: u64, fence_id: u64) -> FenceIdentity { FenceIdentity { generation, fence_id } }

    #[test]
    fn asyncven_error_waiter_reads_terminal_response() {
        let mut record = CompletionRecord::new();
        let identity = id(2, 3279);
        assert!(record.assign(identity));
        assert!(record.add_consumer(identity));
        assert!(record.complete(identity, ERR_UNSPEC));
        assert_eq!(record.state(), TerminalState::Error { response_type: ERR_UNSPEC });
        assert!(record.release_consumer(identity));
        assert_eq!(record.state(), TerminalState::Error { response_type: ERR_UNSPEC });
    }

    #[test]
    fn asyncven_error_event_reads_terminal_response_after_wake() {
        let mut record = CompletionRecord::new();
        let identity = id(2, 3279);
        assert!(record.assign(identity));
        assert!(record.add_consumer(identity));
        assert!(record.complete(identity, ERR_UNSPEC));
        assert_eq!(record.state(), TerminalState::Error { response_type: ERR_UNSPEC });
        assert!(record.release_consumer(identity));
        assert_eq!(record.state(), TerminalState::Error { response_type: ERR_UNSPEC });
    }

    #[test]
    fn asyncven_ok_wakes_both_consumers_as_success() {
        let mut record = CompletionRecord::new();
        let identity = id(2, 3280);
        assert!(record.assign(identity));
        assert!(record.add_consumer(identity));
        assert!(record.add_consumer(identity));
        assert!(record.complete(identity, OK_NODATA));
        assert_eq!(record.state(), TerminalState::Success);
        assert!(record.release_consumer(identity));
        assert!(!record.is_free());
        assert!(record.release_consumer(identity));
        assert!(record.is_free());
    }

    #[test]
    fn error_a_success_b_and_generation_isolation() {
        let mut a = CompletionRecord::new();
        let mut b = CompletionRecord::new();
        let aid = id(2, 40);
        let bid = id(2, 41);
        assert!(a.assign(aid));
        assert!(b.assign(bid));
        assert!(!a.complete(id(1, 40), ERR_UNSPEC));
        assert_eq!(a.state(), TerminalState::Pending);
        assert!(b.complete(bid, OK_NODATA));
        assert!(a.complete(aid, ERR_UNSPEC));
        assert_eq!(a.state(), TerminalState::Error { response_type: ERR_UNSPEC });
        assert_eq!(b.state(), TerminalState::Success);
        assert!(!a.complete(aid, OK_NODATA));
    }
}
