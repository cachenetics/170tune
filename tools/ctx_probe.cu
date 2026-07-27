// ctx_probe - can anything actually USE this GPU?
//
// There is a failure state that every cheap health check misses. After a hard kill of an inference
// server mid-CUDA-context, the card can reach a point where nvidia-smi answers normally, NVML does
// not report "requires reset" and the clocks read fine - and no process can create a CUDA context.
// The signature seen in the field: torch reports device_count()=1 with is_available()=False.
// Measured on the reference card; 'recover' cleared the offsets, saw a healthy nvidia-smi and
// declared success while the GPU was useless to every process on the box until the driver was
// reloaded by hand.
//
// So: create a context, allocate, launch, synchronise, read back. Nothing else. It is the smallest
// thing that proves the card is usable rather than merely answering queries.
//
// usage: ctx_probe [device]
// exit:  0 = a context works, 2 = it does not (this is the wedge the other checks miss),
//        3 = alive but out of memory (a server holding the VRAM is NOT a wedge - do not reload)
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

__global__ void touch(int *p) { *p = 0x170; }

static int fail(const char *what, cudaError_t e) {
    // Out of memory means the driver and the context path are fine and something else owns the
    // VRAM. Reloading the driver on that would kill a healthy running server.
    int oom = (e == cudaErrorMemoryAllocation);
    printf("ctx_probe: %s: %s\n", what, cudaGetErrorString(e));
    return oom ? 3 : 2;
}

int main(int argc, char **argv) {
    int dev = (argc > 1) ? atoi(argv[1]) : 0;
    cudaError_t e;
    if ((e = cudaSetDevice(dev)))                  return fail("cudaSetDevice", e);
    if ((e = cudaFree(0)))                         return fail("context create", e);
    int *d = 0;
    if ((e = cudaMalloc(&d, sizeof(int))))         return fail("cudaMalloc", e);
    touch<<<1, 1>>>(d);
    if ((e = cudaGetLastError()))                  return fail("kernel launch", e);
    if ((e = cudaDeviceSynchronize()))             return fail("synchronize", e);
    int h = 0;
    if ((e = cudaMemcpy(&h, d, sizeof(int), cudaMemcpyDeviceToHost))) return fail("memcpy", e);
    cudaFree(d);
    if (h != 0x170) { printf("ctx_probe: kernel wrote %#x, expected 0x170\n", h); return 2; }
    printf("ctx_probe: context ok on device %d\n", dev);
    return 0;
}
