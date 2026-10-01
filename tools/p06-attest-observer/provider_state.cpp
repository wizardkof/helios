#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <evntrace.h>
#include <cstdio>
#include <cstring>
#include "provider_state_parse.hpp"
static_assert(sizeof(TRACE_GUID_INFO)==8 && sizeof(TRACE_PROVIDER_INSTANCE_INFO)==16 && sizeof(TRACE_ENABLE_INFO)==32, "ETW ABI layout differs");
static GUID provider={0x7b8bf667,0x80a2,0x4e27,{0xbf,0xf8,0x8a,0x67,0xab,0x47,0xc6,0xac}};
static ULONG query(TRACE_QUERY_INFO_CLASS kind,void* in,ULONG length,std::vector<unsigned char>& out){
 ULONG needed=0,status=EnumerateTraceGuidsEx(kind,in,length,nullptr,0,&needed);
 for(unsigned attempt=0;attempt<8 && (status==ERROR_INSUFFICIENT_BUFFER || (status==ERROR_SUCCESS && needed>out.size()));attempt++){
  if(needed>16*1024*1024)return ERROR_NOT_ENOUGH_MEMORY;
  out.assign(needed,0);status=EnumerateTraceGuidsEx(kind,in,length,out.data(),static_cast<ULONG>(out.size()),&needed);
 }
 if(status==ERROR_SUCCESS){if(needed>out.size())return ERROR_INVALID_DATA;out.resize(needed);}return status;
}
int main(){
 FILETIME ft;GetSystemTimeAsFileTime(&ft);ULARGE_INTEGER time;time.LowPart=ft.dwLowDateTime;time.HighPart=ft.dwHighDateTime;
 LARGE_INTEGER before,after;QueryPerformanceCounter(&before);
 std::vector<unsigned char> list,data;ULONG list_status=query(TraceGuidQueryList,nullptr,0,list),info_status=ERROR_IO_PENDING;
 State result;bool listed=false;
 if(list_status==ERROR_SUCCESS){
  if(list.size()%sizeof(GUID))list_status=ERROR_INVALID_DATA;
  else {for(size_t p=0;p<list.size();p+=sizeof(GUID))if(std::memcmp(list.data()+p,&provider,sizeof(provider))==0)listed=true;
   if(!listed)result.state="ABSENT";
   else{info_status=query(TraceGuidQueryInfo,&provider,sizeof(provider),data);if(info_status==ERROR_SUCCESS)result=parse_state(data);}
  }
 }
 QueryPerformanceCounter(&after);
 printf("{\"provider_guid\":\"7b8bf667-80a2-4e27-bff8-8a67ab47c6ac\",\"query\":\"EnumerateTraceGuidsEx\",\"state\":\"%s\",\"snapshot_only\":true,\"filetime_utc\":%llu,\"qpc_begin\":%lld,\"qpc_end\":%lld,\"list_status\":%lu,\"info_status\":",result.state.c_str(),time.QuadPart,before.QuadPart,after.QuadPart,list_status);
 if(listed)printf("%lu",info_status);else printf("null");
 printf(",\"registered_instances\":");if(result.state=="FAILED")printf("null");else printf("%u",result.registered);
 printf(",\"instances\":[");bool first=true;
 for(const auto& instance:result.instances){
  if(!first)printf(",");
  first=false;
  printf("{\"pid\":%u,\"flags\":%u,\"pre_enabled\":%s,\"EnableCount\":%llu,\"sessions\":[",instance.pid,instance.flags,(instance.flags&2)?"true":"false",static_cast<unsigned long long>(instance.enables.size()));bool first_session=true;
  for(const auto& e:instance.enables){if(!first_session)printf(",");first_session=false;printf("{\"IsEnabled\":%u,\"LoggerId\":%u,\"Level\":%u,\"EnableProperty\":%u,\"MatchAnyKeyword\":%llu,\"MatchAllKeyword\":%llu}",e.enabled,e.logger,e.level,e.property,static_cast<unsigned long long>(e.any),static_cast<unsigned long long>(e.all));}
  printf("]}");
 }
 printf("]}\n");if(fflush(stdout)!=0)return 3;
 return result.state=="OFF"?0:result.state=="ABSENT"?2:result.state=="ENABLED"?1:3;
}
