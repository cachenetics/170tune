# CMP 170HX tuning guide

How to run an NVIDIA CMP 170HX well, and a record of what is closed and why so no
dead end gets walked twice.

Reference card: serial 1322621047793 (GA100, 70 SM, 64 GB HBM2e unlocked, driver
610.43.03, stock 300W VBIOS 92.00.6D.00.0A, PCIe Gen2 x4), on a single-card test host. All tuning
numbers below were measured on this card unless stated otherwise. Per-card silicon
varies; see "Qualifying a new card" before you trust any offset on a different serial.

This is the distilled SM tuning record: the core OC story and the full offset x clock-ceiling
matrix, consolidated into one shippable guide. The per-experiment raw analysis it draws on lives in
the separate cmp170hx research repo. For the HBM side see
[`hbm-matrix.md`](hbm-matrix.md) and [`hbm-timing-understanding.md`](hbm-timing-understanding.md).

---

## 1. What this card is, in measured numbers

```
+-------------------------------------------+-----------------------------------------------+
| Property                                  | Value                                         |
+-------------------------------------------+-----------------------------------------------+
| GPU                                       | GA100, 70 SM                                  |
| Memory                                    | 64 GB HBM2e, 4096-bit bus, stock 1728 MHz     |
| Link                                      | PCIe Gen2 x4                                  |
| Driver / VBIOS                            | 610.43.03 / 92.00.6D.00.0A (stock 300 W)      |
| bf16 tensor-core GEMM, stock              | 184.3 TFLOPS at 199.2 W (925 GFLOPS/W)        |
| bf16 tensor-core GEMM, tuned peak         | 215.3 TFLOPS at 186.1 W (max profile, gated)  |
| HBM read bandwidth (24 GiB stream), stock | 1679.1 GB/s                                   |
| HBM read bandwidth, tuned peak            | 1699.3 GB/s (max profile)                     |
| Theoretical HBM peak at 1728 MHz          | 1769 GB/s (measured delivery is 95-96% of it) |
| ECC                                       | N/A on this SKU (no ECC-off lever exists)     |
+-------------------------------------------+-----------------------------------------------+
```

Compute-datatype note: every TFLOPS figure in the tuning tables is a sustained bf16
tensor-core GEMM (`tools/oc_eff.cu`, n=8192, 10-15 s soak, NVML power sampled
in-process). The other datatypes were measured separately at stock clocks with
`tools/gemm_probe.cu` (n=8192, 30 iterations) and are listed below for reference only;
they were not swept across profiles, so do not scale them by the bf16 ratios.

```
+-----------------------------------+---------------+
| datatype (stock clocks)           | TFLOPS        |
+-----------------------------------+---------------+
| bf16 tensor core, fp32 accumulate | 188.1 - 192.7 |
| fp16 tensor core, fp32 accumulate | 158.7 - 160.0 |
| tf32 tensor core                  | 88.9 - 91.9   |
| fp32, no tensor core              | 12.76         |
+-----------------------------------+---------------+
```

Two probe gotchas worth carrying forward: `CUBLAS_COMPUTE_16F` with a `float` alpha/beta
pointer returns instantly and reports an absurd 10748 TFLOPS, which is a no-op and not a
result - use the 32f-accumulate rows. And CUDA 13 removed `cudaDeviceProp::clockRate` and
`memoryClockRate`; use `cudaDeviceGetAttribute` with `cudaDevAttrClockRate` /
`cudaDevAttrMemoryClockRate` instead.

---

## 2. The tuning primitive

### What the offset actually does

The one lever on this card is the GPC clock VF offset, applied through NVML
(`nvmlDeviceSetGpcClkVfOffset`). `nvidia-smi` on this driver exposes only the negative
direction (`--set-vf-derate`), which is why OC looks unavailable; NVML exports the full
API and on this card the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [   0 ..     0] MHz     <- refused by the driver
```

The offset is an undervolt expressed as a frequency offset. `+X` shifts the
voltage/frequency curve so that at every voltage point the clock is X MHz higher, which
is the same statement as "a given clock is now reached at a lower voltage". Pin the
clock so frequency is held constant and the saving shows up directly as watts:

```
+-----------------+-----------+-------------+--------+----------------------+
| pinned SM clock | offset +0 | offset +300 | delta  | bf16 (unchanged)     |
+-----------------+-----------+-------------+--------+----------------------+
| 1200 MHz        | 130.6 W   | 120.6 W     | -7.7%  | 160.4 / 160.6 TFLOPS |
| 1350 MHz        | 174.6 W   | 132.0 W     | -24.4% | 179.7 / 180.7 TFLOPS |
+-----------------+-----------+-------------+--------+----------------------+
```

Same clock, same work, less power. The saving grows with frequency because power tracks
V^2*f and the stock curve climbs steeply in voltage near the top. This SKU reports no
voltage telemetry (`nvidia-smi -q -d VOLTAGE` is empty), so watts-at-fixed-clock is the
proxy, and it is unambiguous.

### Why the clock ceiling is the right second lever

The offset alone does not buy efficiency; it only lets the clock arbiter climb higher.
You must also pin where it lands. Two ways to pin, measured:

- Cap POWER (`-pl`): works, but the clock oscillates around the cap. Measured 198.0 TF
  at 159.7 W mean / 163.8 W peak = 1240 GFLOPS/W.
- Cap the CLOCK (`-lgc 210,<max>`): holds one voltage point and measures better
  everywhere. Measured at a 1470 ceiling: 196.3 TF at 152.7 W = 1286 GFLOPS/W.

Capping the clock wins, so every shipped profile sets the offset, leaves the power limit
wide open at 300 W, and pins a clock ceiling. The ceiling is set as `210,<max>` (not
`<max>,<max>`) so the card still idles down to 210 MHz / ~40-54 W when unused; a bare
`<max>,<max>` lock would block idle downclocking.

Also relevant: the card never draws its 250 W cap on this workload. It is VF-limited near
190-200 W, which is why raising the cap to 300 W changed nothing on its own. Voltage, not
the power cap, is the constraint the offset relaxes.

Effective clocks under offset (VBIOS table max graphics clock is 1695 MHz):

```
+------------+----------------------------------------------------+
| offset     | sustained effective SM clock                       |
+------------+----------------------------------------------------+
| +0 (stock) | ~1425 MHz                                          |
| +150       | ~1571 MHz                                          |
| +300       | ~1647 MHz (just under the advertised 1695 ceiling) |
+------------+----------------------------------------------------+
```

---

## 3. Shipped profiles

All applied by `/usr/local/bin/170hx-oc <profile>`. Every row passed the full-VRAM
pattern sweep with `mem_errors=0` at least twice; these are the only settings that
carry the integrity gate.

```
+---------------+--------+-------------+-------------+---------+----------+
| profile       | offset | clk ceiling | bf16 TFLOPS | draw    | GFLOPS/W |
+---------------+--------+-------------+-------------+---------+----------+
| stock         | +0     | none        | 184.3       | 199.2 W | 925      |
| dense         | +250   | 1200        | 160.8       | 120.2 W | 1337     |
| eff (default) | +300   | 1350        | 180.8       | 131.2 W | 1378     |
| match         | +250   | 1400        | 186.5       | 142.2 W | 1311     |
| balanced      | +300   | 1470        | 196.2       | 149.7 W | 1311     |
| perf          | +350   | 1590        | 212.2       | 181.2 W | 1171     |
| max           | +350   | 1650        | 215.3       | 186.1 W | 1157     |
+---------------+--------+-------------+-------------+---------+----------+
```

```
+---------------+--------------------------+---------------------------------------------+
| profile       | vs stock                 | use for                                     |
+---------------+--------------------------+---------------------------------------------+
| dense         | -13% perf, -40% power    | max cards per rail; power-capped racks      |
| eff (default) | -2% perf, -34% power     | best efficiency; the safe everyday setting  |
| match         | stock perf, -29% power   | stock throughput at much lower power        |
| balanced      | +6% perf, -25% power     | more throughput, still well under 200 W     |
| perf          | +15% perf, -9% power     | throughput-first, still under stock power   |
| max           | +17% perf at stock power | peak validated throughput                   |
+---------------+--------------------------+---------------------------------------------+
```

Note on `match` wattage: this profile table (from the shipped applier) records 142.2 W;
the raw matrix cell for +250/1400 shows 143.3 W. Both are run-to-run averages of the
same point (per-point CSV rows at +250/1400 read 144.4, 143.2, 142.2 W); the ~1 W spread
is variance, not a second measurement. Switch profiles with `sudo 170hx-oc perf`
(immediate) or by editing the systemd unit's `ExecStart`.

---

## 4. Safety: the cliff, the floor, and the gate

### The rule that dominates everything

A settings cell that shows numbers means the run completed without a fault. It does NOT
mean the point is safe. `+325 / 1400` completes happily and silently corrupts memory.
Only the shipped profiles in section 3 carry the integrity gate (2-4 full-VRAM pattern
sweeps). Anything in the matrix in section 5 that is not a shipped profile is unverified.

Never accept an operating point on "it did not crash". Gate it on the full-VRAM pattern
sweep, and run the sweep more than once. Two clean sweeps is not a gate for an
intermittent failure mode; use four, and when two settings measure equal, take the one
with more margin.

### The corruption cliff (the most important result)

At a fixed clock, more offset means less voltage, and past a point the data path corrupts
without crashing. Measured at a 1400 MHz ceiling with the full-VRAM pattern sweep as the
gate:

```
+--------+---------+----------------------------------------+
| offset | draw    | pattern sweeps                         |
+--------+---------+----------------------------------------+
| +250   | 142.2 W | 3 sweeps, 0 memory errors              |
| +300   | 138.5 W | 4 sweeps, 0 memory errors              |
| +325   | 132.7 W | 3 sweeps: 6 errors, 3 errors, 0 errors |
| +375   | -       | CUDA device fault under load           |
+--------+---------+----------------------------------------+
```

The safe window at 1400 is one 25 MHz step wide above +300, and on the far side the
failure mode is bad data, not a crash: intermittent, and invisible to any stability test
that only asks whether the kernel finished.

### The voltage floor (why `eff` ships at +250, not higher)

Does a lower ceiling tolerate a bigger offset? Yes, and past a point the rail bottoms out
and power goes flat. Measured at a 1350 ceiling:

```
+--------+---------+---------+---------+---------+---------+---------+---------+
| offset | +150    | +200    | +250    | +300    | +350    | +400    | +450    |
+--------+---------+---------+---------+---------+---------+---------+---------+
| draw   | 146.0 W | 140.9 W | 132.4 W | 131.3 W | 132.1 W | 131.5 W | 132.5 W |
+--------+---------+---------+---------+---------+---------+---------+---------+
```

The floor starts at about +250 and everything above it draws the same wattage. So ship
the lowest offset that reaches the floor, not the highest that appears to work. This was
learned the hard way in-session: `eff` was shipped at +400/1350 on the strength of two
clean sweeps and a later sweep came back `mem_errors=1`. +250 buys the identical ~132 W
with roughly 150 MHz of margin and passed a 4-sweep gate clean. There is no better floor
point between 1350 and 1400: +400/1380 and +375/1395 both fault on the first run, so the
safe-offset boundary collapses quickly above a 1350 ceiling.

At the high-clock profiles (`perf`, `max`) RM selects a higher voltage, so +350 is
comfortable there: 0 errors across 2 sweeps each at 1590 and 1650, plus a full selftest
PASS at 1650.

### Fault and hang boundaries (measured, do not exceed)

- +350 MHz is the highest offset validated clean, and only at the high-clock profiles.
- +355 at 1650 buys nothing (same throughput as +350) and still faults by the third run
  (`illegal instruction`).
- +360 and +375 at 1650 fault within one or two runs (`illegal memory access`); +375
  produced this card's best single result (219.3 TF) then faulted on a repeat, with one
  memory error on the following sweep.
- +325 at 1400 corrupts memory intermittently (see the cliff).
- +375 / +400 take CUDA device faults under load (`illegal instruction`,
  `misaligned address`).
- +375 at a 1700 ceiling hangs the GPU (`GPU requires reset`, power cycle).
- +450 MHz hard-crashes the GPU (`GPU requires reset`); recovery is a power cycle and a
  warm reboot is not always enough.

Why +400 "runs" while +375 faults: it is not safer, it is slower. Ampere's NAFLL has
droop detection and stretches the clock when voltage is inadequate. At +400 the requested
VF point is far enough past the curve that the stretcher engages continuously (clock reads
1650 but delivered work drops 4% below +375). Between roughly +355 and +390 the part runs
at the full requested speed with too little margin, which is where the intermittent faults
live. Running slower is the hardware protecting itself, not headroom.

---

## 5. The complete measurement matrix

Card 1322621047793. Each cell is a sustained bf16 tensor-core GEMM (`tools/oc_eff.cu`,
n=8192) with power sampled in-process through NVML; repeated cells are averaged. Raw
rows: `analysis/oc_tune_sweep.csv`.

Reminder: a numeric cell means the run completed, NOT that the point is safe. Only the
section-3 profiles are gated.

### The grid over the shipped offset range

```
+---------+---------------+---------------+---------------+
| ceiling | +250          | +300          | +350          |
+---------+---------------+---------------+---------------+
| 1200    | 160.8 / 120 W | 160.7 / 119 W | 160.8 / 120 W |
| 1250    | 166.7 / 124 W | 166.8 / 125 W | 166.8 / 125 W |
| 1300    | 172.8 / 127 W | 172.8 / 127 W | 172.8 / 127 W |
| 1350    | 180.1 / 135 W | 180.7 / 131 W | 180.7 / 131 W |
| 1400    | 186.5 / 143 W | 186.6 / 136 W | 186.7 / 134 W |
| 1470    | 196.1 / 162 W | 195.9 / 149 W | 196.1 / 149 W |
| 1530    | 204.1 / 181 W | 204.5 / 168 W | 204.3 / 163 W |
| 1590    | 205.7 / 190 W | 210.8 / 185 W | 211.8 / 177 W |
| 1620    | -             | 210.8 / 187 W | -             |
| 1650    | 204.8 / 192 W | 209.3 / 186 W | 214.7 / 187 W |
| 1700    | -             | -             | 213.2 / 186 W |
| 1740    | -             | -             | 213.8 / 188 W |
+---------+---------------+---------------+---------------+
```

### Offset ladders at the two ceilings that define the limits

1350 shows the voltage floor (power goes flat from +250). 1400 shows the corruption cliff.

```
+---------+--------+---------+-------+----------+-----------+
| ceiling | offset | bf16 TF | draw  | GFLOPS/W | status    |
+---------+--------+---------+-------+----------+-----------+
| 1350    | +150   | 180.2   | 146 W | 1234     | clean run |
| 1350    | +200   | 180.3   | 141 W | 1280     | clean run |
| 1350    | +250   | 180.1   | 135 W | 1337     | clean run |
| 1350    | +300   | 180.7   | 131 W | 1376     | clean run |
| 1350    | +350   | 180.7   | 131 W | 1375     | clean run |
| 1350    | +400   | 180.7   | 132 W | 1369     | corrupt*  |
| 1350    | +450   | 180.8   | 132 W | 1365     | clean run |
| 1400    | +0     | 186.7   | 198 W | 945      | clean run |
| 1400    | +150   | 185.5   | 154 W | 1202     | clean run |
| 1400    | +200   | 186.5   | 150 W | 1241     | clean run |
| 1400    | +250   | 186.5   | 143 W | 1302     | clean run |
| 1400    | +300   | 186.6   | 136 W | 1369     | clean run |
| 1400    | +325   | 186.7   | 135 W | 1386     | CORRUPT   |
| 1400    | +350   | 186.7   | 134 W | 1390     | clean run |
| 1400    | +375   | -       | -     | -        | fault     |
+---------+--------+---------+-------+----------+-----------+
```

### Edge probes at the top of the curve

```
+---------+--------+---------+-------+-----------+
| ceiling | offset | bf16 TF | draw  | status    |
+---------+--------+---------+-------+-----------+
| 1650    | +250   | 204.8   | 192 W | clean run |
| 1650    | +300   | 209.3   | 186 W | clean run |
| 1650    | +350   | 214.7   | 187 W | clean run |
| 1650    | +355   | 215.0   | 183 W | fault     |
| 1650    | +360   | 217.3   | 182 W | fault     |
| 1650    | +375   | 219.3   | 182 W | fault     |
| 1650    | +400   | 210.7   | 179 W | clean run |
| 1590    | +400   | -       | -     | HANG      |
| 1700    | +350   | 213.2   | 186 W | clean run |
| 1700    | +375   | -       | -     | HANG      |
| 1740    | +350   | 213.8   | 188 W | clean run |
+---------+--------+---------+-------+-----------+
```

### Legend and deliberately empty cells

- CORRUPT: completes, but the full-VRAM sweep returns memory errors (silent corruption).
- corrupt*: +400/1350 passed two sweeps, then returned `mem_errors=1` on a later one.
  This is why the shipped `eff` sits at +300/1350 rather than higher: it draws the same ~131 W as
anything above it on the flat floor, with margin below the point that misbehaved.
- fault: CUDA device fault under load (`illegal instruction`, `illegal memory access`,
  cublas 14).
- HANG: GPU wedged, needs a reboot (and sometimes a power cycle).
- +400 at 1400 / 1470 / 1530 is not tested on purpose: +400/1380 faults and +400/1590
  hangs, so that corner costs a reboot per probe with no plausible upside.
- Low offsets at high ceilings (+150, +200 above 1400) are omitted: strictly worse than
  +250 at the same clock (more voltage for the same work).
- 1200-1300 above +400 is omitted: power is already flat there, so extra offset is inert.

### What the matrix shows

1. Two regimes. Below ~1350 the rail bottoms out and power goes flat (1200: 118.9-120.2 W
   across +250..+400). Above ~1400 the corruption cliff arrives before the floor does.
2. Efficiency peaks in a broad plateau at 1350-1400 (1369-1390 GFLOPS/W) and falls off in
   both directions: 1067 at 1650/+250, 1234 at 1350/+150.
3. The clock ceiling above 1650 is silicon-capped: 1700 and 1740 both deliver ~1600 MHz
   and 213-214 TF, no better than 1650. The silicon ceiling is ~1604-1614 MHz at +350.
4. Non-monotonic at the top: 1650/+400 runs (slower, clock-stretching) while 1590/+400
   hangs and 1650/+375 faults. Past the wall the behaviour stops being orderly, which is
   another reason to sit well below it.

---

## 6. Memory

### Delivered bandwidth per profile (stock 1728 MHz memory)

```
+----------------------+----------------+-------------+-----------------------+
| profile              | read (24 GiB)  | bench triad | dependent-load latency|
+----------------------+----------------+-------------+-----------------------+
| stock                | 1693.9 GB/s    | 1589.6 GB/s | 276.3 ns              |
| eff (+300/1350)      | 1685.9 GB/s    | 1599.3 GB/s | 296.1 ns              |
| match (+250/1400)    | 1690.2 GB/s    | 1597.6 GB/s | 288.3 ns              |
| max (+350/1650)      | 1698.2 GB/s    | 1584.8 GB/s | 253.2 ns              |
+----------------------+----------------+-------------+-----------------------+
```

Streaming bandwidth is essentially independent of the core profile: the whole spread is under
1%, and `eff` actually leads on triad. What the core clock does move is **memory latency**, and
it moves it a lot: 253 ns at `max` against 296 ns at `eff`, a 17% spread, because the request
path runs at core clock while the DRAM does not.

So the profile choice for a memory-heavy workload depends on which one it is bound by:

* bandwidth-bound (large-batch decode streaming weights): any profile, they are within 1%. Take
  `eff` and keep the 68 W.
* latency-bound (small-batch or dependent-chain work, sparse gather, graph traversal): the
  high-clock profiles are worth real money, up to 17% lower latency at `max`.

### Memory overclock: RETRACTED - it is not closed, it is live (corrected 2026-08-03)

Earlier revisions of this section claimed the driver's `MEM clock VF offset` refusal
(`[0 .. 0]`, still true - the NVML path really is closed) meant memory overclock itself was
closed by measurement, including up-clocking. **That conclusion is retracted.** The NVML path is
the wrong write. The memory clock has its own PLL, reachable directly over BAR0 (`hbm_mclk`,
`0x009a3c7c` etc. - see the credited work in the repo README's Attribution section), and it moves
in both directions, live, with no driver rebuild and no reboot:

- The write must land **post-GSP** (after `kgspStartLogPolling` - a pre-GSP write is
  reprogrammed by GSP's own devinit), must be **multicast** to all FBPAs (not unicast to one
  partition, which is what a naive read/write address gets you), and needs a **PRI fence and a
  PLL-lock poll** before the clock can be trusted. The earlier "up-clocking delivers nothing"
  finding was measuring the wrong write, not a real hardware clamp - once the write lands
  correctly the clock genuinely moves, proven by bandwidth exceeding the theoretical ceiling of
  the stock rate (impossible unless the clock rose - `nvidia-smi` cannot show this: its
  `clocks.current.memory` field is blind to this class of write and always reports stock).
- `nvidia-smi`'s own read (`clocks.current.memory` / `-lmc`) is still exactly as limited as this
  section originally said - it cannot lock a memory clock and it does not reflect a live BAR0
  write - but that is a limitation of `nvidia-smi`, not of the hardware.

The whole HBM model - the NDIV lever, why it is derived, the DRAM timings that bind past the bare
ceiling, the refresh power lever, and the three measured ceilings (76 robust / 77 thermal-marginal
/ 78 read-eye wall) - is now `170tune explain-hbm` and
[`../docs/hbm-matrix.md`](hbm-matrix.md), the canonical HBM reference. This section is left in
place, retracted rather than deleted, because the correction itself - "we had been measuring the
wrong write" - is worth keeping visible.

One real hazard this correction surfaces: a driver **compiled** with cmpunlocker's
`--mclk-ndiv` flag bakes a non-stock memory clock into devinit, which is a DIFFERENT mechanism
from the live BAR0 write above, and `nvidia-smi` DOES correctly reflect that one (it is the
driver's own belief about "current"). `170tune` will not tune on top of a driver in that state -
see the mclk misclassification guard in `170tune explain-hbm` / the repo README.

### Idle and resting power

Measured on a serving box after a clean reboot, office profile (+200/1200 @200W):

```
+---------------------------------+-----------+-----------+---------+
| state                           | sm clock  | mem clock | draw    |
+---------------------------------+-----------+-----------+---------+
| inference server resident, 0%   | 1140 MHz  | 1728 MHz  | 40.2 W  |
| true idle, no CUDA context      |  405 MHz  | 1728 MHz  | 36.9 W  |
+---------------------------------+-----------+-----------+---------+
```

Holding a 36 GB model resident costs **3.3 W**. That is the whole saving available from unloading
it between requests, against a 4 to 5 minute cold start on the next one.

The SM side idles correctly without help - 405 MHz bare, 1140 MHz with a context - which is what
the `-lgc 210,<max>` form preserves. Pin the ceiling with `<max>,<max>` instead and you lose it.

The remaining ~37 W is HBM refresh at a memory clock `nvidia-smi` reports as fixed. As the
correction above explains, that is `nvidia-smi`'s limitation, not the hardware's: the refresh
interval is itself a live BAR0 lever now (`170tune refresh`), and it is the one that actually
targets this idle/resting power, not the clock:

```
supported memory clocks (nvidia-smi)   1728 MHz  (exactly one - nvidia-smi cannot lock or read a
                                                    live BAR0 clock/refresh change; see explain-hbm)
MEM VF offset range (NVML)             [0 .. +0]  the driver refuses memory offsets via NVML
```

Measured on the HBM matrix work (see `docs/hbm-matrix.md`): loosening the refresh interval alone
cuts idle power ~41 -> 35 W (-15%) and steady load power ~11-14% at every NDIV tested, with
latency flat-to-better and no bandwidth cost - the retention margin at operating temperature is
large. That is now the recommended idle/power lever, not an underclock: `170tune refresh gate`
proves an interval hot on the target card, and `170tune persist save --timings "REFRESH <f>"`
ships it. See `170tune explain-hbm` for the full retention/power/bandwidth model and the
temperature caveat (retention margin shrinks with heat, so keep stock refresh for hot or
unknown-thermal deployments).

Idle fan on the reference card is 1909 rpm against roughly 2700 under load, so a resting card is
close to silent.

### Memory clock as a power lever, both directions (corrected)

An earlier revision of this section described underclocking the memory as a power lever that
"needs a patched kernel module and a reboot", available only downward. That description predates
the live BAR0 `hbm_mclk` tool this repo now ships (`170tune mclk-try`/`mclk-gate`), and is
superseded by it: NDIV moves live, in both directions, with no reboot and no module rebuild. The
underclock-for-power intuition (dropping memory clock on compute-bound work where HBM is
over-provisioned trades a little bandwidth for a little power) is still directionally reasonable,
but the production guidance in this repo is the opposite: raise NDIV to the gated ceiling (76 on
the reference card) for the small compute/latency win it buys "for free" (see
`docs/hbm-matrix.md`), and use the refresh lever above for power, since it costs measured
retention margin rather than measured bandwidth and is the better-characterized trade for a
decode-bound serving workload that wants every GB/s. Do not repeat the old underclock-for-power
measurement without re-gating it on the current tooling; the old numbers were taken against a
different (patched-module) mechanism and are not evidence about the live BAR0 path.

---

## 7. Persistence and multi-card safety (persist model corrected 2026-08-03)

Offsets, clock locks, and the HBM NDIV/timings/refresh writes are all volatile: lost on every
driver reload and reboot. An earlier revision of this section described a per-profile
`170hx-oc.service` unit (`ExecStart=170hx-oc eff`, `ExecStop=170hx-oc stock`) as the persistence
mechanism. **That unit is retired.** It only ever covered the SM profile, it could not express an
HBM point at all, and running it alongside the newer HBM persistence would have meant two units
racing to apply state at boot. Persistence is now unified in `170tune` itself:

```
170tune persist save --offset 200 --clk 1400      # an SM point (needs a passing gate receipt)
170tune persist save --profile eff                # or a named profile, resolved to numbers here
170tune persist save --ndiv 76                     # an HBM point, combine or use alone
170tune persist save --ndiv 76 --timings "REFRESH 24"   # HBM point + the refresh power lever
170tune persist enable                             # installs + enables 170tune-persist.service
170tune persist status                             # profile, service state, quarantine
```

One conf per serial (`/var/lib/170tune/persist/<serial>.conf`), one systemd unit
(`170tune-persist.service`, generated by `170tune` itself with the resolved tool paths baked in),
applied by `170tune boot-apply` after the driver is up - the box always boots stock, so a bad
profile is masked over ssh, never a brick. `persist save` for an SM point demands a gate receipt
from THIS card (not quarantined, at least 4 hot sweeps, current memory clock, `-f`/`--force`
overrides loudly); it also refuses outright if the driver's own memory clock is not genuinely
stock (see the mclk misclassification guard in `170tune explain-hbm`).

A box still running the old `170hx-oc.service` model is migrated automatically the next time
`170tune install` runs: it reads the old `/etc/170tune/profile`, resolves it to an offset/ceiling,
writes the new per-serial conf, disables the old unit FIRST and only then enables the new one (so
a boot is never covered by both), renames the old conf to `.migrated`, and prints exactly what it
did - never silently.

Multi-card guard, unchanged in spirit: `170hx-oc` (still the SM profile applier `apply` hands off
to for a live-now change) guards on both shipped 170HX device ids (0x20C2 8GB, 0x2082 10GB) and
loops over every GPU, because this class of host is often a qualification bench where cards are
swapped constantly. A non-170HX in a slot is skipped and logged, never touched. A persisted
profile also records the serial it was qualified on (`OC_SERIAL`), so plugging in a second 170HX
does not silently inherit the first card's unqualified overclock. Each application logs to the
journal with serial, offset and cap, for example:

```
170hx-oc: GPU 0 (1322621047793) profile=eff offset=+300 clk_max=1350 power_limit=300 W
```

---

## 8. Qualifying a NEW card

Per-card silicon varies. +300 is validated on serial 1322621047793 only; do not assume it
on another card. For the SM side:

1. `sudo 170tune install`, `sudo 170tune preflight`, `sudo 170tune snapshot-stock` once, on the
   new card/box (see the repo README's Setup section).
2. `sudo nvml_oc` - confirm the GPC range is not `[0..0]` (the card is unlocked).
3. `sudo 170hx-oc stock`, then `sudo oc_eff 10` for a baseline.
4. `sudo 170tune ladder <clk>` (or `170tune qualify`) to walk the offset up, gating each rung
   with the full-VRAM memory sweep and compute checksum - `170tune gate` does this for you; do
   not stop at "it ran".
5. Stop at the first step that shows a device fault, and back off one FULL step, not one bin.
6. Record the result under `/var/lib/170tune/results/<serial>/` (`170tune qualify` does this),
   then persist the point deliberately with `170tune persist save` (section 7 above).

For the HBM side, the equivalent flow is `170tune mclk-ladder` / `170tune mclk-gate`, covered in
full in `170tune explain-hbm` and `docs/hbm-matrix.md`.

The gate is the pattern sweep, not "it ran". A silent corruptor (see the cliff in
section 4) passes any test that only checks whether the kernel finished. Run 4 sweeps and
prefer margin over a number that looks equal on paper.

---

## 9. Tooling inventory

SM (this guide):

- `tools/nvml_oc.c` -> `/usr/local/bin/nvml_oc [-i idx] [gpcMHz] [memMHz] [devIdx]`: query/apply
  GPC and MEM VF offsets. The range query is the useful part (confirms unlock). `-i` reads a
  specific device on a multi-card host.
- `tools/oc_eff.cu`: sustained bf16 GEMM with in-process NVML power sampling ->
  TFLOPS, W, GFLOPS/W.
- `tools/170hx-oc`: the SM profile applier (`170tune apply` hands off to it); reads named
  profiles or a per-card `custom <off> <clk>` point.
- `tools/170hx-sweep` + `tools/gpu_selftest.cu`: the SM integrity gate - full-VRAM unique-pattern
  write/verify plus a compute checksum, the one result line `170tune gate` parses.
- `tools/compute_check.cu`: deterministic bf16 GEMM repeated and compared bit for bit; catches
  silent COMPUTE corruption the memory sweep cannot see.
- `tools/ctx_probe.cu`: the smallest proof the card is usable - create a context, allocate,
  launch, read back. Catches the wedge `nvidia-smi` cannot see (170tune `status`/`recover` and
  the HBM gate paths all call it).
- `tools/mem_probe.cu`, `tools/gemm_probe.cu`: standalone streaming-bandwidth/latency and cublas
  GEMM-throughput probes, used for the datatype table in section 1.
- `tools/170hx-soak`: repeats a workload for hours and fails on any new Xid - what actually
  decides whether a gated point can ship (see the soak findings in `docs/measurement-matrix.md`
  and this file's safety section).

HBM (see `170tune explain-hbm` and `docs/hbm-matrix.md` for the model these implement):

- `tools/hbm_mclk.c`: live BAR0 control of the FBPA PLL (NDIV) - the memory clock lever. Set,
  read, and the DDLL eye-recal escape hatch.
- `tools/fbpa_regs.c`: live BAR0 control of the DRAM CONFIG timings and the CONFIG4 refresh
  field. `dump`/`get`/`set`/`save`/`load`.
- `tools/nvidia_bench.cu`: HBM bandwidth/latency bench (read/copy/triad, pointer-chase latency),
  used by `170tune hbm-matrix` and the clock-moved proof in `mclk_verify` (bandwidth exceeding
  the stock theoretical wall is the only thing `nvidia-smi` cannot fake).

Boot/setup, all invoked through `170tune`, not run by hand:

- `170tune install` (thin shim: `./install.sh`): builds every tool above from source and
  installs them, this script, and `systemd/170tune-bootcheck.service`. Also runs the old-persist
  migration (section 7).
- `170tune preflight` / `170tune snapshot-stock`: read-only readiness checklist and the
  per-card stock-value snapshot, for standing this up on a card whose VBIOS differs from the
  reference card's hardcoded defaults.
- `install_persist_unit` (inside `170tune`, not a separate script): generates
  `/etc/systemd/system/170tune-persist.service` with the resolved tool paths baked in, so root
  running the unit at boot does not need `find_tool`'s `$HOME`-guessing fallback to work.

Retired: the earlier `170hx-oc.service` static unit (superseded by the unified persist above,
migrated automatically), and the kernel-module patch this section used to reference to prove the
memory-clock clamp by measurement - that finding was itself a wrong-write artifact, corrected in
section 6; the tooling above supersedes it entirely.

---

## 10. Background: FWSEC BAR0 aperture and the Gen3 line

This is context for the separate Gen3-unlock effort, not part of tuning, and none of it affects a
tuning result above. Full detail lives with the link-training work, not in this repo.

Every `0x14xx....` constant in the FWSEC falcon code is a BAR0 offset OR'd with the
aperture base `0x14000000`, not a Falcon-private address. So e.g. `0x14118F78` is BAR0
offset `0x118F78` inside the ordinary 16 MB BAR0 window, directly readable/writable from
the host in principle. Earlier readings that treated these as a separate "Falcon PRIV
bus" (the `PCIE_GEN_DOSSIER` and `lock_register_map` notes) were wrong about the address
space. Standing caveat: a host read of `0x118F78` returns `0xbadf1100`, so whether that
register is actually host-reachable outside FWSEC context is not yet fully probed. This
does not affect any tuning result above.
