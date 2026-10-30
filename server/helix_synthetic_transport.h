#pragma once

#include <stop_token>

namespace wivrn
{
class wivrn_connection;

namespace helix_synthetic_transport
{
// Run one bounded receiver/transport validation battery over an already-established
// production WiVRn connection. Returns 0 only when the transport promotion gate passes.
int run(wivrn_connection & connection, std::stop_token stop_token);
}
} // namespace wivrn
