// In-memory baseline benchmark for the GLIC C++ codec.
// No file I/O: uses encodeToBuffer / decodeFromBuffer on a synthetic image,
// isolating pure codec compute (segmentation, prediction, wavelet, entropy).
//
// Build (from repo root):
//   clang++ -std=c++17 -O2 -DNDEBUG -I src -I external \
//     src/glic.cpp src/planes.cpp src/colorspaces.cpp src/segment.cpp \
//     src/prediction.cpp src/quantization.cpp src/wavelet.cpp src/encoding.cpp \
//     src/bitio.cpp src/effects.cpp bench/bench_cpp.cpp -o bench/bench_cpp

#include "glic.hpp"
#include "config.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <random>
#include <streambuf>
#include <vector>

using namespace glic;
using clk = std::chrono::steady_clock;

// The codec logs progress to std::cout inside the timed path. Swallow it so it
// does not contaminate timings. Our result table uses C printf (separate stream).
struct NullBuf : std::streambuf {
    int overflow(int c) override { return c; }
};

// A representative "photo-like" image: smooth gradients + structured detail +
// a little high-frequency noise, so segmentation/prediction do real work.
static std::vector<Color> makeImage(int w, int h, uint32_t seed) {
    std::vector<Color> px(static_cast<size_t>(w) * h);
    std::mt19937 rng(seed);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            int r = (x * 255) / w;
            int g = (y * 255) / h;
            int b = ((x ^ y) & 0xFF);
            int n = static_cast<int>(rng() & 0x1F) - 16; // +/- noise
            r = std::clamp(r + n, 0, 255);
            g = std::clamp(g + n, 0, 255);
            b = std::clamp(b + n, 0, 255);
            px[static_cast<size_t>(y) * w + x] =
                makeColor((uint8_t)r, (uint8_t)g, (uint8_t)b);
        }
    }
    return px;
}

static double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

int main() {
    NullBuf nb;
    std::cout.rdbuf(&nb); // silence codec debug logging during timing

    struct Res { int w, h; int iters; };
    std::vector<Res> sizes = {
        {256, 256, 7}, {512, 512, 7}, {1024, 1024, 5},
        {2048, 2048, 4}, {4096, 4096, 3},
    };

    printf("%-12s %8s %9s %9s %9s %10s %9s\n",
           "resolution", "MP", "enc_ms", "dec_ms", "rt_ms", "rt_MP/s", "ratio");
    printf("------------------------------------------------------------------------\n");

    for (auto s : sizes) {
        auto img = makeImage(s.w, s.h, 1234);
        double mp = (double)s.w * s.h / 1e6;

        GlicCodec codec; // default config: HWB / PAETH / SYMLET8 / packed

        // warm-up (allocations, caches) — not timed
        auto buf0 = codec.encodeToBuffer(img.data(), s.w, s.h);
        auto dec0 = codec.decodeFromBuffer(buf0);
        if (!dec0.success) {
            printf("%dx%d  DECODE FAILED: %s\n", s.w, s.h, dec0.error.c_str());
            continue;
        }

        std::vector<double> encT, decT;
        size_t bufBytes = buf0.size();
        for (int i = 0; i < s.iters; ++i) {
            auto t0 = clk::now();
            auto buf = codec.encodeToBuffer(img.data(), s.w, s.h);
            auto t1 = clk::now();
            auto dec = codec.decodeFromBuffer(buf);
            auto t2 = clk::now();
            encT.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
            decT.push_back(std::chrono::duration<double, std::milli>(t2 - t1).count());
            bufBytes = buf.size();
        }

        double e = median(encT), d = median(decT), rt = e + d;
        double ratio = (double)((size_t)s.w * s.h * 4) / (double)bufBytes;
        char label[32];
        snprintf(label, sizeof(label), "%dx%d", s.w, s.h);
        printf("%-12s %8.2f %9.1f %9.1f %9.1f %10.1f %8.2fx\n",
               label, mp, e, d, rt, mp / (rt / 1000.0), ratio);
    }
    return 0;
}
