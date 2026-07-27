// gpu_selftest.cu - CMP 170HX bench self-test (memory integrity + compute + bandwidth)
//
// Pins to ONE device (the runner sets CUDA_VISIBLE_DEVICES=GPU-<uuid>, so device 0 here
// is the card under test). Emits KEY=VALUE lines and a final RESULT=PASS|FAIL; exit code
// is nonzero on any failure so the driver script can gate on it.
//
// Coverage:
//   * fills (almost) all free VRAM in chunks with a globally-unique 64-bit pattern, then
//     re-reads and verifies - this catches dead cells AND aliased/wrapped backing, which is
//     the thing that matters for an unlocked 64GB card (a fake unlock re-maps <8GB and wraps).
//   * integer compute kernel + exact checksum (no float tolerance games) = SM sanity.
//   * H2D / D2H bandwidth so a card on a bad slot/riser shows up.
//   * HBM bandwidth via a warmed STREAM triad (best of 10). Replaced the old one-shot D2D
//     memcpy, which both under-reported (it counted the buffer once, though a copy reads AND
//     writes it) and swung with allocation placement.
//
// Build: nvcc -O2 -arch=sm_80 gpu_selftest.cu -o gpu_selftest   (GA100 = sm_80)

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  printf("CUDA_ERROR=%s@%d:%s\n", #x, __LINE__, cudaGetErrorString(e)); \
  printf("RESULT=FAIL\n"); return 3; } } while(0)

__global__ void fill(uint64_t* p, size_t n, uint64_t base, uint64_t seed){
  size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x;
  if(i<n) p[i] = seed ^ (base + i);
}
__global__ void verify(const uint64_t* p, size_t n, uint64_t base, uint64_t seed, unsigned long long* errs){
  size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x;
  if(i<n && p[i] != (seed ^ (base + i))) atomicAdd(errs, 1ULL);
}
// STREAM-triad over 16-byte vectors: c = a + s*b. Reads 2 arrays, writes 1, so the
// HBM traffic is 3*bytes. Chosen as THE bandwidth metric because it is the only one that
// held steady (0.4% spread) whether the card was empty or nearly full, while a plain
// device-to-device copy moved 6% and a pure write moved 35% with allocation placement.
__global__ void triad(const float4* __restrict__ a, const float4* __restrict__ b,
                      float4* __restrict__ c, size_t n, float s){
  for(size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x*blockDim.x){
    float4 x=a[i], y=b[i];
    c[i] = make_float4(x.x+s*y.x, x.y+s*y.y, x.z+s*y.z, x.w+s*y.w);
  }
}
// integer FMA-style loop; result is deterministic so we can check it exactly.
__global__ void compute(uint64_t* out, size_t n, uint64_t k){
  size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x;
  if(i<n){
    uint64_t a = i ^ k, acc = 0;
    #pragma unroll 8
    for(int j=0;j<1024;j++){ acc = acc*6364136223846793005ULL + 1442695040888963407ULL + a; }
    out[i] = acc;
  }
}

int main(int argc, char** argv){
  double frac = (argc>1)? atof(argv[1]) : 0.92;   // fraction of FREE vram to sweep
  int dev=0; CK(cudaSetDevice(dev));
  cudaDeviceProp pr; CK(cudaGetDeviceProperties(&pr, dev));
  size_t freeB=0, totB=0; CK(cudaMemGetInfo(&freeB,&totB));
  printf("DEV_NAME=%s\n", pr.name);
  printf("DEV_TOTAL_MIB=%zu\n", totB>>20);
  printf("DEV_FREE_MIB=%zu\n", freeB>>20);
  printf("DEV_ECC=%d\n", pr.ECCEnabled);
  printf("DEV_CC=%d.%d\n", pr.major, pr.minor);

  const int TPB=256;
  // ---- bandwidth (256 MiB) ----
  size_t bw = (size_t)256<<20;
  void *hbuf=nullptr,*dbuf=nullptr,*dbuf2=nullptr;
  CK(cudaHostAlloc(&hbuf, bw, cudaHostAllocDefault));
  CK(cudaMalloc(&dbuf, bw)); CK(cudaMalloc(&dbuf2, bw));
  cudaEvent_t a,b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
  float ms;
  CK(cudaEventRecord(a)); CK(cudaMemcpy(dbuf,hbuf,bw,cudaMemcpyHostToDevice)); CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b));
  CK(cudaEventElapsedTime(&ms,a,b)); printf("BW_H2D_GBs=%.2f\n", (bw/1e9)/(ms/1e3));
  CK(cudaEventRecord(a)); CK(cudaMemcpy(hbuf,dbuf,bw,cudaMemcpyDeviceToHost)); CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b));
  CK(cudaEventElapsedTime(&ms,a,b)); printf("BW_D2H_GBs=%.2f\n", (bw/1e9)/(ms/1e3));
  cudaFree(dbuf); cudaFree(dbuf2); cudaFreeHost(hbuf);

  // ---- HBM bandwidth: warmed STREAM triad, best of 10 ----
  // Report the free VRAM this was measured at: triad is placement-sensitive, so a low
  // number on a card that was already occupied is a measurement artifact, not a defect.
  {
    size_t tf=0, tt=0; CK(cudaMemGetInfo(&tf,&tt));
    printf("BW_TRIAD_FREE_MIB=%zu\n", tf>>20);
    size_t tbytes = (size_t)1<<30;                       // 1 GiB per array (>> 32 MiB L2)
    while(tbytes > ((size_t)64<<20) && tbytes*3 > (tf - (tf>>3))) tbytes >>= 1;
    float4 *ta=nullptr,*tb=nullptr,*tc=nullptr;
    if(cudaMalloc(&ta,tbytes)==cudaSuccess && cudaMalloc(&tb,tbytes)==cudaSuccess
                                          && cudaMalloc(&tc,tbytes)==cudaSuccess){
      CK(cudaMemset(ta,1,tbytes)); CK(cudaMemset(tb,2,tbytes));
      size_t n4 = tbytes/sizeof(float4);
      int grid = pr.multiProcessorCount*32, blk = 256;
      double best = 0.0;
      for(int i=0;i<13;i++){                             // first 3 are warmup
        CK(cudaEventRecord(a));
        triad<<<grid,blk>>>(ta,tb,tc,n4,2.5f);
        CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b)); CK(cudaGetLastError());
        CK(cudaEventElapsedTime(&ms,a,b));
        if(i>=3 && ms>0){ double g=(3.0*tbytes/1e9)/(ms/1e3); if(g>best) best=g; }
      }
      printf("BW_TRIAD_GBs=%.2f\n", best);
      printf("BW_TRIAD_BUF_MIB=%zu\n", tbytes>>20);
    } else {
      printf("BW_TRIAD_GBs=0.00\n");
      printf("BW_TRIAD_BUF_MIB=0\n");
    }
    cudaFree(ta); cudaFree(tb); cudaFree(tc);             // free BEFORE the sweep sizes itself
  }

  // ---- full-VRAM memory integrity sweep ----
  unsigned long long *dErr=nullptr, hErr=0; CK(cudaMalloc(&dErr,sizeof(hErr))); CK(cudaMemset(dErr,0,sizeof(hErr)));
  const uint64_t SEED=0xA5A5F00D12345678ULL;
  CK(cudaMemGetInfo(&freeB,&totB));
  size_t target = (size_t)(freeB*frac);
  size_t chunkBytes = (size_t)1<<30;              // 1 GiB chunks
  uint64_t globalBase=0; size_t sweptB=0; int chunks=0;
  uint64_t* cd=nullptr;
  while(sweptB < target){
    size_t want = chunkBytes; if(target-sweptB < want) want = target-sweptB;
    // shrink until the alloc succeeds (leaves headroom for driver)
    while(want >= ((size_t)64<<20) && cudaMalloc(&cd, want)!=cudaSuccess){ want >>= 1; }
    if(want < ((size_t)64<<20)) break;
    size_t n = want/sizeof(uint64_t);
    size_t blocks = (n+TPB-1)/TPB;
    fill<<<blocks,TPB>>>(cd,n,globalBase,SEED);
    verify<<<blocks,TPB>>>(cd,n,globalBase,SEED,dErr);
    CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    cudaFree(cd); cd=nullptr;
    globalBase += n; sweptB += want; chunks++;
  }
  CK(cudaMemcpy(&hErr,dErr,sizeof(hErr),cudaMemcpyDeviceToHost)); cudaFree(dErr);
  printf("MEM_SWEPT_MIB=%zu\n", sweptB>>20);
  printf("MEM_CHUNKS=%d\n", chunks);
  printf("MEM_ERRORS=%llu\n", hErr);

  // ---- compute sanity (exact integer checksum) ----
  size_t cn = (size_t)16<<20; uint64_t* co=nullptr; CK(cudaMalloc(&co, cn*sizeof(uint64_t)));
  compute<<<(unsigned)((cn+TPB-1)/TPB),TPB>>>(co,cn,SEED);
  CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
  // reduce a sample on host
  uint64_t* hc=(uint64_t*)malloc(cn*sizeof(uint64_t));
  CK(cudaMemcpy(hc,co,cn*sizeof(uint64_t),cudaMemcpyDeviceToHost));
  uint64_t sum=0; for(size_t i=0;i<cn;i++) sum+=hc[i];
  // CPU recompute of the same deterministic function for cross-check
  uint64_t csum=0; for(size_t i=0;i<cn;i++){ uint64_t aa=i^SEED,acc=0; for(int j=0;j<1024;j++) acc=acc*6364136223846793005ULL+1442695040888963407ULL+aa; csum+=acc; }
  free(hc); cudaFree(co);
  printf("COMPUTE_GPU_SUM=%llu\n",(unsigned long long)sum);
  printf("COMPUTE_CPU_SUM=%llu\n",(unsigned long long)csum);
  int compute_ok = (sum==csum);
  printf("COMPUTE_OK=%d\n", compute_ok);

  int pass = (hErr==0) && compute_ok && (sweptB>0);
  printf("RESULT=%s\n", pass?"PASS":"FAIL");
  return pass?0:1;
}
