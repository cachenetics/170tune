#ifndef RESIDENT_SWEEP_H
#define RESIDENT_SWEEP_H

#include <cstddef>
#include <cstdint>
#include <vector>

struct ResidentSweepResult {
    std::size_t swept_bytes;
    std::size_t chunks;
    bool complete;
    bool fill_ok;
    bool verify_ok;
};

struct ResidentSweepChunk {
    void* handle;
    std::size_t bytes;
    std::uint64_t base;
};

template <typename Allocate, typename Fill, typename Verify, typename Release>
ResidentSweepResult run_resident_sweep(std::size_t target_bytes,
                                       std::size_t preferred_chunk_bytes,
                                       std::size_t minimum_chunk_bytes,
                                       Allocate allocate,
                                       Fill fill,
                                       Verify verify,
                                       Release release)
{
    ResidentSweepResult result = {0, 0, false, false, false};
    std::vector<ResidentSweepChunk> chunks;
    std::uint64_t global_base = 0;

    if (target_bytes == 0 || preferred_chunk_bytes == 0 || minimum_chunk_bytes == 0)
        return result;
    try {
        chunks.reserve(target_bytes / minimum_chunk_bytes +
                       (target_bytes % minimum_chunk_bytes != 0));
    } catch (...) {
        return result;
    }

    const auto cleanup = [&]() {
        for (std::size_t i = 0; i < chunks.size(); ++i)
            release(chunks[i].handle);
    };

    while (result.swept_bytes < target_bytes) {
        std::size_t want = preferred_chunk_bytes;
        const std::size_t remaining = target_bytes - result.swept_bytes;
        if (want > remaining) want = remaining;
        want -= want % sizeof(std::uint64_t);

        void* handle = NULL;
        bool allocated = false;
        while (want >= minimum_chunk_bytes) {
            if (allocate(want, &handle)) {
                allocated = true;
                break;
            }
            want /= 2;
            want -= want % sizeof(std::uint64_t);
        }

        if (!allocated) {
            result.chunks = chunks.size();
            cleanup();
            return result;
        }

        ResidentSweepChunk chunk = {handle, want, global_base};
        chunks.push_back(chunk);
        result.swept_bytes += want;
        global_base += want / sizeof(std::uint64_t);
    }

    result.chunks = chunks.size();
    result.complete = (result.swept_bytes == target_bytes);
    if (!result.complete) {
        cleanup();
        return result;
    }

    result.fill_ok = true;
    for (std::size_t i = 0; i < chunks.size(); ++i) {
        const ResidentSweepChunk& chunk = chunks[i];
        if (!fill(chunk.handle, chunk.bytes, chunk.base)) {
            result.fill_ok = false;
            cleanup();
            return result;
        }
    }

    result.verify_ok = true;
    for (std::size_t i = 0; i < chunks.size(); ++i) {
        const ResidentSweepChunk& chunk = chunks[i];
        if (!verify(chunk.handle, chunk.bytes, chunk.base)) {
            result.verify_ok = false;
            cleanup();
            return result;
        }
    }

    cleanup();
    return result;
}

#endif
