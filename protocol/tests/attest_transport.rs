use helios_protocol::attest_transport::*;
use bytemuck::Zeroable;
#[test]
fn layout() {
 assert_eq!(core::mem::size_of::<AttestTransport>(),120);
 assert_eq!(core::mem::align_of::<AttestTransport>(),8);
 assert_eq!(core::mem::offset_of!(AttestTransport,request_id),24);
 assert_eq!(core::mem::offset_of!(AttestTransport,user_handle),40);
 assert_eq!(core::mem::offset_of!(AttestTransport,response_version),72);
 assert_eq!(core::mem::offset_of!(AttestTransport,response_id),88);
}
#[test]
fn query_and_every_verdict() {
 for op in [QUERY,ATTEST] {
  let q=AttestTransport::request(op,[1;16],42,[2;16],2);
  assert!(q.valid_request(120));
  assert!(!q.valid_response(&q,120));
  for class in 0..8 {
   let r=q.complete(class).unwrap();
   assert!(r.valid_response(&q,120));
   assert_eq!(r.accepted,u32::from(op==ATTEST && class==0));
   assert_eq!(r.refusal_class,if op==QUERY {0} else {class});
   assert!(!r.valid_request(120));
  }
  assert!(q.complete(8).is_none());
 }
}
#[test]
fn malformed_and_stale() {
 let q=AttestTransport::request(ATTEST,[1;16],42,[2;16],2);
 for size in [0,16,119,121] {assert!(!q.valid_request(size));}
 let mut bad=q;bad.transport_version=2;assert!(!bad.valid_request(120));
 bad=q;bad.hdr.size=119;assert!(!bad.valid_request(120));
 bad=q;bad.request_id=[0;16];assert!(!bad.valid_request(120));
 bad=q;bad.operation=QUERY;assert!(!bad.valid_request(120));
 let r=q.complete(0).unwrap();
 for offset in 0..120 {
  let mut b=r;bytemuck::bytes_of_mut(&mut b)[offset]^=0x80;
  assert!(!b.valid_response(&q,120),"offset {offset}");
 }
 let other=AttestTransport::request(ATTEST,[2;16],42,[2;16],2);
 assert!(!r.valid_response(&other,120));
 bad=r;bad.accepted=0;assert!(!bad.valid_response(&q,120));
 bad=q.complete(1).unwrap();bad.accepted=1;assert!(!bad.valid_response(&q,120));
 assert!(!AttestTransport::zeroed().valid_response(&q,120));
}
#[test]
fn concurrent_calls_do_not_exchange_responses() {
 let threads:Vec<_>=(1u64..=16).map(|n|std::thread::spawn(move || {
  let mut id=[0;16];id[..8].copy_from_slice(&n.to_le_bytes());
  let q=AttestTransport::request(ATTEST,id,n,[2;16],2);
  let r=q.complete((n%8) as u32).unwrap();
  assert!(r.valid_response(&q,120));
  id[8]=1;
  let other=AttestTransport::request(ATTEST,id,n,[2;16],2);
  assert!(!r.valid_response(&other,120));
 })).collect();
 for t in threads {t.join().unwrap();}
}
