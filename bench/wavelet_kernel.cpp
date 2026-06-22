// Language head-to-head: a representative wavelet kernel (same shape as GLIC's
// Symlet8 forward transform — 16-tap separable periodic convolution + downsample,
// multi-level Mallat). NOT bit-identical to GLIC; matched in arithmetic shape so
// the only variable is C++ vs Swift codegen. Checksum lets us confirm the Swift
// port computes the identical result.
//
// Build: clang++ -std=c++17 -O2 -DNDEBUG bench/wavelet_kernel.cpp -o bench/wk_cpp

#include <chrono>
#include <cstdio>
#include <vector>

using clk = std::chrono::steady_clock;

static const double H[16] = {
    0.054415842, -0.312871590, 0.675630736, -0.585354684,
    -0.015829105, 0.284015543, -0.000472485, -0.128747427,
    0.017369301, 0.044088254, -0.013981028, -0.008746094,
    0.004870353, -0.000391740, -0.000675449, 0.000117477};
static double G[16];

// 1D forward step: src contiguous (stride 1), dst with stride `ds`.
// First half = approximation, second half = detail. Periodic (n >= 16).
static inline void fwt1d(const double* src, double* dst, int n, int ds) {
    const int half = n >> 1;
    for (int i = 0; i < half; ++i) {
        double a = 0.0, d = 0.0;
        const int base = 2 * i;
        for (int k = 0; k < 16; ++k) {
            int idx = base + k;
            if (idx >= n) idx -= n;
            const double v = src[idx];
            a += H[k] * v;
            d += G[k] * v;
        }
        dst[i * ds] = a;
        dst[(half + i) * ds] = d;
    }
}

static void fwt2d(std::vector<double>& a, std::vector<double>& tmp, int W, int levels) {
    for (int lvl = 0; lvl < levels; ++lvl) {
        const int n = W >> lvl;
        for (int r = 0; r < n; ++r) { // rows
            double* row = a.data() + (size_t)r * W;
            for (int i = 0; i < n; ++i) tmp[i] = row[i];
            fwt1d(tmp.data(), row, n, 1);
        }
        for (int c = 0; c < n; ++c) { // columns
            for (int i = 0; i < n; ++i) tmp[i] = a[(size_t)i * W + c];
            fwt1d(tmp.data(), a.data() + c, n, W);
        }
    }
}

int main() {
    for (int k = 0; k < 16; ++k) G[k] = ((k & 1) ? -1.0 : 1.0) * H[15 - k];

    const int W = 512, levels = 5, iters = 100;
    const size_t count = (size_t)W * W;

    std::vector<double> input(count), work(count), tmp(W);
    for (int y = 0; y < W; ++y)
        for (int x = 0; x < W; ++x)
            input[(size_t)y * W + x] = (double)((x * 131 + y * 977) % 251) / 251.0;

    work = input;
    fwt2d(work, tmp, W, levels); // warm-up

    std::vector<double> times;
    double checksum = 0.0;
    for (int it = 0; it < iters; ++it) {
        for (size_t i = 0; i < count; ++i) work[i] = input[i]; // untimed refill
        auto t0 = clk::now();
        fwt2d(work, tmp, W, levels);
        auto t1 = clk::now();
        times.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        if (it == iters - 1) {
            for (size_t i = 0; i < count; ++i) checksum += work[i];
        }
    }
    std::sort(times.begin(), times.end());
    printf("C++   (-O2)        %7.3f ms/transform   checksum=%.6f\n",
           times[times.size() / 2], checksum);
    return 0;
}
