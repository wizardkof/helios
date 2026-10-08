//! Versioned P06/E1 Green B control and submit envelopes.
//! ABI: e1-green-b-local-20261001/GREEN_B_ABI_V1.md.
use crate::{HeliosEscapeHeader, HELIOS_ESCAPE_MAGIC, HELIOS_ESCAPE_VERSION};
use bytemuck::{Pod, Zeroable};

pub const CONTROL: u32 = 0x1b;
pub const SUBMIT: u32 = 0x1c;
pub const SCHEMA_VERSION: u32 = 1;
pub const CONTROL_QUERY: u32 = 1;
pub const CONTROL_REGISTER: u32 = 2;
pub const CONTROL_UNREGISTER: u32 = 3;
pub const CONTROL_VALID: u32 = 0x4231_4531;
pub const SUBMIT_VALID: u32 = 0x4231_5331;
pub const MAX_TARGETS: u32 = 16;
pub const MAX_BINDINGS: u32 = 256;
pub const MAX_REGISTRATIONS: u32 = 256;

fn header(cmd: u32, size: u32) -> HeliosEscapeHeader {
    HeliosEscapeHeader {
        magic: HELIOS_ESCAPE_MAGIC,
        cmd_type: cmd,
        version: HELIOS_ESCAPE_VERSION,
        size,
    }
}

#[repr(C, align(8))]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct E1Control {
    pub hdr: HeliosEscapeHeader,
    pub schema_version: u32,
    pub operation: u32,
    pub request_id: [u8; 16],
    pub carrier_handle: u64,
    pub event_handle: u64,
    pub target_value: u64,
    pub registration_token: u64,
    pub carrier_id: [u8; 16],
    pub record_version: u32,
    pub reserved: u32,
    pub response_version: u32,
    pub response_size: u32,
    pub response_operation: u32,
    pub valid_marker: u32,
    pub response_id: [u8; 16],
    pub response_token: u64,
    pub accepted: u32,
    pub refusal: u32,
    pub capabilities: u32,
    pub max_registrations: u32,
}

impl E1Control {
    fn base(op: u32, id: [u8; 16]) -> Self {
        let mut value = Self::zeroed();
        value.hdr = header(CONTROL, 152);
        value.schema_version = SCHEMA_VERSION;
        value.operation = op;
        value.request_id = id;
        value
    }

    pub fn query(id: [u8; 16]) -> Self {
        Self::base(CONTROL_QUERY, id)
    }

    pub fn register(
        id: [u8; 16],
        carrier_handle: u64,
        event_handle: u64,
        target_value: u64,
        carrier_id: [u8; 16],
    ) -> Self {
        let mut value = Self::base(CONTROL_REGISTER, id);
        value.carrier_handle = carrier_handle;
        value.event_handle = event_handle;
        value.target_value = target_value;
        value.carrier_id = carrier_id;
        value.record_version = 2;
        value
    }

    pub fn unregister(id: [u8; 16], token: u64) -> Self {
        let mut value = Self::base(CONTROL_UNREGISTER, id);
        value.registration_token = token;
        value
    }

    pub fn valid_request(&self, actual: usize) -> bool {
        if actual != 152
            || self.hdr.magic != HELIOS_ESCAPE_MAGIC
            || self.hdr.cmd_type != CONTROL
            || self.hdr.version != HELIOS_ESCAPE_VERSION
            || self.hdr.size != 152
            || self.schema_version != SCHEMA_VERSION
            || self.request_id == [0; 16]
            || self.reserved != 0
            || bytemuck::bytes_of(self)[96..].iter().any(|byte| *byte != 0)
        {
            return false;
        }
        match self.operation {
            CONTROL_QUERY => bytemuck::bytes_of(self)[40..92].iter().all(|b| *b == 0),
            CONTROL_REGISTER => {
                self.carrier_handle != 0
                    && self.event_handle != 0
                    && self.target_value != 0
                    && self.registration_token == 0
                    && self.carrier_id != [0; 16]
                    && self.record_version == 2
            }
            CONTROL_UNREGISTER => {
                self.registration_token != 0
                    && bytemuck::bytes_of(self)[40..64].iter().all(|b| *b == 0)
                    && bytemuck::bytes_of(self)[72..92].iter().all(|b| *b == 0)
            }
            _ => false,
        }
    }

    pub fn complete(
        &self,
        accepted: u32,
        refusal: u32,
        token: u64,
        capabilities: u32,
        max_registrations: u32,
    ) -> Option<Self> {
        if !self.valid_request(152) || accepted > 1 || (accepted == 1) == (refusal != 0) {
            return None;
        }
        if accepted == 1
            && match self.operation {
                CONTROL_QUERY => token != 0 || capabilities & 3 != 3 || max_registrations == 0,
                CONTROL_REGISTER => token == 0,
                CONTROL_UNREGISTER => token != 0,
                _ => true,
            }
        {
            return None;
        }
        let mut out = *self;
        out.response_version = SCHEMA_VERSION;
        out.response_size = 152;
        out.response_operation = self.operation;
        out.valid_marker = CONTROL_VALID;
        out.response_id = self.request_id;
        out.response_token = token;
        out.accepted = accepted;
        out.refusal = refusal;
        out.capabilities = capabilities;
        out.max_registrations = max_registrations;
        Some(out)
    }

    pub fn valid_response(&self, request: &Self, actual: usize) -> bool {
        if actual != 152
            || !request.valid_request(152)
            || bytemuck::bytes_of(self)[..96] != bytemuck::bytes_of(request)[..96]
            || self.response_version != SCHEMA_VERSION
            || self.response_size != 152
            || self.response_operation != request.operation
            || self.valid_marker != CONTROL_VALID
            || self.response_id != request.request_id
            || self.accepted > 1
            || (self.accepted == 1) == (self.refusal != 0)
        {
            return false;
        }
        if self.accepted == 1 {
            match self.operation {
                CONTROL_QUERY => {
                    self.response_token == 0
                        && self.capabilities & 3 == 3
                        && self.max_registrations > 0
                }
                CONTROL_REGISTER => self.response_token != 0,
                CONTROL_UNREGISTER => self.response_token == 0,
                _ => false,
            }
        } else {
            self.response_token == 0
        }
    }
}

#[repr(C, align(8))]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct E1Target {
    pub carrier_handle: u64,
    pub target_value: u64,
    pub carrier_id: [u8; 16],
}

#[repr(C, align(8))]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct E1Submit {
    pub hdr: HeliosEscapeHeader,
    pub schema_version: u32,
    pub flags: u32,
    pub request_id: [u8; 16],
    pub fence_id: u64,
    pub ctx_id: u32,
    pub ring_idx: u32,
    pub stream_size: u32,
    pub target_count: u32,
    pub present_cookie: u64,
    pub present_value32: u32,
    pub reserved: u32,
    pub response_version: u32,
    pub response_size: u32,
    pub valid_marker: u32,
    pub response_status: u32,
    pub response_id: [u8; 16],
}

impl E1Submit {
    pub fn request(
        id: [u8; 16],
        ctx_id: u32,
        ring_idx: u32,
        stream_size: u32,
        target_count: u32,
    ) -> Self {
        let mut out = Self::zeroed();
        out.hdr = header(
            SUBMIT,
            112u32.saturating_add(target_count.saturating_mul(32)),
        );
        out.schema_version = SCHEMA_VERSION;
        out.request_id = id;
        out.ctx_id = ctx_id;
        out.ring_idx = ring_idx;
        out.stream_size = stream_size;
        out.target_count = target_count;
        out
    }

    fn valid_fixed_request(&self) -> bool {
        if self.hdr.magic != HELIOS_ESCAPE_MAGIC
            || self.hdr.cmd_type != SUBMIT
            || self.hdr.version != HELIOS_ESCAPE_VERSION
            || self.schema_version != SCHEMA_VERSION
            || self.flags != 0
            || self.request_id == [0; 16]
            || self.fence_id != 0
            || self.ctx_id == 0
            || self.ring_idx == 0
            || self.ring_idx > u8::MAX as u32
            || self.stream_size == 0
            || self.reserved != 0
            || self.target_count == 0
            || self.target_count > MAX_TARGETS
            || (self.present_cookie == 0) != (self.present_value32 == 0)
            || bytemuck::bytes_of(self)[80..].iter().any(|byte| *byte != 0)
        {
            return false;
        }
        self.hdr.size == 112 + self.target_count * 32
    }

    pub fn valid_request(&self, actual: usize, targets: &[E1Target]) -> bool {
        if !self.valid_fixed_request() || self.target_count as usize != targets.len() {
            return false;
        }
        let header_size = self.hdr.size as usize;
        header_size == 112 + targets.len() * 32
            && header_size.checked_add(self.stream_size as usize) == Some(actual)
            && targets
                .iter()
                .all(|t| t.carrier_handle != 0 && t.target_value != 0 && t.carrier_id != [0; 16])
    }

    pub fn complete(&self, fence_id: u64, actual: usize, targets: &[E1Target]) -> Option<Self> {
        if fence_id == 0 || !self.valid_request(actual, targets) {
            return None;
        }
        let mut out = *self;
        out.fence_id = fence_id;
        out.response_version = SCHEMA_VERSION;
        out.response_size = 112;
        out.valid_marker = SUBMIT_VALID;
        out.response_id = self.request_id;
        Some(out)
    }

    pub fn valid_response(&self, request: &Self, actual_header: usize) -> bool {
        actual_header == 112
            && request.valid_fixed_request()
            && bytemuck::bytes_of(self)[..40] == bytemuck::bytes_of(request)[..40]
            && bytemuck::bytes_of(self)[48..80] == bytemuck::bytes_of(request)[48..80]
            && self.fence_id != 0
            && self.response_version == SCHEMA_VERSION
            && self.response_size == 112
            && self.valid_marker == SUBMIT_VALID
            && self.response_status == 0
            && self.response_id == request.request_id
    }
}

const _: () = {
    assert!(core::mem::size_of::<E1Control>() == 152);
    assert!(core::mem::size_of::<E1Target>() == 32);
    assert!(core::mem::size_of::<E1Submit>() == 112);
};
