#include "result_gate.h"
#include <initializer_list>
#include <cassert>
int main() {
 constexpr std::uint32_t trustOnly=0x800B0109u;
 assert(content_and_peer_trust_accepted(trustOnly,true,true,0,true,0,true));
 for(auto raw:{0u,0x80096010u,0x800B0100u,0x800B0101u,0x800B0110u,0x80004005u})
  assert(!content_and_peer_trust_accepted(raw,true,true,0,true,0,true));
 assert(!content_and_peer_trust_accepted(trustOnly,false,true,0,true,0,true));
 assert(!content_and_peer_trust_accepted(trustOnly,true,false,0,true,0,true));
 assert(!content_and_peer_trust_accepted(trustOnly,true,true,1,true,0,true));
 assert(!content_and_peer_trust_accepted(trustOnly,true,true,0,false,0,true));
 assert(!content_and_peer_trust_accepted(trustOnly,true,true,0,true,1,true));
 assert(!content_and_peer_trust_accepted(trustOnly,true,true,0,true,0,false));
}
