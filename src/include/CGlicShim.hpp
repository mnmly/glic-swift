#pragma once

// Bridging surface exposed to Swift via C++ interop.
// Pulls in the public codec API and instantiates the std::vector
// specializations Swift needs (class templates aren't directly importable;
// a `using` alias forces instantiation — see swift.org/documentation/cxx-interop).

#include "../glic.hpp"
#include "../studio_api.hpp"

#include <cstdint>
#include <vector>

namespace glic {
// Force instantiation so Swift imports these as RandomAccessCollection types.
using ByteVector = std::vector<uint8_t>;   // encodeToBuffer() return / decode input
using ColorVector = std::vector<Color>;    // GlicResult::pixels (Color == uint32_t)
} // namespace glic
