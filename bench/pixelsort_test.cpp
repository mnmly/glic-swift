// Render pixel-sort on a real codec-glitched image at a few thresholds, to see
// what's visible and choose a sensible default.
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

// type=8 (PIXEL_SORT): params used = sortMode, threshold, vertical
static void sortAndSave(const std::vector<Color>& base, int w, int h,
                        int sortMode, int threshold, int vertical, const char* path) {
    auto buf = base;
    applyStudioEffect(buf.data(), w, h, 8, 50, 8, 2, 0, 4, sortMode, threshold, vertical, 0.5f, 1);
    saveImage(path, buf, w, h);
}

int main() {
    setQuietLogging(true);
    const int w = 320, h = 240;
    auto img = makeImage(w, h);
    StudioParams p;
    p.quantization = 25;
    p.tile = 256;
    p.threads = 4;
    auto base = roundTripTiled(img.data(), w, h, p);
    saveImage("bench/ps_base.png", base, w, h);

    sortAndSave(base, w, h, 0, 20, 0, "bench/ps_t20_h.png");   // threshold 20, horizontal
    sortAndSave(base, w, h, 0, 50, 0, "bench/ps_t50_h.png");   // threshold 50 (current default)
    sortAndSave(base, w, h, 0, 20, 1, "bench/ps_t20_v.png");   // threshold 20, vertical
    printf("saved ps_base, ps_t20_h, ps_t50_h, ps_t20_v\n");
    return 0;
}
