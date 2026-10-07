#include "common.hpp"
using namespace p06;
static int pair_run(const std::string& mode){
 bool e1=mode!="legacy",lifetime=mode=="lifetime";
 const char* gate=getenv("HELIOS_P06_E1_CARRIER_EXPORT");require(e1?(gate&&strcmp(gate,"1")==0):gate==nullptr,"Fresh-process gate environment mismatch");
 std::wstring name;
 {
  Vulkan v;v.open();
  if(e1)v.work();
  Semaphore sem(v,true);Handle one=v.export_handle(sem.s);Record a{};bool signature=snapshot(one.h,a,e1);require(signature==e1,"Legacy/E1 carrier discrimination");
  printf("HANDLE_PATH=%s\n",e1?"E1_V2_SECTION":"LEGACY_WDDM_NO_V2_SIGNATURE");
  if(e1)name=object_name(one.h);
  Child child(sibling_pair());require(child.call(Import,one.h,0,0,e1).result==VK_SUCCESS,"Consumer public Vulkan import");
  if(!e1){v.work(sem.s);require(child.call(Wait,nullptr,7,5000000000ULL,false).result==VK_SUCCESS,"Legacy consumer synchronization");auto count=child.call(Counter);require(count.result==VK_SUCCESS&&count.value>=7,"Legacy consumer counter");printf("LEGACY_MATRIX=PASS\n");}
  else {
   auto count=child.call(Counter);require(count.result==VK_SUCCESS&&count.value==a.completed_value,"E1 imported counter after caller handle close");
   if(lifetime){Handle two=v.export_handle(sem.s);Record b{};snapshot(two.h,b,true);require(memcmp(a.carrier_id,b.carrier_id,16)==0,"Repeated exports identity");one.reset();sem.reset();count=child.call(Counter);require(count.result==VK_SUCCESS&&count.value==a.completed_value,"Consumer survives producer semaphore destruction");Child late(sibling_pair());require(late.call(Import,two.h,0,0,true).result==0,"Late import after exporter semaphore destruction");two.reset();require(late.call(Counter).result==0,"Late importer owns independent duplicate");late.finish();printf("VULKAN_PRODUCER_SEMAPHORE_LIFETIME=PASS\n");}
   printf("E1_PUBLIC_EXPORT_IMPORT=PASS SOURCE_PATH=PINNED_MESA_CLASSIFY_ATTEST_WITH_NO_FALLBACK\n");
  }
  child.finish();one.reset();sem.reset();
 }
 if(e1)reclaimed(name);
 return 0;
}
int main(int argc,char**argv){try{process_evidence(argc,argv);require(argc>=2,"Mode required");std::string mode=argv[1];if(mode=="--smoke"){printf("ABI_SMOKE=PASS REQUEST=%zu RECORD=%zu PACKET=%zu REPLY=%zu DRIVER_CALLS=0\n",sizeof(CarrierRequest),sizeof(Record),sizeof(Packet),sizeof(Reply));return 0;}if(mode=="--consumer"){require(argc==3,"Consumer reply handle required");int r=consumer((HANDLE)(uintptr_t)strtoull(argv[2],nullptr,10));require(cleanup_ok,"Consumer cleanup");return r;}require(mode=="legacy"||mode=="e1"||mode=="lifetime","Unknown pair mode");pair_run(mode);require(cleanup_ok,"Pair cleanup");printf("CASE=%s RESULT=PASS\n",mode.c_str());return 0;}catch(const std::exception&e){fprintf(stderr,"FIRST_DIVERGENCE PID=%lu MESSAGE=%s CLEANUP_OK=%d\n",GetCurrentProcessId(),e.what(),int(cleanup_ok));return 1;}}
