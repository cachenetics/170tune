# Reference matrices

Every measured table for the reference card, in one place. The prose documents link here
instead of restating numbers; if a figure in this repo has a home, this is it.

Reference card: serial 1322621047793 (GA100, 70 SM, 64 GB HBM2e on a 4096-bit bus, 8
active FBPAs, driver 610.43.03, stock 300 W VBIOS 92.00.6D.00.0A, PCIe Gen2 x4). All
numbers are from this one card unless stated. Per-card silicon varies: regenerate the SM
side on your card with `170tune qualify` and the HBM grid with `170tune hbm-matrix`, and
gate before trusting any point.

**How to read every table in this file:** a cell showing numbers means the run completed
without a fault. It does not mean the point is safe. Silent corruption completes happily;
only a gated, workload-soaked point is qualified. The
[serving qualification matrix](#serving-qualification-matrix) is the table that decides
what ships.

## Card baseline

Reading guide: what the card measures at stock and at its gated bench peak.

| property | value |
|---|---|
| GPU | GA100, 70 SM |
| Memory | 64 GB HBM2e, 4096-bit bus, stock 1728 MHz (NDIV 64) |
| Link | PCIe Gen2 x4 |
| Driver / VBIOS | 610.43.03 / 92.00.6D.00.0A (stock 300 W) |
| bf16 tensor-core GEMM, stock | 184.3 TFLOPS at 199.2 W (925 GFLOPS/W) |
| bf16 tensor-core GEMM, bench peak | 215.3 TFLOPS at 186.1 W (max profile, bench-only) |
| HBM read bandwidth (24 GiB stream), stock | 1679.1 GB/s |
| HBM read bandwidth, bench peak (max profile) | 1699.3 GB/s |
| Theoretical HBM peak at 1728 MHz | 1769 GB/s (delivery is 95-96% of it) |
| ECC | N/A on this SKU (no ECC-off lever exists) |

Every TFLOPS figure in the SM tables below is a sustained bf16 tensor-core GEMM
(`tools/oc_eff.cu`, n=8192, 10-15 s soak, NVML power sampled in-process).

## Datatype throughput at stock clocks

Reading guide: other datatypes measured once at stock (`tools/gemm_probe.cu`, n=8192, 30
iterations); they were not swept across profiles, so do not scale them by the bf16 ratios.

| datatype (stock clocks) | TFLOPS |
|---|---|
| bf16 tensor core, fp32 accumulate | 188.1 - 192.7 |
| fp16 tensor core, fp32 accumulate | 158.7 - 160.0 |
| tf32 tensor core | 88.9 - 91.9 |
| fp32, no tensor core | 12.76 |

Two measurement notes carried forward: `CUBLAS_COMPUTE_16F` with a `float` alpha/beta
pointer returns instantly and reports an absurd 10748 TFLOPS, which is a no-op, not a
result; use the 32f-accumulate rows. And CUDA 13 removed `cudaDeviceProp::clockRate` and
`memoryClockRate`; use `cudaDeviceGetAttribute` with `cudaDevAttrClockRate` /
`cudaDevAttrMemoryClockRate` instead.

## Serving qualification matrix

Reading guide: this is the ship table. Each tested point was gated 4/4 hot with a workload
rung, then soaked against long-context prompts and multi-step generations under vLLM. CLEAN
means it survived the soak; FAULT means it faulted there (Xid 13 on the weak SMs at
GPC3/TPC6) despite passing every benchmark first.

| offset | 1200 | 1350 | 1400 | 1470 | 1590 | 1650 |
|---|---|---|---|---|---|---|
| +200 | CLEAN | - | CLEAN | - | - | - |
| +250 | CLEAN | - | CLEAN | - | - | - |
| +300 | - | FAULT | FAULT | FAULT | - | FAULT |
| +350 | - | - | - | - | FAULT | FAULT |

Serving throughput at the qualified points (Qwen3.6-27B INT8, fp8 KV, MTP, concurrency 24):

| point | decode tok/s | prefill tok/s | watts | core C | HBM C | tok/s per W |
|---|---|---|---|---|---|---|
| +200/1200 @200W | 303.0 | 2,329 | 149 | 59 | 66 | 2.03 (peak efficiency) |
| +250/1200 @200W | 303.6 | 2,331 | 152 | 59 | 66 | 2.00 |
| +200/1400 @300W | 341.8 | 2,668 | 181 | 60 | 66 | 1.89 (peak throughput) |
| +250/1400 @300W | 342.9 | 2,669 | 178 | 62 | 67 | 1.93 |

+200 and +250 are equivalent within noise, and both ship. Note what the matrix says about
the risk lever: it is neither the offset nor the ceiling alone. +250 survives 1400 where
+300 dies, and +300 dies at low ceilings too. What matters is voltage-at-frequency, and
+300 crosses the line everywhere tested on this card. See
[mechanism.md](mechanism.md) for the model.

## SM offset x ceiling grid

Reading guide: bf16 TFLOPS / watts per cell; each cell is a sustained GEMM, repeated cells
averaged. A numeric cell is a completed run, nothing more; only the qualification matrix
above says what serves.

| ceiling | +0 | +150 | +200 | +250 | +300 | +325 | +350 | +355 | +360 | +375 | +400 | +450 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **1200** | - | - | - | 160.8 / 120.2W | 160.7 / 118.9W | - | 160.8 / 120.0W | - | - | - | 160.7 / 120.0W | - |
| **1250** | - | - | - | 166.7 / 124.0W | 166.8 / 124.9W | - | 166.8 / 125.0W | - | - | - | 166.8 / 123.6W | - |
| **1300** | - | - | - | 172.8 / 127.0W | 172.8 / 127.3W | - | 172.8 / 127.4W | - | - | - | 172.8 / 128.2W | - |
| **1350** | - | 180.2 / 146.0W | 180.3 / 140.9W | 180.1 / 134.7W | 180.7 / 131.3W | - | 180.7 / 131.5W | - | - | - | 181/132W corrupt* | 180.8 / 132.4W |
| **1400** | 186.7 / 197.6W | 185.5 / 154.3W | 186.5 / 150.2W | 186.5 / 143.3W | 186.6 / 136.3W | 187/133W CORRUPT | 186.7 / 134.3W | - | - | fault | - | - |
| **1470** | - | - | - | 196.1 / 161.8W | 195.9 / 149.2W | - | 196.1 / 148.7W | - | - | - | - | - |
| **1530** | - | - | - | 204.1 / 180.9W | 204.5 / 168.1W | - | 204.3 / 163.0W | - | - | - | - | - |
| **1590** | - | - | - | 205.7 / 189.6W | 210.8 / 184.7W | - | 211.8 / 177.1W | - | - | - | HANG | - |
| **1620** | - | - | - | - | 210.8 / 187.4W | - | - | - | - | - | - | - |
| **1650** | - | - | - | 204.8 / 191.9W | 209.3 / 186.3W | - | 214.7 / 186.8W | 215/181W fault | 217/182W fault | 219/182W fault | 210.7 / 179.1W | - |
| **1700** | - | - | - | - | - | - | 213.2 / 185.8W | - | - | HANG | - | - |
| **1740** | - | - | - | - | - | - | 213.8 / 187.5W | - | - | - | - | - |

## GFLOPS/W grid

Reading guide: the grid above divided out; the efficiency landscape.

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

### Legend, and the cells that are deliberately empty

- **CORRUPT**: completes, but the full-VRAM sweep returns memory errors (silent data
  corruption).
- **corrupt***: +400/1350 passed two sweeps, then returned `mem_errors=1` on a later one.
  Two clean sweeps is not a gate for an intermittent failure mode.
- **fault**: CUDA device fault under load (`illegal instruction`, `illegal memory access`,
  cublas 14).
- **HANG**: GPU wedged, needs a reboot (and sometimes a power cycle).
- +400 at 1400 / 1470 / 1530 is untested on purpose: +400/1380 faults and +400/1590 hangs,
  so that corner costs a reboot per probe with no plausible upside.
- Low offsets at high ceilings (+150, +200 above 1400) are omitted: strictly worse than
  +250 at the same clock (more voltage for the same work).
- 1200-1300 above +400 is omitted: power is already flat there, so extra offset is inert.

### What the grids show

1. **Two regimes.** Below ~1350 the rail bottoms out and power goes flat (1200:
   118.9-120.2 W across +250..+400). Above ~1400 the corruption cliff arrives before the
   floor does.
2. **Efficiency peaks in a broad plateau at 1350-1400** (1369-1390 GFLOPS/W) and falls off
   in both directions: 1067 at 1650/+250, 1234 at 1350/+150.
3. **The clock ceiling above 1650 is silicon-capped**: 1700 and 1740 both deliver
   ~1600 MHz and 213-214 TF, no better than 1650. The silicon ceiling is ~1604-1614 MHz at
   +350.
4. **Non-monotonic at the top**: 1650/+400 runs (slower, clock-stretching) while 1590/+400
   hangs and 1650/+375 faults. Past the wall the behavior stops being orderly, which is one
   more reason to sit well below it.

Additional measured boundaries, for completeness: +355 at 1650 buys nothing over +350 and
faults by the third run; +375 at 1650 produced the card's best single result (219.3 TF)
then faulted on a repeat, with a memory error on the following sweep; +375 at a 1700
ceiling hangs the GPU; +450 hard-crashes it (recovery is a power cycle; a warm reboot is
not always enough). The offset edge under a live power cap is in
[power-cap-curve.md](power-cap-curve.md).

## Named profiles (bench points)

Reading guide: the profiles `170tune apply` / `170hx-oc` install, measured on a sustained
bf16 GEMM. Every row passed the full-VRAM pattern sweep at least twice. These are
benchmark operating points: only the rows at +200/+250-class offsets align with the serving
qualification matrix; **eff, balanced, perf, and max sit at +300/+350 and are bench-only**
(they pass benchmarks and fault under a serving soak).

| profile | offset | clk ceiling | bf16 TFLOPS | draw | GFLOPS/W | standing |
|---|---|---|---|---|---|---|
| stock | +0 | none | 184.3 | 199.2 W | 925 | baseline |
| dense | +250 | 1200 | 160.8 | 120.2 W | 1337 | serving-qualified offset |
| eff | +300 | 1350 | 180.8 | 131.2 W | 1378 | bench-only |
| match | +250 | 1400 | 186.5 | 142.2 W | 1311 | serving-qualified offset |
| balanced | +300 | 1470 | 196.2 | 149.7 W | 1311 | bench-only |
| perf | +350 | 1590 | 212.2 | 181.2 W | 1171 | bench-only |
| max | +350 | 1650 | 215.3 | 186.1 W | 1157 | bench-only |

Note on `match` wattage: the profile table records 142.2 W and the grid cell for +250/1400
reads 143.3 W. Both are run-to-run averages of the same point (per-point CSV rows read
144.4, 143.2, 142.2 W); the ~1 W spread is variance, not a second measurement.

## Memory bandwidth and latency per SM profile

Reading guide: memory behavior at the STOCK 1728 MHz memory clock across SM profiles; the
SM offset and ceiling do not move the memory clock. The eff and max rows stand as
measurements of those clock points even though those profiles are bench-only.

| profile | read (24 GiB) | bench triad | dependent-load latency |
|---|---|---|---|
| stock | 1693.9 GB/s | 1589.6 GB/s | 276.3 ns |
| eff (+300/1350) | 1685.9 GB/s | 1599.3 GB/s | 296.1 ns |
| match (+250/1400) | 1690.2 GB/s | 1597.6 GB/s | 288.3 ns |
| max (+350/1650) | 1698.2 GB/s | 1584.8 GB/s | 253.2 ns |

Streaming bandwidth is essentially independent of the SM profile: the whole spread is
under 1 percent, and triad (read+write, the better decode proxy) peaks near match. Memory
LATENCY is not independent: 253 ns at max against 296 ns at eff, a 17 percent spread,
because the request path runs at core clock while the DRAM does not. Bandwidth-bound work
can take a low-power profile for free; latency-bound work (dependent-chain access, sparse
gather, graph traversal) pays real money for a high clock. Delivery is 95-96 percent of
the 1769 GB/s theoretical peak; the remainder is protocol overhead, not a setting.

## HBM NDIV bandwidth grid

Reading guide: bandwidth per memory clock, measured hot in one `170tune hbm-matrix 64 2 76`
sweep (HBM 60-71 C, shown per row). The stock NDIV 64 row is fully stock (REFRESH 6);
every OC row is measured at REFRESH 24, the shipped opt-in setting. The GATE column is the
memory-only pattern sweep, not a serving qualification: the serving ceiling is NDIV 70
(see [HBM serving outcomes](#hbm-serving-outcomes) below and the ceiling model in
[hbm-timing-understanding.md](hbm-timing-understanding.md)).

Columns: PEAK = theoretical GB/s at that clock (MHz x 4096-bit x 2 / 8); READ = delivered
peak streaming read (`mem_probe`); %PK = READ over PEAK; TRIAD / COPY / D2D = STREAM
kernels (`nvidia_bench`; triad = 2 reads + 1 write, the closest decode proxy; D2D = real
`cudaMemcpy`); LAT = dependent-load latency (pointer chase over 8 GiB); PWR = mean board
draw during the read load; MEM C = HBM temperature the row was taken at; dSTOCK = READ vs
the fully stock row; MOVED = READ exceeds the stock 1769 GB/s theoretical wall, the
physical proof the clock rose (`nvidia-smi` reports 1728 MHz at every NDIV); GATE =
`170tune mclk-gate <N> 12` (12 hot full-VRAM pattern sweeps plus a bit-exact compute
check, stock timings).

| NDIV | MHz | PEAK | READ | %PK | TRIAD | COPY | D2D | LAT ns | PWR W | GB/s/W | MEM C | dSTOCK | MOVED | GATE |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 (stock) | 1728 | 1769 | 1687 | 95.4 | 1610 | 1520 | 1584 | 276 | 65 | 26.1 | 60 | baseline | - | (baseline) |
| 66 | 1782 | 1825 | 1757 | 96.3 | 1669 | 1613 | 1655 | 272 | 67 | 26.4 | 63 | +4.1% | - | pass |
| 68 | 1836 | 1880 | 1808 | 96.1 | 1724 | 1671 | 1708 | 273 | 67 | 27.0 | 64 | +7.1% | yes | pass |
| 70 | 1890 | 1935 | 1859 | 96.0 | 1779 | 1722 | 1759 | 271 | 70 | 26.6 | 66 | +10.2% | yes | GATED 12/12 |
| 72 | 1944 | 1991 | 1909 | 95.9 | 1818 | 1769 | 1808 | 270 | 74 | 25.9 | 68 | +13.2% | yes | GATED 12/12 |
| 74 | 1998 | 2046 | 1958 | 95.7 | 1885 | 1821 | 1859 | 268 | 76 | 25.7 | 70 | +16.1% | yes | GATED 12/12 |
| 76 | 2052 | 2101 | 2006 | 95.5 | 1930 | 1873 | 1911 | 267 | 80 | 25.2 | 71 | +18.9% | yes | GATED 12/12 |
| 77 | 2079 | 2129 | - | - | ~1935 | - | - | - | - | - | - | - | - | retention-marginal |
| 78 | 2106 | 2156 | - | - | ~1966 | - | - | - | - | - | - | - | - | REJECTED (eye wall) |

Notes on the grid:

- 77 and 78 are not bandwidth-swept: bare NDIV 77 hard-hangs the controller (a row timing
  crosses its floor), so the matrix stops at 76. Their triad figures are from the separate
  command-loosened ceiling hunt.
- vs the fully stock baseline, NDIV 76 (at REFRESH 24) delivers read +18.9%, triad +19.9%,
  copy +23.2%, D2D +20.6%, latency -3.3%. Every bandwidth kernel climbs monotonically,
  tracking the clock almost 1:1; read holds ~96% of theoretical peak at every OC NDIV,
  a genuinely DRAM-bound result, not a cache artifact. The stock row reads slightly lower
  (95.4%) because it runs stock refresh, which costs a few percent bandwidth.
- Read is thermally sensitive and droops as HBM heats; the MEM C column is the temperature
  each row was taken at, so reads are comparable only within the band shown.
- A "-" in MOVED at NDIV 66 is not "did not move": the clock rose, the read just has not
  yet cleared the stock theoretical ceiling.
- Read/watt is roughly flat at 26-27 across the range, dipping to 25.2 at 76: there is no
  efficiency knee on the bandwidth curve alone. The serving ceiling, not efficiency, is
  what bounds the useful range.

Regenerate on any card with `170tune hbm-matrix` (writes a per-serial CSV).

## HBM serving outcomes

Reading guide: what the pattern-gated NDIV points did under a real inference workload
(Qwen3.6-27B INT8, MTP, vLLM, single-stream decode 256/256). This table is why the serving
ceiling is NDIV 70, two steps below the pattern-sweep ceiling.

| config | decode over 3-4 sustained runs | outcome |
|---|---|---|
| stock NDIV 64 | 38.9 -> 36.6 -> 32.6 -> 38.3 tok/s (recovers) | throttles, self-heals |
| NDIV 72, uncooled | 29 -> 21 -> 20 tok/s, HBM 80 -> 87 -> 91 C | corrupts, then wedges |
| NDIV 72, fan maxed | 37.9 -> 30.5 -> 28.7 -> 25.8 tok/s, HBM 67 -> 80 C | corrupts (no wedge) |
| NDIV 76, cool start | 22 tok/s plus 4 Xids on the first load at 56 C | unservable (eye wall, not heat) |

The tell is the shape: stock dips and recovers (thermal throttle, self-healing); the OC
declines monotonically and never recovers, which is silent corruption feeding speculative-
decode rejections. Even fully cooled, NDIV 72 at 67 C matched stock's 37.9 tok/s: single-
stream decode of a 27B INT8 model is only ~40 percent weight-bandwidth-bound, so +19
percent HBM read is invisible there. A maxed fan could not hold HBM below ~75 C under
100 percent duty; real serving is burstier, which is why NDIV 70 with a fan driven by HBM
temperature holds.

## Refresh lever

Reading guide: the refresh interval as a power lever, measured at NDIV 76, HBM 62-64 C, 8
hot pattern sweeps per row. Interval_us = field x 1024 / mclk_MHz; stock field 6 is
~3.9 us at 1728 MHz. The model and the temperature caveat are in
[hbm-timing-understanding.md](hbm-timing-understanding.md#7-the-refresh-axis-retention-power-bandwidth).

| REFRESH field | interval | latency ns | triad GB/s | idle W | load W | gate |
|---|---|---|---|---|---|---|
| 6 (stock) | ~3 us | 342.7 | 1921 | 41.0 | 78.7 | 8/8 |
| 16 | ~8 us | - | - | 36.0 | 73.3 | 8/8 |
| 24 (ship, opt-in) | ~12 us | 343.5 | 1927 | 34.9 | 67.7 | 8/8 |
| 96 | ~48 us | 340.6 | 1930 | - | 66.4 | 8/8 |
| 384 | ~192 us (~49x JEDEC) | 340.4 | 1935 | - | 69.7 | 8/8 |
| 768 | ~383 us | - | - | - | - | WEDGED |

Notes:

- Loosening cut idle power 41 -> 35 W (-15%) and steady load ~56 -> 49-50 W (-11 to -14%)
  at every NDIV tested, with latency flat-to-slightly-better and bandwidth flat.
- Under a serving load (stock clock, so no eye confound) the same loosening is worth only
  ~2.5% of board power (206 W vs 201 W, bracketed to remove thermal drift), because compute
  dominates the total; even REFRESH 192 (~30x JEDEC) showed zero corruption at stock clock.
  Refresh is an idle and resting-power lever, not a serving lever.
- All retention data is from 62-70 C; JEDEC halves the interval above 85 C. Keep stock
  refresh for hot or unknown thermals, and gate any loosening with a write / hold /
  read-back test (`170tune refresh gate`).

## Idle and resting power

Reading guide: measured on a serving box after a clean reboot, +200/1200 at a 200 W cap.

| state | SM clock | mem clock | draw |
|---|---|---|---|
| inference server resident, 0% load | 1140 MHz | 1728 MHz | 40.2 W |
| true idle, no CUDA context | 405 MHz | 1728 MHz | 36.9 W |

Holding a 36 GB model resident costs 3.3 W; that is the entire saving available from
unloading it between requests, against a 4-5 minute cold start on the next one. The SM
side idles correctly on its own (405 MHz bare, 1140 MHz with a context), which is what the
`-lgc 210,<max>` ceiling form preserves; a `<max>,<max>` lock would forfeit it. The
remaining ~37 W is dominated by HBM refresh, which is why the
[refresh lever](#refresh-lever) is the tool that targets idle power, not an underclock.
Idle fan on the reference card is 1909 rpm against roughly 2700 under load, so a resting
card is close to silent.
