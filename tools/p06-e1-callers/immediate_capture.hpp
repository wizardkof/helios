#pragma once
// Harness-only observer. No expected semantic status enters this function.
struct Capture {
 NTSTATUS external;
 unsigned char before[sizeof(CarrierRequest)],after[sizeof(CarrierRequest)];
 void* submitted;
 DWORD pid,tid;
 LARGE_INTEGER begin,end,frequency;
};
static Capture capture_call(PFND3DKMT_ESCAPE fn,D3DKMT_ESCAPE& e){
 Capture c{};c.submitted=e.pPrivateDriverData;c.pid=GetCurrentProcessId();c.tid=GetCurrentThreadId();
 require(e.PrivateDriverDataSize==sizeof(CarrierRequest),"Capture exact wire size");
 memcpy(c.before,c.submitted,sizeof(c.before));QueryPerformanceFrequency(&c.frequency);QueryPerformanceCounter(&c.begin);
 c.external=fn(&e);
 // First operation after the external status assignment: snapshot the EXACT submitted bytes.
 // Volatile reads prevent a compiler from reusing pre-call request values.
 for(size_t i=0;i<sizeof(c.after);++i)c.after[i]=static_cast<volatile unsigned char*>(c.submitted)[i];
 QueryPerformanceCounter(&c.end);
 return c;
}
static bool classified_reply(const Capture& c){
 uint32_t status;memcpy(&status,c.after+offsetof(CarrierRequest,status),sizeof(status));
 return status!=0xa5a5a5a5u;
}
struct alignas(8) GuardedRequest {
 uint64_t prefix[2]{0x12345678cafef00dULL,0xfedcba9876543210ULL};
 CarrierRequest request{};
 uint64_t suffix[2]{0x12345678cafef00dULL,0xfedcba9876543210ULL};
 bool intact()const{return prefix[0]==0x12345678cafef00dULL&&prefix[1]==0xfedcba9876543210ULL&&suffix[0]==0x12345678cafef00dULL&&suffix[1]==0xfedcba9876543210ULL;}
};
static_assert(offsetof(GuardedRequest,request)==16,"Canary/request adjacency");
static_assert(offsetof(GuardedRequest,suffix)==16+sizeof(CarrierRequest),"Request/canary adjacency");
static NTSTATUS APIENTRY synthetic_write(const D3DKMT_ESCAPE* e){
 static_cast<CarrierRequest*>(e->pPrivateDriverData)->status=6;
 return static_cast<NTSTATUS>(0xc0000008u);
}
static NTSTATUS APIENTRY synthetic_unchanged(const D3DKMT_ESCAPE*){return static_cast<NTSTATUS>(0xc0000008u);}
static void capture_regression(){
 GuardedRequest g;init(g.request,9);g.request.status=0xa5a5a5a5u;
 D3DKMT_ESCAPE e{};e.pPrivateDriverData=&g.request;e.PrivateDriverDataSize=sizeof(g.request);
 Capture written=capture_call(synthetic_write,e);uint32_t status=0;memcpy(&status,written.after+offsetof(CarrierRequest,status),4);
 require(uint32_t(written.external)==0xc0000008u&&status==6&&classified_reply(written),"Capture negative transport with semantic write");
 require(written.submitted==&g.request&&g.intact(),"Exact buffer and guards");
 g.request.status=0xa5a5a5a5u;Capture untouched=capture_call(synthetic_unchanged,e);
 require(!classified_reply(untouched)&&memcmp(untouched.before,untouched.after,sizeof(untouched.after))==0,"Untouched sentinel must remain unobserved");
 g.suffix[0]^=1;require(!g.intact(),"Corrupt guard must be detected");g.suffix[0]^=1;
 printf("CAPTURE_REGRESSION=PASS NEGATIVE_WRITTEN_CAPTURE=PASS SENTINEL_NOT_OBSERVED=PASS CANARY_DETECTION=PASS DRIVER_CALLS=0 VULKAN_CALLS=0 SYNTHETIC_ONLY=1\n");
}
