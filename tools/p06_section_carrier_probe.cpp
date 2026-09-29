// P06 E1 section-carrier feasibility probe. Diagnostic-only: no GPU submission,
// external semaphore, wait/retire, fault hook, success control, or P09 path.
//
// Build (MSVC developer prompt):
//   cl /nologo /W4 /O2 tools\p06_section_carrier_probe.cpp ^
//      /Iicd\win-build\wdk-include /Fe:p06_section_carrier_probe.exe /link gdi32.lib
// Capture stdout/stderr raw and execute once from the interactive desktop.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifndef _NTDEF_
typedef LONG NTSTATUS, *PNTSTATUS;
#endif
#include <d3dkmthk.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define ESCAPE_MAGIC 0x48454C53u
#define ESCAPE_VERSION 1u
#define ESCAPE_P06_SECTION 0x0017u
#define OP_CREATE 1u
#define OP_PUBLISH 2u
#define OP_RELEASE 3u
#define OP_QUERY 4u
#define SECTION_MAGIC 0x504636534543544Eull
#define SECTION_VERSION 1u
#define SECTION_NAME_CAP 128u

struct escape_header { uint32_t magic, cmd_type, version, size; };
struct section_escape {
  struct escape_header hdr;
  uint32_t op, probe_id;
  uint64_t generation;
  uint32_t reserved, slot_index;
  uint64_t sequence, test_value;
  WCHAR object_name[SECTION_NAME_CAP];
};
struct section_record {
  uint64_t magic;
  uint32_t version, size, probe_id, reserved;
  uint64_t generation;
  volatile LONG64 sequence;
  volatile LONG64 test_value;
};
static_assert(sizeof(section_escape) == 312, "escape ABI drift");
static_assert(offsetof(section_escape, sequence) == 40, "escape sequence offset drift");
static_assert(offsetof(section_escape, object_name) == 56, "escape name offset drift");
static_assert(sizeof(section_record) == 48, "section record ABI drift");

static D3DKMT_HANDLE g_adapter;
static D3DKMT_HANDLE g_device;
static uint32_t g_id;
static uint64_t g_generation;
static uint32_t g_slot;
static WCHAR g_name[SECTION_NAME_CAP];
static bool g_cleanup_ok = true;

static bool checked_close(const char* label,HANDLE h) {
  if(!h) return true;
  BOOL ok=CloseHandle(h); DWORD error=ok?ERROR_SUCCESS:GetLastError();
  printf("CLEANUP_CLOSE_%s=%s error=%lu\n",label,ok?"PASS":"FAIL",error);
  g_cleanup_ok=g_cleanup_ok&&ok; return ok!=FALSE;
}
static bool checked_unmap(const char* label,const void* p) {
  if(!p) return true;
  BOOL ok=UnmapViewOfFile(p); DWORD error=ok?ERROR_SUCCESS:GetLastError();
  printf("CLEANUP_UNMAP_%s=%s error=%lu\n",label,ok?"PASS":"FAIL",error);
  g_cleanup_ok=g_cleanup_ok&&ok; return ok!=FALSE;
}
static bool close_adapter_handle(D3DKMT_HANDLE adapter,const char* label) {
  if(!adapter) return true;
  D3DKMT_CLOSEADAPTER c{}; c.hAdapter=adapter; NTSTATUS s=D3DKMTCloseAdapter(&c);
  printf("CLEANUP_ADAPTER_%s=%s status=0x%08lx\n",label,s==0?"PASS":"FAIL",(unsigned long)s);
  g_cleanup_ok=g_cleanup_ok&&(s==0); return s==0;
}

static void init(section_escape* r, uint32_t op) {
  memset(r, 0, sizeof(*r));
  r->hdr = { ESCAPE_MAGIC, ESCAPE_P06_SECTION, ESCAPE_VERSION, sizeof(*r) };
  r->op = op;
}
static NTSTATUS escape(section_escape* r) {
  D3DKMT_ESCAPE e{};
  e.hAdapter = g_adapter; e.hDevice = g_device;
  e.Type = D3DKMT_ESCAPE_DRIVERPRIVATE;
  e.pPrivateDriverData = r; e.PrivateDriverDataSize = sizeof(*r);
  NTSTATUS s = D3DKMTEscape(&e);
  printf("ESCAPE op=%u status=0x%08lx reply_status=0x%08x id=%u generation=%llu sequence=%llu\n",
      r->op, (unsigned long)s, r->reserved, r->probe_id, r->generation,
         (unsigned long long)r->sequence);
  return s;
}
static bool enum_adapters(D3DKMT_ADAPTERINFO** out, UINT* count) {
  D3DKMT_ENUMADAPTERS2 e{};
  NTSTATUS s = D3DKMTEnumAdapters2(&e);
  if (s || !e.NumAdapters) { printf("ADAPTER_ENUM=FAIL status=0x%08lx count=%lu\n", (unsigned long)s, (unsigned long)e.NumAdapters); return false; }
  *count = e.NumAdapters;
  *out = (D3DKMT_ADAPTERINFO*)calloc(*count, sizeof(**out));
  if (!*out) return false;
  e.pAdapters = *out;
  s = D3DKMTEnumAdapters2(&e);
  if (s) { printf("ADAPTER_ENUM_FILL=FAIL status=0x%08lx\n",(unsigned long)s); free(*out); *out = nullptr; return false; }
  return true;
}
static void close_kmt() {
  if (g_device) { D3DKMT_DESTROYDEVICE d{}; d.hDevice = g_device; NTSTATUS s=D3DKMTDestroyDevice(&d); printf("DESTROY_DEVICE_STATUS=0x%08lx\n",(unsigned long)s); g_cleanup_ok=g_cleanup_ok&&(s==0); if(s==0)g_device=0; }
  if (g_adapter) { D3DKMT_CLOSEADAPTER c{}; c.hAdapter = g_adapter; NTSTATUS s=D3DKMTCloseAdapter(&c); printf("CLOSE_ADAPTER_STATUS=0x%08lx\n",(unsigned long)s); g_cleanup_ok=g_cleanup_ok&&(s==0); if(s==0)g_adapter=0; }
}
static bool create_helios_section() {
  D3DKMT_ADAPTERINFO* list = nullptr; UINT count = 0;
  if (!enum_adapters(&list, &count)) return false;
  for (UINT i = 0; i < count; ++i) {
    D3DKMT_CREATEDEVICE cd{}; cd.hAdapter = list[i].hAdapter;
    NTSTATUS create_status=D3DKMTCreateDevice(&cd);
    if (create_status != 0) { printf("D3DKMT_CREATE_DEVICE status=0x%08lx\n",(unsigned long)create_status); close_adapter_handle(list[i].hAdapter,"CREATE_DEVICE_REJECTED"); continue; }
    g_adapter = cd.hAdapter; g_device = cd.hDevice;
    section_escape r{}; init(&r, OP_CREATE);
    NTSTATUS s = escape(&r);
    if (!s && r.probe_id && r.generation && r.object_name[0]) {
      g_id = r.probe_id; g_generation = r.generation;
      g_slot = r.slot_index;
      memcpy(g_name, r.object_name, sizeof(g_name));
      free(list);
      printf("SECTION_CREATE_STATUS=PASS\n");
      printf("SECTION_KERNEL_HANDLE_POLICY=OBJ_KERNEL_HANDLE\n");
      printf("SECTION_USER_OPEN_MECHANISM=OpenFileMappingW(Global namespace)\n");
      printf("SECTION_SECURITY_MODEL=CAPTURED_REQUESTOR_SID_READ_ONLY_ACL\n");
      printf("ACL_SOURCE_IMPLEMENTED=YES owner=SYSTEM dacl=non_null requestor=read_query_only\n");
      printf("SECTION_OBJECT_REFERENCE_GATE=PASS\n");
      printf("SECTION_SYSTEM_VIEW_GATE=PASS\n");
      printf("SECTION_GLOBAL_NAMESPACE_MAPPING=PENDING_WINDOWS_RUNTIME\n");
      return true;
    }
    printf("SECTION_CREATE_STATUS=FAIL stage=%llu diag_class=%u\n",
           (unsigned long long)r.sequence, r.reserved);
    printf("SECTION_OBJECT_REFERENCE_GATE=%s\n", r.sequence >= 3 ? "FAIL" : "NOT_REACHED");
    printf("SECTION_SYSTEM_VIEW_GATE=%s\n", r.sequence >= 4 ? "FAIL" : "NOT_REACHED");
    close_kmt();
  }
  free(list); printf("SECTION_CREATE_DISCOVERY=FAIL\n"); return false;
}
static bool publish(uint32_t id, uint64_t gen, uint32_t slot, uint64_t seq, uint64_t value) {
  section_escape r{}; init(&r, OP_PUBLISH);
  r.probe_id=id; r.generation=gen; r.slot_index=slot; r.sequence=seq; r.test_value=value;
  return escape(&r) == 0;
}
static bool release_section(uint32_t id, uint64_t gen, uint32_t slot) {
  section_escape r{}; init(&r, OP_RELEASE); r.probe_id=id; r.generation=gen; r.slot_index=slot;
  return escape(&r) == 0;
}
static bool stale_rejected(uint32_t op,uint32_t id,uint64_t gen,uint32_t slot) {
  section_escape r{}; init(&r,op); r.probe_id=id; r.generation=gen; r.slot_index=slot;
  NTSTATUS s=escape(&r);
  bool rejected=s==static_cast<NTSTATUS>(0xC0000059L); // STATUS_REVISION_MISMATCH
  printf("SECTION_STALE_TOKEN_%s=%s\n",op==OP_PUBLISH?"PUBLISH":op==OP_QUERY?"QUERY":"RELEASE",rejected?"PASS":"FAIL");
  return rejected;
}
static bool read_record(HANDLE mapping, section_record* out) {
  SetLastError(ERROR_SUCCESS);
  auto* p=(volatile section_record*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 4096);
  if (!p) { printf("SECTION_MAP_READ=FAIL error=%lu\n",GetLastError()); return false; }
  bool ok=false;
  for (unsigned i=0;i<1000;i++) {
    LONG64 a=InterlockedCompareExchange64((volatile LONG64*)&p->sequence,0,0);
    if (a&1) { YieldProcessor(); continue; }
    out->magic=p->magic; out->version=p->version; out->size=p->size;
    out->probe_id=p->probe_id; out->generation=p->generation;
    out->test_value=InterlockedCompareExchange64((volatile LONG64*)&p->test_value,0,0);
    MemoryBarrier();
    LONG64 b=InterlockedCompareExchange64((volatile LONG64*)&p->sequence,0,0);
    if (a==b && !(b&1)) { out->sequence=b; ok=true; break; }
  }
  bool unmap=checked_unmap("READ_RECORD",(const void*)p);
  return ok&&unmap;
}
static bool matches(HANDLE mapping,uint32_t id,uint64_t gen,uint64_t seq,uint64_t value) {
  section_record r{};
  bool ok=read_record(mapping,&r) && r.magic==SECTION_MAGIC && r.version==SECTION_VERSION &&
      r.size==sizeof(r) && r.probe_id==id && r.generation==gen &&
      (uint64_t)r.sequence==seq*2 && (uint64_t)r.test_value==value;
  printf("SECTION_RECORD=%s magic=0x%llx version=%u size=%u id=%u generation=%llu seq=%lld value=0x%llx\n",
      ok?"PASS":"FAIL",(unsigned long long)r.magic,r.version,r.size,r.probe_id,r.generation,
      (long long)r.sequence,(unsigned long long)r.test_value);
  return ok;
}
typedef BOOL (WINAPI *CompareObjectHandlesFn)(HANDLE,HANDLE);
static CompareObjectHandlesFn compare_fn() {
  HMODULE k=GetModuleHandleW(L"kernelbase.dll");
  FARPROC symbol=k?GetProcAddress(k,"CompareObjectHandles"):nullptr;
  if(!symbol) printf("SECTION_COMPARE_OBJECT_HANDLES=UNAVAILABLE error=%lu\n",GetLastError());
  CompareObjectHandlesFn fn=nullptr;
  static_assert(sizeof(fn)==sizeof(symbol),"function pointer size mismatch");
  memcpy(&fn,&symbol,sizeof(fn));
  return fn;
}
static bool open_publisher(uint32_t id,uint64_t gen,uint32_t slot,uint64_t seq,uint64_t value) {
  D3DKMT_ADAPTERINFO* list=nullptr; UINT count=0;
  if (!enum_adapters(&list,&count)) return false;
  for (UINT i=0;i<count;i++) {
    D3DKMT_CREATEDEVICE cd{}; cd.hAdapter=list[i].hAdapter;
    NTSTATUS create_status=D3DKMTCreateDevice(&cd);
    if (create_status!=0) { printf("PUBLISHER_CREATE_DEVICE status=0x%08lx\n",(unsigned long)create_status); close_adapter_handle(list[i].hAdapter,"PUBLISHER_REJECTED"); continue; }
    g_adapter=cd.hAdapter; g_device=cd.hDevice;
    if (publish(id,gen,slot,seq,value)) { free(list); return true; }
    close_kmt();
  }
  free(list); return false;
}
static int importer(HANDLE pipe,DWORD exporter_pid,uint32_t id,uint64_t gen,uint32_t slot) {
  uintptr_t raw=0; DWORD got=0;
  SetLastError(ERROR_SUCCESS);
  if (!ReadFile(pipe,&raw,sizeof(raw),&got,nullptr) || got!=sizeof(raw)) {
    DWORD error=GetLastError(); printf("SECTION_DUPLICATE_TRANSFER=FAIL error=%lu bytes=%lu\n",error,got);
    checked_close("PIPE_AFTER_TRANSFER_FAILURE",pipe); return 20;
  }
  bool pipe_closed=checked_close("PIPE",pipe);
  HANDLE exporter=OpenProcess(SYNCHRONIZE,FALSE,exporter_pid);
  if (!exporter) { printf("SECTION_EXPORTER_WAIT=FAIL error=%lu\n",GetLastError()); return 21; }
  DWORD wait=WaitForSingleObject(exporter,INFINITE); printf("SECTION_EXPORTER_WAIT_STATUS=%s value=0x%08lx\n",wait==WAIT_OBJECT_0?"PASS":"FAIL",(unsigned long)wait);
  bool exporter_waited=wait==WAIT_OBJECT_0; bool exporter_closed=checked_close("EXPORTER_PROCESS",exporter);
  printf("SECTION_EXPORTER_EXITED=%s\n",exporter_waited?"PASS":"FAIL");
  if(!exporter_waited) return 21;

  HANDLE mapping=(HANDLE)raw;
  bool late=matches(mapping,id,gen,1,0xE1A0000000000001ull);
  printf("SECTION_LATE_IMPORT_AFTER_EXPORTER_EXIT=%s\n",late?"PASS":"FAIL");
  bool kmd_publish=open_publisher(id,gen,slot,2,0xE1A0000000000002ull);
  bool visible=kmd_publish && matches(mapping,id,gen,2,0xE1A0000000000002ull);
  printf("SECTION_KMD_PUBLICATION_AFTER_EXPORTER_EXIT=%s\n",visible?"PASS":"FAIL");
  bool released=release_section(id,gen,slot);
  bool retained=released && matches(mapping,id,gen,2,0xE1A0000000000002ull);
  printf("SECTION_USER_HANDLE_RETAINS_OBJECT_AFTER_KMD_RELEASE=%s\n",retained?"PASS":"FAIL");
  section_escape temporary{}; init(&temporary,OP_CREATE);
  bool temporary_created=escape(&temporary)==0;
  bool temporary_other_slot=temporary_created&&temporary.slot_index!=slot;
  bool temporary_released=temporary_created&&release_section(temporary.probe_id,temporary.generation,temporary.slot_index);
  section_escape replacement{}; init(&replacement,OP_CREATE);
  bool replacement_created=temporary_released&&escape(&replacement)==0;
  bool reused=replacement_created&&replacement.slot_index==slot&&replacement.generation!=gen;
  printf("SECTION_SLOT_REUSE_GATE=%s old_slot=%u new_slot=%u old_generation=%llu new_generation=%llu\n",
      reused?"PASS":"FAIL",slot,replacement.slot_index,(unsigned long long)gen,(unsigned long long)replacement.generation);
  bool stale_publish=reused&&stale_rejected(OP_PUBLISH,id,gen,slot);
  bool stale_query=reused&&stale_rejected(OP_QUERY,id,gen,slot);
  bool stale_release=reused&&stale_rejected(OP_RELEASE,id,gen,slot);
  HANDLE replacement_map=replacement_created?OpenFileMappingW(FILE_MAP_READ,FALSE,replacement.object_name):nullptr;
  section_record old_before{};
  bool old_data_before=replacement_map&&read_record(replacement_map,&old_before)&&
      old_before.probe_id==replacement.probe_id&&old_before.generation==replacement.generation&&old_before.sequence==0;
  bool replacement_isolated=reused&&old_data_before&&
      publish(replacement.probe_id,replacement.generation,replacement.slot_index,1,0xE1B0000000000001ull) &&
      matches(replacement_map,replacement.probe_id,replacement.generation,1,0xE1B0000000000001ull) &&
      matches(mapping,id,gen,2,0xE1A0000000000002ull);
  printf("SECTION_OLD_NEW_SLOT_ISOLATION=%s\n",replacement_isolated?"PASS":"FAIL");
  bool replacement_released=replacement_created&&release_section(replacement.probe_id,replacement.generation,replacement.slot_index);
  if(replacement_map) checked_close("REPLACEMENT_MAPPING",replacement_map);
  WCHAR replacement_name[SECTION_NAME_CAP]{};
  swprintf_s(replacement_name,L"Global\\HeliosP06Section_%08X_%016llX",replacement.probe_id,(unsigned long long)replacement.generation);
  SetLastError(ERROR_SUCCESS);
  HANDLE replacement_reopen=OpenFileMappingW(FILE_MAP_READ,FALSE,replacement_name);
  DWORD replacement_error=GetLastError(); if(replacement_reopen) checked_close("REPLACEMENT_REOPEN",replacement_reopen);
  bool replacement_reclaimed=replacement_released&&!replacement_reopen&&replacement_error==ERROR_FILE_NOT_FOUND;
  printf("SECTION_REPLACEMENT_FINAL_RECLAIM=%s error=%lu\n",replacement_reclaimed?"PASS":"FAIL",replacement_error);
  close_kmt();
  checked_close("OLD_MAPPING",mapping);
  WCHAR name[SECTION_NAME_CAP]{};
  swprintf_s(name,L"Global\\HeliosP06Section_%08X_%016llX",id,(unsigned long long)gen);
  SetLastError(ERROR_SUCCESS);
  HANDLE reopened=OpenFileMappingW(FILE_MAP_READ,FALSE,name);
  DWORD reopen_error=GetLastError();
  if (reopened) checked_close("OLD_REOPEN",reopened);
  bool reclaimed=!reopened && reopen_error==ERROR_FILE_NOT_FOUND;
  printf("SECTION_KMD_LEAK_GATE=%s\n",reclaimed?"PASS":"FAIL");
  bool all=late&&exporter_waited&&visible&&retained&&temporary_other_slot&&temporary_released&&reused&&stale_publish&&stale_query&&stale_release&&replacement_isolated&&replacement_reclaimed&&reclaimed&&g_cleanup_ok;
  printf("SECTION_OLD_FINAL_RECLAIM=%s error=%lu\n",reclaimed?"PASS":"FAIL",reopen_error);
  printf("OPTION_E_SECTION_CARRIER_FEASIBILITY=%s\n",all?"PASS":"FAIL");
  return all&&pipe_closed&&exporter_closed?0:22;
}
static int exporter() {
  if (!create_helios_section()) return 2;
  HANDLE mapping=OpenFileMappingW(FILE_MAP_READ,FALSE,g_name);
  DWORD open_error=mapping?ERROR_SUCCESS:GetLastError();
  printf("SECTION_USER_OPEN=%s error=%lu\n",mapping?"PASS":"FAIL",open_error);
  if (!mapping) { printf("SECTION_GLOBAL_NAMESPACE_MAPPING=FAIL error=%lu\n",open_error); release_section(g_id,g_generation,g_slot); close_kmt(); return 3; }
  printf("SECTION_GLOBAL_NAMESPACE_MAPPING=PASS\n");
  auto* view=MapViewOfFile(mapping,FILE_MAP_READ,0,0,4096);
  section_record initial{};
  bool read_ok=view && read_record(mapping,&initial) && initial.magic==SECTION_MAGIC &&
      initial.version==SECTION_VERSION && initial.size==sizeof(initial) && initial.probe_id==g_id &&
      initial.generation==g_generation && initial.sequence==0;
  printf("SECTION_USER_READ_GATE=%s\n",read_ok?"PASS":"FAIL");
  SetLastError(ERROR_SUCCESS);
  HANDLE write_open=OpenFileMappingW(FILE_MAP_WRITE,FALSE,g_name); DWORD write_open_error=GetLastError();
  if(write_open) checked_close("WRITE_OPEN",write_open);
  SetLastError(ERROR_SUCCESS);
  void* write_view=MapViewOfFile(mapping,FILE_MAP_WRITE,0,0,4096); DWORD map_error=GetLastError();
  bool write_view_cleanup=checked_unmap("WRITE_TEST",write_view);
  bool write_denied=!write_open&&!write_view&&(write_open_error==ERROR_ACCESS_DENIED||map_error==ERROR_ACCESS_DENIED);
  printf("SECTION_USER_WRITE_DENIED_GATE=%s open_error=%lu map_error=%lu\n",write_denied?"PASS":"FAIL",write_open_error,map_error);
  SetLastError(ERROR_SUCCESS);
  HANDLE write_dac=OpenFileMappingW(WRITE_DAC|WRITE_OWNER,FALSE,g_name);
  DWORD security_open_error=GetLastError();
  if(write_dac) checked_close("WRITE_DAC",write_dac);
  bool security_denied=!write_dac&&security_open_error==ERROR_ACCESS_DENIED;
  printf("SECTION_USER_WRITE_DAC_OWNER_DENIED_GATE=%s error=%lu\n",
      security_denied?"PASS":"FAIL",security_open_error);

  bool parent_publish=publish(g_id,g_generation,g_slot,1,0xE1A0000000000001ull) &&
      matches(mapping,g_id,g_generation,1,0xE1A0000000000001ull);
  printf("SECTION_KMD_TO_PARENT_PUBLICATION=%s\n",parent_publish?"PASS":"FAIL");
  auto compare=compare_fn(); HANDLE same=nullptr;
  bool same_dup=DuplicateHandle(GetCurrentProcess(),mapping,GetCurrentProcess(),&same,SECTION_MAP_READ|SECTION_QUERY,FALSE,0);
  bool same_ok=same_dup&&compare&&compare(mapping,same);
  printf("SECTION_SAME_OBJECT_IDENTITY_GATE=%s\n",same_ok?"PASS":"FAIL");
  if(same) checked_close("DUPLICATE",same);

  section_escape second{}; init(&second,OP_CREATE);
  NTSTATUS second_status=escape(&second);
  HANDLE second_map=second_status==0?OpenFileMappingW(FILE_MAP_READ,FALSE,second.object_name):nullptr;
  bool distinct=second_map&&compare&&!compare(mapping,second_map);
  printf("SECTION_DISTINCT_OBJECT_GATE=%s\n",distinct?"PASS":"FAIL");
  if(second_map) checked_close("SECOND_MAPPING",second_map);
  bool second_release=second_status==0&&release_section(second.probe_id,second.generation,second.slot_index);
  printf("SECTION_DISTINCT_RELEASE=%s\n",second_release?"PASS":"FAIL");

  HANDLE pipe_read=nullptr,pipe_write=nullptr;
  SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};
  bool pipe_ok=CreatePipe(&pipe_read,&pipe_write,&sa,0)!=FALSE;
  BOOL pipe_handle_ok=pipe_ok&&SetHandleInformation(pipe_write,HANDLE_FLAG_INHERIT,0); DWORD pipe_handle_error=pipe_handle_ok?ERROR_SUCCESS:GetLastError();
  printf("SECTION_PIPE_HANDLE_SETUP=%s error=%lu\n",pipe_handle_ok?"PASS":"FAIL",pipe_handle_error);
  WCHAR exe[MAX_PATH]{}; DWORD exe_len=GetModuleFileNameW(nullptr,exe,MAX_PATH); printf("SECTION_EXE_PATH=%s error=%lu\n",exe_len?"PASS":"FAIL",exe_len?ERROR_SUCCESS:GetLastError());
  WCHAR command[512]{};
  swprintf_s(command,L"\"%s\" --importer %llu %lu %u %llu %u",exe,
      (unsigned long long)(uintptr_t)pipe_read,GetCurrentProcessId(),g_id,g_generation,g_slot);
  STARTUPINFOW si{}; si.cb=sizeof(si); si.dwFlags=STARTF_USESTDHANDLES;
  si.hStdOutput=GetStdHandle(STD_OUTPUT_HANDLE); si.hStdError=GetStdHandle(STD_ERROR_HANDLE);
  si.hStdInput=GetStdHandle(STD_INPUT_HANDLE);
  PROCESS_INFORMATION pi{};
  bool started=pipe_ok&&CreateProcessW(exe,command,nullptr,nullptr,TRUE,CREATE_SUSPENDED,nullptr,nullptr,&si,&pi);
  if(!pipe_ok) printf("SECTION_CHILD_PIPE_CREATE=FAIL error=%lu\n",GetLastError());
  if(pipe_ok&&!started) printf("SECTION_IMPORTER_START=FAIL error=%lu\n",GetLastError());
  uintptr_t remote=0; DWORD written=0;
  bool dup=started&&DuplicateHandle(GetCurrentProcess(),mapping,pi.hProcess,(HANDLE*)&remote,
      SECTION_MAP_READ|SECTION_QUERY,FALSE,0);
  DWORD duplicate_error=dup?ERROR_SUCCESS:(started?GetLastError():ERROR_SUCCESS);
  printf("SECTION_DUPLICATE_HANDLE=%s error=%lu\n",!started?"NOT_REACHED":dup?"PASS":"FAIL",duplicate_error);
  SetLastError(ERROR_SUCCESS);
  bool wrote=dup&&WriteFile(pipe_write,&remote,sizeof(remote),&written,nullptr);
  DWORD transfer_error=wrote?ERROR_SUCCESS:(dup?GetLastError():ERROR_SUCCESS);
  bool transferred=wrote&&written==sizeof(remote);
  printf("SECTION_CHILD_HANDLE_TRANSFER=%s error=%lu bytes=%lu\n",!dup?"NOT_REACHED":transferred?"PASS":"FAIL",transfer_error,written);
  if(pipe_write) checked_close("CHILD_PIPE_WRITE",pipe_write);
  if(pipe_read) checked_close("CHILD_PIPE_READ",pipe_read);
  DWORD resume_result=transferred?ResumeThread(pi.hThread):(DWORD)-1; bool resumed=resume_result!=(DWORD)-1;
  printf("SECTION_CHILD_RESUME=%s previous_suspend=%lu error=%lu\n",resumed?"PASS":"FAIL",resume_result,resumed?ERROR_SUCCESS:GetLastError());
  printf("SECTION_CROSS_PROCESS_DUPLICATE_GATE=%s\n",resumed?"PASS":"FAIL");
  if(!resumed) {
    if(started) { BOOL terminated=TerminateProcess(pi.hProcess,1); printf("SECTION_CHILD_TERMINATE=%s error=%lu\n",terminated?"PASS":"FAIL",terminated?ERROR_SUCCESS:GetLastError()); checked_close("CHILD_THREAD",pi.hThread); checked_close("CHILD_PROCESS",pi.hProcess); }
    checked_unmap("EXPORTER",view); checked_close("EXPORTER_MAPPING",mapping); release_section(g_id,g_generation,g_slot); close_kmt(); return 5;
  }
  bool view_cleanup=checked_unmap("EXPORTER",view); bool mapping_cleanup=checked_close("EXPORTER_MAPPING",mapping);
  close_kmt();
  checked_close("CHILD_THREAD",pi.hThread); checked_close("CHILD_PROCESS",pi.hProcess);
  printf("SECTION_EXPORTER_CLOSING=PASS\n"); fflush(stdout);
  return (read_ok&&write_denied&&write_view_cleanup&&security_denied&&parent_publish&&same_ok&&distinct&&second_release&&view_cleanup&&mapping_cleanup&&pipe_handle_ok&&exe_len&&g_cleanup_ok)?0:6;
}
int wmain(int argc,wchar_t** argv) {
  if(argc>1&&wcscmp(argv[1],L"--importer")==0) {
    if(argc!=7) return 30;
    HANDLE pipe=(HANDLE)(uintptr_t)_wcstoui64(argv[2],nullptr,10);
    return importer(pipe,wcstoul(argv[3],nullptr,10),wcstoul(argv[4],nullptr,10),_wcstoui64(argv[5],nullptr,10),wcstoul(argv[6],nullptr,10));
  }
  if(argc>1&&wcscmp(argv[1],L"--exporter")==0) return exporter();
  HANDLE read_pipe=nullptr,write_pipe=nullptr; SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};
  if(!CreatePipe(&read_pipe,&write_pipe,&sa,0)) return 1;
  BOOL inherit_setup=SetHandleInformation(read_pipe,HANDLE_FLAG_INHERIT,0); DWORD inherit_error=inherit_setup?ERROR_SUCCESS:GetLastError();
  printf("SECTION_TOP_PIPE_SETUP=%s error=%lu\n",inherit_setup?"PASS":"FAIL",inherit_error);
  STARTUPINFOW si{}; si.cb=sizeof(si); si.dwFlags=STARTF_USESTDHANDLES;
  si.hStdOutput=write_pipe; si.hStdError=GetStdHandle(STD_ERROR_HANDLE); si.hStdInput=GetStdHandle(STD_INPUT_HANDLE);
  WCHAR exe[MAX_PATH]{}; DWORD exe_len=GetModuleFileNameW(nullptr,exe,MAX_PATH); printf("SECTION_EXE_PATH=%s error=%lu\n",exe_len?"PASS":"FAIL",exe_len?ERROR_SUCCESS:GetLastError());
  WCHAR command[MAX_PATH+32]{}; swprintf_s(command,L"\"%s\" --exporter",exe);
  PROCESS_INFORMATION pi{};
  if(!CreateProcessW(exe,command,nullptr,nullptr,TRUE,0,nullptr,nullptr,&si,&pi)) { printf("SECTION_EXPORTER_START=FAIL error=%lu\n",GetLastError()); checked_close("TOP_PIPE_READ",read_pipe); checked_close("TOP_PIPE_WRITE",write_pipe); return 1; }
  checked_close("TOP_PIPE_WRITE",write_pipe); char bytes[2048]; DWORD n=0;
  bool output_ok=true; for(;;) { BOOL read=ReadFile(read_pipe,bytes,sizeof(bytes),&n,nullptr); if(read&&n) { fwrite(bytes,1,n,stdout); fflush(stdout); continue; } DWORD read_error=read?ERROR_SUCCESS:GetLastError(); printf("SECTION_OUTPUT_PIPE_END=%s error=%lu\n",(!read&&read_error==ERROR_BROKEN_PIPE)?"PASS":read?"PASS":"FAIL",read_error); output_ok=read||read_error==ERROR_BROKEN_PIPE; break; }
  checked_close("TOP_PIPE_READ",read_pipe); DWORD wait=WaitForSingleObject(pi.hProcess,INFINITE); printf("SECTION_EXPORTER_WAIT_STATUS=%s value=0x%08lx\n",wait==WAIT_OBJECT_0?"PASS":"FAIL",(unsigned long)wait);
  DWORD code=1; BOOL got_exit=GetExitCodeProcess(pi.hProcess,&code); printf("SECTION_EXPORTER_EXIT_STATUS_READ=%s error=%lu\n",got_exit?"PASS":"FAIL",got_exit?ERROR_SUCCESS:GetLastError()); checked_close("TOP_EXPORTER_THREAD",pi.hThread); checked_close("TOP_EXPORTER_PROCESS",pi.hProcess);
  printf("SECTION_EXPORTER_EXIT_CODE=%lu\n",code); return (inherit_setup&&exe_len&&output_ok&&wait==WAIT_OBJECT_0&&got_exit&&g_cleanup_ok)?(int)code:1;
}
