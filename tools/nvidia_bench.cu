/*
 * nvidia_bench — GPU micro-benchmark:
 *   - memory latency (pointer chase, chain scaled to >= 16x L2, 128 B stride)
 *   - DRAM bandwidth (vectorized float4 read/write/copy/triad, cudaMemcpy D2D)
 *   - dense tensor-core throughput via WMMA: TF32 (FP32 inputs), BF16, INT8
 *     (on Hopper/Blackwell datacenter parts WMMA can understate absolute
 *     peak — wgmma/tcgen05 paths are not used)
 *   - measured max SM boost clock
 *   - PCIe H2D/D2H bandwidth (pinned) + link config guess vs NVML readout
 *   - feature report: NVENC/NVDEC presence and engine counts (probed through
 *     the driver's libnvidia-encode/libnvcuvid rather than NVML's tables),
 *     MIG, ECC, NVLink, BAR1, copy engines, ...
 *
 * Minimum CUDA to build the source: 11.0 (WMMA TF32/BF16 and cuda_bf16.h;
 * the CUDA-cores line needs 11.5+ headers and a R495+ driver — it is bound
 * weakly and skipped when the driver lacks the symbol). The full build line
 * below needs CUDA 12.8+ (compute_100/120 gencodes); CUDA 13.x cannot target
 * Volta (sm_70) or older. NVML queries degrade gracefully on old drivers.
 *
 * Build: nvcc -O3 -o nvidia_bench nvidia_bench.cu -lnvidia-ml -ldl \
          -gencode arch=compute_75,code=sm_75 \
          -gencode arch=compute_80,code=sm_80 \
          -gencode arch=compute_86,code=sm_86 \
          -gencode arch=compute_89,code=sm_89 \
          -gencode arch=compute_90,code=sm_90 \
          -gencode arch=compute_100,code=sm_100 \
          -gencode arch=compute_120,code=sm_120 \
          -gencode arch=compute_120,code=compute_120
 *
 * Run:   ./nvidia_bench
          ./nvidia_bench [gpu_id] [iterations] [--csv]
 *        iterations <= 0 (default) auto-sizes each timed run to ~1 s, which
 *        stays under the ~2 s display watchdog; compute tests keep a 100 ms
 *        floor. --csv prints one header line and one data line instead of the
 *        report. -h for usage help.
 */

#include <cuda_runtime.h>
#include <nvml.h>
#include <mma.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <limits.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

#if defined(CUDART_VERSION) && CUDART_VERSION < 11000
#error "nvidia_bench requires CUDA 11.0+ (WMMA TF32/BF16 fragments, cuda_bf16.h)"
#endif

// nvmlDeviceGetNumGpuCores only exists in libnvidia-ml from driver R495; bind
// it weakly so older drivers skip the CUDA Cores line instead of dying with a
// dynamic-loader "undefined symbol" before any output.
#if defined(CUDART_VERSION) && CUDART_VERSION >= 11050 && defined(__GNUC__)
extern "C" nvmlReturn_t nvmlDeviceGetNumGpuCores(nvmlDevice_t, unsigned int *) __attribute__((weak));
#define HAVE_NUM_GPU_CORES 1
#endif

#define CHECK_CUDA(call) do { \
    cudaError_t err = call; \
    if (err != cudaSuccess) { \
        fprintf(stderr, "CUDA Error at %s:%d - %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        if (err == cudaErrorLaunchTimeout) \
            fprintf(stderr, "  The display watchdog killed a kernel. Re-run with a small explicit\n" \
                            "  iteration count, e.g. %s <gpu_id> 20\n", "./nvidia_bench"); \
        exit(1); \
    } \
} while(0)

// --csv replaces the human-readable report with one header + one data line
static bool g_csv = false;
#define OUT(...) do { if (!g_csv) printf(__VA_ARGS__); } while (0)

// ─── Vectorized float4 memory access kernels (128-bit / 16 bytes per thread) ───

// Read-Only: read float4 from global memory and reduce into scalar register
__global__ void bench_hbm_read(const float4 * __restrict__ A, float * __restrict__ dummy_out, size_t N_vec, int iters) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    size_t stride = blockDim.x * gridDim.x;

    float acc = 0.0f;
    for (int iter = 0; iter < iters; iter++) {
        for (size_t i = idx; i < N_vec; i += stride) {
            float4 v = A[i];
            acc += v.x + v.y + v.z + v.w;
        }
    }
    // A holds only positive values, so acc can never be -1.0f — but the compiler
    // can't prove that, which keeps every thread's loads live
    if (acc == -1.0f) dummy_out[0] = acc;
}

// Write-Only: store float4 values to global memory
__global__ void bench_hbm_write(float4 * __restrict__ A, float4 val, size_t N_vec, int iters) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    size_t stride = blockDim.x * gridDim.x;

    for (int iter = 0; iter < iters; iter++) {
        float4 v = val;
        v.x += (float)iter;  // distinct value each pass so passes can't be merged
        for (size_t i = idx; i < N_vec; i += stride) {
            A[i] = v;
        }
    }
}

// Copy (D2D): dst[i] = src[i] (1 float4 read + 1 float4 write = 32 bytes traffic per element).
// Direction alternates each pass, so every store feeds the next pass's loads and
// no pass is a repeat of the previous one.
__global__ void bench_hbm_copy(float4 * __restrict__ A, float4 * __restrict__ B, size_t N_vec, int iters) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    size_t stride = blockDim.x * gridDim.x;

    for (int iter = 0; iter < iters; iter++) {
        const float4 *src = (iter & 1) ? B : A;
        float4 *dst = (iter & 1) ? A : B;
        for (size_t i = idx; i < N_vec; i += stride) {
            dst[i] = src[i];
        }
    }
}

// STREAM Triad: dst[i] = src[i] + alpha * B[i] (2 float4 reads + 1 float4 write = 48 bytes traffic per element).
// A and C swap roles each pass for the same reason as in bench_hbm_copy.
__global__ void bench_hbm_triad(float4 * __restrict__ A, const float4 * __restrict__ B, float4 * __restrict__ C, float alpha, size_t N_vec, int iters) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    size_t stride = blockDim.x * gridDim.x;

    for (int iter = 0; iter < iters; iter++) {
        const float4 *src = (iter & 1) ? C : A;
        float4 *dst = (iter & 1) ? A : C;
        for (size_t i = idx; i < N_vec; i += stride) {
            float4 a = src[i];
            float4 b = B[i];
            float4 c;
            c.x = a.x + alpha * b.x;
            c.y = a.y + alpha * b.y;
            c.z = a.z + alpha * b.z;
            c.w = a.w + alpha * b.w;
            dst[i] = c;
        }
    }
}

// ─── Memory latency kernel (Pointer Chasing / Stride) ───
__global__ void bench_hbm_latency(const uint32_t * __restrict__ chain, uint32_t * __restrict__ out_idx, int steps) {
    uint32_t idx = 0;
    for (int i = 0; i < steps; i++) {
        idx = chain[idx];
    }
    out_idx[0] = idx;
}

// Scatter the permutation into the padded chain: one slot per 128-byte cache line
// (stride 32 uint32_t), indices pre-scaled by 32 so the chase loop needs no math.
__global__ void build_chain(const uint32_t * __restrict__ perm, uint32_t * __restrict__ chain, size_t n_slots) {
    size_t k = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    size_t stride = (size_t)blockDim.x * gridDim.x;
    for (; k < n_slots; k += stride) {
        chain[k * 32] = perm[k] * 32u;
    }
}

// ─── Tensor core throughput kernels (WMMA) ───
// Operands live in registers; each warp drives TC_ACC independent MMA
// accumulation chains so the tensor pipes stay saturated with no memory
// traffic. FLOPs are counted host-side as 2*M*N*K per mma_sync.
#define TC_ACC 4

__global__ void bench_tensor_tf32(float * __restrict__ dummy_out, int iters) {
#if __CUDA_ARCH__ >= 800
    using namespace nvcuda;
    wmma::fragment<wmma::matrix_a, 16, 16, 8, wmma::precision::tf32, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, 16, 16, 8, wmma::precision::tf32, wmma::col_major> b;
    wmma::fragment<wmma::accumulator, 16, 16, 8, float> c[TC_ACC];
    wmma::fill_fragment(a, 1.0f);
    wmma::fill_fragment(b, 1.0f);
    for (int k = 0; k < TC_ACC; k++) wmma::fill_fragment(c[k], 0.0f);
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < TC_ACC; k++) wmma::mma_sync(c[k], a, b, c[k]);
    }
    float sum = 0.0f;
    for (int k = 0; k < TC_ACC; k++)
        for (int e = 0; e < c[k].num_elements; e++) sum += c[k].x[e];
    // c accumulates only non-negative products, so sum can never be -1.0f —
    // but the compiler can't prove that, which keeps the MMA chains live
    if (sum == -1.0f) dummy_out[0] = sum;
#endif
}

__global__ void bench_tensor_bf16(float * __restrict__ dummy_out, int iters) {
#if __CUDA_ARCH__ >= 800
    using namespace nvcuda;
    wmma::fragment<wmma::matrix_a, 16, 16, 16, __nv_bfloat16, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, 16, 16, 16, __nv_bfloat16, wmma::col_major> b;
    wmma::fragment<wmma::accumulator, 16, 16, 16, float> c[TC_ACC];
    wmma::fill_fragment(a, __float2bfloat16(1.0f));
    wmma::fill_fragment(b, __float2bfloat16(1.0f));
    for (int k = 0; k < TC_ACC; k++) wmma::fill_fragment(c[k], 0.0f);
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < TC_ACC; k++) wmma::mma_sync(c[k], a, b, c[k]);
    }
    float sum = 0.0f;
    for (int k = 0; k < TC_ACC; k++)
        for (int e = 0; e < c[k].num_elements; e++) sum += c[k].x[e];
    if (sum == -1.0f) dummy_out[0] = sum;
#endif
}

__global__ void bench_tensor_int8(int * __restrict__ dummy_out, int iters) {
#if __CUDA_ARCH__ >= 720
    using namespace nvcuda;
    wmma::fragment<wmma::matrix_a, 16, 16, 16, signed char, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, 16, 16, 16, signed char, wmma::col_major> b;
    wmma::fragment<wmma::accumulator, 16, 16, 16, int> c[TC_ACC];
    wmma::fill_fragment(a, 1);
    wmma::fill_fragment(b, 1);
    for (int k = 0; k < TC_ACC; k++) wmma::fill_fragment(c[k], 0);
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < TC_ACC; k++) wmma::mma_sync(c[k], a, b, c[k]);
    }
    long long sum = 0;
    for (int k = 0; k < TC_ACC; k++)
        for (int e = 0; e < c[k].num_elements; e++) sum += c[k].x[e];
    if (sum == -1) dummy_out[0] = (int)sum;
#endif
}

// ─── CUDA-core FMA throughput kernels ───
// Each thread runs CC_CHAINS independent FMA dependency chains held in
// registers — enough ILP to saturate the pipes with no memory traffic. The
// multiplier/addend arrive as kernel arguments (not literals) and the
// recurrence x = x*b + c converges to a finite fixed point, so nothing folds
// at compile time and no value ever overflows. FLOPs are counted host-side as
// 2 per FMA (fp64/fp32) or 4 per packed half2 FMA.
#define CC_CHAINS 8

__global__ void bench_fp64_fma(double * __restrict__ out, double b, double c, int iters) {
    double a[CC_CHAINS];
#pragma unroll
    for (int k = 0; k < CC_CHAINS; k++) a[k] = (double)(threadIdx.x + k);
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < CC_CHAINS; k++) a[k] = fma(a[k], b, c);
    }
    double sum = 0.0;
#pragma unroll
    for (int k = 0; k < CC_CHAINS; k++) sum += a[k];
    // The chains converge to positive values, so sum can never be -1.0 — but
    // the compiler can't prove it, which keeps every FMA live
    if (sum == -1.0) out[0] = sum;
}

__global__ void bench_fp32_fma(float * __restrict__ out, float b, float c, int iters) {
    float a[CC_CHAINS];
#pragma unroll
    for (int k = 0; k < CC_CHAINS; k++) a[k] = (float)(threadIdx.x + k);
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < CC_CHAINS; k++) a[k] = fmaf(a[k], b, c);
    }
    float sum = 0.0f;
#pragma unroll
    for (int k = 0; k < CC_CHAINS; k++) sum += a[k];
    if (sum == -1.0f) out[0] = sum;
}

__global__ void bench_fp16_fma(__half * __restrict__ out, __half2 b, __half2 c, int iters) {
#if __CUDA_ARCH__ >= 530
    __half2 a[CC_CHAINS];
#pragma unroll
    for (int k = 0; k < CC_CHAINS; k++)
        a[k] = __float2half2_rn((float)((threadIdx.x & 7) + k));  // stay well inside half range
    for (int i = 0; i < iters; i++) {
#pragma unroll
        for (int k = 0; k < CC_CHAINS; k++) a[k] = __hfma2(a[k], b, c);
    }
    __half2 s = a[0];
#pragma unroll
    for (int k = 1; k < CC_CHAINS; k++) s = __hadd2(s, a[k]);
    float sf = __low2float(s) + __high2float(s);
    if (sf == -1.0f) out[0] = __float2half(sf);
#endif
}

// ─── SM clock measurement kernel ───
// A single busy thread is the lightest load the boost governor sees, so it
// settles at the top clock bin; each segment derives the true SM frequency
// from clock64() cycles over %globaltimer nanoseconds (no NVML involved).
#define CLK_SEGMENTS 12
__global__ void bench_clock(unsigned long long * __restrict__ out_cycles, unsigned long long * __restrict__ out_ns, int seg_ms) {
    for (int s = 0; s < CLK_SEGMENTS; s++) {
        unsigned long long t0, t1;
        asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(t0));
        unsigned long long c0 = clock64();
        unsigned long long tgt = t0 + (unsigned long long)seg_ms * 1000000ull;
        do { asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(t1)); } while (t1 < tgt);
        out_cycles[s] = clock64() - c0;
        out_ns[s] = t1 - t0;
    }
}

// ─── NVENC/NVDEC hardware probes ───
// Engine counts come from the driver's own video stacks instead of NVML's
// device table (which drivers may get wrong): a real NVENC session open -
// it fails with NO_ENCODE_DEVICE on encoder-less parts like GA100/H100 - plus
// NV_ENC_CAPS_NUM_ENCODER_ENGINES, and cuvidGetDecoderCaps' nNumNVDECs.
// The structs below are minimal ABI mirrors of nvEncodeAPI.h / cuviddec.h
// (Video Codec SDK headers are not shipped with the CUDA toolkit). Both
// libraries come with the driver but may be absent in containers, so every
// failure path degrades to "unknown". Requires an R455+ (API 11.0) driver.

typedef struct { unsigned int Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } nvb_guid;

typedef struct {
    uint32_t version;
    uint32_t capsToQuery;
    uint32_t reserved[62];
} nvb_enc_caps_param;

typedef struct {
    uint32_t version;
    uint32_t deviceType;      // NV_ENC_DEVICE_TYPE_CUDA = 1
    void *device;             // CUcontext
    void *reserved;
    uint32_t apiVersion;
    uint32_t reserved1[253];
    void *reserved2[64];
} nvb_enc_session_params;

// NV_ENCODE_API_FUNCTION_LIST: 318 pointer slots after version/reserved;
// we only type the three slots we call (8, 28, 30 — stable since API 7)
typedef struct {
    uint32_t version;
    uint32_t reserved;
    void *fn_a[7];
    int (*getEncodeCaps)(void *, nvb_guid, nvb_enc_caps_param *, int *);
    void *fn_b[19];
    int (*destroyEncoder)(void *);
    void *fn_c[1];
    int (*openSessionEx)(nvb_enc_session_params *, void **);
    void *fn_d[288];
} nvb_enc_function_list;

#define NVB_ENCAPI_VERSION (11u | (0u << 24))
#define NVB_ENC_STRUCT_VER(v) (NVB_ENCAPI_VERSION | ((v) << 16) | (0x7u << 28))
#define NVB_ENC_CAPS_NUM_ENCODER_ENGINES 49

// Returns 1 = present (engines set if the driver can count them, else -1),
// 0 = absent, -1 = could not tell. Needs a current CUDA context.
static int probe_nvenc(int *engines) {
    *engines = -1;
    void *lib = dlopen("libnvidia-encode.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) return -1;
    typedef int (*create_fn)(nvb_enc_function_list *);
    typedef int (*ctxget_fn)(void **);
    create_fn create = (create_fn)dlsym(lib, "NvEncodeAPICreateInstance");
    // cudart loads libcuda with RTLD_LOCAL, so its symbols are invisible via
    // RTLD_DEFAULT — open it explicitly (already resident, refcount bump only)
    void *cuda_lib = dlopen("libcuda.so.1", RTLD_LAZY | RTLD_LOCAL);
    ctxget_fn ctxget = cuda_lib ? (ctxget_fn)dlsym(cuda_lib, "cuCtxGetCurrent") : NULL;
    void *ctx = NULL;
    int rc = -1;
    if (create && ctxget && ctxget(&ctx) == 0 && ctx) {
        nvb_enc_function_list fl;
        memset(&fl, 0, sizeof(fl));
        fl.version = NVB_ENC_STRUCT_VER(2);
        if (create(&fl) == 0 && fl.openSessionEx && fl.destroyEncoder) {
            nvb_enc_session_params sp;
            memset(&sp, 0, sizeof(sp));
            sp.version = NVB_ENC_STRUCT_VER(1);
            sp.deviceType = 1;
            sp.device = ctx;
            sp.apiVersion = NVB_ENCAPI_VERSION;
            void *enc = NULL;
            int st = fl.openSessionEx(&sp, &enc);
            if (st == 0 && enc) {
                rc = 1;
                if (fl.getEncodeCaps) {
                    nvb_guid h264 = { 0x6bc82762, 0x4e63, 0x4ca4,
                                      { 0xaa, 0x85, 0x1e, 0x50, 0xf3, 0x21, 0xf6, 0xbf } };
                    nvb_enc_caps_param cp;
                    memset(&cp, 0, sizeof(cp));
                    cp.version = NVB_ENC_STRUCT_VER(1);
                    cp.capsToQuery = NVB_ENC_CAPS_NUM_ENCODER_ENGINES;
                    int val = 0;
                    if (fl.getEncodeCaps(enc, h264, &cp, &val) == 0 && val > 0)
                        *engines = val;
                }
                fl.destroyEncoder(enc);
            } else if (st == 1 || st == 2) {
                // NO_ENCODE_DEVICE / UNSUPPORTED_DEVICE — device-absence codes;
                // INVALID_ENCODERDEVICE (3) is a handle error, kept as unknown
                rc = 0;
            }
        }
    }
    if (cuda_lib) dlclose(cuda_lib);
    dlclose(lib);
    return rc;
}

// CUVIDDECODECAPS mirror; older drivers simply leave the newer OUT fields zero
typedef struct {
    int eCodecType;               // cudaVideoCodec_H264 = 4
    int eChromaFormat;            // cudaVideoChromaFormat_420 = 1
    unsigned int nBitDepthMinus8;
    unsigned int reserved1[3];
    unsigned char bIsSupported;
    unsigned char nNumNVDECs;
    unsigned short nOutputFormatMask;
    unsigned int nMaxWidth, nMaxHeight, nMaxMBCount;
    unsigned short nMinWidth, nMinHeight;
    unsigned char bIsHistogramSupported, nCounterBitDepth;
    unsigned short nMaxHistogramBins;
    unsigned char bIsDecodeStatsSupported, reserved4[3];
    unsigned int reserved3[9];
} nvb_dec_caps;

static int probe_nvdec(int *engines) {
    *engines = -1;
    void *lib = dlopen("libnvcuvid.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) return -1;
    typedef int (*caps_fn)(nvb_dec_caps *);
    caps_fn get_caps = (caps_fn)dlsym(lib, "cuvidGetDecoderCaps");
    int rc = -1;
    if (get_caps) {
        // Try H264 first, and double-check with HEVC before declaring absence
        static const int codecs[2] = { 4, 8 };
        for (int c = 0; c < 2 && rc <= 0; c++) {
            nvb_dec_caps caps;
            memset(&caps, 0, sizeof(caps));
            caps.eCodecType = codecs[c];
            caps.eChromaFormat = 1;
            if (get_caps(&caps) != 0) break;
            if (caps.nNumNVDECs > 0) { rc = 1; *engines = caps.nNumNVDECs; }
            else rc = caps.bIsSupported ? 1 : 0;
        }
    }
    dlclose(lib);
    return rc;
}

static const char *pci_ids_paths[] = {
    "/usr/share/hwdata/pci.ids",
    "/usr/share/misc/pci.ids",
    "/usr/local/share/pci.ids",
    NULL
};

// Lookup device name from pci.ids database (e.g. "GA100 [CMP 170HX]")
static bool lookup_pci_device_name(unsigned int dev_id, char *out, size_t out_sz) {
    FILE *f = NULL;
    for (int i = 0; pci_ids_paths[i]; i++) {
        f = fopen(pci_ids_paths[i], "r");
        if (f) break;
    }
    if (!f) return false;

    char line[512];
    bool in_nvidia = false;
    char target[8];
    snprintf(target, sizeof(target), "\t%04x", dev_id);

    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (!in_nvidia) {
            if (strncmp(line, "10de", 4) == 0) in_nvidia = true;
            continue;
        }
        if (line[0] != '\t') break;
        if (line[0] == '\t' && line[1] == '\t') continue;
        if (strncasecmp(line, target, 5) == 0) {
            char *name = line + 5;
            while (*name == ' ') name++;
            size_t len = strlen(name);
            while (len > 0 && (name[len-1] == '\n' || name[len-1] == '\r')) len--;
            if (len >= out_sz) len = out_sz - 1;
            memcpy(out, name, len);
            out[len] = '\0';
            fclose(f);
            return true;
        }
    }
    fclose(f);
    return false;
}

// Timed iteration count: explicit user value, or sized from a calibration
// sample so the run lasts ~kTargetMs.
static const double kTargetMs = 1000.0;
static int auto_iters(int user_iters, double per_iter_ms) {
    if (user_iters > 0) return user_iters;
    if (per_iter_ms <= 0.0) return 5;
    double it = kTargetMs / per_iter_ms;
    if (it < 1.0) it = 1.0;
    if (it > 100000000.0) it = 100000000.0;
    return (int)it;
}

// One compute (tensor / CUDA-core FMA) iteration is ~1000x cheaper than one
// 512 MiB bandwidth sweep, so an explicit user count sized for the bandwidth
// kernels would leave those tests a microsecond timed window dominated by
// launch overhead and event resolution; floor the window at ~100 ms regardless.
static int compute_iters(int user_iters, double per_iter_ms) {
    int it = auto_iters(user_iters, per_iter_ms);
    if (per_iter_ms > 0.0 && (double)it * per_iter_ms < 100.0) {
        double min_it = 100.0 / per_iter_ms;
        it = min_it > 100000000.0 ? 100000000 : (int)min_it;
    }
    return it;
}

void print_bar() {
    OUT("─────────────────────────────────────────────────────────────────────────────\n");
}

// Runs one benchmark end to end: warm-up, calibration sample, then a timed run
// sized to ~kTargetMs (or to the user's explicit count). launch(n) must enqueue
// exactly n iterations of the work. Returns the timed run's duration in seconds
// and stores the iteration count it used. short_work floors the timed window at
// 100 ms, for kernels whose single iteration is far below event resolution.
template <typename LaunchFn>
static double run_timed(LaunchFn launch, int sample_iters, int user_iters, bool short_work,
                        cudaEvent_t start, cudaEvent_t stop, int *out_iters) {
    float ms = 0.0f;
    launch(sample_iters);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());
    CHECK_CUDA(cudaEventRecord(start));
    launch(sample_iters);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaEventRecord(stop));
    CHECK_CUDA(cudaEventSynchronize(stop));
    CHECK_CUDA(cudaEventElapsedTime(&ms, start, stop));
    double per_iter_ms = (double)ms / sample_iters;
    int n = short_work ? compute_iters(user_iters, per_iter_ms) : auto_iters(user_iters, per_iter_ms);
    CHECK_CUDA(cudaEventRecord(start));
    launch(n);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaEventRecord(stop));
    CHECK_CUDA(cudaEventSynchronize(stop));
    CHECK_CUDA(cudaEventElapsedTime(&ms, start, stop));
    *out_iters = n;
    return (double)ms / 1000.0;
}

// ─── CSV assembly (--csv) ───
static char g_csv_buf[4096];
static size_t g_csv_len = 0;

// Appends one comma-separated field; a NULL format emits an empty field
static void csv_field(const char *fmt, ...) {
    if (g_csv_len > 0 && g_csv_len < sizeof(g_csv_buf) - 1) g_csv_buf[g_csv_len++] = ',';
    g_csv_buf[g_csv_len] = '\0';
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(g_csv_buf + g_csv_len, sizeof(g_csv_buf) - g_csv_len, fmt, ap);
    va_end(ap);
    if (n > 0) {
        g_csv_len += (size_t)n;
        if (g_csv_len >= sizeof(g_csv_buf)) g_csv_len = sizeof(g_csv_buf) - 1;
    }
}

// Numeric field, left empty when the value was not measured (<= 0)
static void csv_num(double v, int prec) {
    if (v > 0.0) csv_field("%.*f", prec, v);
    else csv_field(NULL);
}

static void usage(const char *prog) {
    printf("Usage: %s [gpu_id] [iterations] [--csv]\n"
           "  gpu_id       CUDA device index (default 0)\n"
           "  iterations   explicit per-test iteration count; <= 0 (default) auto-sizes\n"
           "               each timed run to ~%.1f s (compute tests keep a 100 ms floor)\n"
           "  --csv        one CSV header line + one data line instead of the report\n"
           "  -h, --help   this text\n", prog, kTargetMs / 1000.0);
}

int main(int argc, char **argv) {
    size_t size_mb = 512;
    int device = 0;
    int iters = 0;  // <= 0: auto-size each timed run to ~kTargetMs

    int positional = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--csv") == 0) { g_csv = true; continue; }
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) { usage(argv[0]); return 0; }
        char *end = NULL;
        long v = strtol(a, &end, 10);
        if (*a == '\0' || *end != '\0') {
            fprintf(stderr, a[0] == '-' ? "Error: unknown option '%s'\n\n" : "Error: '%s' is not an integer\n\n", a);
            usage(argv[0]);
            return 1;
        }
        if (v > INT_MAX) v = INT_MAX;
        if (v < INT_MIN) v = INT_MIN;
        if (positional == 0) device = (int)v;
        else if (positional == 1) iters = (int)v;
        else {
            fprintf(stderr, "Error: too many arguments\n\n");
            usage(argv[0]);
            return 1;
        }
        positional++;
    }

    int dev_count = 0;
    CHECK_CUDA(cudaGetDeviceCount(&dev_count));
    if (device < 0 || device >= dev_count) {
        fprintf(stderr, "Error: GPU %d not found (%d GPU(s) available)\n", device, dev_count);
        return 1;
    }
    cudaDeviceProp prop;
    CHECK_CUDA(cudaGetDeviceProperties(&prop, device));
    // The primary context itself needs a few hundred MiB; say so plainly rather
    // than reporting a bare "out of memory" from the first allocation
    cudaError_t set_err = cudaSetDevice(device);
    if (set_err == cudaErrorMemoryAllocation || set_err == cudaErrorDevicesUnavailable) {
        fprintf(stderr, "Error: cannot create a CUDA context on GPU %d (%s)\n"
                        "  The GPU is busy or nearly out of memory — another process is probably using it.\n",
                device, cudaGetErrorString(set_err));
        return 1;
    }
    CHECK_CUDA(set_err);

    int l2_bytes = 0;
    if (cudaDeviceGetAttribute(&l2_bytes, cudaDevAttrL2CacheSize, device) != cudaSuccess) l2_bytes = 0;

    // INT8 tensor-core probe, done before any real allocations: TU116/TU117
    // report CC 7.5 but have no tensor cores — the s8 IMMA path faults and no
    // device property distinguishes them. A fault kills the context, so probe
    // while there is nothing to lose and recover with cudaDeviceReset(). The
    // result gates the INT8 test and feeds the Features report. Below sm_72
    // the kernel body is compiled out and a launch would succeed vacuously,
    // so gate on the arch first.
    bool int8_hw = false;
    if (prop.major > 7 || (prop.major == 7 && prop.minor >= 2)) {
        int *d_probe = NULL;
        if (cudaMalloc(&d_probe, sizeof(int)) == cudaSuccess) {
            bench_tensor_int8<<<1, 32>>>(d_probe, 1);
            int8_hw = cudaGetLastError() == cudaSuccess && cudaDeviceSynchronize() == cudaSuccess;
            if (int8_hw) {
                CHECK_CUDA(cudaFree(d_probe));
            } else {
                cudaGetLastError();   // clear the sticky fault
                cudaDeviceReset();    // recover the context; d_probe dies with it
                CHECK_CUDA(cudaSetDevice(device));
            }
        }
    }

    // NVML is best-effort (identification and clock info only): resolve the handle
    // by PCI bus id — NVML indices are PCI-ordered and ignore CUDA_VISIBLE_DEVICES,
    // so reusing the CUDA ordinal can address a different physical GPU.
    bool nvml_inited = (nvmlInit() == NVML_SUCCESS);
    bool nvml_ok = nvml_inited;
    nvmlDevice_t nvml_dev = NULL;
    if (nvml_ok) {
        char pci_bus[32];
        nvml_ok = cudaDeviceGetPCIBusId(pci_bus, sizeof(pci_bus), device) == cudaSuccess
               && nvmlDeviceGetHandleByPciBusId_v2(pci_bus, &nvml_dev) == NVML_SUCCESS;
    }

    unsigned int nvml_cur_mhz = 0, nvml_max_mhz = 0;
    if (nvml_ok) {
        if (nvmlDeviceGetClockInfo(nvml_dev, NVML_CLOCK_MEM, &nvml_cur_mhz) != NVML_SUCCESS) nvml_cur_mhz = 0;
        if (nvmlDeviceGetMaxClockInfo(nvml_dev, NVML_CLOCK_MEM, &nvml_max_mhz) != NVML_SUCCESS) nvml_max_mhz = 0;
    }
    int cuda_max_khz = 0;
    if (cudaDeviceGetAttribute(&cuda_max_khz, cudaDevAttrMemoryClockRate, device) != cudaSuccess) cuda_max_khz = 0;
    unsigned int mem_rated_mhz = nvml_max_mhz;
    if ((unsigned int)(cuda_max_khz / 1000) > mem_rated_mhz) mem_rated_mhz = (unsigned int)(cuda_max_khz / 1000);

    unsigned int dev_id = 0;
    char pci_name[256] = {0};
    bool has_pci_name = false;
    if (nvml_ok) {
        nvmlPciInfo_t pci;
        if (nvmlDeviceGetPciInfo(nvml_dev, &pci) == NVML_SUCCESS) {
            dev_id = (pci.pciDeviceId >> 16) & 0xFFFF;
            has_pci_name = lookup_pci_device_name(dev_id, pci_name, sizeof(pci_name));
        }
    }

    // MIG state feeds both the header and the feature report. Under MIG the
    // NVML handle (physical die) and the CUDA device (slice) describe
    // different things, so die-wide counters must not be mixed with slice SMs.
    int mig_state = -1;  // -1 unknown, 0 unsupported, 1 supported/off, 2 enabled
#ifdef NVML_DEVICE_MIG_ENABLE
    if (nvml_ok) {
        unsigned int mig_cur = 0, mig_pend = 0;
        nvmlReturn_t mr = nvmlDeviceGetMigMode(nvml_dev, &mig_cur, &mig_pend);
        if (mr == NVML_SUCCESS) mig_state = (mig_cur == NVML_DEVICE_MIG_ENABLE) ? 2 : 1;
        else if (mr == NVML_ERROR_NOT_SUPPORTED) mig_state = 0;
    }
#endif

    // Measured SM boost clock — taken here so the header can report it. Runs on
    // an idle GPU, so a shorter ramp-up launch precedes the measured one to let
    // the boost governor settle. Everything is timed on-device (clock64 cycles
    // over %globaltimer ns), so no CUDA events are needed yet. The same window
    // doubles as the memory-clock sample: read at idle the memory clock can sit
    // in a low power state, and substituting the rated maximum (as this used to
    // do) would mask a deliberate underclock.
    double sm_meas_mhz = 0.0;
    unsigned int sm_rated_mhz = 0, mem_load_mhz = 0;
    if (nvml_ok && nvmlDeviceGetMaxClockInfo(nvml_dev, NVML_CLOCK_SM, &sm_rated_mhz) != NVML_SUCCESS)
        sm_rated_mhz = 0;
    unsigned long long *d_clk = NULL;
    if (cudaMalloc(&d_clk, 2 * CLK_SEGMENTS * sizeof(unsigned long long)) == cudaSuccess) {
        for (int pass = 0; pass < 2; pass++) {
            bench_clock<<<1, 1>>>(d_clk, d_clk + CLK_SEGMENTS, pass == 0 ? 10 : 25);
            CHECK_CUDA(cudaGetLastError());
            while (cudaStreamQuery(0) == cudaErrorNotReady) {
                unsigned int c = 0;
                if (nvml_ok && nvmlDeviceGetClockInfo(nvml_dev, NVML_CLOCK_MEM, &c) == NVML_SUCCESS && c > mem_load_mhz)
                    mem_load_mhz = c;
                usleep(5000);
            }
            cudaGetLastError();   // discard the cudaErrorNotReady left by polling
            CHECK_CUDA(cudaDeviceSynchronize());
        }
        unsigned long long h_clk[2 * CLK_SEGMENTS];
        CHECK_CUDA(cudaMemcpy(h_clk, d_clk, sizeof(h_clk), cudaMemcpyDeviceToHost));
        CHECK_CUDA(cudaFree(d_clk));
        // Max over segments, discarding implausible ones: a segment interrupted
        // by compute preemption (display GPUs) can resume with a discontinuous
        // cycle counter, and max-of-segments would else select that outlier
        for (int s = 0; s < CLK_SEGMENTS; s++) {
            if (h_clk[CLK_SEGMENTS + s] == 0) continue;
            double mhz = (double)h_clk[s] * 1000.0 / (double)h_clk[CLK_SEGMENTS + s];
            if (mhz > 5000.0) continue;
            if (sm_rated_mhz > 0 && mhz > 1.25 * sm_rated_mhz) continue;
            if (mhz > sm_meas_mhz) sm_meas_mhz = mhz;
        }
    }
    unsigned int mem_clock_mhz = mem_load_mhz;      // operating clock, sampled under load
    bool mem_under_load = mem_clock_mhz > 0;
    if (!mem_under_load)                            // no NVML: fall back to the rated figure
        mem_clock_mhz = nvml_cur_mhz > mem_rated_mhz ? nvml_cur_mhz : mem_rated_mhz;

    // Size the test arrays to what is actually free: three of them plus the
    // pinned staging block and the latency chain have to coexist
    size_t free_b = 0, total_b = 0;
    CHECK_CUDA(cudaMemGetInfo(&free_b, &total_b));
    size_t max_per_array = free_b / 2 / 3;          // leave half the card for everything else
    if (size_mb * 1024 * 1024 > max_per_array) {
        size_t new_mb = (max_per_array >> 20) & ~(size_t)15;   // round down to 16 MiB
        if (new_mb < 16) {
            fprintf(stderr, "Error: only %.0f MiB free on GPU %d, need at least ~300 MiB\n",
                    free_b / 1048576.0, device);
            return 1;
        }
        fprintf(stderr, "Note: test buffers reduced to %zu MiB each (%.0f MiB free on GPU %d)\n",
                new_mb, free_b / 1048576.0, device);
        size_mb = new_mb;
    }

    unsigned int gpu_cores = 0;
#ifdef HAVE_NUM_GPU_CORES
    // Skipped under MIG: the NVML count covers the whole die, not the slice
    if (nvml_ok && mig_state != 2 && nvmlDeviceGetNumGpuCores != NULL) {
        if (nvmlDeviceGetNumGpuCores(nvml_dev, &gpu_cores) != NVML_SUCCESS) gpu_cores = 0;
    }
#endif

    print_bar();
    OUT("  NVIDIA Performance And Memory Benchmark\n");
    print_bar();
    if (has_pci_name)
        OUT("  GPU:               %s [%04X] (%s)\n", prop.name, dev_id, pci_name);
    else if (dev_id)
        OUT("  GPU:               %s [%04X]\n", prop.name, dev_id);
    else
        OUT("  GPU:               %s\n", prop.name);
    OUT("  SMs:               %d\n", prop.multiProcessorCount);
    if (gpu_cores > 0) {
        if (gpu_cores % (unsigned int)prop.multiProcessorCount == 0)
            OUT("  CUDA Cores:        %u (%u per SM)\n", gpu_cores, gpu_cores / (unsigned int)prop.multiProcessorCount);
        else
            OUT("  CUDA Cores:        %u\n", gpu_cores);
    }
    OUT("  Memory Bus Width:  %d-bit\n", prop.memoryBusWidth);
    if (l2_bytes > 0)
        OUT("  L2 Cache:          %.0f MiB\n", l2_bytes / 1048576.0);
    if (sm_meas_mhz > 0.0) {
        if (sm_rated_mhz > 0)
            OUT("  SM Clock:          %.0f MHz (measured, max %u MHz)\n", sm_meas_mhz, sm_rated_mhz);
        else
            OUT("  SM Clock:          %.0f MHz (measured)\n", sm_meas_mhz);
    }
    double theo_bw = 0.0;
    if (mem_clock_mhz > 0) {
        if (mem_under_load && mem_rated_mhz > 0 && mem_rated_mhz != mem_clock_mhz)
            OUT("  Memory Clock:      %u MHz (under load, rated %u MHz)\n", mem_clock_mhz, mem_rated_mhz);
        else if (mem_under_load)
            OUT("  Memory Clock:      %u MHz (under load)\n", mem_clock_mhz);
        else
            OUT("  Memory Clock:      %u MHz (rated)\n", mem_clock_mhz);
        theo_bw = (double)mem_clock_mhz * 2 * prop.memoryBusWidth / 8 / 1000;
        OUT("  Theoretical BW:    %.2f GB/s\n", theo_bw);
    } else {
        OUT("  Memory Clock:      unknown\n");
    }
    // Under MIG the CUDA device is a slice, so report the slice's memory rather
    // than the die-wide NVML figure that would contradict the SM count above
    unsigned long long total_mem = (unsigned long long)prop.totalGlobalMem;
    if (nvml_ok && mig_state != 2) {
        nvmlMemory_t mem_info;
        memset(&mem_info, 0, sizeof(mem_info));
        if (nvmlDeviceGetMemoryInfo(nvml_dev, &mem_info) == NVML_SUCCESS && mem_info.total > 0)
            total_mem = mem_info.total;
    }
    OUT("  Total Memory:      %.2f GiB (%llu MiB)%s\n", total_mem / (1024.0 * 1024.0 * 1024.0),
        total_mem / (1024 * 1024), mig_state == 2 ? "  [MIG slice]" : "");
    OUT("  Test Buffer Size:  %zu MiB per array\n", size_mb);
    if (iters > 0)
        OUT("  Kernel Iterations: %d\n", iters);
    else
        OUT("  Kernel Iterations: auto (~%.1f s per test)\n", kTargetMs / 1000.0);
    print_bar();

    size_t total_bytes = size_mb * 1024 * 1024;
    size_t N_vec = total_bytes / sizeof(float4);
    total_bytes = N_vec * sizeof(float4); // Align to exact multiple of sizeof(float4)

    // Configure grid geometry to maximize HBM memory controller utilization
    int threads = 256;
    int blocks = prop.multiProcessorCount * 16;
    if ((size_t)blocks * threads > N_vec) blocks = (int)((N_vec + threads - 1) / threads);

    // Device memory allocation
    float4 *d_A, *d_B, *d_C;
    float *d_dummy;
    CHECK_CUDA(cudaMalloc(&d_A, total_bytes));
    CHECK_CUDA(cudaMalloc(&d_B, total_bytes));
    CHECK_CUDA(cudaMalloc(&d_C, total_bytes));
    CHECK_CUDA(cudaMalloc(&d_dummy, 16));  // 16 B so double/half2 sinks fit too

    // Initialize buffers
    CHECK_CUDA(cudaMemset(d_A, 0x3F, total_bytes));
    CHECK_CUDA(cudaMemset(d_B, 0x40, total_bytes));
    CHECK_CUDA(cudaDeviceSynchronize());

    cudaEvent_t start, stop;
    CHECK_CUDA(cudaEventCreate(&start));
    CHECK_CUDA(cudaEventCreate(&stop));
    int n = 0;
    double secs = 0.0;

    // ─── PCIe ───
    // Pinned-memory transfers on the copy engines
    size_t pcie_bytes = 256ull * 1024 * 1024;
    if (pcie_bytes > total_bytes) pcie_bytes = total_bytes;
    void *h_pinned = NULL;
    if (cudaMallocHost(&h_pinned, pcie_bytes) != cudaSuccess) {
        cudaGetLastError();
        pcie_bytes = 64ull * 1024 * 1024;
        CHECK_CUDA(cudaMallocHost(&h_pinned, pcie_bytes));
    }
    memset(h_pinned, 0x3F, pcie_bytes);

    unsigned int link_gen = 0, link_width = 0;

    // The link state is sampled from inside the timed run: ASPM parks an idle
    // link at Gen1, so an idle-time readout can be misleading
    secs = run_timed([&](int it) {
        for (int i = 0; i < it; i++)
            CHECK_CUDA(cudaMemcpyAsync(d_A, h_pinned, pcie_bytes, cudaMemcpyHostToDevice, 0));
        if (nvml_ok && it > 2) {
            nvmlDeviceGetCurrPcieLinkGeneration(nvml_dev, &link_gen);
            nvmlDeviceGetCurrPcieLinkWidth(nvml_dev, &link_width);
        }
    }, 1, 0, false, start, stop, &n);
    double h2d_gbs = (double)pcie_bytes * n / 1e9 / secs;
    OUT("  PCIe H2D Bandwidth:     %8.2f GB/s   (pinned, %zu MiB blocks)\n", h2d_gbs, pcie_bytes >> 20);
    fflush(stdout);

    secs = run_timed([&](int it) {
        for (int i = 0; i < it; i++)
            CHECK_CUDA(cudaMemcpyAsync(h_pinned, d_A, pcie_bytes, cudaMemcpyDeviceToHost, 0));
    }, 1, 0, false, start, stop, &n);
    double d2h_gbs = (double)pcie_bytes * n / 1e9 / secs;
    OUT("  PCIe D2H Bandwidth:     %8.2f GB/s\n", d2h_gbs);
    CHECK_CUDA(cudaFreeHost(h_pinned));

    {
        // Effective per-lane GB/s after encoding. Gen1-5 lose ~12% more to
        // framing tokens/TLP headers; Gen6 FLIT mode has no framing tokens
        // (~6% headers only). When NVML reports the trained link, validate the
        // measured bandwidth against it; otherwise guess the config from
        // bandwidth alone (equal-product configs like Gen4 x8 == Gen5 x4 are
        // inherently ambiguous — ties resolve to the lowest generation).
        static const double lane_gbs[7] = { 0.0, 0.25, 0.5, 0.985, 1.969, 3.938, 7.375 };
        static const double gen_eff[7] = { 0.0, 0.88, 0.88, 0.88, 0.88, 0.88, 0.94 };
        double pcie_meas = h2d_gbs > d2h_gbs ? h2d_gbs : d2h_gbs;
        if (link_gen > 0 && link_width > 0) {
            OUT("  PCIe Link (NVML):       Gen%u x%u\n", link_gen, link_width);
            if (link_gen <= 6) {
                double expected = lane_gbs[link_gen] * link_width * gen_eff[link_gen];
                if (pcie_meas > expected * 1.3)
                    OUT("  PCIe BW vs link:        %.1fx the Gen%u x%u ceiling — non-PCIe path (NVLink-C2C?)\n",
                        pcie_meas / expected, link_gen, link_width);
                else
                    OUT("  PCIe BW vs link:        %.0f%% of ~%.2f GB/s expected for Gen%u x%u\n",
                        pcie_meas / expected * 100.0, expected, link_gen, link_width);
            }
        } else {
            static const int widths[5] = { 1, 2, 4, 8, 16 };
            int bg = 1, bw = 1;
            double berr = 1e30;
            for (int g = 1; g <= 6; g++)
                for (int w = 0; w < 5; w++) {
                    double eff = lane_gbs[g] * widths[w] * gen_eff[g];
                    double err = eff > pcie_meas ? eff - pcie_meas : pcie_meas - eff;
                    if (err < berr) { berr = err; bg = g; bw = widths[w]; }
                }
            if (pcie_meas > lane_gbs[6] * 16 * gen_eff[6] * 1.3)
                OUT("  PCIe BW suggests:       beyond Gen6 x16 — non-PCIe interconnect (NVLink-C2C?)\n");
            else
                OUT("  PCIe BW suggests:       ~Gen%d x%d (%.2f GB/s effective)\n",
                    bg, bw, lane_gbs[bg] * bw * gen_eff[bg]);
        }
    }
    print_bar();

    // ─── Features ───
    char enc_s[24] = "unknown", dec_s[24] = "unknown", mig_s[24] = "unknown",
         ecc_s[24] = "unknown", nvl_s[24] = "unknown", disp_s[24] = "unknown",
         plim_s[24] = "unknown", bar1_s[24] = "unknown";
    // NVENC/NVDEC ground truth (presence + engine count) via the driver's own
    // video libraries; NVML's device-table claims are only a fallback
    int enc_engines = -1, dec_engines = -1;
    int enc_probe = probe_nvenc(&enc_engines);
    int dec_probe = probe_nvdec(&dec_engines);
    if (enc_probe == 1) {
        if (enc_engines > 0)
            snprintf(enc_s, sizeof(enc_s), "yes (%d engine%s)", enc_engines, enc_engines == 1 ? "" : "s");
        else
            snprintf(enc_s, sizeof(enc_s), "yes");
    } else if (enc_probe == 0) {
        snprintf(enc_s, sizeof(enc_s), "no");
    }
    if (dec_probe == 1) {
        if (dec_engines > 0)
            snprintf(dec_s, sizeof(dec_s), "yes (%d engine%s)", dec_engines, dec_engines == 1 ? "" : "s");
        else
            snprintf(dec_s, sizeof(dec_s), "yes");
    } else if (dec_probe == 0) {
        snprintf(dec_s, sizeof(dec_s), "no");
    }
    if (nvml_ok) {
        // NOT_SUPPORTED means the feature is absent; any other error means we
        // could not tell and the label stays "unknown". Under MIG the codec
        // utilization/capacity queries are disabled regardless of the engines,
        // so NOT_SUPPORTED proves nothing there.
        nvmlReturn_t r;
        unsigned int v = 0, v2 = 0;
        if (enc_probe < 0) {
            r = nvmlDeviceGetEncoderCapacity(nvml_dev, NVML_ENCODER_QUERY_H264, &v);
            if (r == NVML_SUCCESS)
                snprintf(enc_s, sizeof(enc_s), "%s", v > 0 ? "yes" : "no");
            else if (r == NVML_ERROR_NOT_SUPPORTED && mig_state != 2)
                snprintf(enc_s, sizeof(enc_s), "no");
        }
        if (dec_probe < 0) {
            r = nvmlDeviceGetDecoderUtilization(nvml_dev, &v, &v2);
            if (r == NVML_SUCCESS)
                snprintf(dec_s, sizeof(dec_s), "yes");
            else if (r == NVML_ERROR_NOT_SUPPORTED && mig_state != 2)
                snprintf(dec_s, sizeof(dec_s), "no");
        }
        if (mig_state == 2) snprintf(mig_s, sizeof(mig_s), "enabled");
        else if (mig_state == 1) snprintf(mig_s, sizeof(mig_s), "supported, off");
        else if (mig_state == 0) snprintf(mig_s, sizeof(mig_s), "no");
        nvmlEnableState_t cur, pend;
        r = nvmlDeviceGetEccMode(nvml_dev, &cur, &pend);
        if (r == NVML_SUCCESS)
            snprintf(ecc_s, sizeof(ecc_s), "%s", cur == NVML_FEATURE_ENABLED ? "enabled" : "disabled");
        else if (r == NVML_ERROR_NOT_SUPPORTED)
            snprintf(ecc_s, sizeof(ecc_s), "no");
        int nvlinks = 0;
        for (unsigned int l = 0; l < NVML_NVLINK_MAX_LINKS; l++) {
            nvmlEnableState_t st;
            if (nvmlDeviceGetNvLinkState(nvml_dev, l, &st) == NVML_SUCCESS && st == NVML_FEATURE_ENABLED)
                nvlinks++;
        }
        if (nvlinks > 0)
            snprintf(nvl_s, sizeof(nvl_s), "yes (%d links)", nvlinks);
        else
            snprintf(nvl_s, sizeof(nvl_s), "no");
        if (nvmlDeviceGetDisplayActive(nvml_dev, &cur) == NVML_SUCCESS)
            snprintf(disp_s, sizeof(disp_s), "%s", cur == NVML_FEATURE_ENABLED ? "yes" : "no");
        unsigned int mw = 0;
        if (nvmlDeviceGetPowerManagementLimit(nvml_dev, &mw) == NVML_SUCCESS)
            snprintf(plim_s, sizeof(plim_s), "%u W", mw / 1000);
        nvmlBAR1Memory_t bar1;
        memset(&bar1, 0, sizeof(bar1));
        if (nvmlDeviceGetBAR1MemoryInfo(nvml_dev, &bar1) == NVML_SUCCESS) {
            if (bar1.bar1Total >= 1024ull * 1024 * 1024)
                snprintf(bar1_s, sizeof(bar1_s), "%.1f GiB", bar1.bar1Total / (1024.0 * 1024.0 * 1024.0));
            else
                snprintf(bar1_s, sizeof(bar1_s), "%.0f MiB", bar1.bar1Total / (1024.0 * 1024.0));
        }
    }
    OUT("  Features:\n");
    // CC 8.0+ always has tensor cores; CC 7.0/7.2 (Volta/Xavier) always does;
    // CC 7.5 splits into TU10x (yes) vs TU116/117 (no), decided by the startup
    // INT8 probe; below CC 7.0 there are none.
    OUT("    Tensor Cores:     %-14s NVENC:            %s\n",
        (prop.major >= 8 || (prop.major == 7 && (prop.minor < 5 || int8_hw))) ? "yes" : "no", enc_s);
    OUT("    ECC:              %-14s NVDEC:            %s\n", ecc_s, dec_s);
    OUT("    MIG:              %-14s NVLink:           %s\n", mig_s, nvl_s);
    OUT("    Copy Engines:     %-14d Managed Memory:   %s\n",
        prop.asyncEngineCount, prop.managedMemory ? "yes" : "no");
    OUT("    Coop Launch:      %-14s Compute Preempt:  %s\n",
        prop.cooperativeLaunch ? "yes" : "no", prop.computePreemptionSupported ? "yes" : "no");
    OUT("    Display Active:   %-14s Power Limit:      %s\n", disp_s, plim_s);
    OUT("    BAR1 Size:        %s\n", bar1_s);
    print_bar();

    // ─── Memory Latency (Pointer Chasing) ───
    // One chain slot per 128-byte cache line, chain sized >= 16x L2 (min 512 MiB):
    // a random walk over a footprint comparable to L2 partially hits cache and
    // reads low (e.g. a 128 MiB chain under-reports ~5% at 32 MiB L2, up to ~2x
    // on 96+ MiB L2 parts).
    size_t chain_bytes = (size_t)l2_bytes * 16;
    if (chain_bytes < 512ull * 1024 * 1024) chain_bytes = 512ull * 1024 * 1024;
    CHECK_CUDA(cudaMemGetInfo(&free_b, &total_b));
    while (chain_bytes > free_b / 2 && chain_bytes > 64ull * 1024 * 1024) chain_bytes /= 2;
    if ((size_t)l2_bytes * 8 > chain_bytes)
        fprintf(stderr, "Note: latency chain limited to %zu MiB (< 8x L2), latency may read low\n",
                chain_bytes >> 20);

    size_t n_slots = chain_bytes / 128;

    uint32_t *h_perm = (uint32_t *)malloc(n_slots * sizeof(uint32_t));
    if (!h_perm) { fprintf(stderr, "Error: host allocation of %zu MiB failed\n", (n_slots * sizeof(uint32_t)) >> 20); return 1; }
    for (size_t i = 0; i < n_slots; i++) h_perm[i] = (uint32_t)i;
    // Sattolo shuffle — single cycle visiting all slots
    for (size_t i = n_slots - 1; i > 0; i--) {
        size_t j = (size_t)rand() % i;
        uint32_t tmp = h_perm[i]; h_perm[i] = h_perm[j]; h_perm[j] = tmp;
    }

    uint32_t *d_perm, *d_chain, *d_out;
    CHECK_CUDA(cudaMalloc(&d_perm, n_slots * sizeof(uint32_t)));
    CHECK_CUDA(cudaMalloc(&d_chain, chain_bytes));
    CHECK_CUDA(cudaMalloc(&d_out, sizeof(uint32_t)));
    CHECK_CUDA(cudaMemcpy(d_perm, h_perm, n_slots * sizeof(uint32_t), cudaMemcpyHostToDevice));
    free(h_perm);
    build_chain<<<blocks, threads>>>(d_perm, d_chain, n_slots);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());
    CHECK_CUDA(cudaFree(d_perm));

    // Hand-rolled rather than run_timed: the walk needs an L2 flush between the
    // calibration pass and the measured one, and it scales steps, not iterations
    float time_ms = 0.0f, sample_ms = 0.0f;
    CHECK_CUDA(cudaEventRecord(start));
    bench_hbm_latency<<<1, 1>>>(d_chain, d_out, 1000000);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaEventRecord(stop));
    CHECK_CUDA(cudaEventSynchronize(stop));
    CHECK_CUDA(cudaEventElapsedTime(&sample_ms, start, stop));
    int lat_steps = 1000000;
    if (iters <= 0) {
        double s = kTargetMs / ((double)sample_ms / 1000000.0);
        if (s < 1000000.0) s = 1000000.0;
        if (s > 50000000.0) s = 50000000.0;
        lat_steps = (int)s;
    }
    // The warmup walked the same path the timed run will take; stream the test
    // buffer through L2 to evict that footprint (keeps clocks/TLB warm only)
    CHECK_CUDA(cudaMemset(d_A, 0x3F, total_bytes));
    CHECK_CUDA(cudaDeviceSynchronize());
    CHECK_CUDA(cudaEventRecord(start));
    bench_hbm_latency<<<1, 1>>>(d_chain, d_out, lat_steps);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaEventRecord(stop));
    CHECK_CUDA(cudaEventSynchronize(stop));
    CHECK_CUDA(cudaEventElapsedTime(&time_ms, start, stop));
    double latency_ns = (double)time_ms * 1e6 / lat_steps;
    OUT("  Memory Latency:         %6.1f ns   (chain %zu MiB, 128 B stride)\n", latency_ns, chain_bytes >> 20);
    fflush(stdout);

    CHECK_CUDA(cudaFree(d_chain));
    CHECK_CUDA(cudaFree(d_out));

    // ─── Memory Bandwidth ───
    secs = run_timed([&](int it) { bench_hbm_read<<<blocks, threads>>>(d_A, d_dummy, N_vec, it); },
                     5, iters, false, start, stop, &n);
    double read_gbs = (double)total_bytes * n / 1e9 / secs;
    OUT("  Global Read Bandwidth:  %8.2f GB/s\n", read_gbs);
    fflush(stdout);

    float4 val = make_float4(1.0f, 2.0f, 3.0f, 4.0f);
    secs = run_timed([&](int it) { bench_hbm_write<<<blocks, threads>>>(d_A, val, N_vec, it); },
                     5, iters, false, start, stop, &n);
    double write_gbs = (double)total_bytes * n / 1e9 / secs;
    OUT("  Global Write Bandwidth: %8.2f GB/s\n", write_gbs);
    fflush(stdout);

    secs = run_timed([&](int it) { bench_hbm_copy<<<blocks, threads>>>(d_A, d_B, N_vec, it); },
                     5, iters, false, start, stop, &n);
    double copy_gbs = (double)total_bytes * 2 * n / 1e9 / secs;
    OUT("  Global Copy Bandwidth:  %8.2f GB/s\n", copy_gbs);
    fflush(stdout);

    secs = run_timed([&](int it) { bench_hbm_triad<<<blocks, threads>>>(d_A, d_B, d_C, 2.5f, N_vec, it); },
                     5, iters, false, start, stop, &n);
    double triad_gbs = (double)total_bytes * 3 * n / 1e9 / secs;
    OUT("  Global Triad Bandwidth: %8.2f GB/s\n", triad_gbs);
    fflush(stdout);

    // Intra-device cudaMemcpy runs as an SM copy kernel, not on the DMA engines,
    // hence the honest label
    secs = run_timed([&](int it) {
        for (int i = 0; i < it; i++)
            CHECK_CUDA(cudaMemcpyAsync(d_B, d_A, total_bytes, cudaMemcpyDeviceToDevice, 0));
    }, 1, 0, false, start, stop, &n);
    double d2d_gbs = (double)total_bytes * 2 * n / 1e9 / secs;
    OUT("  cudaMemcpy D2D BW:      %8.2f GB/s\n", d2d_gbs);
    print_bar();

    // ─── CUDA Core Throughput ───
    // 32 warps/SM with 8 in-flight FMA chains each is far past what the FMA
    // pipes need; calibration samples use 10000 iters because a single
    // iteration is far below event resolution
    int cc_blocks = prop.multiProcessorCount * 4;
    int cc_threads = 256;
    double cc_threads_total = (double)cc_blocks * cc_threads;
    const int cc_sample = 10000;

    secs = run_timed([&](int it) { bench_fp64_fma<<<cc_blocks, cc_threads>>>((double *)d_dummy, 0.5, 1.0, it); },
                     cc_sample, iters, true, start, stop, &n);
    double fp64_tflops = cc_threads_total * n * CC_CHAINS * 2.0 / 1e12 / secs;
    OUT("  FP64 (CUDA cores):      %8.2f TFLOPS\n", fp64_tflops);
    fflush(stdout);

    secs = run_timed([&](int it) { bench_fp32_fma<<<cc_blocks, cc_threads>>>(d_dummy, 0.5f, 1.0f, it); },
                     cc_sample, iters, true, start, stop, &n);
    double fp32_tflops = cc_threads_total * n * CC_CHAINS * 2.0 / 1e12 / secs;
    OUT("  FP32 (CUDA cores):      %8.2f TFLOPS\n", fp32_tflops);
    fflush(stdout);

    double fp16_tflops = 0.0;
    if (prop.major > 5 || (prop.major == 5 && prop.minor >= 3)) {
        __half2 hb = __float2half2_rn(0.5f), hc = __float2half2_rn(1.0f);
        secs = run_timed([&](int it) { bench_fp16_fma<<<cc_blocks, cc_threads>>>((__half *)d_dummy, hb, hc, it); },
                         cc_sample, iters, true, start, stop, &n);
        // 4 FLOP per packed half2 FMA (2 lanes x multiply-add)
        fp16_tflops = cc_threads_total * n * CC_CHAINS * 4.0 / 1e12 / secs;
        OUT("  FP16 (CUDA cores):      %8.2f TFLOPS\n", fp16_tflops);
    } else {
        OUT("  FP16 (CUDA cores):           n/a (requires sm_53+)\n");
    }
    fflush(stdout);

    // ─── Tensor Core Throughput ───
    int tc_blocks = prop.multiProcessorCount * 6;
    int tc_threads = 256;
    double tc_warps = (double)tc_blocks * tc_threads / 32.0;
    const int tc_sample = 10000;

    double tf32_tflops = 0.0, bf16_tflops = 0.0, int8_tops = 0.0;
    if (prop.major >= 8) {
        secs = run_timed([&](int it) { bench_tensor_tf32<<<tc_blocks, tc_threads>>>(d_dummy, it); },
                         tc_sample, iters, true, start, stop, &n);
        tf32_tflops = tc_warps * n * TC_ACC * (2.0 * 16 * 16 * 8) / 1e12 / secs;
        OUT("  FP32 Tensor (TF32):     %8.2f TFLOPS\n", tf32_tflops);
    } else {
        OUT("  FP32 Tensor (TF32):          n/a (requires sm_80+)\n");
    }
    fflush(stdout);

    if (prop.major >= 8) {
        secs = run_timed([&](int it) { bench_tensor_bf16<<<tc_blocks, tc_threads>>>(d_dummy, it); },
                         tc_sample, iters, true, start, stop, &n);
        bf16_tflops = tc_warps * n * TC_ACC * (2.0 * 16 * 16 * 16) / 1e12 / secs;
        OUT("  BF16 Tensor:            %8.2f TFLOPS\n", bf16_tflops);
    } else {
        OUT("  BF16 Tensor:                 n/a (requires sm_80+)\n");
    }
    fflush(stdout);

    // INT8 hardware presence was probed at startup (int8_hw)
    if (int8_hw) {
        secs = run_timed([&](int it) { bench_tensor_int8<<<tc_blocks, tc_threads>>>((int *)d_dummy, it); },
                         tc_sample, iters, true, start, stop, &n);
        int8_tops = tc_warps * n * TC_ACC * (2.0 * 16 * 16 * 16) / 1e12 / secs;
        OUT("  INT8 Tensor:            %8.2f TOPS\n", int8_tops);
    } else if (prop.major > 7 || (prop.major == 7 && prop.minor >= 2)) {
        OUT("  INT8 Tensor:                 n/a (no tensor cores)\n");
    } else {
        OUT("  INT8 Tensor:                 n/a (requires sm_72+)\n");
    }
    print_bar();

    if (g_csv) {
        printf("gpu,sms,cuda_cores,bus_bits,l2_mib,sm_clock_mhz,sm_clock_rated_mhz,"
               "mem_clock_mhz,mem_clock_rated_mhz,theo_bw_gbs,total_mem_gib,buffer_mib,"
               "lat_ns,read_gbs,write_gbs,copy_gbs,triad_gbs,d2d_gbs,h2d_gbs,d2h_gbs,"
               "pcie_gen,pcie_width,fp64_tflops,fp32_tflops,fp16_tflops,"
               "tf32_tflops,bf16_tflops,int8_tops,nvenc_engines,nvdec_engines\n");
        csv_field("\"%s\"", has_pci_name ? pci_name : prop.name);
        csv_field("%d", prop.multiProcessorCount);
        csv_num((double)gpu_cores, 0);
        csv_field("%d", prop.memoryBusWidth);
        csv_num(l2_bytes / 1048576.0, 0);
        csv_num(sm_meas_mhz, 0);
        csv_num((double)sm_rated_mhz, 0);
        csv_num((double)mem_clock_mhz, 0);
        csv_num((double)mem_rated_mhz, 0);
        csv_num(theo_bw, 2);
        csv_num(total_mem / (1024.0 * 1024.0 * 1024.0), 2);
        csv_field("%zu", size_mb);
        csv_num(latency_ns, 1);
        csv_num(read_gbs, 2);
        csv_num(write_gbs, 2);
        csv_num(copy_gbs, 2);
        csv_num(triad_gbs, 2);
        csv_num(d2d_gbs, 2);
        csv_num(h2d_gbs, 2);
        csv_num(d2h_gbs, 2);
        csv_num((double)link_gen, 0);
        csv_num((double)link_width, 0);
        csv_num(fp64_tflops, 2);
        csv_num(fp32_tflops, 2);
        csv_num(fp16_tflops, 2);
        csv_num(tf32_tflops, 2);
        csv_num(bf16_tflops, 2);
        csv_num(int8_tops, 2);
        if (enc_probe < 0) csv_field(NULL); else csv_field("%d", enc_probe == 0 ? 0 : (enc_engines > 0 ? enc_engines : 1));
        if (dec_probe < 0) csv_field(NULL); else csv_field("%d", dec_probe == 0 ? 0 : (dec_engines > 0 ? dec_engines : 1));
        printf("%s\n", g_csv_buf);
    }

    // Cleanup
    CHECK_CUDA(cudaFree(d_dummy));
    CHECK_CUDA(cudaFree(d_A));
    CHECK_CUDA(cudaFree(d_B));
    CHECK_CUDA(cudaFree(d_C));
    CHECK_CUDA(cudaEventDestroy(start));
    CHECK_CUDA(cudaEventDestroy(stop));
    if (nvml_inited) nvmlShutdown();

    return 0;
}
