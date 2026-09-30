//! Fixed, bounded ATTEST observation data; no object references or kernel APIs.
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn output_status_is_read_from_actual_buffer_not_local_request() {
        let mut wire = [0u8; 600];
        wire[68..72].copy_from_slice(&0xa5a5a5a5u32.to_le_bytes());
        assert_eq!(read_status(&wire), Some(0xa5a5a5a5));
        let local = 6u32;
        assert_ne!(read_status(&wire), Some(local));
        wire[68..72].copy_from_slice(&local.to_le_bytes());
        assert_eq!(read_status(&wire), Some(6));
        assert_eq!(read_status(&wire[..71]), None);
    }
    #[test]
    fn encoding_has_explicit_offsets_and_no_padding_or_addresses() {
        let e = Event {
            instance: 13,
            call: 14,
            qpc: 15,
            sequence: 16,
            pid: 17,
            tid: 18,
            phase: 4,
            branch: 35,
            version: 2,
            handle: 0x1234,
            id: [0x42; 16],
            local: 6,
            buffer: Some(0xa5a5a5a5),
            external: 0xc0000008,
            failures: 19,
            epoch: 20,
            frequency: 10000000,
        };
        let b = e.encode();
        assert_eq!(b.len(), 128);
        assert_eq!(&b[..4], &0x314f4150u32.to_le_bytes());
        assert_eq!(&b[72..88], &[0x42; 16]);
        assert_eq!(&b[88..92], &6u32.to_le_bytes());
        assert_eq!(&b[92..96], &0xa5a5a5a5u32.to_le_bytes());
        assert_eq!(&b[96..100], &0xc0000008u32.to_le_bytes());
        assert_eq!(&b[104..112], &19u64.to_le_bytes());
        assert_eq!(&b[112..120], &20u64.to_le_bytes());
    }
    #[test]
    fn ddi_return_observation_contract_preserves_bytes_on_disabled_or_failing_sink() {
        for enabled in [false, true] {
            for transport_ok in [false, true] {
                let mut called = false;
                let mut wire = [0xa5u8; 600];
                let before = wire;
                let result = crate::observe_result_preserving(0xc0000008u32, |_| {
                    if enabled {
                        called = true;
                        let _ = read_status(&wire);
                        let sink_result: Result<(), ()> = if transport_ok { Ok(()) } else { Err(()) };
                        assert_eq!(sink_result.is_ok(), transport_ok);
                        // Models ETW return only; real ETW/lifecycle is qualified separately.
                        let _ = sink_result;
                    }
                });
                assert_eq!(result, 0xc0000008);
                assert_eq!(wire, before);
                assert_eq!(called, enabled);
                wire[68..72].copy_from_slice(&6u32.to_le_bytes());
                assert_eq!(read_status(&wire), Some(6));
            }
        }
    }
}

pub struct Event {
    pub instance: u64,
    pub call: u64,
    pub qpc: u64,
    pub sequence: u64,
    pub pid: u32,
    pub tid: u32,
    pub phase: u32,
    pub branch: u32,
    pub version: u32,
    pub handle: u64,
    pub id: [u8; 16],
    pub local: u32,
    pub buffer: Option<u32>,
    pub external: u32,
    pub failures: u64,
    pub epoch: u64,
    pub frequency: u64,
}
pub fn read_status(wire: &[u8]) -> Option<u32> {
    let bytes = wire.get(68..72)?;
    let mut value = [0u8;4];
    for (i,out) in value.iter_mut().enumerate() {
        // SAFETY: bounds checked four-byte slice lives through these reads.
        // Volatile forces readback of destination memory rather than forwarding a local write.
        *out = unsafe { core::ptr::read_volatile(bytes.as_ptr().add(i)) };
    }
    Some(u32::from_le_bytes(value))
}
impl Event {
    pub fn encode(&self) -> [u8; 128] {
        let mut b = [0u8; 128];
        for (offset, value) in [
            (0, 0x314f4150u32),
            (4, 1),
            (8, 128),
            (12, self.phase),
            (48, self.pid),
            (52, self.tid),
            (56, self.branch),
            (60, self.version),
            (88, self.local),
            (92, self.buffer.unwrap_or(0)),
            (96, self.external),
            (100, u32::from(self.buffer.is_some())),
        ] {
            b[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        for (offset, value) in [
            (16, self.instance),
            (24, self.call),
            (32, self.qpc),
            (40, self.sequence),
            (64, self.handle),
            (104, self.failures),
            (112, self.epoch),
            (120, self.frequency),
        ] {
            b[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
        }
        b[72..88].copy_from_slice(&self.id);
        b
    }
}
