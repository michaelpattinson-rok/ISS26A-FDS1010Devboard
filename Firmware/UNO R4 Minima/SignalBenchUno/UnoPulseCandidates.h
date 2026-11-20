#pragma once
#include <stdint.h>

namespace uno_pulse {
constexpr unsigned block = 1024, limit = 6, warmup = 98;
enum Coverage : uint8_t { eligible, calibration, failedCalibration, fault, envelope, overflow, prolonged };
enum Decision : uint8_t { candidate, narrow, wide, separated, edge };

struct Settings {
    unsigned threshold, minimum, maximum, separation, drift, noise;
    bool valid() const {
        return threshold >= 2 && threshold <= 8192 && minimum >= 2 && minimum <= maximum &&
               maximum <= 2048 && separation <= 5000 && drift >= 1 && drift <= 4096 && noise >= 1 && noise <= 4096;
    }
};

struct Record {
    uint32_t start, peak, end;
    uint16_t height, baseline;
    Decision decision;
};

struct Detector {
    Settings settings{};
    Record records[limit]{};
    Record open{};
    uint32_t expected{}, first{}, separationEnd{};
    uint64_t square{}, warmSquares{};
    uint32_t sum{}, warmSum{};
    unsigned filled{}, count{}, quietBlocks{};
    uint16_t baseline{}, warmMean{};
    bool warmFailed{}, opened{}, edgeStart{}, leftKnown{}, tooWide{}, tooMany{}, faulted{}, suppressWide{}, prolongedBlock{};
    Coverage coverage = calibration;

    void begin(uint32_t index) {
        if (index != expected) {
            if (quietBlocks < warmup) warmFailed = true;
            resetPulse();
        }
        first = index;
        filled = count = sum = 0;
        square = 0;
        faulted = tooMany = prolongedBlock = false;
        coverage = warmFailed ? failedCalibration : (quietBlocks < warmup ? calibration : eligible);
    }

    void resetPulse() {
        opened = edgeStart = leftKnown = tooWide = suppressWide = false;
        separationEnd = 0;
    }

    void append(uint16_t word) {
        const uint32_t at = first + filled++;
        const unsigned code = word & 0x3fff;
        if ((word & 0xc000) || code == 0 || code == 16383) {
            faulted = true;
            finishPulse(at, true);
            resetPulse();
            return;
        }
        sum += code;
        square += code * code;
        if (coverage != eligible || faulted) return;
        const int height = int(opened ? open.baseline : baseline) - int(code);
        if (height >= int(settings.threshold)) {
            if (suppressWide) { prolongedBlock = true; return; }
            if (!opened) {
                opened = true;
                edgeStart = !leftKnown;
                open = {at, at, 0, uint16_t(height), baseline, candidate};
            } else if (!tooWide && height > open.height) {
                open.height = uint16_t(height);
                open.peak = at;
            }
            if (at - open.start >= settings.maximum) {
                tooWide = prolongedBlock = true;
                finishPulse(at + 1, false);
                suppressWide = true;
            }
        } else {
            suppressWide = false;
            finishPulse(at, false);
            leftKnown = true;
        }
    }

    void finishPulse(uint32_t end, bool interrupted) {
        if (!opened) return;
        opened = false;
        const unsigned width = end - open.start;
        open.end = end;
        open.decision = tooWide ? wide : ((interrupted || edgeStart) ? edge :
            (width < settings.minimum ? narrow : (open.start < separationEnd ? separated : candidate)));
        if (open.decision == candidate) separationEnd = end + settings.separation;
        tooWide = false;
        if (count == limit) { tooMany = true; return; }
        records[count++] = open;
    }

    void complete() {
        expected = first + filled;
        if (coverage == calibration) {
            if (faulted) { warmFailed = true; coverage = failedCalibration; return; }
            warmSum += sum;
            warmSquares += square;
            if (++quietBlocks == warmup) {
                constexpr uint64_t n = block * warmup;
                const uint64_t variance = warmSquares * n - uint64_t(warmSum) * warmSum;
                if (variance > uint64_t(settings.noise) * settings.noise * n * n) {
                    warmFailed = true; coverage = failedCalibration;
                } else baseline = warmMean = uint16_t((warmSum + n / 2) / n);
            }
            return;
        }
        if (coverage != eligible) return;
        if (faulted) coverage = fault;
        else if (tooMany) coverage = overflow;
        else if (prolongedBlock) coverage = prolonged;
        else {
            const uint32_t mean = (sum + block / 2) / block;
            const int drift = int(mean) - int(warmMean);
            const uint64_t variance = square * block - uint64_t(sum) * sum;
            if (drift > int(settings.drift) || drift < -int(settings.drift) ||
                variance > uint64_t(settings.noise) * settings.noise * block * block) coverage = envelope;
            else if (!opened && count == 0 && leftKnown) baseline = uint16_t((15u * baseline + mean + 8) / 16);
        }
        if (coverage != eligible) {
            finishPulse(expected, true);
            for (unsigned i = 0; i < count; ++i)
                if (records[i].decision == candidate) records[i].decision = edge;
            const bool hold = coverage == prolonged && suppressWide;
            resetPulse();
            suppressWide = hold;
        }
    }
};
}
