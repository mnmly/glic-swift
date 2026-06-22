#include "studio_api.hpp"
#include "glic.hpp"

#include <algorithm>
#include <atomic>
#include <iostream>
#include <thread>
#include <vector>

namespace glic {

static CodecConfig makeConfig(const StudioParams& p) {
    CodecConfig cfg;
    cfg.colorSpace = static_cast<ColorSpace>(p.colorSpace);
    for (auto& ch : cfg.channels) {
        ch.minBlockSize = p.minBlock;
        ch.maxBlockSize = p.maxBlock;
        ch.segmentationPrecision = p.threshold;
        ch.predictionMethod = static_cast<PredictionMethod>(p.prediction);
        ch.quantizationValue = p.quantization;
        ch.clampMethod = p.clampMod256 ? ClampMethod::MOD256 : ClampMethod::NONE;
        ch.transformType = static_cast<TransformType>(p.transform);
        ch.waveletType = static_cast<WaveletType>(p.wavelet);
        ch.encodingMethod = static_cast<EncodingMethod>(p.encoding);
    }
    return cfg;
}

void setQuietLogging(bool quiet) {
    if (quiet) std::cout.setstate(std::ios_base::failbit);
    else std::cout.clear();
}

std::vector<Color> roundTripTiled(const Color* pixels, int w, int h, const StudioParams& p) {
    const CodecConfig cfg = makeConfig(p);
    std::vector<Color> out((size_t)w * h, 0);

    int tile = p.tile;
    if (tile <= 0) tile = std::max(w, h); // whole image

    struct T { int x, y, tw, th; };
    std::vector<T> tiles;
    for (int y = 0; y < h; y += tile)
        for (int x = 0; x < w; x += tile)
            tiles.push_back({x, y, std::min(tile, w - x), std::min(tile, h - y)});
    if (tiles.empty()) return out;

    int threads = p.threads;
    if (threads <= 0) threads = (int)std::thread::hardware_concurrency();
    threads = std::max(1, std::min<int>(threads, (int)tiles.size()));

    std::atomic<int> next{0};
    auto worker = [&]() {
        GlicCodec codec(cfg); // own instance + own thread_local rng
        int j;
        while ((j = next.fetch_add(1)) < (int)tiles.size()) {
            const T& t = tiles[j];
            std::vector<Color> sub((size_t)t.tw * t.th);
            for (int yy = 0; yy < t.th; ++yy)
                for (int xx = 0; xx < t.tw; ++xx)
                    sub[(size_t)yy * t.tw + xx] = pixels[(size_t)(t.y + yy) * w + (t.x + xx)];
            auto buf = codec.encodeToBuffer(sub.data(), t.tw, t.th);
            auto dec = codec.decodeFromBuffer(buf);
            if (!dec.success) continue;
            for (int yy = 0; yy < t.th; ++yy)
                for (int xx = 0; xx < t.tw; ++xx)
                    out[(size_t)(t.y + yy) * w + (t.x + xx)] = dec.pixels[(size_t)yy * t.tw + xx];
        }
    };

    std::vector<std::thread> pool;
    pool.reserve(threads);
    for (int i = 0; i < threads; ++i) pool.emplace_back(worker);
    for (auto& th : pool) th.join();
    return out;
}

} // namespace glic
