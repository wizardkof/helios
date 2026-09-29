//! Pure publication and read ordering for the versioned production carrier.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProductionState {
    pub completed_value: u64,
    pub terminal_error_value: u64,
    pub terminal_response_type: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PublishError {
    ZeroValue,
    ZeroResponseType,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Observe {
    Pending,
    Complete,
    TerminalError(u32),
}

impl ProductionState {
    pub const EMPTY: Self = Self {
        completed_value: 0,
        terminal_error_value: 0,
        terminal_response_type: 0,
    };

    pub fn publish_success(&mut self, value: u64) {
        self.completed_value = self.completed_value.max(value);
    }

    pub fn publish_error(&mut self, value: u64, response_type: u32) -> Result<(), PublishError> {
        if value == 0 {
            return Err(PublishError::ZeroValue);
        }
        if response_type == 0 {
            return Err(PublishError::ZeroResponseType);
        }
        if self.terminal_response_type == 0 || value < self.terminal_error_value {
            self.terminal_error_value = value;
            self.terminal_response_type = response_type;
        }
        Ok(())
    }

    pub fn observe(self, target: u64) -> Observe {
        if self.terminal_response_type != 0 && self.terminal_error_value <= target {
            Observe::TerminalError(self.terminal_response_type)
        } else if self.completed_value >= target {
            Observe::Complete
        } else {
            Observe::Pending
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_is_max_monotonic_and_preserves_terminal_error() {
        let mut state = ProductionState::EMPTY;
        state.publish_success(9);
        state.publish_success(4);
        state.publish_error(12, 0x1200).unwrap();
        state.publish_success(15);
        assert_eq!(state.completed_value, 15);
        assert_eq!(state.terminal_error_value, 12);
        assert_eq!(state.terminal_response_type, 0x1200);
    }

    #[test]
    fn first_lowest_error_wins_and_zero_response_is_refused() {
        let mut state = ProductionState::EMPTY;
        assert_eq!(state.publish_error(0, 0x1200), Err(PublishError::ZeroValue));
        assert_eq!(state.publish_error(4, 0), Err(PublishError::ZeroResponseType));
        state.publish_error(20, 0x1200).unwrap();
        state.publish_error(30, 0x1300).unwrap();
        state.publish_error(10, 0x1400).unwrap();
        assert_eq!(state.terminal_error_value, 10);
        assert_eq!(state.terminal_response_type, 0x1400);
    }

    #[test]
    fn terminal_error_takes_priority_over_completion_for_affected_target() {
        let mut state = ProductionState::EMPTY;
        state.publish_success(20);
        state.publish_error(12, 0x1200).unwrap();
        assert_eq!(state.observe(11), Observe::Complete);
        assert_eq!(state.observe(12), Observe::TerminalError(0x1200));
        assert_eq!(state.observe(21), Observe::TerminalError(0x1200));
    }

    #[test]
    fn pending_is_never_reported_complete() {
        let mut state = ProductionState::EMPTY;
        state.publish_success(3);
        assert_eq!(state.observe(4), Observe::Pending);
    }
}
