#pragma once

// Flat, interop-friendly surface for the SwiftUI app (GlicStudio).
// Avoids exposing CodecConfig's nested std::array<ChannelConfig,3> across the
// C++ interop boundary — Swift just fills a POD of primitives.

#include "config.hpp"

#include <cstdint>
#include <vector>

namespace glic {

struct StudioParams {
    int colorSpace = 9;      // ColorSpace raw (HWB)
    int prediction = 9;      // PredictionMethod raw (PAETH)
    int quantization = 110;  // 0..255
    float threshold = 15.0f; // segmentation precision
    int wavelet = 28;        // WaveletType raw (SYMLET8)
    int transform = 0;       // TransformType raw (FWT)
    int encoding = 1;        // EncodingMethod raw (PACKED)
    int minBlock = 2;
    int maxBlock = 256;
    int clampMod256 = 0;     // 0 = none, 1 = mod256
    int tile = 256;          // tile size in px; <= 0 => whole image (monolithic)
    int threads = 0;         // <= 0 => hardware_concurrency
};

// Tiled parallel encode -> decode round-trip. Returns decoded pixels (w*h, ARGB).
std::vector<Color> roundTripTiled(const Color* pixels, int w, int h, const StudioParams& p);

// Silence the codec's std::cout progress logging (thread-safe no-op insertions).
void setQuietLogging(bool quiet);

} // namespace glic
