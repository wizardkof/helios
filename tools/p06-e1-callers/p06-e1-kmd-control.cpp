#include "common.hpp"
#include <aclapi.h>
#include "fixture_security.hpp"
#include <d3dkmthk.h>
using namespace p06;
#include "immediate_capture.hpp"
#define _Alignas alignas
#define _Alignof alignof
#define _Static_assert static_assert
#include "transport.h"
static const char* active_case="setup";
static unsigned call_sequence=0;
static unsigned unobserved_classifications=0;
struct Kmt {
 D3DKMT_HANDLE adapter=0,device=0;HMODULE gdi=nullptr;
 PFND3DKMT_ESCAPE escapeFn=nullptr;
 void open(const Vulkan& v){require(v.id.deviceLUIDValid!=0,"KMD control requires selected Vulkan LUID");gdi=LoadLibraryW(L"gdi32.dll");require(gdi!=nullptr,"gdi32");
  auto openAdapter=(PFND3DKMT_OPENADAPTERFROMLUID)GetProcAddress(gdi,"D3DKMTOpenAdapterFromLuid");auto createDevice=(PFND3DKMT_CREATEDEVICE)GetProcAddress(gdi,"D3DKMTCreateDevice");escapeFn=(PFND3DKMT_ESCAPE)GetProcAddress(gdi,"D3DKMTEscape");require(openAdapter&&createDevice&&escapeFn,"D3DKMT function availability");
  D3DKMT_OPENADAPTERFROMLUID a{};memcpy(&a.AdapterLuid,v.id.deviceLUID,8);NTSTATUS s=openAdapter(&a);printf("KMT_OPEN LUID=%s NTSTATUS=%08lx\n",hex(v.id.deviceLUID,8).c_str(),(unsigned long)s);require(s==0,"Open selected KMT adapter");adapter=a.hAdapter;
  D3DKMT_CREATEDEVICE d{};d.hAdapter=adapter;s=createDevice(&d);printf("KMT_CREATE_DEVICE NTSTATUS=%08lx DEVICE=%08x\n",(unsigned long)s,d.hDevice);require(s==0,"KMT create device");device=d.hDevice;
 }
 NTSTATUS call(CarrierRequest&r){r.status=0xa5a5a5a5;D3DKMT_ESCAPE e{};e.hAdapter=adapter;e.hDevice=device;e.Type=D3DKMT_ESCAPE_DRIVERPRIVATE;e.pPrivateDriverData=&r;e.PrivateDriverDataSize=sizeof(r);Capture c=capture_call(escapeFn,e);NTSTATUS s=c.external;
  const char* run=getenv("P06_DIAG_RUN_ID");
  printf("IMMEDIATE_CAPTURE RUN=%s CASE=%s SEQ=%u PID=%lu TID=%lu ARCH=%u PTR=%p SIZE=%zu NTSTATUS=%08lx QPC_BEGIN=%lld QPC_END=%lld QPC_FREQUENCY=%lld\n",run?run:"unset",active_case,++call_sequence,c.pid,c.tid,unsigned(sizeof(void*)*8),c.submitted,sizeof(r),(unsigned long)s,c.begin.QuadPart,c.end.QuadPart,c.frequency.QuadPart);
  printf("IMMEDIATE_BEFORE=%s\nIMMEDIATE_AFTER=%s\n",hex(c.before,sizeof(c.before)).c_str(),hex(c.after,sizeof(c.after)).c_str());fflush(stdout);
  require(memcmp(c.after,&r,sizeof(r))==0,"Snapshot differs before later wrapper parsing");
  printf("PRODUCTION_ESCAPE PID=%lu OP=%u NTSTATUS=%08lx STATUS=%u ID=%s GENERATION=%llu SLOT=%u VALUE=%llu RESPONSE=%x HANDLE=%016llx NAME=%s NATIVE=%s\n",GetCurrentProcessId(),r.op,(unsigned long)s,r.status,hex(r.carrier_id,16).c_str(),(unsigned long long)r.generation,r.slot_index,(unsigned long long)r.value,r.response_type,(unsigned long long)r.user_handle,utf8(std::wstring((wchar_t*)r.object_name,wcsnlen((wchar_t*)r.object_name,128))).c_str(),utf8(std::wstring((wchar_t*)r.native_name,wcsnlen((wchar_t*)r.native_name,128))).c_str());return s;}
 bool transport(uint32_t op,HANDLE h,const uint8_t*id,uint32_t version,uint32_t expected,bool unsupported=false){
  uint8_t identity[16]={};HCRYPTPROV provider;
  require(CryptAcquireContextW(&provider,nullptr,nullptr,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)!=0,"request identity provider");
  BOOL generated=CryptGenRandom(provider,16,identity);CryptReleaseContext(provider,0);require(generated!=0,"request identity");
  auto before=helios_attest_request(op,identity,(uint64_t)(uintptr_t)h,id,version);
  struct Guard{uint64_t pre[2];helios_attest_transport r;uint64_t post[2];} guarded{{0x123456789abcdef0ULL,0xfedcba9876543210ULL},before,{0x123456789abcdef0ULL,0xfedcba9876543210ULL}};
  auto&r=guarded.r;
  D3DKMT_ESCAPE e{};e.hAdapter=adapter;e.hDevice=device;e.Type=D3DKMT_ESCAPE_DRIVERPRIVATE;e.pPrivateDriverData=&r;e.PrivateDriverDataSize=sizeof(r);
  LARGE_INTEGER begin{},end{},frequency{};QueryPerformanceFrequency(&frequency);QueryPerformanceCounter(&begin);NTSTATUS status=escapeFn(&e);QueryPerformanceCounter(&end);require(guarded.pre[0]==0x123456789abcdef0ULL&&guarded.pre[1]==0xfedcba9876543210ULL&&guarded.post[0]==0x123456789abcdef0ULL&&guarded.post[1]==0xfedcba9876543210ULL,"Transport canary corruption");bool valid=helios_attest_response_valid(&r,&before,sizeof(r));
  printf("TRANSPORT_QPC BEGIN=%lld END=%lld FREQUENCY=%lld\n",begin.QuadPart,end.QuadPart,frequency.QuadPart);
  printf("TRANSPORT CASE=%s OP=%x PID=%lu TID=%lu NTSTATUS=%08lx VALID=%u ACCEPTED=%u CLASS=%u EXPECTED=%u ID=%s\n",active_case,op,GetCurrentProcessId(),GetCurrentThreadId(),(unsigned long)status,unsigned(valid),r.accepted,r.refusal_class,expected,hex(identity,16).c_str());
  printf("TRANSPORT_BEFORE=%s\nTRANSPORT_AFTER=%s\n",hex(&before,sizeof(before)).c_str(),hex(&r,sizeof(r)).c_str());fflush(stdout);
  if(unsupported){require(status!=0&&!valid,"Old KMD must refuse unavailable capability");return false;}
  require(status==0&&valid,"Complete valid response required");
  require(r.refusal_class==expected,"Received classification mismatch");
  require(r.accepted==unsigned(op==HELIOS_ATTEST_CALL&&expected==0),"Accepted/class mismatch");return true;
 }
 void attest(HANDLE h,const uint8_t*id,uint32_t expected,uint32_t version=2){
  transport(HELIOS_ATTEST_QUERY,nullptr,id,0,0);
  transport(HELIOS_ATTEST_CALL,h,id,version,expected);
 }
 ~Kmt(){if(device){D3DKMT_DESTROYDEVICE d{};d.hDevice=device;auto f=(PFND3DKMT_DESTROYDEVICE)GetProcAddress(gdi,"D3DKMTDestroyDevice");NTSTATUS s=f(&d);printf("KMT_DESTROY_DEVICE NTSTATUS=%08lx\n",(unsigned long)s);cleanup_ok &= s==0;}if(adapter){D3DKMT_CLOSEADAPTER c{};c.hAdapter=adapter;auto f=(PFND3DKMT_CLOSEADAPTER)GetProcAddress(gdi,"D3DKMTCloseAdapter");NTSTATUS s=f(&c);printf("KMT_CLOSE_ADAPTER NTSTATUS=%08lx\n",(unsigned long)s);cleanup_ok &= s==0;}if(gdi)FreeLibrary(gdi);}
};
struct Lease {
 Kmt& k;CarrierRequest token{};bool live=false;
 explicit Lease(Kmt& x):k(x){init(token,1);auto s=k.call(token);live=s==0;require(s==0&&token.status==0,"PRODUCTION_CREATE");require(token.generation>0&&token.lease_flags==1,"Production lease identity");}
 void query(){auto r=token;r.op=6;require(k.call(r)==0&&r.status==0,"PRODUCTION_QUERY");require(memcmp(r.carrier_id,token.carrier_id,16)==0&&r.generation==token.generation,"Query identity");}
 void publish(uint64_t value,uint32_t response=0){auto r=token;r.op=response?3:2;r.value=value;r.response_type=response;require(k.call(r)==0&&r.status==0,"Controlled PRODUCTION_PUBLISH");}
 void release(){if(live){auto r=token;r.op=5;NTSTATUS s=k.call(r);printf("PRODUCTION_RELEASE_CLEANUP=%s\n",s==0&&r.status==0?"PASS":"FAIL");cleanup_ok &= s==0&&r.status==0;live=false;}}
 ~Lease(){release();}
};
static Handle fixture(const std::wstring&name,const Record&r,bool permissive=false){return Handle(fixture_security::make(name,&r,sizeof(r),permissive));}
static Record distinct_record(const Record&source){Record r=source;HCRYPTPROV p;require(CryptAcquireContextW(&p,nullptr,nullptr,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)!=0,"Fixture random provider");BOOL ok=CryptGenRandom(p,16,r.carrier_id);CryptReleaseContext(p,0);require(ok!=0,"Fixture random id");return r;}
static std::wstring fixture_name(const Record&r){auto id=hex(r.carrier_id,16);return L"Global\\HeliosP06Carrier_"+std::wstring(id.begin(),id.end());}
static void mesa_reject(Child& child,HANDLE h){auto result=child.call(Import,h,0,0,true);require(result.result==VK_ERROR_INVALID_EXTERNAL_HANDLE,"Mesa rejects copied/malformed E1 section");}
static void run_case(const std::string& mode){
 Vulkan v;v.open();Kmt k;k.open(v);std::wstring reclaimName;
 {
  Lease a(k);a.query();Handle h=read_handle(a.token);Record initial{};snapshot(h.h,initial,true);reclaimName=object_name(h.h);
  if(mode=="unsupported") {active_case="unsupported-capability";k.transport(HELIOS_ATTEST_QUERY,nullptr,a.token.carrier_id,0,0,true);Child c(sibling_pair());mesa_reject(c,h.h);c.finish();}
  else if(mode=="attest-positive") {active_case="genuine";k.attest(h.h,a.token.carrier_id,0);}
  else if(mode=="attest-null") {active_case="null";k.attest(nullptr,a.token.carrier_id,1);}
  else if(mode=="attest-version") {active_case="requested-version-1";k.attest(h.h,a.token.carrier_id,7,1);}
  else if(mode=="attest-mask") {
   const char* text=getenv("P06_SEMANTIC_FIXTURE_ID");require(text&&strlen(text)==32,"Fixture ready ID");CarrierRequest own{};
   for(unsigned i=0;i<16;++i){unsigned value=0;require(sscanf(text+2*i,"%2x",&value)==1,"Fixture ID hex");own.carrier_id[i]=uint8_t(value);}
   auto id=hex(own.carrier_id,16);require(id==text,"Canonical ID");std::wstring native=L"\\BaseNamedObjects\\HeliosP06Carrier_"+std::wstring(id.begin(),id.end());memcpy(own.native_name,native.c_str(),(native.size()+1)*2);
   Handle invalid=read_handle(own);require(fixture_security::access(invalid.h,"SEMANTIC_ATTEST_TEST")==5,"Exact read query test rights");Record record{};snapshot(invalid.h,record,true);require(memcmp(record.carrier_id,own.carrier_id,16)==0,"Fixture record ID");
   active_case="semantic-dacl-mask";k.attest(invalid.h,own.carrier_id,6);Child c(sibling_pair());mesa_reject(c,invalid.h);c.finish();
  }
  else if(mode=="remaining-negatives") {
   wchar_t tempDir[MAX_PATH],temp[MAX_PATH];require(GetTempPathW(MAX_PATH,tempDir)>0&&GetTempFileNameW(tempDir,L"p06",0,temp)!=0,"Wrong-type temp file");Handle file(CreateFileW(temp,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_DELETE_ON_CLOSE,nullptr));require(file.h!=INVALID_HANDLE_VALUE,"Wrong-type handle");
   auto rights=fixture_security::access(file.h,"FILE_ATTEST_TEST");require((rights&5)==5,"File HANDLE lacks access bits required before type check");active_case="wrong-type-file";k.attest(file.h,a.token.carrier_id,2);
   Handle foreign=fixture(L"",initial);active_case="anonymous-name";k.attest(foreign.h,initial.carrier_id,3);
   auto random=distinct_record(initial);auto rnd=hex(random.carrier_id,16);Handle named=fixture(L"Global\\P06Foreign_"+std::wstring(rnd.begin(),rnd.end()),initial);active_case="foreign-name";k.attest(named.h,initial.carrier_id,3);
   auto mismatched=initial;mismatched.carrier_id[0]^=1;active_case="id-mismatch";k.attest(h.h,mismatched.carrier_id,4);
   auto wrongOwner=distinct_record(initial);Handle owner=fixture(fixture_name(wrongOwner),wrongOwner);active_case="wrong-owner";k.attest(owner.h,wrongOwner.carrier_id,5);
   auto wrongDacl=distinct_record(initial);Handle dacl=fixture(fixture_name(wrongDacl),wrongDacl,true);active_case="structural-dacl";k.attest(dacl.h,wrongDacl.carrier_id,6);
  }
  else if(mode=="positive") {k.attest(h.h,a.token.carrier_id,0);Child c(sibling_pair());require(c.call(Import,h.h).result==0,"Production Section Mesa import");require(c.call(Counter).result==0,"Imported counter");c.finish();}
  else if(mode=="negative") {
   k.attest(nullptr,a.token.carrier_id,1);
   wchar_t tempDir[MAX_PATH],temp[MAX_PATH];require(GetTempPathW(MAX_PATH,tempDir)>0&&GetTempFileNameW(tempDir,L"p06",0,temp)!=0,"Wrong-type temp file");Handle file(CreateFileW(temp,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_DELETE_ON_CLOSE,nullptr));require(file.h!=INVALID_HANDLE_VALUE,"Wrong-type handle");k.attest(file.h,a.token.carrier_id,2);
   Handle foreign=fixture(L"",initial);k.attest(foreign.h,initial.carrier_id,3);
   auto random=distinct_record(initial);std::wstring bad;
   // Avoid iterators from different temporary strings.
   auto rnd=hex(random.carrier_id,16);bad=L"Global\\P06Foreign_"+std::wstring(rnd.begin(),rnd.end());Handle named=fixture(bad,initial);k.attest(named.h,initial.carrier_id,3);
   auto mismatched=initial;mismatched.carrier_id[0]^=1;k.attest(h.h,mismatched.carrier_id,4);k.attest(h.h,initial.carrier_id,7,1);
   auto wrongOwner=distinct_record(initial);Handle owner=fixture(fixture_name(wrongOwner),wrongOwner);k.attest(owner.h,wrongOwner.carrier_id,5);
   auto wrongDacl=distinct_record(initial);Handle dacl=fixture(fixture_name(wrongDacl),wrongDacl,true);k.attest(dacl.h,wrongDacl.carrier_id,6);
   Child c(sibling_pair());mesa_reject(c,foreign.h);mesa_reject(c,named.h);mesa_reject(c,owner.h);mesa_reject(c,dacl.h);auto wrongVersion=initial;wrongVersion.version=1;Handle version=fixture(L"",wrongVersion);mesa_reject(c,version.h);c.finish();printf("NEGATIVE_ATTESTATION=%s STRUCTURAL_ACE_COUNT_PRECEDES_POLICY=1 SEMANTIC_MASK_BRANCH_NOT_ISOLATED=1\n",unobserved_classifications?"NOT_PROVEN":"PASS");
  }
  else if(mode=="lifetime") {
   Child c(sibling_pair());require(c.call(Import,h.h).result==0,"Lifetime import");HANDLE duplicate=nullptr;require(DuplicateHandle(GetCurrentProcess(),h.h,GetCurrentProcess(),&duplicate,0,FALSE,DUPLICATE_SAME_ACCESS)!=0,"Independent exported reference");Handle old(duplicate);h.reset();a.release();require(c.call(Counter).result==0,"Consumer survives lease release");k.attest(old.h,initial.carrier_id,0);Child late(sibling_pair());require(late.call(Import,old.h).result==0,"Late import after lease release");
   {Lease b(k);Handle replacement=read_handle(b.token);Record newer{};snapshot(replacement.h,newer,true);require(memcmp(newer.carrier_id,initial.carrier_id,16)!=0,"Carrier ID must differ on new creation");printf("SLOT_REUSE OLD=%u NEW=%u\n",a.token.slot_index,b.token.slot_index);require(a.token.slot_index==b.token.slot_index,"Required slot reuse not observed");Record unchanged{};snapshot(old.h,unchanged,true);require(memcmp(&initial,&unchanged,sizeof(initial))==0,"Old carrier transformed by slot reuse");auto stale=b.token;stale.op=6;memcpy(stale.carrier_id,initial.carrier_id,16);require(uint32_t(k.call(stale))==0xc0000225u,"Old ID accepted as new carrier");b.release();auto replacementName=object_name(replacement.h);replacement.reset();reclaimed(replacementName);}
   old.reset();require(late.call(Counter).result==0,"Importer duplicate lifetime after final caller close");late.finish();c.finish();printf("KMD_LEASE_HANDLE_LIFETIME=PASS\n");
  }
  else if(mode=="pending"||mode=="complete"||mode=="error") {
   Child c(sibling_pair());require(c.call(Import,h.h).result==0,"State consumer import");require(initial.completed_value==0&&initial.terminal_error_value==0,"Controlled initial record");
   if(mode!="pending")a.publish(7,mode=="error"?0x1200:0);
   Record after{};snapshot(h.h,after,true);if(mode!="pending")require(after.sequence>initial.sequence,"Publication sequence did not advance");auto count=c.call(Counter);require(count.result==0&&count.value==(mode=="complete"?7u:0u),"Counter must expose only completion");auto wait=c.call(Wait,nullptr,7,0,true);int expected=mode=="pending"?VK_TIMEOUT:mode=="complete"?VK_SUCCESS:VK_ERROR_UNKNOWN;require(wait.result==expected,"Controlled wait VkResult mismatch");if(mode=="error")require(after.terminal_error_value==7&&after.terminal_response_type==0x1200&&after.completed_value==0,"Error record mismatch");if(mode=="complete")require(after.completed_value==7&&after.terminal_error_value==0,"Completion record mismatch");c.finish();printf("CONTROLLED_STATE=%s RESULT=PASS REAL_RENDERER_ERROR_EXECUTIONS_ADDED=0\n",mode.c_str());
  } else throw std::runtime_error("Unknown KMD matrix mode");
  active_case="cleanup";a.release();h.reset();
 }
 reclaimed(reclaimName);
}
int main(int argc,char**argv){try{process_evidence(argc,argv);require(argc==2,"One KMD matrix mode required");if(strcmp(argv[1],"--capture-selftest")==0){capture_regression();return 0;}if(strcmp(argv[1],"--smoke")==0){printf("KMD_ABI_SMOKE=PASS ESCAPE=0018 SIZE=%zu HANDLE_OFFSET=%zu DRIVER_CALLS=0\n",sizeof(CarrierRequest),offsetof(CarrierRequest,user_handle));return 0;}run_case(argv[1]);require(cleanup_ok,"KMD cleanup failed");if(unobserved_classifications){printf("CASE=%s RESULT=NOT_PROVEN CLASSIFICATIONS_NOT_OBSERVED=%u\n",argv[1],unobserved_classifications);return 3;}printf("CASE=%s RESULT=PASS\n",argv[1]);return 0;}catch(const std::exception&e){fprintf(stderr,"FIRST_DIVERGENCE PID=%lu MESSAGE=%s CLEANUP_OK=%d\n",GetCurrentProcessId(),e.what(),int(cleanup_ok));return 1;}}
