// 170HX GEMM throughput probe: does the mining-card throttle hit tensor cores?
// Measures FP16/BF16/TF32/FP32 cublas GEMM TFLOPS + a big-alloc HBM read bandwidth.
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <cstdio>
#include <vector>

#define CK(x) do{ cudaError_t _ce=(x); if(_ce){printf("cuda err %s @%d\n",cudaGetErrorString(_ce),__LINE__); exit(1);} }while(0)
#define CB(x) do{ cublasStatus_t _cs=(x); if(_cs){printf("cublas err %d @%d\n",(int)_cs,__LINE__); exit(1);} }while(0)

static double bench(cublasHandle_t h, int n, cudaDataType_t dt, cublasComputeType_t ct,
                    void *A, void *B, void *C, const char *tag) {
  float alpha = 1.f, beta = 0.f;
  cublasGemmAlgo_t algo = CUBLAS_GEMM_DEFAULT;
  // warmup
  for (int i = 0; i < 5; i++)
    CB(cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, dt, n, B, dt, n,
                    &beta, C, dt, n, ct, algo));
  CK(cudaDeviceSynchronize());
  cudaEvent_t ev0, ev1; CK(cudaEventCreate(&ev0)); CK(cudaEventCreate(&ev1));
  int iters = 30;
  CK(cudaEventRecord(ev0));
  for (int i = 0; i < iters; i++)
    CB(cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha, A, dt, n, B, dt, n,
                    &beta, C, dt, n, ct, algo));
  CK(cudaEventRecord(ev1)); CK(cudaEventSynchronize(ev1));
  float ms; CK(cudaEventElapsedTime(&ms, ev0, ev1));
  double tflops = 2.0 * n * n * n * iters / (ms / 1e3) / 1e12;
  printf("%-28s n=%d  %8.2f TFLOPS  (%.3f ms/gemm)\n", tag, n, tflops, ms / iters);
  return tflops;
}

__global__ void readk(const float4 *__restrict p, size_t n, float *out) {
  size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
  float4 acc = {0, 0, 0, 0};
  for (; i < n; i += (size_t)gridDim.x * blockDim.x) {
    float4 v = p[i]; acc.x += v.x; acc.y += v.y; acc.z += v.z; acc.w += v.w;
  }
  if (acc.x == 1e30f) out[0] = acc.x + acc.y + acc.z + acc.w;
}

int main() {
  cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, 0));
  size_t fr, tot; CK(cudaMemGetInfo(&fr, &tot));
  int clkRate=0, memClk=0;
  CK(cudaDeviceGetAttribute(&clkRate, cudaDevAttrClockRate, 0));
  CK(cudaDeviceGetAttribute(&memClk, cudaDevAttrMemoryClockRate, 0));
  printf("dev: %s  sm_%d%d  SMs=%d  clk=%.0fMHz  mem=%.1f GiB free=%.1f GiB  buswidth=%d memclk=%.0fMHz\n",
         p.name, p.major, p.minor, p.multiProcessorCount, clkRate / 1000.0,
         tot / 1073741824.0, fr / 1073741824.0, p.memoryBusWidth, memClk / 1000.0);
  double peak_fp32 = p.multiProcessorCount * 64.0 * 2 * (clkRate / 1e6);
  printf("theoretical fp32 (64 fma/SM/clk): %.2f TFLOPS ; tc fp16 (x16 fp32 rate): %.1f TFLOPS\n\n",
         peak_fp32, peak_fp32 * 16);

  int n = 8192;
  size_t elems = (size_t)n * n;
  void *A, *B, *C;
  CK(cudaMalloc(&A, elems * 4)); CK(cudaMalloc(&B, elems * 4)); CK(cudaMalloc(&C, elems * 4));
  CK(cudaMemset(A, 0x3c, elems * 4)); CK(cudaMemset(B, 0x3c, elems * 4));

  cublasHandle_t h; CB(cublasCreate(&h));
  bench(h, n, CUDA_R_16F, CUBLAS_COMPUTE_16F,        A, B, C, "fp16 tensorcore (16f acc)");
  bench(h, n, CUDA_R_16F, CUBLAS_COMPUTE_32F,        A, B, C, "fp16 tensorcore (32f acc)");
  bench(h, n, CUDA_R_16BF, CUBLAS_COMPUTE_32F,       A, B, C, "bf16 tensorcore (32f acc)");
  bench(h, n, CUDA_R_32F, CUBLAS_COMPUTE_32F_FAST_TF32, A, B, C, "tf32 tensorcore");
  bench(h, n, CUDA_R_32F, CUBLAS_COMPUTE_32F,        A, B, C, "fp32 (no tensorcore)");

  // HBM read bandwidth on a large buffer (well past the old 8GiB line)
  size_t bytes = 24ull << 30;
  float4 *buf; float *out;
  if (cudaMalloc(&buf, bytes) == cudaSuccess) {
    CK(cudaMalloc(&out, 4)); CK(cudaMemset(buf, 1, bytes));
    size_t n4 = bytes / sizeof(float4);
    readk<<<p.multiProcessorCount * 32, 256>>>(buf, n4, out);
    CK(cudaDeviceSynchronize());
    cudaEvent_t ev0, ev1; CK(cudaEventCreate(&ev0)); CK(cudaEventCreate(&ev1));
    CK(cudaEventRecord(ev0));
    for (int i = 0; i < 5; i++) readk<<<p.multiProcessorCount * 32, 256>>>(buf, n4, out);
    CK(cudaEventRecord(ev1)); CK(cudaEventSynchronize(ev1));
    float ms; CK(cudaEventElapsedTime(&ms, ev0, ev1));
    printf("\nHBM read bandwidth (%zu GiB buf): %.1f GB/s\n", bytes >> 30,
           bytes * 5.0 / (ms / 1e3) / 1e9);
  } else {
    printf("\n(24 GiB alloc failed - skipping bandwidth)\n");
  }
  return 0;
}
