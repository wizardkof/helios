#include "provider_state_parse.hpp"
#include <cassert>
#include <cstdio>
static void put(std::vector<unsigned char>& b,size_t p,uint32_t v){for(int i=0;i<4;i++)b[p+i]=static_cast<unsigned char>(v>>(8*i));}
int main(){
 std::vector<unsigned char> b(24);put(b,0,1);
 assert(parse_state(b).state=="OFF");
 b.resize(56);put(b,12,1);put(b,24,1);
 assert(parse_state(b).state=="ENABLED");
 put(b,20,2);assert(parse_state(b).registered==0);assert(parse_state(b).state=="ENABLED");
 put(b,12,0);b.resize(24);assert(parse_state(b).state=="UNKNOWN");
 put(b,20,4);assert(parse_state(b).state=="UNKNOWN");
 b.resize(10);assert(parse_state(b).state=="FAILED");
 b.assign(24,0);put(b,0,2);assert(parse_state(b).state=="FAILED");
 b.assign(8,0);assert(parse_state(b).state=="ABSENT");
 b.assign(24,0);put(b,0,1);put(b,12,0xffffffff);assert(parse_state(b).state=="FAILED");
 b.assign(40,0);put(b,0,2);put(b,8,16);assert(parse_state(b).state=="OFF");
 puts("provider state parser: 10 checks PASS");
}
