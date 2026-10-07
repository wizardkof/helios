use bytemuck::Zeroable;
// Extracted .315-derived production wrapper; OS Section decision and wire container are mock seams. NOT WDK/runtime proof.
use helios_protocol::attest_transport::{AttestTransport,QUERY,ATTEST};
type NTSTATUS=i32;
mod wdk_sys {pub const STATUS_SUCCESS:i32=0;pub const STATUS_INVALID_PARAMETER:i32=0xc000000du32 as i32;pub const STATUS_INVALID_HANDLE:i32=0xc0000008u32 as i32;pub const STATUS_UNSUCCESSFUL:i32=0xc0000001u32 as i32;}
thread_local! {static CLASS:std::cell::Cell<u32>=const {std::cell::Cell::new(0)};static STATUS:std::cell::Cell<i32>=const {std::cell::Cell::new(0)};static CALLS:std::cell::Cell<u32>=const {std::cell::Cell::new(0)};}
mod section_attest {pub fn attest(r:&mut helios_protocol::HeliosEscapeP06ProductionCarrier)->i32 {super::CALLS.with(|c|c.set(c.get()+1));assert_eq!(r.op,9);assert_eq!(r.user_handle,42);assert_eq!(r.carrier_id,[2;16]);assert_eq!(r.expected_record_version,2);super::CLASS.with(|c|r.status=c.get());super::STATUS.with(|s|s.get())}}
mod ddi {pub mod escape {
 pub static ESCAPE_BAD_HEADER:std::sync::atomic::AtomicU32=std::sync::atomic::AtomicU32::new(0);
 pub struct EscapeBuf<'a,T>{b:&'a mut[u8],p:std::marker::PhantomData<T>}
 impl<'a,T:bytemuck::Pod> EscapeBuf<'a,T>{pub fn new(b:&'a mut[u8],_h:&helios_protocol::HeliosEscapeHeader)->Result<Self,i32>{if b.len()!=std::mem::size_of::<T>(){return Err(super::super::wdk_sys::STATUS_INVALID_PARAMETER)}Ok(Self{b,p:std::marker::PhantomData})}pub fn read(&self)->T{bytemuck::pod_read_unaligned(self.b)}pub fn write_back(&mut self,t:&T){self.b.copy_from_slice(bytemuck::bytes_of(t));}}
}}
pub(crate) fn escape_attest_transport(
    buf: &mut [u8], hdr: &helios_protocol::HeliosEscapeHeader,
) -> NTSTATUS {
    use helios_protocol::attest_transport::{AttestTransport, ATTEST};
    let actual = buf.len();
    let mut wire = match crate::ddi::escape::EscapeBuf::<AttestTransport>::new(buf, hdr) {
        Ok(wire) => wire, Err(status) => return status,
    };
    let request = wire.read();
    if !request.valid_request(actual) {
        crate::ddi::escape::ESCAPE_BAD_HEADER.fetch_add(1, core::sync::atomic::Ordering::Relaxed);
        return wdk_sys::STATUS_INVALID_PARAMETER;
    }
    let mut class = 0;
    if request.operation == ATTEST {
        let mut decision = helios_protocol::HeliosEscapeP06ProductionCarrier::zeroed();
        decision.op = helios_protocol::HELIOS_P06_PRODUCTION_ATTEST_HANDLE;
        decision.user_handle = request.user_handle;
        decision.carrier_id = request.carrier_id;
        decision.expected_record_version = request.expected_record_version;
        decision.status = u32::MAX;
        let status = section_attest::attest(&mut decision);
        class = decision.status;
        if !((status == wdk_sys::STATUS_SUCCESS && class == 0)
            || (status == wdk_sys::STATUS_INVALID_HANDLE && (1..=7).contains(&class))) {
            return wdk_sys::STATUS_UNSUCCESSFUL;
        }
    }
    match request.complete(class) {
        Some(response) => { wire.write_back(&response); wdk_sys::STATUS_SUCCESS }
        None => wdk_sys::STATUS_UNSUCCESSFUL,
    }
}

fn call(q:AttestTransport,class:u32,status:i32)->(i32,AttestTransport,u32){CLASS.with(|c|c.set(class));STATUS.with(|c|c.set(status));CALLS.with(|c|c.set(0));let mut b=bytemuck::bytes_of(&q).to_vec();let s=escape_attest_transport(&mut b,&q.hdr);(s,bytemuck::pod_read_unaligned(&b),CALLS.with(|c|c.get()))}
#[test]fn query_does_not_attest_a_carrier(){let q=AttestTransport::request(QUERY,[1;16],0,[0;16],0);let(s,r,n)=call(q,7,-1);assert_eq!(s,0);assert_eq!(n,0);assert!(r.valid_response(&q,120));assert_eq!(r.capabilities,1);}
#[test]fn real_wrapper_transports_every_semantic_class(){for c in 0..8{let q=AttestTransport::request(ATTEST,[1;16],42,[2;16],2);let(s,r,n)=call(q,c,if c==0{0}else{wdk_sys::STATUS_INVALID_HANDLE});assert_eq!(s,0);assert_eq!(n,1);assert!(r.valid_response(&q,120));assert_eq!(r.refusal_class,c);assert_eq!(r.accepted,u32::from(c==0));}}
#[test]fn inconsistent_internal_decision_does_not_publish(){for(c,s)in [(0,wdk_sys::STATUS_INVALID_HANDLE),(1,0),(8,wdk_sys::STATUS_INVALID_HANDLE),(1,-1)]{let q=AttestTransport::request(ATTEST,[1;16],42,[2;16],2);let(status,r,n)=call(q,c,s);assert_ne!(status,0);assert_eq!(n,1);assert_eq!(bytemuck::bytes_of(&q),bytemuck::bytes_of(&r));assert!(!r.valid_response(&q,120));}}
#[test]fn malformed_frame_refuses_before_decision(){let mut q=AttestTransport::request(ATTEST,[1;16],42,[2;16],2);q.valid_marker=1;let(s,r,n)=call(q,0,0);assert_ne!(s,0);assert_eq!(n,0);assert_eq!(bytemuck::bytes_of(&q),bytemuck::bytes_of(&r));}
