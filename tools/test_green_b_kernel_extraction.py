#!/usr/bin/env python3
"""Compile the exact production broker under deterministic CPU/OS seams."""
import json,pathlib,subprocess,os,argparse,hashlib,sys
parser=argparse.ArgumentParser();parser.add_argument('--output-dir',required=True);args=parser.parse_args();h=pathlib.Path(__file__).resolve().parents[1];a=pathlib.Path(args.output_dir).resolve();a.mkdir(parents=True,exist_ok=True);d=a/'kmd-production-extraction';(d/'src').mkdir(parents=True,exist_ok=True)
(d/'Cargo.toml').write_text(f'''[package]\nname="green_b_production_extraction"\nversion="0.0.0"\nedition="2021"\n[dependencies]\nhelios_protocol={{path="{h}/protocol"}}\nhelios_kmd_logic={{path="{h}/kmd_logic"}}\nbytemuck={{version="1",features=["derive"]}}\n''')
(d/'src/lib.rs').write_text(r'''
#![allow(non_snake_case,dead_code,unused_imports)]
extern crate alloc;
extern crate self as wdk_sys;
pub type PVOID=*mut core::ffi::c_void;
pub type NTSTATUS=i32;
pub const STATUS_SUCCESS:i32=0;
pub const STATUS_INVALID_PARAMETER:i32=-1;
pub const STATUS_UNSUCCESSFUL:i32=-2;
#[repr(C)]
pub struct FakeSection {pub record:helios_protocol::HeliosP06ProductionSectionRecord,pub refs:core::sync::atomic::AtomicUsize}
pub struct FakeEvent {pub refs:core::sync::atomic::AtomicUsize,pub signals:core::sync::atomic::AtomicUsize}
pub mod ntddk {
 use super::*;
 pub unsafe fn MmMapViewInSystemSpace(object:PVOID,view:*mut PVOID,size:*mut u64)->i32{
    *view=object;*size=4096;0
 }
 pub unsafe fn MmUnmapViewInSystemSpace(_:PVOID)->i32{0}
 pub unsafe fn KeSetEvent(event:*mut FakeEvent,_:i32,_:i32)->i32{
    if !event.is_null(){(*event).signals.fetch_add(1,core::sync::atomic::Ordering::Relaxed);}0
 }
}
pub mod diag{pub fn record_named_bytes(_: &[u8],_:u32){}}
pub mod irql {#[derive(Clone,Copy)]pub struct PassiveLevel;}
pub mod virtio {
 pub mod gpu {#[derive(Clone,Copy)]pub struct DeviceOwner(pub usize);impl DeviceOwner{pub fn raw(self)->usize{self.0}}}
 pub mod ctrl {
  use super::gpu::DeviceOwner;use crate::{adapter::AdapterContext,irql::PassiveLevel};
  pub(crate) fn submit_venus_async_e1(_:PassiveLevel,_:&AdapterContext,_:DeviceOwner,ctx:u32,_:u32,_:&[u8],_:u64,_:u32,b:crate::adapter::green_b::Batch)->Result<u64,()>{
    assert!(b.associate(7,9,ctx));b.outcome(7,9,ctx,0);Ok(9)
  }
 }
}
pub mod ddi {pub mod escape {
 use core::{ptr::NonNull,sync::atomic::Ordering};use crate::FakeEvent;
 pub fn reference_user_event(h:u64)->Option<NonNull<FakeEvent>>{let p=NonNull::new(h as *mut FakeEvent)?;
    unsafe{p.as_ref().refs.fetch_add(1,Ordering::Relaxed);}Some(p)}
 pub fn dereference_user_event(p:NonNull<FakeEvent>){unsafe{assert!(p.as_ref().refs.fetch_sub(1,Ordering::Relaxed)>0);}}
}}
pub mod adapter {
 use core::{cell::UnsafeCell,sync::atomic::{AtomicUsize,AtomicU32}};
 pub struct AdapterContext {pub green_b_broker:AtomicUsize,pub hpd_stop:AtomicU32,pub hpd_thread:AtomicUsize,
   pub hpd_event:UnsafeCell<crate::FakeEvent>,pub mutex:std::sync::Mutex<()>}
 impl AdapterContext{pub fn new()->Self{Self{green_b_broker:AtomicUsize::new(0),hpd_stop:AtomicU32::new(0),hpd_thread:AtomicUsize::new(1),
    hpd_event:UnsafeCell::new(crate::FakeEvent{refs:AtomicUsize::new(0),signals:AtomicUsize::new(0)}),mutex:std::sync::Mutex::new(())}}}
 pub mod section_attest {
  use crate::{PVOID,FakeSection};use core::sync::atomic::Ordering;
  pub struct ObjectRef(pub PVOID);
  impl Drop for ObjectRef{fn drop(&mut self){unsafe{assert!((*(self.0 as *mut FakeSection)).refs.fetch_sub(1,Ordering::Relaxed)>0);}}}
  pub fn reference_attested(h:u64,id:[u8;16])->Option<ObjectRef>{if h==0{return None;}
    let s=unsafe{&*(h as *const FakeSection)};if s.record.carrier_id!=id{return None;}
    s.refs.fetch_add(1,Ordering::Relaxed);Some(ObjectRef(h as PVOID))}
 }
 pub mod section_probe {
  use super::AdapterContext;use helios_kmd_logic::production_carrier::ProductionState;
  pub fn with_slots<R>(a:&AdapterContext,f:impl FnOnce(&mut [();1])->R)->Result<R,i32>{
    let _g=a.mutex.lock().unwrap();Ok(f(&mut[()]))}
  pub fn write_production_record(v:usize,id:[u8;16],seq:u64,state:ProductionState){
    unsafe{let r=&mut *(v as *mut helios_protocol::HeliosP06ProductionSectionRecord);
      r.carrier_id=id;r.sequence=seq*2;r.completed_value=state.completed_value;
      r.terminal_error_value=state.terminal_error_value;r.terminal_response_type=state.terminal_response_type;}
  }
 }
 pub mod green_b {
''')
# Extract exact production module, only module-doc syntax adapted for include.
s=(h/'kmd_render/src/adapter/green_b.rs').read_text();(a/'kmd-extracted-source.sha256.txt').write_text(hashlib.sha256(s.encode()).hexdigest()+'  kmd_render/src/adapter/green_b.rs\n');s='\n'.join('//'+l[3:] if l.startswith('//!') else l for l in s.splitlines())
with (d/'src/lib.rs').open('a') as f:
 f.write(s)
 f.write(r'''

 fn fixture()->(AdapterContext,alloc::boxed::Box<crate::FakeSection>,alloc::boxed::Box<crate::FakeEvent>){
    use core::sync::atomic::AtomicUsize;
    (AdapterContext::new(),alloc::boxed::Box::new(crate::FakeSection{record:HeliosP06ProductionSectionRecord{
    magic:HELIOS_P06_SECTION_MAGIC,version:2,size:64,carrier_id:[1;16],sequence:0,completed_value:0,
    terminal_error_value:0,terminal_response_type:0,reserved_tail:0},refs:AtomicUsize::new(0)}),
    alloc::boxed::Box::new(crate::FakeEvent{refs:AtomicUsize::new(0),signals:AtomicUsize::new(0)}))
 }

 #[test]fn zero_or_wrong_success_response_is_not_completion(){
    assert_ne!(completion_response(0),0);
    assert_ne!(completion_response(0x1101),0);
    assert_eq!(completion_response(0x1100),0);
    assert_eq!(completion_response(0x1200),0x1200);
 }
 #[test]fn rollback_releases_blocked_ready_higher_and_emits_wake(){
    let(a,mut s,_)=fixture();let handle=&mut *s as *mut _ as u64;
    let target=E1Target{carrier_handle:handle,target_value:1,carrier_id:[1;16]};
    let low=prepare(&a,&[target]).unwrap();let mut high=prepare(&a,&[E1Target{target_value:2,..target}]).unwrap();
    assert!(high.batch.associate(1,7,3));high.admit();high.batch.outcome(1,7,3,0);service(&a);
    assert_eq!(s.record.completed_value,0);
    let before=unsafe{&*a.hpd_event.get()}.signals.load(Ordering::Relaxed);
    drop(low);
    assert!(unsafe{&*a.hpd_event.get()}.signals.load(Ordering::Relaxed)>before);
    service(&a);assert_eq!(s.record.completed_value,2);release_all(&a);
 }

 #[test]fn dpc_device_loss_defers_cleanup_and_restart_preserves_token_generation(){
    let(a,mut s,mut event)=fixture();let handle=&mut *s as *mut _ as u64;
    let reg=E1Control::register([3;16],handle,&mut *event as *mut _ as u64,1,[1;16]);
    let mut bytes=bytemuck::bytes_of(&reg).to_vec();control(&a,DeviceOwner(7),&mut bytes);
    let first:E1Control=bytemuck::pod_read_unaligned(&bytes);
    notify_device_loss(&a);
    assert_eq!(event.refs.load(Ordering::Relaxed),1);assert_eq!(s.refs.load(Ordering::Relaxed),1);
    assert_eq!(s.record.terminal_response_type,0); /* DPC never publishes or drops refs */
    let q=E1Control::query([4;16]);let mut bytes=bytemuck::bytes_of(&q).to_vec();control(&a,DeviceOwner(7),&mut bytes);
    let denied:E1Control=bytemuck::pod_read_unaligned(&bytes);assert_eq!(denied.accepted,0);
    service(&a);assert_eq!(event.refs.load(Ordering::Relaxed),0);assert_eq!(s.refs.load(Ordering::Relaxed),0);
    reset_transport(&a);
    // New pending target on another carrier after Start, old token not reused.
    let(_,mut fresh,_)=fixture();fresh.record.carrier_id=[2;16];
    let reg=E1Control::register([5;16],&mut *fresh as *mut _ as u64,&mut *event as *mut _ as u64,1,[2;16]);
    let mut bytes=bytemuck::bytes_of(&reg).to_vec();control(&a,DeviceOwner(7),&mut bytes);
    let second:E1Control=bytemuck::pod_read_unaligned(&bytes);assert_eq!(second.accepted,1);assert_ne!(second.response_token,first.response_token);
    release_all(&a);assert_eq!(fresh.refs.load(Ordering::Relaxed),0);
 }
 #[test]fn stop_and_device_loss_cancel_unbound_pending_registration(){
    let(a,mut s,mut event)=fixture();let handle=&mut *s as *mut _ as u64;
    let reg=E1Control::register([3;16],handle,&mut *event as *mut _ as u64,1,[1;16]);
    let mut bytes=bytemuck::bytes_of(&reg).to_vec();control(&a,DeviceOwner(7),&mut bytes);
    abort_transport(&a);
    assert!(event.signals.load(Ordering::Relaxed)>0);
    assert_eq!(event.refs.load(Ordering::Relaxed),0);assert_eq!(s.refs.load(Ordering::Relaxed),0);
    assert_eq!(s.record.terminal_error_value,1);release_all(&a);
 }
 #[test]fn sequence_exhaustion_refused_before_admission(){
    let(a,mut s,_)=fixture();s.record.sequence=u64::MAX-1;
    let target=E1Target{carrier_handle:&mut *s as *mut _ as u64,target_value:1,carrier_id:[1;16]};
    assert!(prepare(&a,&[target]).is_none());assert_eq!(s.refs.load(Ordering::Relaxed),0);release_all(&a);
 }
 #[test]fn multi_waiter_unregister_and_adapter_teardown(){
    let(a,mut s,mut e)=fixture();let(_,_,mut second)=fixture();let handle=&mut *s as *mut _ as u64;
    for event in [&mut *e,&mut *second]{let reg=E1Control::register([3;16],handle,event as *mut _ as u64,1,[1;16]);
      let mut bytes=bytemuck::bytes_of(&reg).to_vec();assert_eq!(control(&a,DeviceOwner(7),&mut bytes),0);}
    let mut p=prepare(&a,&[E1Target{carrier_handle:handle,target_value:1,carrier_id:[1;16]}]).unwrap();
    assert!(p.batch.associate(1,2,3));p.admit();
    // Producer lifetime is absent from Batch. Teardown after transport drain
    // terminalizes independently owned record, wakes both consumers, drops refs.
    release_all(&a);assert_eq!(s.record.terminal_error_value,1);assert_eq!(s.record.terminal_response_type,0x1200);
    assert!(e.signals.load(Ordering::Relaxed)>0&&second.signals.load(Ordering::Relaxed)>0);
    assert_eq!(e.refs.load(Ordering::Relaxed),0);assert_eq!(second.refs.load(Ordering::Relaxed),0);assert_eq!(s.refs.load(Ordering::Relaxed),0);
 }
 #[test]fn capacity_partial_failure_and_generation_exhaustion(){
    let(a,mut s,mut event)=fixture();let handle=&mut *s as *mut _ as u64;
    let reg=E1Control::register([3;16],handle,&mut *event as *mut _ as u64,1,[1;16]);
    for _ in 0..R{let mut bytes=bytemuck::bytes_of(&reg).to_vec();control(&a,DeviceOwner(7),&mut bytes);
      let out:E1Control=bytemuck::pod_read_unaligned(&bytes);assert_eq!(out.accepted,1);}
    let mut bytes=bytemuck::bytes_of(&reg).to_vec();control(&a,DeviceOwner(7),&mut bytes);
    let out:E1Control=bytemuck::pod_read_unaligned(&bytes);assert_eq!(out.accepted,0);
    assert_eq!(event.refs.load(Ordering::Relaxed),R);release_owner(&a,7);
    assert_eq!(s.refs.load(Ordering::Relaxed),0);assert_eq!(event.refs.load(Ordering::Relaxed),0);
    let target=E1Target{carrier_handle:handle,target_value:1,carrier_id:[1;16]};
    assert!(prepare(&a,&[target,E1Target{carrier_id:[9;16],..target}]).is_none());assert_eq!(s.refs.load(Ordering::Relaxed),0);
    let b=broker(&a).unwrap();for e in &b.bindings{e.generation.store(u32::MAX as u64,Ordering::Relaxed);}
    assert!(prepare(&a,&[target]).is_none());release_all(&a);
 }
 #[test]fn production_interleavings_ownership_and_correlation(){
   use core::sync::atomic::AtomicUsize;
   let a=AdapterContext::new();let mut section=alloc::boxed::Box::new(crate::FakeSection{
      record:HeliosP06ProductionSectionRecord{magic:HELIOS_P06_SECTION_MAGIC,version:2,size:64,
      carrier_id:[1;16],sequence:0,completed_value:0,terminal_error_value:0,terminal_response_type:0,reserved_tail:0},refs:AtomicUsize::new(0)});
   let handle=&mut *section as *mut _ as u64;
   let mut event=alloc::boxed::Box::new(crate::FakeEvent{refs:AtomicUsize::new(0),signals:AtomicUsize::new(0)});
   let owner=DeviceOwner(44);let id=[2;16];
   let reg=E1Control::register(id,handle,&mut *event as *mut _ as u64,5,[1;16]);
   let mut bytes=bytemuck::bytes_of(&reg).to_vec();assert_eq!(control(&a,owner,&mut bytes),0);
   let response:E1Control=bytemuck::pod_read_unaligned(&bytes);assert!(response.valid_response(&reg,152));
   let token=response.response_token;assert_eq!(section.refs.load(Ordering::Relaxed),1);
   let target=E1Target{carrier_handle:handle,target_value:5,carrier_id:[1;16]};
   let mut p=prepare(&a,&[target]).unwrap();assert_eq!(section.refs.load(Ordering::Relaxed),2);
   assert!(p.batch.associate(7,9,1));p.admit();
   // Wrong fence, epoch and context never publish.
   p.batch.outcome(7,10,1,0);p.batch.outcome(8,9,1,0);p.batch.outcome(7,9,2,0);service(&a);
   assert_eq!(section.record.completed_value,0);
   p.batch.outcome(7,9,1,0);assert_eq!(section.record.completed_value,0);service(&a);
   assert_eq!(section.record.completed_value,5);assert_eq!(section.refs.load(Ordering::Relaxed),1);
   assert_eq!(event.signals.load(Ordering::Relaxed),1);p.batch.outcome(7,9,1,0);service(&a);
   assert_eq!(event.signals.load(Ordering::Relaxed),1);drop(p);
   // Completion before REGISTER must signal under the same publisher lock.
   let mut late=bytemuck::bytes_of(&reg).to_vec();assert_eq!(control(&a,owner,&mut late),0);
   assert_eq!(event.signals.load(Ordering::Relaxed),2);
   let unreg=E1Control::unregister([3;16],token);let mut u=bytemuck::bytes_of(&unreg).to_vec();
   assert_eq!(control(&a,DeviceOwner(45),&mut u),0);let denied:E1Control=bytemuck::pod_read_unaligned(&u);assert_eq!(denied.accepted,0);
   let mut u=bytemuck::bytes_of(&unreg).to_vec();assert_eq!(control(&a,owner,&mut u),0);
   assert_eq!(section.refs.load(Ordering::Relaxed),1);
   // Rollback and duplicate HANDLE folding retain and release exactly once.
   let target=E1Target{target_value:6,..target};let p=prepare(&a,&[target,target]).unwrap();assert_eq!(p.batch.len,1);
   assert!(p.batch.associate(7,10,1));p.batch.rollback_admission();drop(p);
   assert_eq!(section.refs.load(Ordering::Relaxed),1);
   // Out-of-order higher completion cannot expose success over lower error.
   let mut low=prepare(&a,&[target]).unwrap();let higher=E1Target{target_value:7,..target};let mut high=prepare(&a,&[higher]).unwrap();
   assert!(low.batch.associate(7,11,1));low.admit();assert!(high.batch.associate(7,12,1));high.admit();
   high.batch.outcome(7,12,1,0);service(&a);assert_eq!(section.record.completed_value,5);
   low.batch.outcome(7,11,1,0x1200);service(&a);assert_eq!(section.record.completed_value,7);
   assert_eq!(section.record.terminal_error_value,6);assert_eq!(section.record.terminal_response_type,0x1200);
   // Slot reuse cannot accept a stale completion from the previous generation.
   low.batch.outcome(7,11,1,0);service(&a);assert_eq!(section.record.terminal_response_type,0x1200);
   release_owner(&a,44);assert_eq!(event.refs.load(Ordering::Relaxed),0);assert_eq!(section.refs.load(Ordering::Relaxed),0);
   drop(low);drop(high);release_all(&a);assert_eq!(a.green_b_broker.load(Ordering::Relaxed),0);
 }
 }
}
''')
env=os.environ.copy();env['CARGO_TARGET_DIR']=str(h/'target/linux')
r=subprocess.run(['cargo','test','--offline','--manifest-path',str(d/'Cargo.toml')],env=env,capture_output=True,text=True)
for suf,v in [('stdout',r.stdout),('stderr',r.stderr),('exit',str(r.returncode))]:(a/('kmd-production-extraction.current.'+suf+'.txt')).write_text(v)
print(r.returncode,r.stdout[-1500:],r.stderr[-4000:])

sys.exit(r.returncode)
