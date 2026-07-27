// Independent memory-clock probes for the 170HX: streaming read bandwidth AND
// dependent-load latency. Latency in ns scales with tCK, so if the DRAM clock really
// moved, latency must fall by the same ratio - a check that cannot be spoofed by a
// register that only feeds nvidia-smi's computed clock.
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

#define CK(x) do{ cudaError_t _e=(x); if(_e){printf("cuda err %s @%d\n",cudaGetErrorString(_e),__LINE__); exit(1);} }while(0)

__global__ void readk(const float4 *__restrict p, size_t n, float *out) {
  size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
  float4 acc = {0, 0, 0, 0};
  for (; i < n; i += (size_t)gridDim.x * blockDim.x) {
    float4 v = p[i]; acc.x += v.x; acc.y += v.y; acc.z += v.z; acc.w += v.w;
  }
  if (acc.x == 1e30f) out[0] = acc.x + acc.y + acc.z + acc.w;
}

// single-thread dependent pointer chase: each load's address depends on the previous value
__global__ void chase(const unsigned *idx, unsigned start, int hops, unsigned *out) {
  unsigned p = start;
  for (int i = 0; i < hops; i++) p = idx[p];
  *out = p;
}

int main(int argc, char **argv) {
  int dev = 0; CK(cudaSetDevice(dev));
  int clk = 0, mclk = 0;
  CK(cudaDeviceGetAttribute(&clk, cudaDevAttrClockRate, dev));
  CK(cudaDeviceGetAttribute(&mclk, cudaDevAttrMemoryClockRate, dev));
  cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
  double peak = p.memoryBusWidth / 8.0 * (mclk / 1e6) * 2.0;   // GB/s, DDR
  printf("sm_clk=%d MHz  reported_mclk=%d MHz  bus=%d bit  reported_peak=%.1f GB/s\n",
         clk / 1000, mclk / 1000, p.memoryBusWidth, peak);

  // ---- streaming read
  size_t bytes = 24ull << 30;
  float4 *buf; float *out4;
  CK(cudaMalloc(&buf, bytes)); CK(cudaMalloc(&out4, 4)); CK(cudaMemset(buf, 1, bytes));
  size_t n4 = bytes / sizeof(float4);
  int blocks = p.multiProcessorCount * 32;
  readk<<<blocks, 256>>>(buf, n4, out4); CK(cudaDeviceSynchronize());
  cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
  CK(cudaEventRecord(a));
  for (int i = 0; i < 5; i++) readk<<<blocks, 256>>>(buf, n4, out4);
  CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b));
  float ms; CK(cudaEventElapsedTime(&ms, a, b));
  double bw = bytes * 5.0 / (ms / 1e3) / 1e9;
  printf("read_bw = %.1f GB/s   (%.1f%% of reported peak)\n", bw, 100.0 * bw / peak);
  CK(cudaFree(buf));

  // ---- dependent-load latency: 8 GiB chase, 4 KiB stride, random page order
  size_t N = (8ull << 30) / sizeof(unsigned);
  size_t stride = 4096 / sizeof(unsigned);
  size_t slots = N / stride;
  unsigned *h = (unsigned *)malloc(N * sizeof(unsigned));
  if (!h) { printf("host alloc failed\n"); return 1; }
  unsigned *order = (unsigned *)malloc(slots * sizeof(unsigned));
  for (size_t i = 0; i < slots; i++) order[i] = (unsigned)i;
  // deterministic shuffle (fixed LCG - same permutation every run, comparable across boots)
  unsigned long long s = 88172645463325252ull;
  for (size_t i = slots - 1; i > 0; i--) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    size_t j = (size_t)(s % (i + 1));
    unsigned t = order[i]; order[i] = order[j]; order[j] = t;
  }
  for (size_t i = 0; i < slots; i++)
    h[order[i] * stride] = (unsigned)(order[(i + 1) % slots] * stride);
  unsigned *d; CK(cudaMalloc(&d, N * sizeof(unsigned)));
  CK(cudaMemcpy(d, h, N * sizeof(unsigned), cudaMemcpyHostToDevice));
  unsigned *dout; CK(cudaMalloc(&dout, 4));
  int hops = 200000;
  chase<<<1, 1>>>(d, order[0] * stride, 20000, dout); CK(cudaDeviceSynchronize());
  double best = 1e30;
  for (int r = 0; r < 3; r++) {
    CK(cudaEventRecord(a));
    chase<<<1, 1>>>(d, order[0] * stride, hops, dout);
    CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b));
    CK(cudaEventElapsedTime(&ms, a, b));
    double ns = ms * 1e6 / hops;
    if (ns < best) best = ns;
  }
  printf("dram_latency = %.2f ns/dependent-load (best of 3, %d hops over 8 GiB)\n", best, hops);
  printf("  -> if the DRAM clock rose x%%, this must fall by ~x%%\n");
  return 0;
}
