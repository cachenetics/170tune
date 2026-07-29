// Sanctioned-OC probe: the driver exports nvmlDeviceSet{GpcClk,MemClk}VfOffset and
// nvmlDeviceSetClockOffsets even though nvidia-smi only surfaces the negative direction
// (--set-vf-derate). Query the allowed VF-offset range, then optionally apply one.
//   usage: nvml_oc                              # report only (device 0)
//          nvml_oc -i <devIdx>                  # report only, a SPECIFIC device
//          nvml_oc <gpcMHz> <memMHz> [devIdx]   # apply offsets (0 is a valid value)
//
// The -i read form exists because without it every read landed on device 0. On a two-card box
// that made 170hx-oc report card 0's offset while configuring card 1 - a check describing the
// wrong card, which is worse than no check.
#include <nvml.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TRY(call) do { nvmlReturn_t r = (call); \
  printf("  %-46s -> %s\n", #call, nvmlErrorString(r)); } while (0)

int main(int argc, char **argv) {
    nvmlReturn_t r = nvmlInit_v2();
    if (r != NVML_SUCCESS) { printf("nvmlInit: %s\n", nvmlErrorString(r)); return 1; }
    int a = 1;                       // first positional argument
    unsigned idx = 0u;
    if (argc >= 3 && (strcmp(argv[1], "-i") == 0 || strcmp(argv[1], "--device") == 0)) {
        idx = (unsigned)atoi(argv[2]);
        a = 3;
    } else if (argc >= 4) {
        idx = (unsigned)atoi(argv[3]);
    }
    nvmlDevice_t d;
    if ((r = nvmlDeviceGetHandleByIndex_v2(idx, &d)) != NVML_SUCCESS) {
        printf("handle: %s\n", nvmlErrorString(r)); return 1; }

    char name[96] = {0};
    nvmlDeviceGetName(d, name, sizeof name);
    printf("device %u: %s\n\n", idx, name);

    int mn = 0, mx = 0, cur = 0;
    printf("GPC clock VF offset:\n");
    r = nvmlDeviceGetGpcClkMinMaxVfOffset(d, &mn, &mx);
    printf("  allowed range      : %s", nvmlErrorString(r));
    if (r == NVML_SUCCESS) printf("  [%d .. %+d] MHz", mn, mx);
    printf("\n");
    r = nvmlDeviceGetGpcClkVfOffset(d, &cur);
    printf("  current offset     : %s", nvmlErrorString(r));
    if (r == NVML_SUCCESS) printf("  %+d MHz", cur);
    printf("\n");

    mn = mx = cur = 0;
    printf("MEM clock VF offset:\n");
    r = nvmlDeviceGetMemClkMinMaxVfOffset(d, &mn, &mx);
    printf("  allowed range      : %s", nvmlErrorString(r));
    if (r == NVML_SUCCESS) printf("  [%d .. %+d] MHz", mn, mx);
    printf("\n");
    r = nvmlDeviceGetMemClkVfOffset(d, &cur);
    printf("  current offset     : %s", nvmlErrorString(r));
    if (r == NVML_SUCCESS) printf("  %+d MHz", cur);
    printf("\n");

#ifdef NVML_CLOCK_OFFSET_VERSION
    printf("\nnvmlDeviceGetClockOffsets (P0):\n");
    for (int t = 0; t < 2; t++) {
        nvmlClockOffset_t info;
        memset(&info, 0, sizeof info);
        info.version = nvmlClockOffset_v1;
        info.type = t ? NVML_CLOCK_MEM : NVML_CLOCK_GRAPHICS;
        info.pstate = NVML_PSTATE_0;
        r = nvmlDeviceGetClockOffsets(d, &info);
        printf("  %-4s : %s", t ? "MEM" : "GPC", nvmlErrorString(r));
        if (r == NVML_SUCCESS)
            printf("  offset=%+d  range=[%d .. %+d]", info.clockOffsetMHz, info.minClockOffsetMHz,
                   info.maxClockOffsetMHz);
        printf("\n");
    }
#endif

    if (argc - a >= 2) {
        int gpc = atoi(argv[a]), mem = atoi(argv[a + 1]);
        int setGpc = 1, setMem = 1;   // 0 is a VALID offset (= stock), always apply
        printf("\napplying offsets: gpc=%+d MHz  mem=%+d MHz\n", gpc, mem);
        if (setGpc) {
            TRY(nvmlDeviceSetGpcClkVfOffset(d, gpc));
#ifdef NVML_CLOCK_OFFSET_VERSION
            nvmlClockOffset_t s; memset(&s, 0, sizeof s);
            s.version = nvmlClockOffset_v1; s.type = NVML_CLOCK_GRAPHICS;
            s.pstate = NVML_PSTATE_0; s.clockOffsetMHz = gpc;
            TRY(nvmlDeviceSetClockOffsets(d, &s));
#endif
        }
        if (setMem) {
            TRY(nvmlDeviceSetMemClkVfOffset(d, mem));
#ifdef NVML_CLOCK_OFFSET_VERSION
            nvmlClockOffset_t s; memset(&s, 0, sizeof s);
            s.version = nvmlClockOffset_v1; s.type = NVML_CLOCK_MEM;
            s.pstate = NVML_PSTATE_0; s.clockOffsetMHz = mem;
            TRY(nvmlDeviceSetClockOffsets(d, &s));
#endif
        }
        int g = 0, m = 0;
        nvmlDeviceGetGpcClkVfOffset(d, &g);
        nvmlDeviceGetMemClkVfOffset(d, &m);
        printf("readback: gpc=%+d  mem=%+d MHz\n", g, m);
        unsigned int sm = 0, mc = 0;
        nvmlDeviceGetClockInfo(d, NVML_CLOCK_SM, &sm);
        nvmlDeviceGetClockInfo(d, NVML_CLOCK_MEM, &mc);
        printf("clocks now: sm=%u MHz mem=%u MHz\n", sm, mc);
    }
    nvmlShutdown();
    return 0;
}
