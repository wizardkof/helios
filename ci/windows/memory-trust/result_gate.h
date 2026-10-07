#pragma once
#include <cstdint>
// Only the exact system-trust boundary can be supplied by an exclusive peer policy.
inline bool content_and_peer_trust_accepted(std::uint32_t raw, bool signerMatch,
    bool chainBuilt, std::uint32_t chainErrors, bool policyChecked,
    std::uint32_t policyError, bool stateClosed) {
 return raw==0x800B0109u && signerMatch && chainBuilt && chainErrors==0 &&
        policyChecked && policyError==0 && stateClosed;
}
