// Does wavelet transformScale control the high-quant washout?
// Sweep quant x transformScale; distinct-color count ~ "is it washed to flat".
#include "glic.hpp"
#include "studio_api.hpp"

#include <algorithm>
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

static size_t distinct(const std::vector<Color>& px) {
    std::vector<Color> v = px;
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v.size();
}

static std::vector<Color> rt(const std::vector<Color>& img, int w, int h, int quant, int scale) {
    CodecConfig cfg;
    cfg.colorSpace = ColorSpace::HWB;
    for (auto& ch : cfg.channels) {
        ch.predictionMethod = PredictionMethod::PAETH;
        ch.waveletType = WaveletType::SYMLET8;
        ch.quantizationValue = quant;
        ch.transformScale = scale;
        ch.encodingMethod = EncodingMethod::PACKED;
    }
    GlicCodec codec(cfg);
    return codec.decodeFromBuffer(codec.encodeToBuffer(img.data(), w, h)).pixels;
}

int main() {
    setQuietLogging(true);
    const int w = 256, h = 256;
    auto img = makeImage(w, h);
    printf("input distinct colors: %zu  (washed-flat ~= a few hundred)\n\n", distinct(img));
    printf("HWB/PAETH/SYM8 — distinct colors by quant x transformScale:\n");
    printf("%6s", "");
    for (int sc : {20, 60, 120, 240, 480}) printf("  sc=%-6d", sc);
    printf("\n");
    for (int q : {30, 60, 110, 180, 255}) {
        printf("q=%-4d", q);
        for (int sc : {20, 60, 120, 240, 480}) printf("  %-9zu", distinct(rt(img, w, h, q, sc)));
        printf("\n");
    }
    saveImage("bench/scale_q110_sc20.png", rt(img, w, h, 110, 20), w, h);
    saveImage("bench/scale_q110_sc240.png", rt(img, w, h, 110, 240), w, h);
    saveImage("bench/scale_q200_sc480.png", rt(img, w, h, 200, 480), w, h);
    printf("\nsaved bench/scale_q110_sc20.png, scale_q110_sc240.png, scale_q200_sc480.png\n");
    return 0;
}
