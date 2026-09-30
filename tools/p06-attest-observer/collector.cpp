#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <evntprov.h>
#include <atomic>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

static const GUID real_guid={0x7b8bf667,0x80a2,0x4e27,{0xbf,0xf8,0x8a,0x67,0xab,0x47,0xc6,0xac}};
static const GUID test_guid={0x239f86a1,0x41b7,0x4a93,{0xa8,0x91,0x63,0x7b,0x2e,0x81,0x44,0xfa}};
static const GUID handshake_guid={0x4d4a6219,0x63aa,0x4cb7,{0xab,0x90,0x51,0x52,0x7a,0xe4,0x0d,0x32}};
static const EVENT_DESCRIPTOR descriptor={1,1,0,4,0,0,1};
struct Capture {
 GUID provider; FILE* file=nullptr; std::atomic<unsigned long long> count{0}; std::atomic<bool> io_failed{false};
 TRACEHANDLE reader=INVALID_PROCESSTRACE_HANDLE; HANDLE active=nullptr; HANDLE dispatched=nullptr; std::atomic<ULONG> process_status{ERROR_IO_PENDING};
};
static void WINAPI receive(EVENT_RECORD* e) {
 auto* c=static_cast<Capture*>(e->UserContext);
 if(IsEqualGUID(e->EventHeader.ProviderId,handshake_guid) && e->EventHeader.ProcessId==GetCurrentProcessId()) { SetEvent(c->active); return; }
 if (!IsEqualGUID(e->EventHeader.ProviderId,c->provider)) return;
 if (fprintf(c->file,"{\"event_id\":%u,\"event_version\":%u,\"header_pid\":%lu,\"header_tid\":%lu,\"header_timestamp\":%lld,\"raw_hex\":\"",e->EventHeader.EventDescriptor.Id,e->EventHeader.EventDescriptor.Version,e->EventHeader.ProcessId,e->EventHeader.ThreadId,e->EventHeader.TimeStamp.QuadPart)<0) c->io_failed=true;
 auto* b=static_cast<const unsigned char*>(e->UserData);
 for (unsigned i=0;i<e->UserDataLength;i++) if(fprintf(c->file,"%02x",b[i])<0)c->io_failed=true;
 if(fputs("\"}\n",c->file)==EOF || fflush(c->file)!=0)c->io_failed=true;
 c->count++;
}
static DWORD WINAPI process(void* p) {
 auto* c=static_cast<Capture*>(p); SetEvent(c->dispatched);
 c->process_status=ProcessTrace(&c->reader,1,nullptr,nullptr); return 0;
}
static void put32(unsigned char* b,unsigned offset,uint32_t value){for(unsigned i=0;i<4;i++)b[offset+i]=static_cast<unsigned char>(value>>(8*i));}
static void put64(unsigned char* b,unsigned offset,uint64_t value){for(unsigned i=0;i<8;i++)b[offset+i]=static_cast<unsigned char>(value>>(8*i));}
static bool emit_test() {
 REGHANDLE h=0; if(EventRegister(&test_guid,nullptr,nullptr,&h)!=ERROR_SUCCESS)return false;
 bool ok=EventEnabled(h,&descriptor)!=0;
 LARGE_INTEGER frequency; QueryPerformanceFrequency(&frequency);
 for(unsigned p=1;p<=5 && ok;p++) {
  unsigned char b[128]={}; LARGE_INTEGER qpc; QueryPerformanceCounter(&qpc);
  put32(b,0,0x314f4150);put32(b,4,1);put32(b,8,128);put32(b,12,p);
  put64(b,16,0x1122334455667788ULL);put64(b,24,1);put64(b,32,qpc.QuadPart);put64(b,40,p);
  put32(b,48,GetCurrentProcessId());put32(b,52,GetCurrentThreadId());put32(b,56,7);put32(b,60,4);put64(b,64,0xaabbccdd);
  for(unsigned i=0;i<16;i++)b[72+i]=static_cast<unsigned char>(i);
  put32(b,100,1);put64(b,112,1);put64(b,120,frequency.QuadPart);
  EVENT_DATA_DESCRIPTOR data;EventDataDescCreate(&data,b,sizeof(b));ok=EventWrite(h,&descriptor,1,&data)==ERROR_SUCCESS;
 }
 if(EventUnregister(h)!=ERROR_SUCCESS)ok=false;
 return ok;
}
static FILE* open_file(const std::wstring& path){return _wfopen(path.c_str(),L"wb");}
int wmain(int argc,wchar_t** argv) {
 if(argc<3 || argc>4 || (std::wstring(argv[1])!=L"--capture" && std::wstring(argv[1])!=L"--selftest")) {
  fwprintf(stderr,L"usage: collector.exe --capture|--selftest NEW_RUN_DIRECTORY [duration_seconds 1..600]\n");return 2;
 }
 bool selftest=std::wstring(argv[1])==L"--selftest";std::wstring dir=argv[2];
 wchar_t* end=nullptr;unsigned long seconds=argc==4?wcstoul(argv[3],&end,10):600;
 if(seconds<1 || seconds>600 || (end && *end))return 2;
 if(!CreateDirectoryW(dir.c_str(),nullptr)){fwprintf(stderr,L"run directory must be new, parent must exist: %lu\n",GetLastError());return 2;}
 Capture c;c.provider=selftest?test_guid:real_guid;c.file=open_file(dir+L"\\events.jsonl");if(!c.file)return 2;
 wchar_t name[128];swprintf(name,128,L"HeliosP06Observe-%lu-%llu",GetCurrentProcessId(),GetTickCount64());
 std::vector<unsigned char> memory(sizeof(EVENT_TRACE_PROPERTIES)+sizeof(name));auto* props=reinterpret_cast<EVENT_TRACE_PROPERTIES*>(memory.data());
 props->Wnode.BufferSize=static_cast<ULONG>(memory.size());props->Wnode.Flags=WNODE_FLAG_TRACED_GUID;props->Wnode.ClientContext=1;
 props->BufferSize=16;props->MinimumBuffers=4;props->MaximumBuffers=16;props->LogFileMode=EVENT_TRACE_REAL_TIME_MODE | EVENT_TRACE_NO_PER_PROCESSOR_BUFFERING;props->FlushTimer=1;props->LoggerNameOffset=sizeof(EVENT_TRACE_PROPERTIES);
 TRACEHANDLE session=0;ULONG start=StartTraceW(&session,name,props);ULONG enable=ERROR_IO_PENDING,disable=ERROR_IO_PENDING,stop=ERROR_IO_PENDING; bool emitted=false;HANDLE thread=nullptr;
 if(start==ERROR_SUCCESS) {
  EVENT_TRACE_LOGFILEW input={};input.LoggerName=name;input.ProcessTraceMode=PROCESS_TRACE_MODE_REAL_TIME|PROCESS_TRACE_MODE_EVENT_RECORD;input.EventRecordCallback=receive;input.Context=&c;
  c.reader=OpenTraceW(&input);
  if(c.reader!=INVALID_PROCESSTRACE_HANDLE) {
   c.active=CreateEventW(nullptr,TRUE,FALSE,nullptr);
   c.dispatched=CreateEventW(nullptr,TRUE,FALSE,nullptr);if(c.dispatched)thread=CreateThread(nullptr,0,process,&c,0,nullptr);
   if(thread && WaitForSingleObject(c.dispatched,5000)==WAIT_OBJECT_0) {
    REGHANDLE handshake=0;
    bool handshake_ok=c.active && EventRegister(&handshake_guid,nullptr,nullptr,&handshake)==ERROR_SUCCESS;
    if(handshake_ok)handshake_ok=EnableTraceEx2(session,&handshake_guid,EVENT_CONTROL_CODE_ENABLE_PROVIDER,4,1,0,5000,nullptr)==ERROR_SUCCESS;
    if(handshake_ok)handshake_ok=EventWrite(handshake,&descriptor,0,nullptr)==ERROR_SUCCESS;
    if(handshake_ok)handshake_ok=WaitForSingleObject(c.active,5000)==WAIT_OBJECT_0;
    if(handshake)EventUnregister(handshake);
    EnableTraceEx2(session,&handshake_guid,EVENT_CONTROL_CODE_DISABLE_PROVIDER,0,0,0,5000,nullptr);
    if(handshake_ok)enable=EnableTraceEx2(session,&c.provider,EVENT_CONTROL_CODE_ENABLE_PROVIDER,4,1,0,5000,nullptr);
    if(enable==ERROR_SUCCESS && WaitForSingleObject(thread,0)==WAIT_TIMEOUT) {
     FILE* ready=open_file(dir+L"\\ready.json");if(ready){fprintf(ready,"{\"enabled\":true,\"consumer_callback_observed\":true,\"mode\":\"%s\",\"pid\":%lu}\n",selftest?"SELFTEST_ONLY":"REAL_PROVIDER",GetCurrentProcessId());if(fclose(ready)!=0)c.io_failed=true;}else c.io_failed=true;
     if(selftest)emitted=emit_test();
     ULONGLONG deadline=GetTickCount64()+seconds*1000ULL;
     while(GetTickCount64()<deadline && WaitForSingleObject(thread,0)==WAIT_TIMEOUT && !c.io_failed) {
      if(GetFileAttributesW((dir+L"\\stop").c_str())!=INVALID_FILE_ATTRIBUTES)break;
      if(selftest && c.count>=5)break;
      Sleep(100);
     }
    }
   }
  }
  disable=EnableTraceEx2(session,&c.provider,EVENT_CONTROL_CODE_DISABLE_PROVIDER,0,0,0,5000,nullptr);
  stop=ControlTraceW(session,name,props,EVENT_TRACE_CONTROL_STOP);
 }
 bool drained=false;
 if(thread){drained=WaitForSingleObject(thread,10000)==WAIT_OBJECT_0;}
 if(c.reader!=INVALID_PROCESSTRACE_HANDLE)CloseTrace(c.reader);
 if(thread && !drained) { // No stack/file destruction while the callback can still execute.
  FILE* failure=open_file(dir+L"\\summary.json");if(failure){fputs("{\"complete\":false,\"reason\":\"consumer_drain_timeout\",\"EventsLost\":null,\"LogBuffersLost\":null,\"RealTimeBuffersLost\":null}\n",failure);fclose(failure);}ExitProcess(3);
 }
 if(thread)CloseHandle(thread);
 if(c.dispatched)CloseHandle(c.dispatched);
 if(c.active)CloseHandle(c.active);
 if(fclose(c.file)!=0)c.io_failed=true;
 bool complete=start==0 && enable==0 && disable==0 && stop==0 && drained && c.process_status==0 && !c.io_failed && (!selftest || (emitted && c.count==5));
 FILE* summary=open_file(dir+L"\\summary.json");if(!summary)return 3;
 fprintf(summary,"{\"complete\":%s,\"mode\":\"%s\",\"events\":%llu,\"start_status\":%lu,\"enable_status\":%lu,\"disable_status\":%lu,\"stop_status\":%lu,\"process_trace_status\":%lu,\"EventsLost\":",complete?"true":"false",selftest?"SELFTEST_ONLY":"REAL_PROVIDER",c.count.load(),start,enable,disable,stop,c.process_status.load());
 if(stop==0)fprintf(summary,"%lu,\"LogBuffersLost\":%lu,\"RealTimeBuffersLost\":%lu",props->EventsLost,props->LogBuffersLost,props->RealTimeBuffersLost);else fputs("null,\"LogBuffersLost\":null,\"RealTimeBuffersLost\":null",summary);
 fprintf(summary,",\"io_failed\":%s}\n",c.io_failed?"true":"false");if(fclose(summary)!=0)return 3;
 return complete?0:3;
}
