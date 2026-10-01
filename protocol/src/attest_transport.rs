//! Versioned, classified ATTEST transport. See docs/p06/ATTEST_TRANSPORT_V1.md.
use bytemuck::{Pod,Zeroable};
use crate::{HeliosEscapeHeader,HELIOS_ESCAPE_MAGIC,HELIOS_ESCAPE_VERSION};
pub const QUERY:u32=0x19;
pub const ATTEST:u32=0x1a;
pub const VALID:u32=0x41545431;
#[repr(C,align(8))]
#[derive(Clone,Copy,Pod,Zeroable)]
pub struct AttestTransport {
 pub hdr:HeliosEscapeHeader,
 pub transport_version:u32,pub operation:u32,pub request_id:[u8;16],
 pub user_handle:u64,pub carrier_id:[u8;16],pub expected_record_version:u32,pub reserved:u32,
 pub response_version:u32,pub response_size:u32,pub response_operation:u32,pub valid_marker:u32,
 pub response_id:[u8;16],pub accepted:u32,pub refusal_class:u32,
 pub capabilities:u32,pub supported_record_version:u32,
}
impl AttestTransport {
 pub fn request(op:u32,id:[u8;16],handle:u64,carrier:[u8;16],record:u32)->Self {
  let mut r=Self::zeroed();
  r.hdr.magic=HELIOS_ESCAPE_MAGIC;r.hdr.cmd_type=op;r.hdr.version=HELIOS_ESCAPE_VERSION;r.hdr.size=120;
  r.transport_version=1;r.operation=op;r.request_id=id;
  if op==ATTEST {r.user_handle=handle;r.carrier_id=carrier;r.expected_record_version=record;}
  r
 }
 pub fn valid_request(&self,actual:usize)->bool {
  actual==120 && self.hdr.magic==HELIOS_ESCAPE_MAGIC && self.hdr.version==HELIOS_ESCAPE_VERSION && self.hdr.size==120
  && matches!(self.operation,QUERY|ATTEST) && self.hdr.cmd_type==self.operation
  && self.transport_version==1 && self.reserved==0 && self.request_id!=[0;16]
  && bytemuck::bytes_of(self)[72..].iter().all(|x|*x==0)
  && (self.operation!=QUERY || (self.user_handle==0 && self.carrier_id==[0;16] && self.expected_record_version==0))
 }
 pub fn complete(&self,class:u32)->Option<Self> {
  if !self.valid_request(120) || class>7 {return None;}
  let mut r=*self;
  r.response_version=1;r.response_size=120;r.response_operation=self.operation;
  r.valid_marker=VALID;r.response_id=self.request_id;
  r.accepted=u32::from(self.operation==ATTEST && class==0);
  r.refusal_class=if self.operation==QUERY {0} else {class};
  r.capabilities=1;r.supported_record_version=2;Some(r)
 }
 pub fn valid_response(&self,expected:&Self,actual:usize)->bool {
  if actual!=120 || !expected.valid_request(120) || bytemuck::bytes_of(self)[..72]!=bytemuck::bytes_of(expected)[..72] {return false;}
  self.response_version==1 && self.response_size==120 && self.response_operation==expected.operation
  && self.valid_marker==VALID && self.response_id==expected.request_id
  && self.capabilities==1 && self.supported_record_version==2
  && if expected.operation==QUERY {self.accepted==0 && self.refusal_class==0}
     else {(self.accepted==1 && self.refusal_class==0)||(self.accepted==0 && (1..=7).contains(&self.refusal_class))}
 }
}
const _:()={assert!(core::mem::size_of::<AttestTransport>()==120);assert!(core::mem::align_of::<AttestTransport>()==8);};
