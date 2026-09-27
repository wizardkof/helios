#[cfg(test)]
mod tests {
    #[derive(Clone, Copy, Debug, PartialEq)]
    enum RegisterResult {
        Registered,
        AlreadyComplete,
        AlreadyError(u32),
        Invalid,
        TableFull,
        Duplicate,
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    enum UnregisterResult {
        Cancelled,
        Success,
        Error(u32),
        NotFound,
    }

    fn register_observation(result: &RegisterResult) -> (u64, u64) {
        match result {
            RegisterResult::Registered => (1, 0),
            RegisterResult::AlreadyComplete => (2, 0),
            RegisterResult::AlreadyError(response) => (3, *response as u64),
            RegisterResult::Invalid => (4, 0),
            RegisterResult::TableFull => (5, 0),
            RegisterResult::Duplicate => (6, 0),
        }
    }

    fn unregister_observation(result: &UnregisterResult) -> (u64, u64) {
        match result {
            UnregisterResult::Cancelled => (1, 0),
            UnregisterResult::Success => (2, 0),
            UnregisterResult::Error(response) => (3, *response as u64),
            UnregisterResult::NotFound => (4, 0),
        }
    }

    #[test]
    fn observing_register_result_preserves_the_exact_return_value() {
        let cases = [
            (RegisterResult::Registered, 1u64, 0u64),
            (RegisterResult::AlreadyComplete, 2u64, 0u64),
            (RegisterResult::AlreadyError(0x1200), 3u64, 0x1200u64),
            (RegisterResult::Invalid, 4u64, 0u64),
            (RegisterResult::TableFull, 5u64, 0u64),
            (RegisterResult::Duplicate, 6u64, 0u64),
        ];
        for (result, expected_code, expected_response) in cases {
            let mut observed = None;
            let returned = super::observe_result_preserving(result, |value| {
                observed = Some(super::tests::register_observation(value));
            });
            assert_eq!(returned, result);
            assert_eq!(observed, Some((expected_code, expected_response)));
        }
    }

    #[test]
    fn observing_unregister_result_preserves_exact_status_and_response() {
        let cases = [
            (UnregisterResult::Cancelled, (1, 0)),
            (UnregisterResult::Success, (2, 0)),
            (UnregisterResult::Error(0x1200), (3, 0x1200)),
            (UnregisterResult::NotFound, (4, 0)),
        ];
        for (result, expected) in cases {
            let mut observed = None;
            let returned = super::observe_result_preserving(result, |value| {
                observed = Some(super::tests::unregister_observation(value));
            });
            assert_eq!(returned, result);
            assert_eq!(observed, Some(expected));
        }
    }
}

/// Run an observer on a result while returning the exact result unchanged.
/// The observer must be bounded and nonblocking when called from kernel paths.
#[inline]
pub fn observe_result_preserving<T>(result: T, observer: impl FnOnce(&T)) -> T {
    observer(&result);
    result
}
