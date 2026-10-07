/* P06 transport v1. Mirror of helios_protocol::attest_transport. */
#ifndef VN_RENDERER_HELIOS_ATTEST_TRANSPORT_H
#define VN_RENDERER_HELIOS_ATTEST_TRANSPORT_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#define HELIOS_ATTEST_QUERY 0x19u
#define HELIOS_ATTEST_CALL 0x1au
struct helios_attest_transport {
 _Alignas(8) uint32_t magic;
 uint32_t command,version,size,transport_version,operation;
 uint8_t request_id[16];
 uint64_t user_handle;
 uint8_t carrier_id[16];
 uint32_t expected_record_version,reserved;
 uint32_t response_version,response_size,response_operation,valid_marker;
 uint8_t response_id[16];
 uint32_t accepted,refusal_class,capabilities,supported_record_version;
};
_Static_assert(sizeof(struct helios_attest_transport)==120,"ATTEST size");
_Static_assert(_Alignof(struct helios_attest_transport)==8,"ATTEST alignment");
_Static_assert(offsetof(struct helios_attest_transport,user_handle)==40,"HANDLE offset");
_Static_assert(offsetof(struct helios_attest_transport,response_version)==72,"response offset");
_Static_assert(offsetof(struct helios_attest_transport,response_id)==88,"identity offset");
static inline struct helios_attest_transport
helios_attest_request(uint32_t op,const uint8_t id[16],uint64_t handle,
                     const uint8_t carrier[16],uint32_t record)
{
 struct helios_attest_transport r={0};
 r.magic=0x48454c53;r.command=op;r.version=1;r.size=sizeof(r);
 r.transport_version=1;r.operation=op;memcpy(r.request_id,id,16);
 if(op==HELIOS_ATTEST_CALL) {
  r.user_handle=handle;memcpy(r.carrier_id,carrier,16);r.expected_record_version=record;
 }
 return r;
}
static inline bool
helios_attest_response_valid(const struct helios_attest_transport *r,
                            const struct helios_attest_transport *q,size_t actual)
{
 const uint8_t zero[48]={0};
 if(actual!=120 || q->magic!=0x48454c53 || q->version!=1 || q->size!=120 ||
    q->transport_version!=1 || q->command!=q->operation || q->reserved ||
    (q->operation!=HELIOS_ATTEST_QUERY && q->operation!=HELIOS_ATTEST_CALL) ||
    !memcmp(q->request_id,zero,16) || memcmp((const uint8_t*)q+72,zero,48) ||
    memcmp(r,q,72)) return false;
 if(q->operation==HELIOS_ATTEST_QUERY &&
    (q->user_handle || memcmp(q->carrier_id,zero,16) || q->expected_record_version)) return false;
 if(r->response_version!=1 || r->response_size!=120 ||
    r->response_operation!=q->operation || r->valid_marker!=0x41545431 ||
    memcmp(r->response_id,q->request_id,16) || r->capabilities!=1 ||
    r->supported_record_version!=2) return false;
 if(q->operation==HELIOS_ATTEST_QUERY) return r->accepted==0 && r->refusal_class==0;
 return (r->accepted==1 && r->refusal_class==0) ||
        (r->accepted==0 && r->refusal_class>=1 && r->refusal_class<=7);
}
#endif
