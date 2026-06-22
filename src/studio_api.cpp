#include "studio_api.hpp"
#include "glic.hpp"
#include "effects.hpp"
#include "preset_loader.hpp"

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
        ch.transformScale = p.transformScale;
        ch.waveletType = static_cast<WaveletType>(p.wavelet);
        ch.encodingMethod = static_cast<EncodingMethod>(p.encoding);
    }
    return cfg;
}

void setQuietLogging(bool quiet) {
    if (quiet) std::cout.setstate(std::ios_base::failbit);
    else std::cout.clear();
}

// Shared tiled parallel encode->decode round-trip for a given CodecConfig.
static std::vector<Color> tiledRoundTrip(const Color* pixels, int w, int h,
                                         const CodecConfig& cfg, int tile, int threads) {
    std::vector<Color> out((size_t)w * h, 0);
    if (tile <= 0) tile = std::max(w, h); // whole image

    struct T { int x, y, tw, th; };
    std::vector<T> tiles;
    for (int y = 0; y < h; y += tile)
        for (int x = 0; x < w; x += tile)
            tiles.push_back({x, y, std::min(tile, w - x), std::min(tile, h - y)});
    if (tiles.empty()) return out;

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

std::vector<Color> roundTripTiled(const Color* pixels, int w, int h, const StudioParams& p) {
    return tiledRoundTrip(pixels, w, h, makeConfig(p), p.tile, p.threads);
}

std::vector<Color> roundTripPreset(const Color* pixels, int w, int h,
                                   const std::string& presetsDir, const std::string& presetName,
                                   int tile, int threads) {
    CodecConfig cfg; // sensible defaults, overwritten by the preset
    PresetLoader::loadPresetByName(presetsDir, presetName, cfg);
    return tiledRoundTrip(pixels, w, h, cfg, tile, threads);
}

std::vector<std::string> listPresets(const std::string& presetsDir) {
    return PresetLoader::listPresets(presetsDir);
}

void applyStudioEffect(Color* pixels, int w, int h,
                       int type, int intensity, int blockSize,
                       int offsetX, int offsetY, int levels,
                       int sortMode, int threshold, int sortVertical,
                       float leakAmount, uint32_t seed) {
    if (static_cast<EffectType>(type) == EffectType::NONE) return;
    EffectConfig e;
    e.type = static_cast<EffectType>(type);
    e.intensity = intensity;
    e.blockSize = blockSize;
    e.offsetX = offsetX;
    e.offsetY = offsetY;
    e.levels = levels;
    e.sortMode = static_cast<PixelSortMode>(sortMode);
    e.threshold = threshold;
    e.sortVertical = (sortVertical != 0);
    e.leakAmount = leakAmount;
    e.seed = seed;

    std::vector<Color> buf(pixels, pixels + (size_t)w * h);
    applyEffect(buf, w, h, e);
    std::copy(buf.begin(), buf.end(), pixels);
}

} // namespace glic
