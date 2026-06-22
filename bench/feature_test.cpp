// Verify the new studio_api bridges: preset loading + C++ post-effects.
// Build (repo root):
//   clang++ -std=c++20 -O2 -DNDEBUG -I src -I external/stb \
//     src/glic.cpp src/planes.cpp src/colorspaces.cpp src/segment.cpp \
//     src/prediction.cpp src/quantization.cpp src/wavelet.cpp src/encoding.cpp \
//     src/bitio.cpp src/effects.cpp src/preset_loader.cpp src/studio_api.cpp \
//     bench/feature_test.cpp -o bench/feature_test

#include "glic.hpp"
#include "studio_api.hpp"

#include <cstdio>
#include <vector>

using namespace glic;

static std::vector<Color> makeImage(int w, int h) {
    std::vector<Color> px((size_t)w * h);
    uint32_t s = 1234;
    auto rnd = [&]() { s = s * 1664525u + 1013904223u; return s; };
    auto cl = [](int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); };
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            int r = (x * 255) / w, g = (y * 255) / h, b = (x ^ y) & 0xFF;
            int n = (int)(rnd() & 0x1F) - 16;
            px[(size_t)y * w + x] = makeColor((uint8_t)cl(r + n), (uint8_t)cl(g + n), (uint8_t)cl(b + n));
        }
    return px;
}

// crude "is this real content" metric: count distinct colors
static size_t distinctColors(const std::vector<Color>& px) {
    std::vector<Color> v = px;
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v.size();
}

int main() {
    setQuietLogging(true);
    const int w = 256, h = 256;
    auto img = makeImage(w, h);
    printf("input distinct colors: %zu\n", distinctColors(img));

    // ---- presets ----
    auto names = listPresets("presets");
    printf("\npresets found: %zu\n", names.size());
    for (size_t i = 0; i < names.size() && i < 8; ++i) printf("  - %s\n", names[i].c_str());
    if (!names.empty()) {
        const std::string& n = names[names.size() / 2]; // a middle one
        auto out = roundTripPreset(img.data(), w, h, "presets", n, 256, 4);
        printf("preset '%s' round-trip: %zu distinct colors -> bench/feat_preset.png\n",
               n.c_str(), distinctColors(out));
        saveImage("bench/feat_preset.png", out, w, h);
    }

    // ---- effects ----
    auto save = [&](const char* tag, int type, int intensity, int blockSize,
                    int sortMode, int threshold, int sortVertical, float leak, uint32_t seed,
                    const char* path) {
        auto buf = img;
        applyStudioEffect(buf.data(), w, h, type, intensity, blockSize, 2, 0, 4,
                          sortMode, threshold, sortVertical, leak, seed);
        printf("%s: %zu distinct colors -> %s\n", tag, distinctColors(buf), path);
        saveImage(path, buf, w, h);
    };
    printf("\neffects:\n");
    save("DCT_CORRUPT",     7, 60, 16, 0, 50, 0, 0.5f, 999,   "bench/feat_dct.png");
    save("PIXEL_SORT",      8, 50,  8, 0, 60, 0, 0.5f, 12345, "bench/feat_sort.png");
    save("PREDICTION_LEAK", 9, 50, 16, 0, 50, 0, 0.7f, 7,     "bench/feat_leak.png");
    return 0;
}
