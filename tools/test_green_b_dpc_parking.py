#!/usr/bin/env python3
"""Execute the exact DMA parking method with a destructor/IRQL seam."""
import argparse, pathlib, subprocess, hashlib, json
parser=argparse.ArgumentParser();parser.add_argument('--output-dir',required=True);args=parser.parse_args()
h=pathlib.Path(__file__).resolve().parents[1];a=pathlib.Path(args.output_dir);a.mkdir(parents=True,exist_ok=True)
s=(h/'kmd_render/src/virtio/gpu/mod.rs').read_text();start=s.index('    fn park_drained(');i=s.index('{',start);j=i+1;depth=1
while depth:
 depth+=(s[j]=='{')-(s[j]=='}');j+=1
method=s[start:j]
fixture=r"""
use std::sync::atomic::{AtomicUsize,Ordering};
static DROPS:AtomicUsize=AtomicUsize::new(0);
static IRQL:AtomicUsize=AtomicUsize::new(0);
static PARKED_LEAKS:AtomicUsize=AtomicUsize::new(0);
static PARKED_HIGH_WATER:AtomicUsize=AtomicUsize::new(0);
const MAX_PARKED:usize=2;
fn bump_high_water(v:&AtomicUsize,n:usize){v.fetch_max(n,Ordering::Relaxed);}
struct InFlight(u8);
impl Drop for InFlight{fn drop(&mut self){assert_eq!(IRQL.load(Ordering::SeqCst),0,"DMA released above PASSIVE");DROPS.fetch_add(1,Ordering::SeqCst);}}
struct Transport{parked:Vec<InFlight>}
impl Transport {
"""+method+r"""
}
#[test]fn normal_and_overflow_never_release_at_dispatch(){
 let mut t=Transport{parked:Vec::with_capacity(MAX_PARKED)};
 IRQL.store(2,Ordering::SeqCst);
 t.park_drained(InFlight(1));t.park_drained(InFlight(1));t.park_drained(InFlight(1));
 assert_eq!(DROPS.load(Ordering::SeqCst),0);
 assert_eq!(t.parked.len(),2);assert_eq!(t.parked.capacity(),2);
 assert_eq!(PARKED_HIGH_WATER.load(Ordering::SeqCst),2);
 assert_eq!(PARKED_LEAKS.load(Ordering::SeqCst),1);
 IRQL.store(0,Ordering::SeqCst);t.parked.clear();
 assert_eq!(DROPS.load(Ordering::SeqCst),2);
}
"""
p=a/'dpc-parking-extracted.rs';p.write_text(fixture)
(a/'dpc-parking-source.sha256.txt').write_text(hashlib.sha256(s.encode()).hexdigest()+'  kmd_render/src/virtio/gpu/mod.rs\n')
r=subprocess.run(['rustc','--edition=2021','--test',str(p),'-o',str(a/'dpc-parking-test')],capture_output=True,text=True)
if r.returncode==0:r=subprocess.run([str(a/'dpc-parking-test')],capture_output=True,text=True)
(a/'dpc-parking-receipt.json').write_text(json.dumps({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr},indent=2))
print(r.stdout,r.stderr);raise SystemExit(r.returncode)
