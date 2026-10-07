#pragma once
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <wincrypt.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <winternl.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <stdexcept>
#include <algorithm>

// Build-time identities keep normal ICD discovery and bind acceptance to each candidate.
#ifndef P06_EXPECT_ICD_X64_SHA256
#define P06_EXPECT_ICD_X64_SHA256 "d8bd1640b5eed072aa4d26cae5b2344179f23ba3dadc60f9c721c5c9da3034ef"
#endif
#ifndef P06_EXPECT_ICD_X86_SHA256
#define P06_EXPECT_ICD_X86_SHA256 "3832702c666633b7132dc16c25749eb5e9839517892b0c81af1251cc7cdffc5b"
#endif
static_assert(sizeof(P06_EXPECT_ICD_X64_SHA256)==65 && sizeof(P06_EXPECT_ICD_X86_SHA256)==65,"Candidate SHA256 lengths");

namespace p06 {
inline bool cleanup_ok=true;
inline void require(bool ok,const char* what) { if(!ok) throw std::runtime_error(what); }
inline void vkcheck(VkResult r,const char* what) { printf("VK_CALL=%s RESULT=%d\n",what,int(r)); if(r!=VK_SUCCESS) throw std::runtime_error(what); }
struct Handle {
 HANDLE h=nullptr;
 Handle()=default; explicit Handle(HANDLE value):h(value){}
 Handle(const Handle&)=delete; Handle& operator=(const Handle&)=delete;
 Handle(Handle&& o) noexcept:h(o.h){o.h=nullptr;}
 Handle& operator=(Handle&& o) noexcept { reset();h=o.h;o.h=nullptr;return *this; }
 void reset(HANDLE value=nullptr){if(h&&h!=INVALID_HANDLE_VALUE){BOOL ok=CloseHandle(h);printf("CLOSE_HANDLE PID=%lu HANDLE=%p OK=%d\n",GetCurrentProcessId(),h,int(ok));cleanup_ok &= ok!=0;}h=value;}
 HANDLE release(){HANDLE v=h;h=nullptr;return v;}
 ~Handle(){reset();}
};
inline std::string utf8(const std::wstring& s) { if(s.empty())return {}; int n=WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);std::string r(n,'\0');WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),r.data(),n,nullptr,nullptr);return r; }
inline std::string hex(const void* data,size_t n){auto p=(const unsigned char*)data;std::string s;for(size_t i=0;i<n;i++){char b[3];snprintf(b,3,"%02x",p[i]);s+=b;}return s;}
inline std::wstring object_name(HANDLE h) {
 using Query=LONG(NTAPI*)(HANDLE,ULONG,PVOID,ULONG,PULONG);
 auto query=(Query)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryObject");
 require(query!=nullptr,"NtQueryObject unavailable");
 alignas(8) unsigned char b[4096]{};ULONG n=0;LONG s=query(h,1,b,sizeof(b),&n);
 printf("OBJECT_NAME_STATUS HANDLE=%p NTSTATUS=%08lx\n",h,(unsigned long)s);
 if(s<0)return {};
 auto u=(UNICODE_STRING*)b; require(u->Length<=sizeof(b)&&u->Length%2==0,"Object name length invalid");
 uintptr_t start=(uintptr_t)u->Buffer,end=start+u->Length;
 require(start>=(uintptr_t)b&&end<=(uintptr_t)b+sizeof(b),"Object name buffer invalid");
 return std::wstring(u->Buffer,u->Length/2);
}
inline std::string sha256_file(const wchar_t* path,std::wstring* finalPath=nullptr) {
 Handle f(CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,0,nullptr));
 require(f.h!=INVALID_HANDLE_VALUE,"Hash file open failed");
 if(finalPath){wchar_t p[2048];DWORD n=GetFinalPathNameByHandleW(f.h,p,2048,FILE_NAME_NORMALIZED);require(n&&n<2048,"Final file path failed");*finalPath=std::wstring(p,n);}
 HCRYPTPROV prov=0;HCRYPTHASH hash=0;
 require(CryptAcquireContextW(&prov,nullptr,nullptr,PROV_RSA_AES,CRYPT_VERIFYCONTEXT)!=0,"CryptAcquireContext failed");
 if(!CryptCreateHash(prov,CALG_SHA_256,0,0,&hash)){CryptReleaseContext(prov,0);throw std::runtime_error("CryptCreateHash failed");}
 unsigned char buf[65536];DWORD n=0;bool ok=true;
 while(true){if(!ReadFile(f.h,buf,sizeof(buf),&n,nullptr)){ok=false;break;}if(!n)break;if(!CryptHashData(hash,buf,n,0)){ok=false;break;}}
 unsigned char digest[32];DWORD len=32;ok=ok&&CryptGetHashParam(hash,HP_HASHVAL,digest,&len,0);
 CryptDestroyHash(hash);CryptReleaseContext(prov,0);require(ok&&len==32,"File SHA256 failed");return hex(digest,32);
}
inline void process_evidence(int argc,char**argv){
 setvbuf(stdout,nullptr,_IONBF,0);DWORD session=0;require(ProcessIdToSessionId(GetCurrentProcessId(),&session)!=0,"Process session query");
 DWORD parent=0;Handle snap(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0));PROCESSENTRY32 pe{};pe.dwSize=sizeof(pe);
 if(Process32First(snap.h,&pe))do{if(pe.th32ProcessID==GetCurrentProcessId())parent=pe.th32ParentProcessID;}while(Process32Next(snap.h,&pe));
 printf("PROCESS PID=%lu PARENT=%lu SESSION=%lu ARCH=x%u\n",GetCurrentProcessId(),parent,session,unsigned(sizeof(void*)*8));
 for(int i=0;i<argc;i++)printf("ARG[%d]=%s\n",i,argv[i]);
 require(session!=0,"Desktop execution refuses session zero");
 HANDLE raw=nullptr;require(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw)!=0,"OpenProcessToken");Handle token(raw);
 DWORD n=0;TOKEN_ELEVATION e{};TOKEN_ELEVATION_TYPE t{};GetTokenInformation(raw,TokenElevation,&e,sizeof(e),&n);GetTokenInformation(raw,TokenElevationType,&t,sizeof(t),&n);
 printf("TOKEN ELEVATED=%lu TYPE=%u\n",e.TokenIsElevated,unsigned(t));
 GetTokenInformation(raw,TokenUser,nullptr,0,&n);std::vector<unsigned char> user(n);require(GetTokenInformation(raw,TokenUser,user.data(),n,&n)!=0,"TokenUser");
 auto sid=((TOKEN_USER*)user.data())->User.Sid;char* text=nullptr;require(ConvertSidToStringSidA(sid,&text)!=0,"SID format");printf("USER_SID=%s\n",text);LocalFree(text);
 char account[256],domain[256];DWORD a=256,d=256;SID_NAME_USE use;require(LookupAccountSidA(nullptr,sid,account,&a,domain,&d,&use)!=0,"LookupAccountSid");printf("USER=%s\\%s\n",domain,account);
 GetTokenInformation(raw,TokenIntegrityLevel,nullptr,0,&n);std::vector<unsigned char> il(n);require(GetTokenInformation(raw,TokenIntegrityLevel,il.data(),n,&n)!=0,"Integrity");auto ilsid=((TOKEN_MANDATORY_LABEL*)il.data())->Label.Sid;printf("INTEGRITY_RID=%lu\n",*GetSidSubAuthority(ilsid,*GetSidSubAuthorityCount(ilsid)-1));
 for(const char* var:{"VK_DRIVER_FILES","VK_ICD_FILENAMES","VK_ADD_DRIVER_FILES","VK_LOADER_DRIVERS_SELECT","VK_LOADER_DRIVERS_DISABLE","HELIOS_P06_E1_CARRIER_EXPORT"})printf("ENV_%s=%s\n",var,getenv(var)?getenv(var):"<unset>");
 wchar_t exe[2048];require(GetModuleFileNameW(nullptr,exe,2048)>0,"Executable path");printf("EXE_SHA256=%s\n",sha256_file(exe).c_str());
}
inline void module_evidence(bool enforce){
 Handle snap(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,GetCurrentProcessId()));require(snap.h!=INVALID_HANDLE_VALUE,"Module snapshot");
 MODULEENTRY32W m{};m.dwSize=sizeof(m);unsigned icds=0;bool candidate=false;
 if(Module32FirstW(snap.h,&m))do{
  std::wstring name=m.szModule;std::transform(name.begin(),name.end(),name.begin(),::towlower);
  bool icd=name.find(L"vulkan_virtio")!=std::wstring::npos;
  if(icd||name==L"vulkan-1.dll"){
   std::wstring final;auto hash=sha256_file(m.szExePath,&final);
   auto dos=(IMAGE_DOS_HEADER*)m.modBaseAddr;auto nt=(IMAGE_NT_HEADERS*)((unsigned char*)m.modBaseAddr+dos->e_lfanew);
   DWORD unused=0;DWORD n=GetFileVersionInfoSizeW(m.szExePath,&unused);std::vector<unsigned char> ver(n);std::string version="absent";
   if(n&&GetFileVersionInfoW(m.szExePath,0,n,ver.data())){VS_FIXEDFILEINFO* f=nullptr;UINT z=0;if(VerQueryValueW(ver.data(),L"\\",(void**)&f,&z)){char v[80];snprintf(v,sizeof(v),"%u.%u.%u.%u",HIWORD(f->dwFileVersionMS),LOWORD(f->dwFileVersionMS),HIWORD(f->dwFileVersionLS),LOWORD(f->dwFileVersionLS));version=v;}}
   printf("MODULE PID=%lu KIND=%s PATH=%s PHYSICAL_FILE=%s SHA256=%s PE=%04x VERSION=%s\n",GetCurrentProcessId(),icd?"ICD":"LOADER",utf8(m.szExePath).c_str(),utf8(final).c_str(),hash.c_str(),nt->FileHeader.Machine,version.c_str());
   if(icd){icds++;candidate=hash==(sizeof(void*)==8?P06_EXPECT_ICD_X64_SHA256:P06_EXPECT_ICD_X86_SHA256);}
  }
 }while(Module32NextW(snap.h,&m));
 if(enforce)require(icds==1&&candidate,"Selected process ICD module identity mismatch");
}
// Mirror of protocol/src/escape.rs at 42d7e734. Layout is asserted on both PE ABIs.
struct EscapeHeader{uint32_t magic,cmd_type,version,size;};
struct alignas(8) CarrierRequest {
 EscapeHeader hdr;uint32_t op,reserved_op;uint8_t carrier_id[16];uint64_t generation;
 uint32_t slot_index,lease_flags;uint64_t value;uint32_t response_type,status,expected_record_version,reserved;
 uint64_t user_handle;uint16_t object_name[128],native_name[128];
};
struct alignas(8) Record {uint64_t magic;uint32_t version,size;uint8_t carrier_id[16];uint64_t sequence,completed_value,terminal_error_value;uint32_t terminal_response_type,reserved_tail;};
static_assert(sizeof(CarrierRequest)==600&&offsetof(CarrierRequest,carrier_id)==24&&offsetof(CarrierRequest,generation)==40&&offsetof(CarrierRequest,value)==56&&offsetof(CarrierRequest,user_handle)==80&&offsetof(CarrierRequest,object_name)==88&&offsetof(CarrierRequest,native_name)==344,"Production escape ABI");
static_assert(sizeof(Record)==64&&offsetof(Record,sequence)==32&&offsetof(Record,completed_value)==40&&offsetof(Record,terminal_error_value)==48&&offsetof(Record,terminal_response_type)==56,"Record ABI");
constexpr uint64_t magic=0x504636534543544eULL;
inline void init(CarrierRequest&r,uint32_t op){memset(&r,0,sizeof(r));r.hdr={0x48454c53,0x18,1,sizeof(r)};r.op=op;}
inline bool snapshot(HANDLE h,Record& record,bool expectE1){
 auto view=(const volatile Record*)MapViewOfFile(h,FILE_MAP_READ,0,0,sizeof(Record));
 if(!view){printf("SECTION_MAP HANDLE=%p ERROR=%lu\n",h,GetLastError());require(!expectE1,"Expected carrier Section mapping failed");return false;}
 bool stable=false;for(int n=0;n<1000;n++){uint64_t a=view->sequence;MemoryBarrier();memcpy(&record,(const void*)view,sizeof(record));MemoryBarrier();uint64_t b=view->sequence;if(a==b&&a==record.sequence&&!(a&1)){stable=true;break;}}
 require(UnmapViewOfFile((const void*)view)!=0,"Unmap snapshot");
 bool nonzero=false;for(auto b:record.carrier_id)nonzero|=b!=0;
 bool valid=stable&&record.magic==magic&&record.version==2&&record.size==64&&nonzero;
 printf("RECORD HANDLE=%p STABLE=%d MAGIC=%016llx VERSION=%u SIZE=%u ID=%s SEQUENCE=%llu COMPLETE=%llu ERROR_VALUE=%llu RESPONSE=%04x VALID_E1=%d\n",h,int(stable),(unsigned long long)record.magic,record.version,record.size,hex(record.carrier_id,16).c_str(),(unsigned long long)record.sequence,(unsigned long long)record.completed_value,(unsigned long long)record.terminal_error_value,record.terminal_response_type,int(valid));
 if(expectE1){require(valid,"Invalid E1 record");auto name=object_name(h);std::string expected="\\BaseNamedObjects\\HeliosP06Carrier_"+hex(record.carrier_id,16);printf("CARRIER_NATIVE_NAME=%s EXPECTED=%s\n",utf8(name).c_str(),expected.c_str());require(utf8(name)==expected,"Carrier object name mismatch");}
 return valid;
}
// Direct KMD CREATE fixtures only. Public Vulkan export regression never calls this.
inline Handle read_handle(const CarrierRequest&r){
 const auto id=hex(r.carrier_id,16);const std::wstring expected=L"\\BaseNamedObjects\\HeliosP06Carrier_"+std::wstring(id.begin(),id.end());
 const auto name=(const wchar_t*)r.native_name;
 require(expected.size()<128&&wcsnlen(name,128)==expected.size()&&expected==name,"Invalid native CREATE carrier name/ID");
 UNICODE_STRING u{};u.Buffer=const_cast<PWSTR>(name);u.Length=USHORT(expected.size()*sizeof(wchar_t));u.MaximumLength=u.Length+sizeof(wchar_t);
 OBJECT_ATTRIBUTES oa{};oa.Length=sizeof(oa);oa.ObjectName=&u;
 using Open=LONG(NTAPI*)(PHANDLE,ACCESS_MASK,POBJECT_ATTRIBUTES);
 auto fn=(Open)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtOpenSection");require(fn!=nullptr,"Native Section open unavailable");
 HANDLE h=nullptr;LONG status=fn(&h,SECTION_MAP_READ|SECTION_QUERY,&oa);
 printf("OPEN_KMD_CREATE_FIXTURE NATIVE=%s ACCESS=00000005 HANDLE=%p NTSTATUS=%08lx\n",utf8(expected).c_str(),h,(unsigned long)status);
 require(status==0&&h!=nullptr,"Open production CREATE fixture");return Handle(h);
}
// Mapping still uses FILE_MAP_READ. Native QUERY is requested only at fixture open.

struct Vulkan {
 HMODULE loader=nullptr;VkInstance instance=VK_NULL_HANDLE;VkPhysicalDevice physical=VK_NULL_HANDLE;VkDevice device=VK_NULL_HANDLE;VkQueue queue=VK_NULL_HANDLE;uint32_t family=0;VkPhysicalDeviceIDProperties id{};
 PFN_vkGetInstanceProcAddr gip=nullptr;PFN_vkGetDeviceProcAddr gdp=nullptr;
#define DEV_FUNCTIONS(X) X(DestroyDevice) X(GetDeviceQueue) X(CreateSemaphore) X(DestroySemaphore) X(GetSemaphoreWin32HandleKHR) X(ImportSemaphoreWin32HandleKHR) X(GetSemaphoreCounterValue) X(WaitSemaphores) X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) X(MapMemory) X(UnmapMemory) X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) X(BeginCommandBuffer) X(EndCommandBuffer) X(CmdFillBuffer) X(CmdPipelineBarrier) X(CreateFence) X(DestroyFence) X(QueueSubmit) X(WaitForFences)
#define FIELD(n) PFN_vk##n n=nullptr;
 DEV_FUNCTIONS(FIELD)
#undef FIELD
 template<typename F>F ip(const char* name){auto f=(F)gip(instance,name);require(f!=nullptr,name);return f;}
 void open(bool createDevice=true){
  loader=LoadLibraryW(L"vulkan-1.dll");require(loader!=nullptr,"Load installed Vulkan loader");gip=(PFN_vkGetInstanceProcAddr)GetProcAddress(loader,"vkGetInstanceProcAddr");require(gip!=nullptr,"vkGetInstanceProcAddr");
  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.pApplicationName="p06-e1-public-pair";app.apiVersion=VK_API_VERSION_1_2;
  VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};ci.pApplicationInfo=&app;
  vkcheck(((PFN_vkCreateInstance)gip(VK_NULL_HANDLE,"vkCreateInstance"))(&ci,nullptr,&instance),"vkCreateInstance");
  auto enumerate=ip<PFN_vkEnumeratePhysicalDevices>("vkEnumeratePhysicalDevices");uint32_t n=0;vkcheck(enumerate(instance,&n,nullptr),"enumerate-count");require(n>0&&n<64,"Physical device count");std::vector<VkPhysicalDevice> ds(n);vkcheck(enumerate(instance,&n,ds.data()),"enumerate-devices");
  auto props=ip<PFN_vkGetPhysicalDeviceProperties2>("vkGetPhysicalDeviceProperties2");unsigned matches=0;
  for(auto d:ds){VkPhysicalDeviceIDProperties ids{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};p.pNext=&ids;props(d,&p);printf("ENUM_DEVICE VENDOR=%04x DEVICE=%04x NAME=%s LUID_VALID=%u LUID=%s\n",p.properties.vendorID,p.properties.deviceID,p.properties.deviceName,ids.deviceLUIDValid,hex(ids.deviceLUID,8).c_str());
   if(p.properties.vendorID==0x10de&&p.properties.deviceID==0x2487&&strstr(p.properties.deviceName,"Virtio-GPU Venus")&&strstr(p.properties.deviceName,"NVIDIA GeForce RTX 3060")){physical=d;id=ids;matches++;}}
  require(matches==1,"Explicit Venus RTX3060 selection requires unique match");printf("SELECTED_DEVICE PID=%lu VENDOR=10de DEVICE=2487 LUID_VALID=%u LUID=%s\n",GetCurrentProcessId(),id.deviceLUIDValid,hex(id.deviceLUID,8).c_str());
  if(!createDevice){module_evidence(true);return;}
  VkPhysicalDeviceTimelineSemaphoreFeatures timeline{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};features.pNext=&timeline;ip<PFN_vkGetPhysicalDeviceFeatures2>("vkGetPhysicalDeviceFeatures2")(physical,&features);require(timeline.timelineSemaphore==VK_TRUE,"Timeline semaphore support");
  VkSemaphoreTypeCreateInfo st{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};st.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
  VkPhysicalDeviceExternalSemaphoreInfo ext{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO};ext.pNext=&st;ext.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;VkExternalSemaphoreProperties ep{VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES};ip<PFN_vkGetPhysicalDeviceExternalSemaphoreProperties>("vkGetPhysicalDeviceExternalSemaphoreProperties")(physical,&ext,&ep);printf("EXTERNAL_TIMELINE FEATURES=%x COMPATIBLE=%x\n",ep.externalSemaphoreFeatures,ep.compatibleHandleTypes);
  require((ep.externalSemaphoreFeatures&(VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT|VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT))==(VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT|VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT),"OPAQUE_WIN32 timeline support");
  auto qp=ip<PFN_vkGetPhysicalDeviceQueueFamilyProperties>("vkGetPhysicalDeviceQueueFamilyProperties");n=0;qp(physical,&n,nullptr);std::vector<VkQueueFamilyProperties> qs(n);qp(physical,&n,qs.data());family=UINT32_MAX;for(uint32_t i=0;i<n;i++)if(qs[i].queueCount&&(qs[i].queueFlags&VK_QUEUE_TRANSFER_BIT)){family=i;break;}require(family!=UINT32_MAX,"Transfer queue family");
  float priority=1;VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};qci.queueFamilyIndex=family;qci.queueCount=1;qci.pQueuePriorities=&priority;const char* extensions[]={VK_KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME};
  VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};dci.pNext=&timeline;dci.queueCreateInfoCount=1;dci.pQueueCreateInfos=&qci;dci.enabledExtensionCount=1;dci.ppEnabledExtensionNames=extensions;
  vkcheck(ip<PFN_vkCreateDevice>("vkCreateDevice")(physical,&dci,nullptr,&device),"vkCreateDevice");gdp=ip<PFN_vkGetDeviceProcAddr>("vkGetDeviceProcAddr");
#define LOAD(n) n=(PFN_vk##n)gdp(device,"vk" #n);require(n!=nullptr,"vk" #n);
  DEV_FUNCTIONS(LOAD)
#undef LOAD
  GetDeviceQueue(device,family,0,&queue);require(queue!=VK_NULL_HANDLE,"Queue selection");printf("SELECTED_QUEUE FAMILY=%u INDEX=0 DEVICE=%p QUEUE=%p\n",family,(void*)device,(void*)queue);module_evidence(true);
 }
 VkSemaphore semaphore(bool exportable,uint64_t initial=0){VkSemaphoreTypeCreateInfo ti{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};ti.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;ti.initialValue=initial;VkExportSemaphoreCreateInfo ei{VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO};ei.handleTypes=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;ti.pNext=exportable?&ei:nullptr;VkSemaphoreCreateInfo ci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};ci.pNext=&ti;VkSemaphore s;vkcheck(CreateSemaphore(device,&ci,nullptr,&s),"vkCreateSemaphore");return s;}
 Handle export_handle(VkSemaphore s){VkSemaphoreGetWin32HandleInfoKHR gi{VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR};gi.semaphore=s;gi.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;HANDLE h=nullptr;vkcheck(GetSemaphoreWin32HandleKHR(device,&gi,&h),"vkGetSemaphoreWin32HandleKHR");printf("EXPORTED_HANDLE PID=%lu HANDLE=%p\n",GetCurrentProcessId(),h);return Handle(h);}
 VkResult import_handle(VkSemaphore s,HANDLE h){VkImportSemaphoreWin32HandleInfoKHR ii{VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR};ii.semaphore=s;ii.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;ii.handle=h;VkResult r=ImportSemaphoreWin32HandleKHR(device,&ii);printf("IMPORT_HANDLE PID=%lu HANDLE=%p RESULT=%d\n",GetCurrentProcessId(),h,int(r));return r;}
 VkResult wait(VkSemaphore s,uint64_t value,uint64_t timeout,bool e1){require(!e1||timeout==0,"E1 blocking wait prohibited");VkSemaphoreWaitInfo wi{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};wi.semaphoreCount=1;wi.pSemaphores=&s;wi.pValues=&value;VkResult r=WaitSemaphores(device,&wi,timeout);printf("CONSUMER_WAIT TARGET=%llu TIMEOUT_NS=%llu RESULT=%d\n",(unsigned long long)value,(unsigned long long)timeout,int(r));return r;}
 void work(VkSemaphore signal=VK_NULL_HANDLE){
  VkBuffer buffer=VK_NULL_HANDLE;VkDeviceMemory memory=VK_NULL_HANDLE;VkCommandPool pool=VK_NULL_HANDLE;VkFence fence=VK_NULL_HANDLE;bool submitted=false,completed=false;
  try{
   VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bi.size=256;bi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;bi.sharingMode=VK_SHARING_MODE_EXCLUSIVE;vkcheck(CreateBuffer(device,&bi,nullptr,&buffer),"vkCreateBuffer");VkMemoryRequirements req{};GetBufferMemoryRequirements(device,buffer,&req);
   VkPhysicalDeviceMemoryProperties mp{};ip<PFN_vkGetPhysicalDeviceMemoryProperties>("vkGetPhysicalDeviceMemoryProperties")(physical,&mp);uint32_t type=UINT32_MAX;for(uint32_t i=0;i<mp.memoryTypeCount;i++)if((req.memoryTypeBits&(1u<<i))&&(mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)){type=i;break;}require(type!=UINT32_MAX,"Coherent readback memory");VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=req.size;ai.memoryTypeIndex=type;vkcheck(AllocateMemory(device,&ai,nullptr,&memory),"vkAllocateMemory");vkcheck(BindBufferMemory(device,buffer,memory,0),"vkBindBufferMemory");
   void* data=nullptr;vkcheck(MapMemory(device,memory,0,256,0,&data),"vkMapMemory-before");memset(data,0xa5,256);UnmapMemory(device,memory);
   VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pi.queueFamilyIndex=family;vkcheck(CreateCommandPool(device,&pi,nullptr,&pool),"vkCreateCommandPool");VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};ca.commandPool=pool;ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ca.commandBufferCount=1;VkCommandBuffer cmd;vkcheck(AllocateCommandBuffers(device,&ca,&cmd),"vkAllocateCommandBuffers");VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};vkcheck(BeginCommandBuffer(cmd,&begin),"vkBeginCommandBuffer");CmdFillBuffer(cmd,buffer,0,256,0x6e31a70c);VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;CmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);vkcheck(EndCommandBuffer(cmd),"vkEndCommandBuffer");
   VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};vkcheck(CreateFence(device,&fi,nullptr,&fence),"vkCreateFence");uint64_t value=7;VkTimelineSemaphoreSubmitInfo timeline{VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};timeline.signalSemaphoreValueCount=signal?1:0;timeline.pSignalSemaphoreValues=&value;VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};si.commandBufferCount=1;si.pCommandBuffers=&cmd;si.pNext=signal?&timeline:nullptr;si.signalSemaphoreCount=signal?1:0;si.pSignalSemaphores=&signal;vkcheck(QueueSubmit(queue,1,&si,fence),"vkQueueSubmit");submitted=true;vkcheck(WaitForFences(device,1,&fence,VK_TRUE,5000000000ULL),"vkWaitForFences-5s");completed=true;
   vkcheck(MapMemory(device,memory,0,256,0,&data),"vkMapMemory-readback");bool valid=true;for(unsigned i=0;i<64;i++)valid &= ((uint32_t*)data)[i]==0x6e31a70c;UnmapMemory(device,memory);require(valid,"GPU fill readback mismatch");printf("SELECTED_DEVICE_WORK=PASS PID=%lu BYTES=256 PATTERN=6e31a70c GPU_FENCE=SUCCESS SIGNAL_VALUE=%u\n",GetCurrentProcessId(),signal?7:0);
  }catch(...){if(submitted&&!completed){printf("WORK_COMPLETION_UNPROVEN=1 RESOURCE_DESTROY_DEFERRED_TO_PROCESS_EXIT=1\n");ExitProcess(91);}if(fence)DestroyFence(device,fence,nullptr);if(pool)DestroyCommandPool(device,pool,nullptr);if(buffer)DestroyBuffer(device,buffer,nullptr);if(memory)FreeMemory(device,memory,nullptr);throw;}
  DestroyFence(device,fence,nullptr);DestroyCommandPool(device,pool,nullptr);DestroyBuffer(device,buffer,nullptr);FreeMemory(device,memory,nullptr);
 }
 ~Vulkan(){if(device&&DestroyDevice)DestroyDevice(device,nullptr);if(instance&&gip){auto d=(PFN_vkDestroyInstance)gip(instance,"vkDestroyInstance");if(d)d(instance,nullptr);}if(loader)FreeLibrary(loader);}
};
struct Semaphore {Vulkan& v;VkSemaphore s;Semaphore(Vulkan& c,bool ex,uint64_t initial=0):v(c),s(c.semaphore(ex,initial)){}void reset(){if(s){v.DestroySemaphore(v.device,s,nullptr);s=VK_NULL_HANDLE;}}~Semaphore(){reset();}};
struct Packet{uint32_t op,e1;uint64_t handle,value,timeout;};
struct Reply{int32_t result;uint32_t pid;uint64_t value;};
static_assert(sizeof(Packet)==32&&sizeof(Reply)==16,"IPC ABI");
enum {Import=1,Counter=2,Wait=3,Drop=4,Quit=5};
inline void write_exact(HANDLE h,const void* data,DWORD n){DWORD sent=0;require(WriteFile(h,data,n,&sent,nullptr)&&sent==n,"IPC WriteFile");}
inline void read_exact(HANDLE h,void* data,DWORD n,DWORD timeout=15000,HANDLE process=nullptr){auto p=(unsigned char*)data;DWORD got=0;ULONGLONG end=GetTickCount64()+timeout;while(got<n){DWORD available=0;require(PeekNamedPipe(h,nullptr,0,nullptr,&available,nullptr)!=0,"IPC pipe closed");if(available){DWORD count=0;require(ReadFile(h,p+got,std::min(n-got,available),&count,nullptr)&&count>0,"IPC ReadFile");got+=count;continue;}if(process&&WaitForSingleObject(process,0)==WAIT_OBJECT_0)throw std::runtime_error("IPC child exited");require(GetTickCount64()<end,"IPC bounded timeout");Sleep(5);}}
struct Child {
 Handle process,thread,send,receive;DWORD pid=0;bool active=false;
 Child(const std::string& exe){SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE a,b,c,d;require(CreatePipe(&a,&b,&sa,0)!=0,"Create control pipe");Handle childIn(a);send.reset(b);require(CreatePipe(&c,&d,&sa,0)!=0,"Create reply pipe");receive.reset(c);Handle childOut(d);SetHandleInformation(send.h,HANDLE_FLAG_INHERIT,0);SetHandleInformation(receive.h,HANDLE_FLAG_INHERIT,0);
  HANDLE so=nullptr,se=nullptr;require(DuplicateHandle(GetCurrentProcess(),GetStdHandle(STD_OUTPUT_HANDLE),GetCurrentProcess(),&so,0,TRUE,DUPLICATE_SAME_ACCESS)!=0,"Duplicate stdout");Handle out(so);require(DuplicateHandle(GetCurrentProcess(),GetStdHandle(STD_ERROR_HANDLE),GetCurrentProcess(),&se,0,TRUE,DUPLICATE_SAME_ACCESS)!=0,"Duplicate stderr");Handle err(se);
  HANDLE list[]={childIn.h,childOut.h,out.h,err.h};SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);std::vector<unsigned char> attr(bytes);auto attrs=(LPPROC_THREAD_ATTRIBUTE_LIST)attr.data();require(InitializeProcThreadAttributeList(attrs,1,0,&bytes)!=0,"Initialize child attributes");require(UpdateProcThreadAttribute(attrs,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,list,sizeof(list),nullptr,nullptr)!=0,"Child handle allowlist");
  STARTUPINFOEXA si{};si.StartupInfo.cb=sizeof(si);si.StartupInfo.dwFlags=STARTF_USESTDHANDLES;si.StartupInfo.hStdInput=childIn.h;si.StartupInfo.hStdOutput=out.h;si.StartupInfo.hStdError=err.h;si.lpAttributeList=attrs;PROCESS_INFORMATION pi{};std::string cmd="\""+exe+"\" --consumer "+std::to_string((uint64_t)(uintptr_t)childOut.h);BOOL ok=CreateProcessA(exe.c_str(),cmd.data(),nullptr,nullptr,TRUE,EXTENDED_STARTUPINFO_PRESENT,nullptr,nullptr,&si.StartupInfo,&pi);DeleteProcThreadAttributeList(attrs);require(ok!=0,"Create consumer process");process.reset(pi.hProcess);thread.reset(pi.hThread);pid=pi.dwProcessId;active=true;printf("CHILD_STARTED PID=%lu PARENT=%lu EXE=%s\n",pid,GetCurrentProcessId(),exe.c_str());Reply ready{};read_exact(receive.h,&ready,sizeof(ready),20000,process.h);require(ready.result==0&&ready.pid==pid,"Consumer startup");
 }
 Reply call(uint32_t op,HANDLE h=nullptr,uint64_t value=0,uint64_t timeout=0,bool e1=true){HANDLE remote=nullptr;if(h){require(DuplicateHandle(GetCurrentProcess(),h,process.h,&remote,0,FALSE,DUPLICATE_SAME_ACCESS)!=0,"Cross-process DuplicateHandle");printf("IPC_HANDLE PARENT=%lu CHILD=%lu SOURCE=%p TARGET=%p\n",GetCurrentProcessId(),pid,h,remote);}Packet packet{op,e1?1u:0u,(uint64_t)(uintptr_t)remote,value,timeout};write_exact(send.h,&packet,sizeof(packet));Reply r{};read_exact(receive.h,&r,sizeof(r),15000,process.h);printf("IPC_REPLY PID=%u OP=%u RESULT=%d VALUE=%llu\n",r.pid,op,r.result,(unsigned long long)r.value);return r;}
 void finish(){if(active){require(call(Quit).result==0,"Consumer cleanup response");require(WaitForSingleObject(process.h,10000)==WAIT_OBJECT_0,"Consumer exit bound");DWORD code=99;require(GetExitCodeProcess(process.h,&code)!=0&&code==0,"Consumer process exit");printf("CHILD_EXIT PID=%lu CODE=%lu\n",pid,code);active=false;}}
 ~Child(){if(active){try{finish();}catch(...){printf("CHILD_CLEANUP_FORCED PID=%lu\n",pid);cleanup_ok=false;TerminateProcess(process.h,92);WaitForSingleObject(process.h,3000);}}}
};
inline int consumer(HANDLE replies){Vulkan v;v.open();VkSemaphore s=VK_NULL_HANDLE;bool e1=true;Reply ready{0,GetCurrentProcessId(),0};write_exact(replies,&ready,sizeof(ready));try{for(;;){Packet p{};read_exact(GetStdHandle(STD_INPUT_HANDLE),&p,sizeof(p),60000);Reply r{0,GetCurrentProcessId(),0};if(p.op==Import){Handle h((HANDLE)(uintptr_t)p.handle);if(s)v.DestroySemaphore(v.device,s,nullptr);s=v.semaphore(false);e1=p.e1!=0;Record record{};if(e1)snapshot(h.h,record,false);r.result=v.import_handle(s,h.h);h.reset();printf("CALLER_HANDLE_CLOSED_AFTER_IMPORT PID=%lu\n",GetCurrentProcessId());}
 else if(p.op==Counter){require(s!=VK_NULL_HANDLE,"Consumer semaphore absent");r.result=v.GetSemaphoreCounterValue(v.device,s,&r.value);}
 else if(p.op==Wait){require(s!=VK_NULL_HANDLE,"Consumer semaphore absent");r.result=v.wait(s,p.value,p.timeout,e1);}
 else if(p.op==Drop||p.op==Quit){if(s){v.DestroySemaphore(v.device,s,nullptr);s=VK_NULL_HANDLE;}}
 else throw std::runtime_error("Unknown IPC op");write_exact(replies,&r,sizeof(r));if(p.op==Quit)break;}}
 catch(...){if(s)v.DestroySemaphore(v.device,s,nullptr);throw;}return 0;}
inline std::string sibling_pair(){char p[2048];require(GetModuleFileNameA(nullptr,p,sizeof(p))>0,"Self path");std::string s=p;return s.substr(0,s.find_last_of("\\/")+1)+"p06-e1-vulkan-pair.exe";}
inline void reclaimed(const std::wstring& native){std::wstring prefix=L"\\BaseNamedObjects\\";require(native.find(prefix)==0,"Reclaim native prefix");std::wstring win=L"Global\\"+native.substr(prefix.size());HANDLE h=OpenFileMappingW(FILE_MAP_READ,FALSE,win.c_str());DWORD error=GetLastError();if(h)CloseHandle(h);printf("FINAL_RECLAIM NAME=%s HANDLE=%p ERROR=%lu\n",utf8(win).c_str(),h,error);require(h==nullptr&&error==ERROR_FILE_NOT_FOUND,"Section final reclaim not proven");}
}
