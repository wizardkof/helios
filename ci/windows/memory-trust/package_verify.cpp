// DIAGNOSTIC ONLY: no persistent trust-store writes. WinTrust owns content semantics.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <mscat.h>
#include <bcrypt.h>
#include <psapi.h>
#include <algorithm>
#include <memory>
#include <filesystem>
#include <chrono>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <stdexcept>
#include "result_gate.h"
#pragma comment(lib,"wintrust.lib")
#pragma comment(lib,"crypt32.lib")
#pragma comment(lib,"psapi.lib")

using Bytes=std::vector<BYTE>;
struct File { HANDLE h=INVALID_HANDLE_VALUE; explicit File(const std::wstring& p){h=CreateFileW(p.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);if(h==INVALID_HANDLE_VALUE)throw std::runtime_error("CreateFile failed");} ~File(){if(h!=INVALID_HANDLE_VALUE)CloseHandle(h);} File(const File&)=delete; };
Bytes read(const std::wstring& path){File f(path);LARGE_INTEGER size{};if(!GetFileSizeEx(f.h,&size)||size.QuadPart<=0||size.QuadPart>256*1024*1024)throw std::runtime_error("File size invalid");Bytes b(static_cast<size_t>(size.QuadPart));DWORD got=0;if(!ReadFile(f.h,b.data(),static_cast<DWORD>(b.size()),&got,nullptr)||got!=b.size())throw std::runtime_error("Short read");return b;}
std::string hex(const BYTE* p,size_t n){const char* d="0123456789ABCDEF";std::string s;for(size_t i=0;i<n;++i){s+=d[p[i]>>4];s+=d[p[i]&15];}return s;}
std::string digest(const Bytes& b,LPCWSTR alg){DWORD n=64;BYTE out[64]{};if(!CryptHashCertificate2(alg,0,nullptr,b.data(),static_cast<DWORD>(b.size()),out,&n))throw std::runtime_error("Hash failed");return hex(out,n);}
std::string utf8(const std::wstring& w){if(w.empty())return {};int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,w.data(),static_cast<int>(w.size()),nullptr,0,nullptr,nullptr);if(n<=0)throw std::runtime_error("UTF8 conversion failed");std::string s(n,'\0');WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,w.data(),static_cast<int>(w.size()),s.data(),n,nullptr,nullptr);return s;}
std::string quote(const std::string& s){std::string out="\"";for(unsigned char c:s){if(c=='"'||c=='\\'){out+='\\';out+=c;}else if(c<32){const char* h="0123456789abcdef";out+="\\u00";out+=h[c>>4];out+=h[c&15];}else out+=c;}return out+'"';}
std::string code(DWORD v){BYTE b[4]={static_cast<BYTE>(v>>24),static_cast<BYTE>(v>>16),static_cast<BYTE>(v>>8),static_cast<BYTE>(v)};return "0x"+hex(b,4);}
const char* symbol(DWORD v){switch(v){case 0:return "SUCCESS";case 0x800B0109:return "CERT_E_UNTRUSTEDROOT";case 0x80096010:return "TRUST_E_BAD_DIGEST";case 0x800B0100:return "TRUST_E_NOSIGNATURE";case 0x800B0101:return "CERT_E_EXPIRED";case 0x800B0110:return "CERT_E_WRONG_USAGE";default:return "OTHER_FAILURE";}}
struct Cert { PCCERT_CONTEXT p=nullptr; explicit Cert(const Bytes& b){p=CertCreateCertificateContext(X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,b.data(),static_cast<DWORD>(b.size()));if(!p)throw std::runtime_error("Invalid DER CER");} ~Cert(){if(p)CertFreeCertificateContext(p);} };
struct MemoryStore { HCERTSTORE h=nullptr; MemoryStore(){h=CertOpenStore(CERT_STORE_PROV_MEMORY,0,0,CERT_STORE_CREATE_NEW_FLAG,nullptr);if(!h)throw std::runtime_error("Memory store failed");} ~MemoryStore(){if(h)CertCloseStore(h,0);} };
struct Engine { HCERTCHAINENGINE h=nullptr; ~Engine(){if(h)CertFreeCertificateChainEngine(h);} };
struct Chain { PCCERT_CHAIN_CONTEXT p=nullptr; ~Chain(){if(p)CertFreeCertificateChain(p);} };
using Acquire2=BOOL(WINAPI*)(HCATADMIN*,const GUID*,PCWSTR,PCCERT_STRONG_SIGN_PARA,DWORD);
using Hash2=BOOL(WINAPI*)(HCATADMIN,HANDLE,DWORD*,BYTE*,DWORD);
struct CatalogAdmin { HCATADMIN h=nullptr; HMODULE dll=nullptr; Hash2 hash=nullptr;
 CatalogAdmin(){dll=LoadLibraryExW(L"wintrust.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(!dll)throw std::runtime_error("System Wintrust missing");auto acquire=reinterpret_cast<Acquire2>(GetProcAddress(dll,"CryptCATAdminAcquireContext2"));hash=reinterpret_cast<Hash2>(GetProcAddress(dll,"CryptCATAdminCalcHashFromFileHandle2"));GUID action=DRIVER_ACTION_VERIFY;if(!acquire||!hash||!acquire(&h,&action,BCRYPT_SHA256_ALGORITHM,nullptr,0)){FreeLibrary(dll);dll=nullptr;throw std::runtime_error("Catalog context2 failed");}}
 ~CatalogAdmin(){if(h)CryptCATAdminReleaseContext(h,0);if(dll)FreeLibrary(dll);} };
struct TrustState { WINTRUST_DATA data{}; GUID action=WINTRUST_ACTION_GENERIC_VERIFY_V2; bool invoked=false,closed=false;LONG closeResult=E_FAIL;
 TrustState(){data.cbStruct=sizeof(data);data.dwUIChoice=WTD_UI_NONE;data.fdwRevocationChecks=WTD_REVOKE_NONE;data.dwStateAction=WTD_STATEACTION_VERIFY;data.dwProvFlags=WTD_CACHE_ONLY_URL_RETRIEVAL;}
 LONG verify(){invoked=true;return WinVerifyTrust(nullptr,&action,&data);}
 void close(){if(invoked&&!closed){data.dwStateAction=WTD_STATEACTION_CLOSE;closeResult=WinVerifyTrust(nullptr,&action,&data);closed=true;}}
 ~TrustState(){close();} };
bool intrinsic_code_signer(PCCERT_CONTEXT certificate){
 // Peer identity trust must not suppress leaf expiry, usage or self-signature errors.
 if(CertVerifyTimeValidity(nullptr,certificate->pCertInfo)!=0)return false;
 DWORD n=0;if(!CertGetEnhancedKeyUsage(certificate,0,nullptr,&n)||n<sizeof(CERT_ENHKEY_USAGE))return false;
 Bytes storage(n);auto eku=reinterpret_cast<PCERT_ENHKEY_USAGE>(storage.data());if(!CertGetEnhancedKeyUsage(certificate,0,eku,&n))return false;
 bool codeSigning=false;for(DWORD i=0;i<eku->cUsageIdentifier;++i)if(strcmp(eku->rgpszUsageIdentifier[i],szOID_PKIX_KP_CODE_SIGNING)==0)codeSigning=true;
 if(!codeSigning)return false;
 if(!CertCompareCertificateName(X509_ASN_ENCODING,&certificate->pCertInfo->Subject,&certificate->pCertInfo->Issuer))return false;
 return CryptVerifyCertificateSignatureEx(0,X509_ASN_ENCODING,CRYPT_VERIFY_CERT_SIGN_SUBJECT_CERT,const_cast<PCERT_CONTEXT>(certificate),CRYPT_VERIFY_CERT_SIGN_ISSUER_CERT,const_cast<PCERT_CONTEXT>(certificate),0,nullptr)!=FALSE;
}
struct Result {
 std::string path,kind,sha,packageSha,signerSha,thumb,memberHash,error;
 size_t size=0;DWORD raw=0xffffffff,chainErrors=0xffffffff,policyError=0xffffffff;bool intrinsicValid=false,match=false,chainBuilt=false,policyChecked=false,accepted=false,closed=false;LONG closeResult=E_FAIL;double durationMs=0;
 std::string json()const{
  return "{\"path\":"+quote(path)+",\"size\":"+std::to_string(size)+",\"sha256\":"+quote(sha)+",\"verificationKind\":"+quote(kind)+",\"winTrustHRESULT\":"+quote(code(raw))+",\"winTrustSymbolicResult\":"+quote(symbol(raw))+",\"winTrustTrustOnlyFailure\":"+(raw==0x800B0109?"true":"false")+",\"signerDerSha256\":"+quote(signerSha)+",\"signerThumbprint\":"+quote(thumb)+",\"packageCertificateDerSha256\":"+quote(packageSha)+",\"signerDerMatch\":"+(match?"true":"false")+",\"certificateIntrinsicChecks\":"+(intrinsicValid?"true":"false")+",\"customChainBuilt\":"+(chainBuilt?"true":"false")+",\"customChainStatus\":"+quote(code(chainErrors))+",\"customPolicyChecked\":"+(policyChecked?"true":"false")+",\"customPolicyStatus\":"+quote(code(policyError))+",\"catalogMemberHash\":"+quote(memberHash)+",\"stateClosed\":"+(closed?"true":"false")+",\"stateCloseHRESULT\":"+quote(code(static_cast<DWORD>(closeResult)))+",\"durationMs\":"+std::to_string(durationMs)+",\"error\":"+quote(error)+",\"finalStatus\":"+quote(accepted?"PASS":"FAIL")+"}";
 }
};
Result verify(const std::wstring& path,const std::wstring& cer,const std::wstring& cat){
 Result r;r.path=utf8(path);r.kind=cat.empty()?"EMBEDDED_AUTHENTICODE":"CATALOG_MEMBER";auto start=std::chrono::steady_clock::now();
 WINTRUST_FILE_INFO fi{};WINTRUST_CATALOG_INFO ci{};Bytes hash;std::wstring tag;std::unique_ptr<CatalogAdmin> admin;std::unique_ptr<File> file;TrustState trust;
 try{
  file=std::make_unique<File>(path);
  Bytes bytes=read(path),der=read(cer);r.size=bytes.size();r.sha=digest(bytes,BCRYPT_SHA256_ALGORITHM);r.packageSha=digest(der,BCRYPT_SHA256_ALGORITHM);Cert certificate(der);
  fi.cbStruct=sizeof(fi);fi.pcwszFilePath=path.c_str();fi.hFile=file->h;
  if(!cat.empty()){
   admin=std::make_unique<CatalogAdmin>();DWORD n=0;if(!admin->hash(admin->h,file->h,&n,nullptr,0)||n==0||n>64)throw std::runtime_error("Catalog hash sizing failed");hash.resize(n);if(!admin->hash(admin->h,file->h,&n,hash.data(),0)||n!=hash.size())throw std::runtime_error("Catalog hash failed");r.memberHash=hex(hash.data(),hash.size());tag.assign(r.memberHash.begin(),r.memberHash.end());
   ci.cbStruct=sizeof(ci);ci.pcwszCatalogFilePath=cat.c_str();ci.pcwszMemberTag=tag.c_str();ci.pcwszMemberFilePath=path.c_str();ci.hMemberFile=file->h;ci.pbCalculatedFileHash=hash.data();ci.cbCalculatedFileHash=static_cast<DWORD>(hash.size());ci.hCatAdmin=admin->h;
  }
  trust.data.dwUnionChoice=cat.empty()?WTD_CHOICE_FILE:WTD_CHOICE_CATALOG;if(cat.empty())trust.data.pFile=&fi;else trust.data.pCatalog=&ci;
  r.raw=static_cast<DWORD>(trust.verify());
  auto provider=WTHelperProvDataFromStateData(trust.data.hWVTStateData);
  auto signer=provider?WTHelperGetProvSignerFromChain(provider,0,FALSE,0):nullptr;
  auto signerCert=signer?WTHelperGetProvCertFromChain(signer,0):nullptr;
  if(signerCert&&signerCert->pCert){
   Bytes signerDer(signerCert->pCert->pbCertEncoded,signerCert->pCert->pbCertEncoded+signerCert->pCert->cbCertEncoded);
   r.signerSha=digest(signerDer,BCRYPT_SHA256_ALGORITHM);r.thumb=digest(signerDer,BCRYPT_SHA1_ALGORITHM);r.match=signerDer==der;
  }
  if(r.raw==0x800B0109u&&r.match){
   r.intrinsicValid=intrinsic_code_signer(signerCert->pCert);if(!r.intrinsicValid)throw std::runtime_error("Leaf time/CodeSigning EKU/self-signature validation failed");
   // Offline, exclusive peer trust only: no system anchors, root substitution or ignore flags.
   MemoryStore memory;if(!CertAddCertificateContextToStore(memory.h,certificate.p,CERT_STORE_ADD_NEW,nullptr))throw std::runtime_error("Memory CER insertion failed");
   CERT_CHAIN_ENGINE_CONFIG config{};config.cbSize=sizeof(config);config.hExclusiveTrustedPeople=memory.h;config.hExclusiveRoot=nullptr;config.dwFlags=CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL|CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE;Engine engine;
   if(!CertCreateCertificateChainEngine(&config,&engine.h))throw std::runtime_error("Exclusive peer engine failed");
   LPSTR usage=const_cast<LPSTR>(szOID_PKIX_KP_CODE_SIGNING);CERT_CHAIN_PARA para{};para.cbSize=sizeof(para);para.RequestedUsage.dwType=USAGE_MATCH_TYPE_AND;para.RequestedUsage.Usage.cUsageIdentifier=1;para.RequestedUsage.Usage.rgpszUsageIdentifier=&usage;
   Chain chain;DWORD flags=CERT_CHAIN_ENABLE_PEER_TRUST|CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL|CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY|CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE;
   r.chainBuilt=CertGetCertificateChain(engine.h,signerCert->pCert,nullptr,nullptr,&para,flags,nullptr,&chain.p)!=FALSE;
   if(r.chainBuilt){
    r.chainErrors=chain.p->TrustStatus.dwErrorStatus;
    AUTHENTICODE_EXTRA_CERT_CHAIN_POLICY_PARA extra{};extra.cbSize=sizeof(extra);extra.pSignerInfo=signer->psSigner;
    CERT_CHAIN_POLICY_PARA policy{};policy.cbSize=sizeof(policy);policy.dwFlags=0;policy.pvExtraPolicyPara=&extra;
    CERT_CHAIN_POLICY_STATUS status{};status.cbSize=sizeof(status);
    r.policyChecked=CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_AUTHENTICODE,chain.p,&policy,&status)!=FALSE;if(r.policyChecked)r.policyError=status.dwError;
   }
  }
  trust.close();r.closed=trust.closed;r.closeResult=trust.closeResult;
  r.accepted=r.intrinsicValid && content_and_peer_trust_accepted(r.raw,r.match,r.chainBuilt,r.chainErrors,r.policyChecked,r.policyError,r.closed&&r.closeResult==ERROR_SUCCESS);
 }catch(const std::exception& e){r.error=e.what();}
 trust.close();r.closed=trust.closed;r.closeResult=trust.closeResult;
 r.durationMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();return r;
}
int wmain(int argc,wchar_t** argv){
 if(argc<5||argc>7){std::cerr<<"usage: package-verify embedded|catalog file cer receipt [catalog] [repeat]\n";return 2;}
 bool catalog=std::wstring(argv[1])==L"catalog";if(!catalog&&std::wstring(argv[1])!=L"embedded")return 2;if(catalog&&argc<6)return 2;
 std::wstring cat=catalog?argv[5]:L"";int repeat=(argc==7)?_wtoi(argv[6]):1;if(repeat<1||repeat>1000)return 2;
 DWORD before=0,after=0;GetProcessHandleCount(GetCurrentProcess(),&before);bool pass=true;unsigned verified=0,closed=0;std::string rows;
 for(int i=0;i<repeat;++i){auto r=verify(argv[2],argv[3],cat);pass=pass&&r.accepted;if(r.raw!=0xffffffff)++verified;if(r.closed&&r.closeResult==0)++closed;if(i)rows+=",";rows+=r.json();if(i==9)GetProcessHandleCount(GetCurrentProcess(),&before);}
 GetProcessHandleCount(GetCurrentProcess(),&after);
 std::ofstream out(std::filesystem::path(argv[4]),std::ios::binary);if(!out)return 2;out<<"{\"results\":["<<rows<<"],\"stateVerifyCount\":"<<verified<<",\"stateCloseCount\":"<<closed<<",\"repeat\":"<<repeat<<",\"handlesAfterWarmup\":"<<before<<",\"handlesAfter\":"<<after<<",\"finalStatus\":"<<quote(pass?"PASS":"FAIL")<<"}\n";return pass?0:1;
}
