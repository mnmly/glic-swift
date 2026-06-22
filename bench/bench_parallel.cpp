// Parallel tiled round-trip benchmark: how much does GLIC's serial ~3 MP/s codec
// speed up when the image is split into independent tiles processed across cores?
// Tiling is the effective lever — channel-parallelism is imbalanced (the luma
// channel carries ~6x the segments of each chroma channel).
//
// Requires the codec RNG to be thread_local (see segment.cpp / prediction.cpp).
//
// Build (from repo root):
//   clang++ -std=c++17 -O2 -DNDEBUG -I src -I external \
//     src/glic.cpp src/planes.cpp src/colorspaces.cpp src/segment.cpp \
//     src/prediction.cpp src/quantization.cpp src/wavelet.cpp src/encoding.cpp \
//     src/bitio.cpp src/effects.cpp bench/bench_parallel.cpp -o bench/bench_parallel

#include "glic.hpp"
#include "config.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <thread>
#include <vector>

using namespace glic;
using clk = std::chrono::steady_clock;

struct Tile { int x0, y0, tw, th; };

static std::vector<Color> makeImage(int w, int h, uint32_t seed) {
    std::vector<Color> px((size_t)w * h);
    uint32_t s = seed;
    auto rnd = [&]() { s = s * 1664525u + 1013904223u; return s; };
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            int r = (x * 255) / w, g = (y * 255) / h, b = (x ^ y) & 0xFF;
            int n = (int)(rnd() & 0x1F) - 16;
            r = std::clamp(r + n, 0, 255);
            g = std::clamp(g + n, 0, 255);
            b = std::clamp(b + n, 0, 255);
            px[(size_t)y * w + x] = makeColor((uint8_t)r, (uint8_t)g, (uint8_t)b);
        }
    return px;
}

static double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

static std::vector<Tile> buildTiles(int W, int H, int tw, int th) {
    std::vector<Tile> tiles;
    for (int y = 0; y < H; y += th)
        for (int x = 0; x < W; x += tw)
            tiles.push_back({x, y, std::min(tw, W - x), std::min(th, H - y)});
    return tiles;
}

static void roundtripRegion(GlicCodec& codec, const std::vector<Color>& img, int W,
                            const Tile& t, std::vector<Color>& out) {
    std::vector<Color> sub((size_t)t.tw * t.th);
    for (int y = 0; y < t.th; ++y)
        for (int x = 0; x < t.tw; ++x)
            sub[(size_t)y * t.tw + x] = img[(size_t)(t.y0 + y) * W + (t.x0 + x)];
    auto buf = codec.encodeToBuffer(sub.data(), t.tw, t.th);
    auto dec = codec.decodeFromBuffer(buf);
    if (!dec.success) return;
    for (int y = 0; y < t.th; ++y)
        for (int x = 0; x < t.tw; ++x)
            out[(size_t)(t.y0 + y) * W + (t.x0 + x)] = dec.pixels[(size_t)y * t.tw + x];
}

static double runTiled(const std::vector<Color>& img, int W, int /*H*/,
                       const std::vector<Tile>& tiles, int nThreads, std::vector<Color>& out) {
    std::atomic<int> next{0};
    auto worker = [&]() {
        GlicCodec codec; // own instance + own thread_local rng
        int j;
        while ((j = next.fetch_add(1)) < (int)tiles.size())
            roundtripRegion(codec, img, W, tiles[j], out);
    };
    auto t0 = clk::now();
    std::vector<std::thread> pool;
    for (int i = 0; i < nThreads; ++i) pool.emplace_back(worker);
    for (auto& th : pool) th.join();
    auto t1 = clk::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

static double runMono(const std::vector<Color>& img, int W, int H) {
    GlicCodec codec;
    auto t0 = clk::now();
    auto buf = codec.encodeToBuffer(img.data(), W, H);
    auto dec = codec.decodeFromBuffer(buf);
    auto t1 = clk::now();
    (void)dec;
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

int main() {
    std::cout.setstate(std::ios_base::failbit); // silence codec logging (thread-safe no-op)

    printf("hardware_concurrency = %u\n\n", std::thread::hardware_concurrency());

    struct Cfg { int W, H, tw, th; };
    std::vector<Cfg> cfgs = {
        {1024, 1024, 256, 256}, // 16 tiles
        {1024, 1024, 512, 512}, // 4 tiles (fewer than cores)
        {2048, 2048, 512, 512}, // 16 tiles
    };
    std::vector<int> threadCounts = {1, 2, 4, 6, 8};
    const int REPS = 5;

    for (auto cfg : cfgs) {
        auto img = makeImage(cfg.W, cfg.H, 1234);
        auto tiles = buildTiles(cfg.W, cfg.H, cfg.tw, cfg.th);
        double mp = (double)cfg.W * cfg.H / 1e6;
        std::vector<Color> out((size_t)cfg.W * cfg.H, 0);

        runMono(img, cfg.W, cfg.H); // warm
        std::vector<double> monoT;
        for (int r = 0; r < REPS; ++r) monoT.push_back(runMono(img, cfg.W, cfg.H));
        double mono = median(monoT);

        printf("=== %dx%d, tile %dx%d (%zu tiles) ===\n",
               cfg.W, cfg.H, cfg.tw, cfg.th, tiles.size());
        printf("  monolithic (1 call)   %8.1f ms   %5.1f fps\n", mono, 1000.0 / mono);

        double base1 = 0;
        for (int nt : threadCounts) {
            runTiled(img, cfg.W, cfg.H, tiles, nt, out); // warm
            std::vector<double> tt;
            for (int r = 0; r < REPS; ++r) tt.push_back(runTiled(img, cfg.W, cfg.H, tiles, nt, out));
            double m = median(tt);
            if (nt == 1) base1 = m;
            printf("  tiled %2d thr          %8.1f ms   %5.1f fps   %4.2fx vs tiled-1   %4.2fx vs mono   %6.1f MP/s\n",
                   nt, m, 1000.0 / m, base1 / m, mono / m, mp / (m / 1000.0));
        }
        printf("\n");
    }
    return 0;
}
