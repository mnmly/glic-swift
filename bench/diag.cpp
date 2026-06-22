// Localize the round-trip failure by sweeping configs from trivial -> default.
// Reports mean abs error per channel for each stage combination.

#include "glic.hpp"
#include "studio_api.hpp"

#include <cmath>
#include <cstdio>
#include <string>
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

static double meanErr(const std::vector<Color>& a, const std::vector<Color>& b) {
    if (a.size() != b.size() || b.empty()) return -1;
    double e = 0;
    for (size_t i = 0; i < a.size(); ++i)
        e += std::abs(getR(a[i]) - getR(b[i])) + std::abs(getG(a[i]) - getG(b[i])) + std::abs(getB(a[i]) - getB(b[i]));
    return e / (a.size() * 3);
}

static void run(const char* tag, const std::vector<Color>& img, int w, int h,
                ColorSpace cs, PredictionMethod pred, WaveletType wav, int quant, EncodingMethod enc,
                float threshold = 15.0f, int maxBlock = 256) {
    CodecConfig cfg;
    cfg.colorSpace = cs;
    for (auto& ch : cfg.channels) {
        ch.predictionMethod = pred;
        ch.waveletType = wav;
        ch.transformType = TransformType::FWT;
        ch.quantizationValue = quant;
        ch.encodingMethod = enc;
        ch.clampMethod = ClampMethod::NONE;
        ch.minBlockSize = 2;
        ch.maxBlockSize = maxBlock;
        ch.segmentationPrecision = threshold;
        ch.transformScale = 20;
    }
    GlicCodec codec(cfg);
    auto buf = codec.encodeToBuffer(img.data(), w, h);
    auto dec = codec.decodeFromBuffer(buf);
    printf("%-52s enc=%7zuB  err=%.2f%s\n", tag, buf.size(), meanErr(img, dec.pixels),
           dec.success ? "" : "  (DECODE FAIL)");
}

int main() {
    setQuietLogging(true);
    const int w = 256, h = 256;
    auto img = makeImage(w, h);

    run("RGB | paeth | nowav | q0   | PACKED | 1 SEGMENT", img, w, h, ColorSpace::RGB, PredictionMethod::PAETH, WaveletType::NONE, 0, EncodingMethod::PACKED, 1e9f, 512);
    run("RGB | none  | nowav | q0   | RAW",    img, w, h, ColorSpace::RGB, PredictionMethod::NONE,  WaveletType::NONE,    0,   EncodingMethod::RAW);
    run("RGB | none  | nowav | q0   | PACKED", img, w, h, ColorSpace::RGB, PredictionMethod::NONE,  WaveletType::NONE,    0,   EncodingMethod::PACKED);
    run("RGB | paeth | nowav | q0   | PACKED", img, w, h, ColorSpace::RGB, PredictionMethod::PAETH, WaveletType::NONE,    0,   EncodingMethod::PACKED);
    run("RGB | none  | sym8  | q0   | PACKED", img, w, h, ColorSpace::RGB, PredictionMethod::NONE,  WaveletType::SYMLET8, 0,   EncodingMethod::PACKED);
    run("RGB | paeth | sym8  | q0   | PACKED", img, w, h, ColorSpace::RGB, PredictionMethod::PAETH, WaveletType::SYMLET8, 0,   EncodingMethod::PACKED);
    run("RGB | paeth | sym8  | q110 | PACKED", img, w, h, ColorSpace::RGB, PredictionMethod::PAETH, WaveletType::SYMLET8, 110, EncodingMethod::PACKED);
    run("HWB | paeth | sym8  | q110 | PACKED (app default)", img, w, h, ColorSpace::HWB, PredictionMethod::PAETH, WaveletType::SYMLET8, 110, EncodingMethod::PACKED);
    printf("--- quant sweep (HWB paeth sym8) ---\n");
    for (int q : {10, 20, 30, 40, 50, 60, 80}) {
        char tag[64]; snprintf(tag, sizeof(tag), "HWB | paeth | sym8  | q%-3d | PACKED", q);
        run(tag, img, w, h, ColorSpace::HWB, PredictionMethod::PAETH, WaveletType::SYMLET8, q, EncodingMethod::PACKED);
    }

    // Render the app-default config (HWB / PAETH / SYMLET8 / q110) to see whether
    // err~64 is legitimate heavy-quantization glitch or still broken.
    saveImage("bench/diag_in.png", img, w, h);
    {
        CodecConfig cfg; // defaults: HWB / PAETH / SYMLET8 / q110 / PACKED
        GlicCodec codec(cfg);
        auto dec = codec.decodeFromBuffer(codec.encodeToBuffer(img.data(), w, h));
        saveImage("bench/diag_default.png", dec.pixels, w, h);
    }
    {
        CodecConfig cfg;
        for (auto& ch : cfg.channels) ch.quantizationValue = 30; // light quant
        GlicCodec codec(cfg);
        auto dec = codec.decodeFromBuffer(codec.encodeToBuffer(img.data(), w, h));
        saveImage("bench/diag_q30.png", dec.pixels, w, h);
    }
    // Exercise the actual app path: tiled round-trip (512px, 256 tiles, q40).
    {
        int W = 512, H = 512;
        auto big = makeImage(W, H);
        StudioParams p;
        p.quantization = 25;
        p.tile = 256;
        p.threads = 4;
        auto out = roundTripTiled(big.data(), W, H, p);
        saveImage("bench/diag_app_in.png", big, W, H);
        saveImage("bench/diag_app_tiled.png", out, W, H);
    }
    return 0;
}
