#include "../tools/resident_sweep.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr std::uint64_t kSeed = 0xA5A5F00D12345678ULL;

struct FakeHandle {
    std::vector<std::uint64_t>* backing;
};

bool alias_is_detected_when_chunks_remain_resident()
{
    std::vector<std::uint64_t> shared_backing(8, 0);
    std::size_t allocations = 0;
    unsigned long long errors = 0;

    const ResidentSweepResult result = run_resident_sweep(
        128, 64, 64,
        [&](std::size_t bytes, void** handle) {
            if (bytes != 64 || allocations >= 2) return false;
            *handle = new FakeHandle{&shared_backing};
            ++allocations;
            return true;
        },
        [&](void* opaque, std::size_t bytes, std::uint64_t base) {
            FakeHandle* handle = static_cast<FakeHandle*>(opaque);
            const std::size_t words = bytes / sizeof(std::uint64_t);
            for (std::size_t i = 0; i < words; ++i)
                (*handle->backing)[i] = kSeed ^ (base + i);
            return true;
        },
        [&](void* opaque, std::size_t bytes, std::uint64_t base) {
            FakeHandle* handle = static_cast<FakeHandle*>(opaque);
            const std::size_t words = bytes / sizeof(std::uint64_t);
            for (std::size_t i = 0; i < words; ++i)
                if ((*handle->backing)[i] != (kSeed ^ (base + i))) ++errors;
            return true;
        },
        [](void* opaque) { delete static_cast<FakeHandle*>(opaque); });

    return result.complete && result.fill_ok && result.verify_ok &&
           result.chunks == 2 && result.swept_bytes == 128 && errors == 8;
}

bool distinct_chunks_pass_without_false_errors()
{
    unsigned long long errors = 0;

    const ResidentSweepResult result = run_resident_sweep(
        128, 64, 64,
        [](std::size_t bytes, void** handle) {
            *handle = new FakeHandle{new std::vector<std::uint64_t>(bytes / sizeof(std::uint64_t), 0)};
            return true;
        },
        [](void* opaque, std::size_t bytes, std::uint64_t base) {
            FakeHandle* handle = static_cast<FakeHandle*>(opaque);
            const std::size_t words = bytes / sizeof(std::uint64_t);
            for (std::size_t i = 0; i < words; ++i)
                (*handle->backing)[i] = kSeed ^ (base + i);
            return true;
        },
        [&](void* opaque, std::size_t bytes, std::uint64_t base) {
            FakeHandle* handle = static_cast<FakeHandle*>(opaque);
            const std::size_t words = bytes / sizeof(std::uint64_t);
            for (std::size_t i = 0; i < words; ++i)
                if ((*handle->backing)[i] != (kSeed ^ (base + i))) ++errors;
            return true;
        },
        [](void* opaque) {
            FakeHandle* handle = static_cast<FakeHandle*>(opaque);
            delete handle->backing;
            delete handle;
        });

    return result.complete && result.fill_ok && result.verify_ok &&
           result.chunks == 2 && result.swept_bytes == 128 && errors == 0;
}

}  // namespace

int main()
{
    if (!alias_is_detected_when_chunks_remain_resident()) {
        std::fprintf(stderr, "FAIL: cross-chunk alias was not detected\n");
        return EXIT_FAILURE;
    }
    if (!distinct_chunks_pass_without_false_errors()) {
        std::fprintf(stderr, "FAIL: distinct resident chunks did not pass cleanly\n");
        return EXIT_FAILURE;
    }
    std::puts("resident sweep tests: PASS");
    return EXIT_SUCCESS;
}
