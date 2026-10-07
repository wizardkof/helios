#pragma once
// Test-owned Sections only. Never called for a genuine Mesa/KMD carrier.
#include <windows.h>
#include <winternl.h>
#include <aclapi.h>
#include <sddl.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <stdexcept>
#include <memory>
namespace fixture_security {
inline void check(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
struct LocalDelete{void operator()(void*p)const{if(p)LocalFree(p);}};
using Local=std::unique_ptr<void,LocalDelete>;
struct Owned{HANDLE h=nullptr;explicit Owned(HANDLE v):h(v){}~Owned(){if(h){BOOL ok=CloseHandle(h);printf("FIXTURE_CLOSE HANDLE=%p OK=%d\n",h,int(ok));}}HANDLE release(){auto v=h;h=nullptr;return v;}};
inline void result(const char* label,DWORD code){
 wchar_t message[1024]{};FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM|FORMAT_MESSAGE_IGNORE_INSERTS,nullptr,code,0,message,1024,nullptr);
 char utf[4096]{};WideCharToMultiByte(CP_UTF8,0,message,-1,utf,sizeof(utf),nullptr,nullptr);
 printf("FIXTURE_API=%s RETURN_DEC=%lu RETURN_HEX=%08lx MESSAGE_UTF8=%s\n",label,code,code,utf);fflush(stdout);
}
inline ACCESS_MASK access(HANDLE h,const char* role){
 using Query=LONG(NTAPI*)(HANDLE,ULONG,PVOID,ULONG,PULONG);
 auto fn=(Query)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryObject");check(fn!=nullptr,"Fixture NtQueryObject");
 PUBLIC_OBJECT_BASIC_INFORMATION b{};ULONG n=0;LONG s=fn(h,0,&b,sizeof(b),&n);
 printf("FIXTURE_HANDLE ROLE=%s HANDLE=%p QUERY_STATUS=%08lx GRANTED_ACCESS=%08lx\n",role,h,(unsigned long)s,b.GrantedAccess);
 check(s==0&&n==sizeof(b),"Fixture access query");return b.GrantedAccess;
}
inline Local descriptor(bool permissive){
 const wchar_t* text=permissive?L"D:P(A;;GA;;;WD)":L"D:P(A;;0x000f001f;;;SY)(A;;0x00000005;;;AU)";
 PSECURITY_DESCRIPTOR sd=nullptr;check(ConvertStringSecurityDescriptorToSecurityDescriptorW(text,1,&sd,nullptr)!=0,"Fixture SDDL");
 printf("FIXTURE_REQUESTED_SDDL=%ls INTENT=%s\n",text,permissive?"WRONG_DACL":"EXACT_DACL_WRONG_NAME_OR_OWNER");return Local(sd);
}
inline PACL dacl(PSECURITY_DESCRIPTOR sd){BOOL present=FALSE,def=FALSE;PACL acl=nullptr;
 check(IsValidSecurityDescriptor(sd)!=0,"Fixture valid SD");check(GetSecurityDescriptorDacl(sd,&present,&acl,&def)&&present&&!def&&acl&&IsValidAcl(acl),"Fixture DACL structure");return acl;}
inline void set_fixture_dacl(HANDLE h,bool permissive){
 auto sd=descriptor(permissive);PACL acl=dacl(sd.get());SECURITY_DESCRIPTOR_CONTROL control=0;DWORD rev=0;check(GetSecurityDescriptorControl(sd.get(),&control,&rev)!=0,"Fixture SD control");
 printf("FIXTURE_SET HANDLE=%p TYPE=%u SECURITY_INFORMATION=%08lx OWNER=NULL GROUP=NULL SACL=NULL DACL=%p ACE_COUNT=%u ACL_SIZE=%u CONTROL=%04x\n",h,unsigned(SE_KERNEL_OBJECT),(unsigned long)(DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION),acl,acl->AceCount,acl->AclSize,control);
 DWORD r=SetSecurityInfo(h,SE_KERNEL_OBJECT,DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION,nullptr,nullptr,acl,nullptr);
 result("SetSecurityInfo",r);check(r==ERROR_SUCCESS,"Fixture DACL set");
}
inline void inspect(HANDLE h,bool permissive){
 PSECURITY_DESCRIPTOR raw=nullptr;PSID owner=nullptr;PACL actual=nullptr;
 DWORD s=GetSecurityInfo(h,SE_KERNEL_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&actual,nullptr,&raw);Local sd(raw);result("GetSecurityInfo",s);check(s==ERROR_SUCCESS&&raw&&owner,"Fixture security readback");
 SECURITY_DESCRIPTOR_CONTROL ctl=0;DWORD rev=0;check(GetSecurityDescriptorControl(raw,&ctl,&rev)!=0&&(ctl&SE_DACL_PROTECTED),"Fixture DACL protection readback");
 wchar_t* text=nullptr;check(ConvertSecurityDescriptorToStringSecurityDescriptorW(raw,1,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&text,nullptr)!=0,"Fixture readback SDDL");Local str(text);printf("FIXTURE_SECURITY_READBACK=%ls CONTROL=%04x\n",text,ctl);
 auto wanted=descriptor(permissive);PACL expected=dacl(wanted.get());check(actual&&IsValidAcl(actual)&&actual->AceCount==expected->AceCount,"Fixture ACE count");
 for(DWORD i=0;i<actual->AceCount;i++){
  void* a=nullptr;void*b=nullptr;check(GetAce(actual,i,&a)&&GetAce(expected,i,&b),"Fixture ACE query");auto aa=(ACCESS_ALLOWED_ACE*)a;auto bb=(ACCESS_ALLOWED_ACE*)b;
  DWORD mask=bb->Mask;GENERIC_MAPPING map{STANDARD_RIGHTS_READ|SECTION_QUERY|SECTION_MAP_READ,STANDARD_RIGHTS_WRITE|SECTION_MAP_WRITE,STANDARD_RIGHTS_EXECUTE|SECTION_MAP_EXECUTE,SECTION_ALL_ACCESS};MapGenericMask(&mask,&map);
  printf("FIXTURE_ACE INDEX=%lu TYPE=%u FLAGS=%u MASK=%08lx EXPECTED_NORMALIZED=%08lx\n",i,aa->Header.AceType,aa->Header.AceFlags,aa->Mask,mask);
  check(aa->Header.AceType==ACCESS_ALLOWED_ACE_TYPE&&aa->Header.AceFlags==bb->Header.AceFlags&&aa->Mask==mask&&EqualSid(&aa->SidStart,&bb->SidStart),"Fixture exact ACE readback");
 }
 BYTE system[SECURITY_MAX_SID_SIZE];DWORD length=sizeof(system);check(CreateWellKnownSid(WinLocalSystemSid,nullptr,system,&length)!=0,"Fixture SYSTEM SID");check(!EqualSid(owner,system),"Negative fixture must not be SYSTEM-owned");
 printf("FIXTURE_SECURITY_VALIDATED=PASS OWNER_NOT_SYSTEM=1 PROTECTED=1\n");
}
inline HANDLE make(const std::wstring& name,const void* record,size_t size,bool permissive=false){
 auto initial=descriptor(permissive);SECURITY_ATTRIBUTES attributes{sizeof(attributes),initial.get(),FALSE};
 // An unnamed Section created without this explicit descriptor has no associated security.
 Owned prep(CreateFileMappingW(INVALID_HANDLE_VALUE,&attributes,PAGE_READWRITE,0,4096,name.empty()?nullptr:name.c_str()));DWORD err=GetLastError();
 printf("FIXTURE_CREATE NAME=%ls PREP_HANDLE=%p ERROR=%lu EXPLICIT_CREATION_SD=1\n",name.c_str(),prep.h,prep.h?0:err);
 check(prep.h&&err!=ERROR_ALREADY_EXISTS,"Create own separate negative Section");auto mask=access(prep.h,"PREPARATION_INSPECTION");check((mask&(WRITE_DAC|READ_CONTROL|SECTION_MAP_WRITE))==(WRITE_DAC|READ_CONTROL|SECTION_MAP_WRITE),"Fixture preparation rights");
 void* view=MapViewOfFile(prep.h,FILE_MAP_WRITE,0,0,size);check(view!=nullptr,"Fixture map write");memcpy(view,record,size);check(UnmapViewOfFile(view)!=0,"Fixture unmap");
 set_fixture_dacl(prep.h,permissive);inspect(prep.h,permissive);
 HANDLE raw=nullptr;check(DuplicateHandle(GetCurrentProcess(),prep.h,GetCurrentProcess(),&raw,SECTION_MAP_READ|SECTION_QUERY,FALSE,0)!=0,"Fixture test handle rights reduction");Owned test(raw);check(access(test.h,"ATTEST_TEST")==5,"Fixture exact test rights5");
 view=MapViewOfFile(test.h,FILE_MAP_READ,0,0,size);check(view!=nullptr,"Fixture readonly mapping");bool equal=memcmp(view,record,size)==0;check(UnmapViewOfFile(view)!=0&&equal,"Fixture readback record");
 printf("FIXTURE_PREPARATION=PASS TEST_HANDLE=%p RECORD_READBACK=PASS\n",test.h);return test.release();
}
}
