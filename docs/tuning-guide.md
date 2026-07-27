# CMP 170HX tuning guide

How to run an NVIDIA CMP 170HX well, and a record of what is closed and why so no
dead end gets walked twice.

Reference card: serial 1322621047793 (GA100, 70 SM, 64 GB HBM2e unlocked, driver
610.43.03, stock 300W VBIOS 92.00.6D.00.0A, PCIe Gen2 x4), host "oberon". All tuning
numbers below were measured on this card unless stated otherwise. Per-card silicon
varies; see "Qualifying a new card" before you trust any offset on a different serial.

Consolidated from:
- `analysis/oc_efficiency_2026-07-27.md` (the core OC story)
- `analysis/oc_matrix.md` (the full offset x clock-ceiling matrix)
- `analysis/hbm_mclk_oc_measured_2026-07-27.md` (why memory OC is closed)
- `analysis/fwsec_bar0_aperture_correction_2026-07-26.md` (FWSEC BAR0 aperture; Gen3 line)

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
  This is why the shipped `eff` backed down to +250/1350, which draws the same ~132 W.
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

### Memory overclock is closed, and why

The MEM clock VF offset range is `[0 .. 0]`: the driver refuses it on this part. That was
independently confirmed by patching the kernel module and measuring
(`analysis/hbm_mclk_oc_measured_2026-07-27.md`). The findings:

- The PLL follows down but not up. Underclocking proves the knob is real and causal:
  NDIV 65 (-6.25% clock) delivered -6.8% bandwidth, and latency rose. Up-clocking
  delivers nothing: NDIV 70 (+4.9% request) measured the same bandwidth as stock, with no
  memory errors and no soft roll-off. The register accepts the new coefficient
  (0x00014601 for NDIV 70) with the PLL lock bit set, yet the DRAM clock does not move up.
  Zero gain with no errors and no roll-off is the signature of a hard clamp at the stock
  rate: the PLL fails to lock, or the DRAM clamps, above the trained rate.
- No Memory Clock Table in any of the 8 ROMs. The trained rate comes from FWSEC devinit
  at 1728 MHz at POST, not from a table you can edit.
- The PTRIM lead is refuted. A whole-8-ROM hunt for the PLL coefficient encoding found
  864 MHz PLLs (FBPA block at 0x903C7C etc.) that do not track the memory clock; the mclk
  path is the FBPA coefficient. Booting at NDIV 60 (demonstrably lower delivered rate,
  read 1574.7 GB/s) and diffing the register dump showed only the FBPA PLL pair changed,
  confirming the clamp is not a PTRIM register anyone can reach.
- Structural reason there was never headroom: per-pin data rate is 2x the mclk. An A100
  80GB runs 1215 MHz = 2.43 Gbps/pin; an A100 40GB runs 1593 MHz = 3.19 Gbps/pin
  (HBM2e nominal top ~3.2); the 170HX already runs 1728 MHz = 3.456 Gbps/pin, about 6-8%
  above the A100 80GB and above HBM2e nominal. NVIDIA spent the memory headroom at the
  factory. Do not re-run the PLL sweep; it is closed by measurement.

### Memory underclock is a power lever (downward only)

Because the PLL follows down, underclocking is free power on compute-bound work where the
HBM is over-provisioned. Measured with the patched module at NDIV 60 (1620 MHz) and
NDIV 52 (1404 MHz), core profiles unchanged:

```
+------------------+---------------------------+---------------------------+---------------------------+
| profile          | mem 1728 (stock)          | mem 1620                  | mem 1404                  |
+------------------+---------------------------+---------------------------+---------------------------+
| perf (+350/1590) | 212.2 TF / 181.2 W / 1171 | 211.6 TF / 172.9 W / 1224 | 210.5 TF / 169.3 W / 1243 |
| eff (+250/1350)  | 180.3 TF / 132.0 W / 1366 | 180.7 TF / 130.2 W / 1388 | 180.7 TF / 132.7 W / 1362 |
| read bandwidth   | 1695 GB/s                 | 1582 GB/s                 | 1279 GB/s                 |
+------------------+---------------------------+---------------------------+---------------------------+
```

- At `perf`, dropping memory one step (1728 -> 1620) saves 8.3 W for 0.3% throughput, a
  4.5% efficiency gain, and it passed the pattern sweep.
- The second step (-> 1404) adds only 3.6 W more while costing 24% of bandwidth: a bad
  trade for anything that is not pure GEMM.
- At `eff` the memory clock makes no measurable difference; that profile is already at the
  floor.
- This needs the patched kernel module and a reboot, unlike the core profiles which are
  runtime NVML calls. It is an option for a compute-bound deployment, not a default.
  Decode-bound LLM serving should NOT use it; that workload wants every GB/s.

---

## 7. Persistence and multi-card safety

Offsets and power limits are volatile: lost on every driver reload and reboot. The
`170hx-oc.service` systemd unit reapplies them at boot:

- `Type=oneshot`, `RemainAfterExit=yes`
- `After=nvidia-persistenced.service gen2-hammer.service`
- `ExecStart=/usr/local/bin/170hx-oc eff`
- `ExecStop=/usr/local/bin/170hx-oc stock`
- Enabled on oberon.

Multi-card guard: the script guards on PCI device id 0x20C2 and loops over every GPU,
because this host is a qualification bench and cards are swapped constantly. A non-170HX
in the slot is skipped and logged, never overclocked. Each application logs to the journal
with serial, offset and cap, for example:

```
170hx-oc: GPU 0 (1322621047793) profile=eff offset=+250 clk_max=1350 power_limit=300 W
```

(The `analysis/oc_efficiency_2026-07-27.md` persistence section shows an illustrative log
line reading `offset=+250 clk_max=1350 power_limit=300.00 W`; that does not match the shipped `eff`
profile, which is offset +250 with the power limit left at 300 W. Trust the applier script
`tools/170hx-oc`, not that example line.)

---

## 8. Qualifying a NEW card

Per-card silicon varies. +300 is validated on serial 1322621047793 only; do not assume it
on another card. Ladder:

1. `sudo nvml_oc` - confirm the GPC range is not `[0..0]` (the card is unlocked).
2. `sudo 170hx-oc stock`, then `sudo oc_eff 10` for a baseline.
3. Ladder +150 -> +300 with `oc_eff` at each step, then run `170hx-test.sh --no-unlock`
   for the full-VRAM memory sweep and compute checksum at the candidate point.
4. Stop at the first step that shows a device fault, and back off one FULL step, not one
   bin.
5. Record the result in `~ariel/170hx/results/<serial>/`.

The gate is the pattern sweep, not "it ran". A silent corruptor (see the cliff in
section 4) passes any test that only checks whether the kernel finished. Run 4 sweeps and
prefer margin over a number that looks equal on paper.

---

## 9. Tooling inventory

- `tools/nvml_oc.c` -> `/usr/local/bin/nvml_oc [gpcMHz] [memMHz] [devIdx]`: query/apply
  GPC and MEM VF offsets. The range query is the useful part (confirms unlock).
- `tools/oc_eff.cu`: sustained bf16 GEMM with in-process NVML power sampling ->
  TFLOPS, W, GFLOPS/W.
- `tools/oc_sweep.sh`: the offset x power-limit sweep that produced the sweep table.
- `tools/oc_tune.sh <offset> <clk> [secs]`: fine-tune driver; writes
  `analysis/oc_tune_sweep.csv`.
- `tools/170hx-oc` + `tools/170hx-oc.service`: the profile applier and its boot unit.
- `170hx-test.sh --no-unlock`: full-VRAM memory pattern sweep plus compute checksum (the
  qualification gate).
- `driver/0009-hbm-mclk-overclock.patch`: kernel-module patch used only to prove the mclk
  clamp by measurement; not for production use.
- `tools/fbpa_pll_dump.py`: FBPA PLL register dump used in the memory-clamp investigation.

---

## 10. Background: FWSEC BAR0 aperture and the Gen3 line

This is context for the separate Gen3-unlock effort, not part of tuning; full detail in
`analysis/fwsec_bar0_aperture_correction_2026-07-26.md`.

Every `0x14xx....` constant in the FWSEC falcon code is a BAR0 offset OR'd with the
aperture base `0x14000000`, not a Falcon-private address. So e.g. `0x14118F78` is BAR0
offset `0x118F78` inside the ordinary 16 MB BAR0 window, directly readable/writable from
the host in principle. Earlier readings that treated these as a separate "Falcon PRIV
bus" (the `PCIE_GEN_DOSSIER` and `lock_register_map` notes) were wrong about the address
space. Standing caveat: a host read of `0x118F78` returns `0xbadf1100`, so whether that
register is actually host-reachable outside FWSEC context is not yet fully probed. This
does not affect any tuning result above.
