// compute_check - catch SILENT COMPUTE corruption under sustained load.
//
// The full-VRAM pattern sweep proves the DRAM and the path to it are sound. It says nothing about
// the SM pipeline: an undervolt can produce wrong arithmetic while memory stays clean. This runs
// the same deterministic bf16 GEMM over and over and compares every result, bit for bit, against
// the first one. cuBLAS with identical inputs, shapes and algorithm is deterministic, so any
// mismatch is the hardware, not the maths.
//
// usage: compute_check [seconds] [n]      (default 60 s, n=4096)
// exit:  0 = clean, 1 = mismatches found, 2 = CUDA/cuBLAS error
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <cstdio>
#include <cstdlib>

#define CK(x)  do{ cudaError_t e=(x); if(e){printf("compute_check: cuda %s @%d\n",cudaGetErrorString(e),__LINE__); return 2;} }while(0)
#define CB(x)  do{ cublasStatus_t s=(x); if(s){printf("compute_check: cublas %d @%d\n",(int)s,__LINE__); return 2;} }while(0)

// count elements that differ bit-for-bit, and remember the first offending index
__global__ void cmp_kernel(const unsigned short *a, const unsigned short *b, size_t n,
                           unsigned long long *nbad, unsigned long long *first) {
    size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    for (; i < n; i += (size_t)gridDim.x * blockDim.x) {
        if (a[i] != b[i]) {
            atomicAdd(nbad, 1ULL);
            atomicMin(first, (unsigned long long)i);
        }
    }
}

__global__ void fill_kernel(unsigned short *p, size_t n, unsigned seed) {
    size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
    for (; i < n; i += (size_t)gridDim.x * blockDim.x) {
        // deterministic, spread across the bf16 range, no NaN/Inf patterns
        unsigned x = (unsigned)i * 2654435761u + seed;
        p[i] = (unsigned short)(0x3f00 | ((x >> 17) & 0x00ff));
    }
}

int main(int argc, char **argv) {
    double secs = (argc > 1) ? atof(argv[1]) : 60.0;
    int n = (argc > 2) ? atoi(argv[2]) : 4096;
    size_t elems = (size_t)n * n;

    unsigned short *A, *B, *Cref, *Ctest;
    CK(cudaMalloc(&A, elems * 2)); CK(cudaMalloc(&B, elems * 2));
    CK(cudaMalloc(&Cref, elems * 2)); CK(cudaMalloc(&Ctest, elems * 2));
    unsigned long long *dbad, *dfirst;
    CK(cudaMalloc(&dbad, 8)); CK(cudaMalloc(&dfirst, 8));

    fill_kernel<<<512, 256>>>(A, elems, 1u);
    fill_kernel<<<512, 256>>>(B, elems, 7u);
    CK(cudaDeviceSynchronize());

    cublasHandle_t h; CB(cublasCreate(&h));
    float alpha = 1.f, beta = 0.f;
    // one fixed algorithm so the result is bit-reproducible run to run
    auto gemm = [&](unsigned short *C) {
        return cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, CUDA_R_16BF, n,
                            B, CUDA_R_16BF, n, &beta, C, CUDA_R_16BF, n, CUBLAS_COMPUTE_32F,
                            CUBLAS_GEMM_DEFAULT);
    };

    CB(gemm(Cref));                      // the reference every later result must match
    CK(cudaDeviceSynchronize());

    cudaEvent_t t0, t1; CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1));
    CK(cudaEventRecord(t0));
    long iters = 0, bad_iters = 0;
    unsigned long long total_bad = 0, first_bad = ~0ULL;
    double elapsed = 0;
    while (elapsed < secs) {
        for (int k = 0; k < 8; k++) { CB(gemm(Ctest)); iters++; }
        unsigned long long zero = 0, big = ~0ULL;
        CK(cudaMemcpy(dbad, &zero, 8, cudaMemcpyHostToDevice));
        CK(cudaMemcpy(dfirst, &big, 8, cudaMemcpyHostToDevice));
        cmp_kernel<<<512, 256>>>(Cref, Ctest, elems, dbad, dfirst);
        unsigned long long nbad = 0, firstb = 0;
        CK(cudaMemcpy(&nbad, dbad, 8, cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(&firstb, dfirst, 8, cudaMemcpyDeviceToHost));
        if (nbad) {
            bad_iters++; total_bad += nbad;
            if (firstb < first_bad) first_bad = firstb;
            printf("compute_check: MISMATCH after %ld gemms: %llu elements differ (first at %llu)\n",
                   iters, nbad, firstb);
        }
        CK(cudaEventRecord(t1)); CK(cudaEventSynchronize(t1));
        float ms; CK(cudaEventElapsedTime(&ms, t0, t1)); elapsed = ms / 1e3;
    }
    unsigned t = 0;
    cudaDeviceGetAttribute((int *)&t, cudaDevAttrClockRate, 0);
    printf("compute_check: %ld gemms in %.1f s, %ld comparison rounds bad, %llu total bad elements\n",
           iters, elapsed, bad_iters, total_bad);
    if (total_bad) {
        printf("compute_check: SILENT COMPUTE CORRUPTION - the arithmetic is wrong and nothing crashed\n");
        return 1;
    }
    printf("compute_check: clean\n");
    return 0;
}
