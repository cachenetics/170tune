# CMP 170HX core OC: the complete measurement matrix

Card 1322621047793 (GA100, 70 SM, 64 GB, driver 610.43.03, stock 300W VBIOS 92.00.6D.00.0A, Gen2 x4).
Each cell is a sustained bf16 tensor-core GEMM (`tools/oc_eff.cu`, n=8192) with power sampled
in-process through NVML; repeated cells are averaged. Raw rows: `analysis/oc_tune_sweep.csv`.

**Read this first.** A cell showing numbers means the run *completed without a fault*. It does NOT
mean the point is safe: `+325 / 1400` completes happily and silently corrupts memory. Only the
shipped profiles carry the integrity gate (2-4 full-VRAM pattern sweeps). Anything else in this
table is unverified.

**And read this second: a GEMM number does not predict whether a point can serve.** `+300/1350` is
the best GFLOPS/W cell in this whole document, gated 4/4 hot, passed a real-workload rung, served a
full day of benchmarks - and then faulted with Xid 13 under an hour-long soak. The qualification
matrix below, not the GEMM matrix here, is what decides what ships.

## Qualification matrix: which points survive real serving

Gated 4/4 with a workload rung, then soaked against long-context prompts and multi-step
generations under vLLM. This is the table to ship from.

| offset | 1200 | 1350 | 1400 | 1470 | 1590 | 1650 |
|---|---|---|---|---|---|---|
| **+200** | **CLEAN** | - | **CLEAN** | - | - | - |
| **+250** | **CLEAN** | - | **CLEAN** | - | - | - |
| **+300** | - | FAULT | FAULT | FAULT | - | FAULT |
| **+350** | - | - | - | - | FAULT | FAULT |

Serving numbers at the qualified points (Qwen3.6-27B INT8, fp8 KV, MTP, concurrency 24):

```
point             decode    prefill   watts   core C   HBM C   tok/s per W
+200/1200 @200W    303.0     2,329     149      59       66       2.03   <- peak efficiency
+250/1200 @200W    303.6     2,331     152      59       66       2.00
+200/1400 @300W    341.8     2,668     181      60       66       1.89   <- peak throughput
+250/1400 @300W    342.9     2,669     178      62       67       1.93
```

`+250` is stable and buys nothing worth having: identical at 1200 while drawing 3 W more, and 2%
more efficient at 1400. The shipped profiles stay at `+200`, one full step below the offset that
has faulted at three separate ceilings.

Note what this says about the risk lever. It is neither the offset nor the ceiling alone: `+250`
survives 1400 where `+300` dies, and `+300` dies at low clocks too. What matters is
voltage-at-frequency, and `+300` crosses the line everywhere tested on this card.

## bf16 TFLOPS / watts

| ceiling | +0 | +150 | +200 | +250 | +300 | +325 | +350 | +355 | +360 | +375 | +400 | +450 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **1200** | - | - | - | 160.8 / 120.2W | 160.7 / 118.9W | - | 160.8 / 120.0W | - | - | - | 160.7 / 120.0W | - |
| **1250** | - | - | - | 166.7 / 124.0W | 166.8 / 124.9W | - | 166.8 / 125.0W | - | - | - | 166.8 / 123.6W | - |
| **1300** | - | - | - | 172.8 / 127.0W | 172.8 / 127.3W | - | 172.8 / 127.4W | - | - | - | 172.8 / 128.2W | - |
| **1350** | - | 180.2 / 146.0W | 180.3 / 140.9W | 180.1 / 134.7W | 180.7 / 131.3W | - | 180.7 / 131.5W | - | - | - | 181/132W **corrupt*** | 180.8 / 132.4W |
| **1400** | 186.7 / 197.6W | 185.5 / 154.3W | 186.5 / 150.2W | 186.5 / 143.3W | 186.6 / 136.3W | 187/133W **CORRUPT** | 186.7 / 134.3W | - | - | **fault** | - | - |
| **1470** | - | - | - | 196.1 / 161.8W | 195.9 / 149.2W | - | 196.1 / 148.7W | - | - | - | - | - |
| **1530** | - | - | - | 204.1 / 180.9W | 204.5 / 168.1W | - | 204.3 / 163.0W | - | - | - | - | - |
| **1590** | - | - | - | 205.7 / 189.6W | 210.8 / 184.7W | - | 211.8 / 177.1W | - | - | - | **HANG** | - |
| **1620** | - | - | - | - | 210.8 / 187.4W | - | - | - | - | - | - | - |
| **1650** | - | - | - | 204.8 / 191.9W | 209.3 / 186.3W | - | 214.7 / 186.8W | 215/181W **fault** | 217/182W **fault** | 219/182W **fault** | 210.7 / 179.1W | - |
| **1700** | - | - | - | - | - | - | 213.2 / 185.8W | - | - | **HANG** | - | - |
| **1740** | - | - | - | - | - | - | 213.8 / 187.5W | - | - | - | - | - |

## GFLOPS/W

| ceiling | +0 | +150 | +200 | +250 | +300 | +325 | +350 | +355 | +360 | +375 | +400 | +450 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **1200** | - | - | - | 1337 | 1352 | - | 1340 | - | - | - | 1340 | - |
| **1250** | - | - | - | 1345 | 1335 | - | 1335 | - | - | - | 1349 | - |
| **1300** | - | - | - | 1360 | 1357 | - | 1356 | - | - | - | 1348 | - |
| **1350** | - | 1234 | 1280 | 1337 | 1376 | - | 1375 | - | - | - | 1369 | 1365 |
| **1400** | 945 | 1202 | 1241 | 1302 | 1369 | 1386 | 1390 | - | - | - | - | - |
| **1470** | - | - | - | 1212 | 1313 | - | 1318 | - | - | - | - | - |
| **1530** | - | - | - | 1128 | 1216 | - | 1253 | - | - | - | - | - |
| **1590** | - | - | - | 1085 | 1141 | - | 1196 | - | - | - | - | - |
| **1620** | - | - | - | - | 1125 | - | - | - | - | - | - | - |
| **1650** | - | - | - | 1067 | 1123 | - | 1149 | 1175 | 1196 | 1204 | 1177 | - |
| **1700** | - | - | - | - | - | - | 1148 | - | - | - | - | - |
| **1740** | - | - | - | - | - | - | 1140 | - | - | - | - | - |

## Legend and the cells that are deliberately empty

* **CORRUPT** - completes, but the full-VRAM sweep returns memory errors (silent data corruption).
* **corrupt\*** - `+400/1350` passed two sweeps, then returned `mem_errors=1` on a later one. This is
  why `eff` sat at `+300/1350` rather than higher: it draws the same ~131 W as
  anything above it on the flat floor, with margin below the point that misbehaved.
* **fault** - CUDA device fault under load (`illegal instruction`, `illegal memory access`, cublas 14).
* **HANG** - GPU wedged, needs a reboot (and sometimes a power cycle).
* `+400` at 1400 / 1470 / 1530 is **not tested on purpose**: `1380/+400` faults and `1590/+400` hangs,
  so that corner costs a reboot per probe with no plausible upside.
* Low offsets at high ceilings (`+150`, `+200` above 1400) are omitted - strictly worse than `+250`
  at the same clock (more voltage for the same work).
* `1200-1300` above `+400` is omitted - power is already flat there, so extra offset is inert.

## What the matrix shows

1. **Two regimes.** Below ~1350 the rail bottoms out and power goes flat (1200: 118.9-120.2 W across
   +250..+400). Above ~1400 the corruption cliff arrives before the floor does.
2. **Efficiency peaks in a broad plateau at 1350-1400** (1369-1390 GFLOPS/W) and falls off in both
   directions - 1067 at 1650/+250, 1234 at 1350/+150.
3. **The clock ceiling above 1650 is silicon-capped**: 1700 and 1740 both deliver ~1600 MHz and
   213-214 TF, no better than 1650.
4. **Non-monotonic at the top**: `1650/+400` runs (slower, clock-stretching) while `1590/+400` hangs
   and `1650/+375` faults. Past the wall the behaviour stops being orderly - another reason to sit
   well below it.

## Delivered memory bandwidth per profile (stock 1728 MHz memory)

| profile | read (24 GiB) | bench triad | dependent-load latency |
|---|---|---|---|
| stock | 1693.9 GB/s | 1589.6 GB/s | 276.3 ns |
| eff (+300/1350) | 1685.9 GB/s | 1599.3 GB/s | 296.1 ns |
| match (+250/1400) | 1690.2 GB/s | 1597.6 GB/s | 288.3 ns |
| max (+350/1650) | 1698.2 GB/s | 1584.8 GB/s | 253.2 ns |

(`eff` and `max` appear in this bandwidth table because it predates their quarantine; the figures
stand as measurements of those clock points, they are just no longer shippable.)

Streaming bandwidth is essentially profile-independent (whole spread under 1%, and `eff` leads on
triad). Memory LATENCY is not: 253 ns at `max` against 296 ns at `eff`, a 17% spread, because the
request path runs at core clock while the DRAM does not. Bandwidth-bound work can take `eff` and
keep the 68 W; latency-bound work should pay for a high-clock profile.

Spread is ~1%. Streaming reads favour the high-clock profiles, triad (read+write, the better proxy
for decode) peaks at `match`. Theoretical peak at 1728 MHz on a 4096-bit bus is 1769 GB/s, so we are
at 95-96% of it; the remaining 4% is protocol overhead, not a setting. ECC is `N/A` on this SKU, so
there is no ECC-off lever.

This table is the SM (GPC clock/voltage) matrix; it measures bandwidth at the STOCK 1728 MHz
memory clock across every SM profile, which is still valid - the SM offset/ceiling do not move
the memory clock. The memory clock itself is a separate, live BAR0 lever (`170tune mclk-try` /
`mclk-gate`, up to a gated ceiling of NDIV 76 on the reference card) - an earlier note here
claiming it "cannot go up" was corrected: see `170tune explain-hbm` and
[`hbm-matrix.md`](hbm-matrix.md) for the current HBM measurement matrix and model.
