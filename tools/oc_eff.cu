// Efficiency probe: run a sustained bf16 tensor-core GEMM while sampling power/clock/temp
// in-process via NVML, and report achieved TFLOPS, mean watts and TFLOPS/W.
// usage: oc_eff [seconds]   (default 12)
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <nvml.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>

#define CK(x)  do{ cudaError_t e=(x); if(e){printf("cuda %s @%d\n",cudaGetErrorString(e),__LINE__); exit(1);} }while(0)
#define CB(x)  do{ cublasStatus_t s=(x); if(s){printf("cublas %d @%d\n",(int)s,__LINE__); exit(1);} }while(0)

int main(int argc, char **argv) {
    double secs = (argc > 1) ? atof(argv[1]) : 12.0;
    int n = 8192;
    size_t elems = (size_t)n * n;
    void *A, *B, *C;
    CK(cudaMalloc(&A, elems * 4)); CK(cudaMalloc(&B, elems * 4)); CK(cudaMalloc(&C, elems * 4));
    CK(cudaMemset(A, 0x3c, elems * 4)); CK(cudaMemset(B, 0x3c, elems * 4));
    cublasHandle_t h; CB(cublasCreate(&h));
    float alpha = 1.f, beta = 0.f;

    nvmlInit_v2();
    nvmlDevice_t d; nvmlDeviceGetHandleByIndex_v2(0, &d);

    // warmup
    for (int i = 0; i < 10; i++)
        CB(cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, CUDA_R_16BF, n,
                        B, CUDA_R_16BF, n, &beta, C, CUDA_R_16BF, n, CUBLAS_COMPUTE_32F,
                        CUBLAS_GEMM_DEFAULT));
    CK(cudaDeviceSynchronize());

    std::vector<unsigned> pw, sm;
    unsigned tmax = 0, mmax = 0;
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    long iters = 0;
    double elapsed = 0;
    while (elapsed < secs) {
        for (int i = 0; i < 20; i++) {
            CB(cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, CUDA_R_16BF, n,
                            B, CUDA_R_16BF, n, &beta, C, CUDA_R_16BF, n, CUBLAS_COMPUTE_32F,
                            CUBLAS_GEMM_DEFAULT));
            iters++;
        }
        CK(cudaDeviceSynchronize());
        unsigned mw = 0, clk = 0, t = 0, mt = 0;
        if (nvmlDeviceGetPowerUsage(d, &mw) == NVML_SUCCESS) pw.push_back(mw);
        if (nvmlDeviceGetClockInfo(d, NVML_CLOCK_SM, &clk) == NVML_SUCCESS) sm.push_back(clk);
        if (nvmlDeviceGetTemperature(d, NVML_TEMPERATURE_GPU, &t) == NVML_SUCCESS) tmax = std::max(tmax, t);
        mmax = std::max(mmax, mt);
        CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b));
        float ms; CK(cudaEventElapsedTime(&ms, a, b));
        elapsed = ms / 1e3;
    }
    double tflops = 2.0 * n * n * n * iters / elapsed / 1e12;
    double mean_w = 0; for (unsigned v : pw) mean_w += v; mean_w = pw.empty() ? 0 : mean_w / pw.size() / 1000.0;
    double max_w = pw.empty() ? 0 : *std::max_element(pw.begin(), pw.end()) / 1000.0;
    double mean_sm = 0; for (unsigned v : sm) mean_sm += v; mean_sm = sm.empty() ? 0 : mean_sm / sm.size();

    unsigned lim = 0; nvmlDeviceGetPowerManagementLimit(d, &lim);
    int off = 0; nvmlDeviceGetGpcClkVfOffset(d, &off);
    printf("offset=%+5d  pl=%3uW | bf16=%7.2f TFLOPS  P=%6.1f W (max %6.1f)  sm=%4.0f MHz  %5.2f GFLOPS/W  Tmax=%uC\n",
           off, lim / 1000, tflops, mean_w, max_w, mean_sm, tflops * 1000.0 / mean_w, tmax);
    nvmlShutdown();
    return 0;
}
