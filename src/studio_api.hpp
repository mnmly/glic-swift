#pragma once

// Flat, interop-friendly surface for the SwiftUI app (GlicStudio).
// Avoids exposing CodecConfig's nested std::array<ChannelConfig,3> across the
// C++ interop boundary — Swift fills a POD of primitives / passes raw enum ints.

#include "config.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace glic {

struct StudioParams {
    int colorSpace = 9;      // ColorSpace raw (HWB)
    int prediction = 9;      // PredictionMethod raw (PAETH)
    int quantization = 25;   // 0..255 (high values wash out toward flat color)
    float threshold = 15.0f; // segmentation precision
    int wavelet = 28;        // WaveletType raw (SYMLET8)
    int transform = 0;       // TransformType raw (FWT)
    int transformScale = 20; // wavelet coeff scale; raise to keep high quant from washing out
    int encoding = 1;        // EncodingMethod raw (PACKED)
    int minBlock = 2;
    int maxBlock = 256;
    int clampMod256 = 0;     // 0 = none, 1 = mod256
    int tile = 256;          // tile size in px; <= 0 => whole image (monolithic)
    int threads = 0;         // <= 0 => hardware_concurrency
};

// Tiled parallel encode -> decode round-trip. Returns decoded pixels (w*h, ARGB).
std::vector<Color> roundTripTiled(const Color* pixels, int w, int h, const StudioParams& p);

// Apply one post-processing effect (effects.cpp; incl. DCT_CORRUPT / PIXEL_SORT /
// PREDICTION_LEAK) to a pixel buffer in place.
void applyStudioEffect(Color* pixels, int w, int h,
                       int type, int intensity, int blockSize,
                       int offsetX, int offsetY, int levels,
                       int sortMode, int threshold, int sortVertical,
                       float leakAmount, uint32_t seed);

// Presets (per-channel CodecConfig from the preset gallery).
std::vector<std::string> listPresets(const std::string& presetsDir);
std::vector<Color> roundTripPreset(const Color* pixels, int w, int h,
                                   const std::string& presetsDir, const std::string& presetName,
                                   int tile, int threads);

// Silence the codec's std::cout progress logging (thread-safe no-op insertions).
void setQuietLogging(bool quiet);

} // namespace glic
