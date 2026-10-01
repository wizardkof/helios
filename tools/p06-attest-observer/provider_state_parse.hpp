#pragma once
#include <cstdint>
#include <string>
#include <vector>
struct EnableInfo {uint32_t enabled,level,logger,property;uint64_t any,all;};
struct InstanceInfo {uint32_t pid,flags;std::vector<EnableInfo> enables;};
struct State {std::string state="FAILED";uint32_t registered=0;std::vector<InstanceInfo> instances;};
inline uint32_t read32(const std::vector<unsigned char>& b,size_t p){return uint32_t(b[p])|(uint32_t(b[p+1])<<8)|(uint32_t(b[p+2])<<16)|(uint32_t(b[p+3])<<24);}
inline uint64_t read64(const std::vector<unsigned char>& b,size_t p){return read32(b,p)|(uint64_t(read32(b,p+4))<<32);}
inline State parse_state(const std::vector<unsigned char>& b){
 State out; if(b.size()<8)return out;
 uint32_t count=read32(b,0);size_t pos=8;bool enabled=false,unknown=false;
 if(count>(b.size()-8)/16)return out;
 for(uint32_t i=0;i<count;i++){
  if(pos>b.size() || b.size()-pos<16)return State{};
  uint32_t next=read32(b,pos),n=read32(b,pos+4),pid=read32(b,pos+8),flags=read32(b,pos+12);
  size_t available=b.size()-pos;
  if(i+1<count){if(next<16 || next>available)return State{};available=next;}else if(next!=0)return State{};
  if(n>(available-16)/32)return State{};
  InstanceInfo instance{pid,flags,{}};
  if((flags&2)==0)out.registered++;
  if((flags&~3u)!=0 || ((flags&2)!=0 && n==0))unknown=true;
  for(uint32_t j=0;j<n;j++){
   size_t p=pos+16+size_t(j)*32;
   uint32_t active=read32(b,p);if(active!=1)unknown=true;else enabled=true;
   instance.enables.push_back({active,b[p+4],uint32_t(b[p+6])|(uint32_t(b[p+7])<<8),read32(b,p+8),read64(b,p+16),read64(b,p+24)});
  }
  out.instances.push_back(instance);pos+=next;
 }
 out.state=unknown?"UNKNOWN":enabled?"ENABLED":out.registered?"OFF":"ABSENT";return out;
}
