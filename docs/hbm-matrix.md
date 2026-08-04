# CMP 170HX HBM tuning matrix (canonical)

2026-08-03. THE reference for HBM memory tuning on this card. Consolidates the NDIV/bandwidth grid,
the three ceilings and their mechanisms, the refresh power lever, what is NOT a lever, the production
profile, and the corrected phantom conclusions. Card 1322621047793 (GA100, 8 active FBPAs /
4096-bit HBM2e, driver 610.43.03 patched unlock). All tuning is live userspace BAR0 (`hbm_mclk` sets
the HBM PLL NDIV, `fbpa_regs` sets the CONFIG timings); the card always boots stock. Tool: `170tune`
(`explain-hbm` for the model, `mclk-gate`/`refresh`/`persist` to apply). This file is the grid and
the ship points; the mechanistic model - the per-field ns constraint structure and which timing
binds as NDIV rises - is in [`hbm-timing-understanding.md`](hbm-timing-understanding.md).

## The grid (hot, one card)

NDIV = HBM PLL multiplier, clock = NDIV x 27 MHz. Regenerate this whole table on any card with
`170tune hbm-matrix` (it drives the sweep and writes a per-serial CSV). The **stock NDIV 64 row is
fully stock** (stock REFRESH 6); every **OC row is measured at REFRESH 24**, the power-optimized ship
setting, so the grid is the shipped config, not a synthetic one. Columns:

- **PEAK** - theoretical GB/s at that clock (MHz x 4096 bit x 2). **READ** - the delivered peak
  streaming read from `mem_probe`. **%PK** - READ as a fraction of PEAK.
- **TRIAD / COPY / D2D** - the `nvidia_bench` STREAM kernels; TRIAD (2 read + 1 write) is the closest
  synthetic proxy for decode, D2D is a real `cudaMemcpy` device-to-device.
- **LAT** - `mem_probe` dependent-load latency (pointer chase over 8 GiB; TLB-sensitive, moves little).
- **PWR** - MEAN board draw sampled during the read load (idle is ~40 W; a pure 2 TB/s read adds
  ~40 W, so wide HBM2e read power is genuinely ~65-80 W). **MEM C** - HBM temperature that row was
  taken at. **GB/s/W** - READ per watt. **dSTOCK** - READ vs the fully-stock NDIV 64 row.
- **MOVED** - READ exceeds the stock 1769 GB/s theoretical wall. That is the clock-moved proof: a read
  above the stock ceiling is impossible unless the DRAM clock actually rose, and it is the one thing
  `nvidia-smi` cannot show (it reports 1728 MHz at every NDIV). A "-" at 66 is not "did not move" -
  the clock rose, the read just has not yet cleared the stock ceiling.
- **GATE** - `170tune mclk-gate <N> 12` (12 hot full-VRAM pattern sweeps + bit-exact compute, bare).

| NDIV | MHz | PEAK | READ | %PK | TRIAD | COPY | D2D | LAT ns | PWR W | GB/s/W | MEM C | dSTOCK | MOVED | GATE |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 (stock) | 1728 | 1769 | 1687 | 95.4 | 1610 | 1520 | 1584 | 276 | 65 | 26.1 | 60 | baseline | - | (baseline) |
| 66 | 1782 | 1825 | 1757 | 96.3 | 1669 | 1613 | 1655 | 272 | 67 | 26.4 | 63 | +4.1% | - | pass |
| 68 | 1836 | 1880 | 1808 | 96.1 | 1724 | 1671 | 1708 | 273 | 67 | 27.0 | 64 | +7.1% | yes | pass |
| 70 | 1890 | 1935 | 1859 | 96.0 | 1779 | 1722 | 1759 | 271 | 70 | 26.6 | 66 | +10.2% | yes | GATED 12/12 |
| 72 | 1944 | 1991 | 1909 | 95.9 | 1818 | 1769 | 1808 | 270 | 74 | 25.9 | 68 | +13.2% | yes | GATED 12/12 |
| 74 | 1998 | 2046 | 1958 | 95.7 | 1885 | 1821 | 1859 | 268 | 76 | 25.7 | 70 | +16.1% | yes | GATED 12/12 |
| **76** | **2052** | **2101** | **2006** | **95.5** | **1930** | **1873** | **1911** | **267** | **80** | **25.2** | **71** | **+18.9%** | **yes** | **GATED 12/12** |
| 77 | 2079 | 2129 | - | - | ~1935 | - | - | - | - | - | - | - | - | thermal-marginal |
| 78 | 2106 | 2156 | - | - | ~1966 | - | - | - | - | - | - | - | - | REJECTED (eye wall) |

The 64-76 rows are a single hot `170tune hbm-matrix 64 2 76` sweep (mem 60-71C, shown per row). 77
and 78 are NOT bandwidth-swept: bare NDIV 77 hard-hangs the controller (a row timing crosses its
floor - see the ceilings below), so the matrix stops at the robust ceiling; their triad figures are
from the separate command-tuned ceiling hunt.

vs the fully-stock baseline, NDIV 76 (at REFRESH 24): **read +18.9%, triad +19.9%, copy +23.2%,
D2D +20.6%, latency -3.3%**. Read, triad, copy and D2D all climb monotonically, tracking the clock
almost 1:1 (read holds ~96% of theoretical peak at every OC NDIV - a genuinely DRAM-bound result,
not a cache artifact; the stock row reads a bit lower at 95.4% because it runs stock refresh, which
costs a few percent bandwidth). Read/watt is roughly flat 26-27 across the range and dips only
slightly to 25.2 at 76 - no efficiency knee, so NDIV 72 is a sensible balance point. Read is
thermally sensitive - it droops as HBM heats; the MEM C column is the temperature each row was taken
at, so read is comparable only within the band shown.

## The three ceilings

- **NDIV 76 = robust ceiling, any thermal.** Stock cycle counts still clear the DRAM's real floor at
  2052 MHz; 12/12 hot, bare, reproducible. THE ship point.
- **NDIV 77 = thermal-marginal, not robust.** It hangs on stock timings (a row timing crosses its
  floor) and needs a command-loosening tune just to RUN. Even tuned it is a sharp thermal threshold:
  16/16 clean at mem <=61C, but 11/12 (fails) at 64-66C. The failure is RETENTION (hot cells leak
  faster than stock refresh cycles them). Robust only if HBM is held <=~61C (chilled/high-airflow),
  for ~1% triad over 76. Not a general ship.
- **NDIV 78 = read-eye wall.** With over-loosened command timings + loose refresh (command and
  retention both ruled out), 78 RUNS (triad ~1966) but gates 0/8 - the read data eye is too narrow to
  sample at 2106 MHz. Exhaustive cold hunt (DDLL recal x3 = max 1/4; RDRET_OFFSET 0-15 = all 0/2;
  tCL 35-40 = all 0/2) found no centering. Not a findable step; the only untested lever is the MR2
  Read-Latency code, but tCL (its controller-side twin) failing flat says the problem is physical eye
  WIDTH, so MR2 is very unlikely to help. 78 is the ceiling.

## The refresh axis - the power/heat lever (retention <-> power <-> bandwidth)

The refresh interval (CONFIG4 REFRESH field) is a linear clock count; the real interval is
clock-relative: interval_us = field x 1024 / mclk_MHz (stock field 6 ~= 3.9us at 1728). Smaller =
more frequent = better retention, more power, less bandwidth; larger = the reverse.

- **Power (measured, consistent):** loosening cut idle power 41 -> 35 W (-15%) and steady load
  ~56 -> 49-50 W (-11 to -12.5%, and -14% at 76 memory-bound) at EVERY NDIV. Real and repeatable.
- **Temperature:** on a well-cooled card, temp is cooling-limited (held ~62C regardless), so the
  deliverable is POWER / heat-generated, not a direct temperature drop. In a cooling-constrained
  deployment, -12% power becomes lower temp; on a well-cooled card temp stays pinned either way.
- **Latency/bandwidth:** flat-to-slightly-better (fewer refresh stalls); no cost.
- **Retention margin (the limit):** held 8/8 to field 384 (~49x JEDEC) at 64C, 12/12 to field 96 at
  the bench ceiling ~66C, wedged at 768. Enormous margin cool. BUT retention is temperature-dependent
  and validated only to ~66C (the bench cannot reach 85C). JEDEC halves the interval above 85C, so a
  loose value safe cool can leak hot. Ship field 24 (~4x stock interval, the measured -14% point):
  it held 12/12 hot to 66C and 8/8 to field 384 at 64C, so it sits ~16x inside the retention margin,
  with ~2x headroom even extrapolating the edge to ~field 48 at 85C. Keep stock for >85C or unknown
  thermals. `170tune refresh {status|set <us>|gate <us>|stock}`.

## What is NOT a lever (tested, negative)

- **tRFC (refresh duration, RFC field):** tightened 657 -> 440 (33% tighter), triad DEAD FLAT ~1922,
  all gates clean. Interleaved RFC 657 vs 590 at verified NDIV 76: read delta bounces -9.7/+1.7/
  -19.4/+8.4 (noise around zero) - the one-time "590 -> 1920" was a cool-moment scatter peak, not a
  tRFC effect. Refresh DURATION moves nothing.
- **Activation timings tightened for bandwidth:** tRRD 5 -> 2, tFAW 22 -> 14, tRC 67 -> 59 all gated
  clean but moved read NOT at all (flat ~1890). Read is bus/controller- and temperature-bound, not
  activation-bound.
- **Latency-timing tightening:** tCL floor is 33 (CL=31 hard-wedges); tCL 37 -> 33 moved latency only
  ~2ns. Pointer-chase latency is access/TLB-dominated. Latency's real lever is the CLOCK, not timings.
- **The DDLL eye recal** is non-deterministic and NOT on the ship path (it was only ever relevant to
  the eye-limited 78, where it still maxed at 1/4).

## Production profile

The only change from stock that pays is the CLOCK. Raising NDIV already tightens every timing in ns
for free (ns = cycles/clock), so stock cycle counts at 76 are both valid (12/12) and maximally
margined - tighter buys nothing measurable and spends the silent-corruption safety budget; looser
only adds latency. So production keeps STOCK timings.

- **Robust (default): NDIV 76, stock timings, stock refresh.** +20% triad / +19% peak read / -3%
  latency (see the grid above), 12/12 hot on any thermal.
- **Power-optimized: NDIV 76, stock timings, REFRESH field 24.** As above plus ~-14% power (~15%
  idle), ~16x inside the retention margin. Gate on the target card; keep HBM within normal thermals.
- **Ultra-conservative: NDIV 75.** Near-identical performance, one extra step of guardband.

Apply + persist (no daemon; boot-apply re-applies after the driver loads, card still boots stock):
```
170tune mclk-gate 76 12                                 # prove it on THIS card, hot
170tune persist save --ndiv 76                          # robust default (stock timings/refresh)
170tune persist save --ndiv 76 --timings "REFRESH 24"   # power-optimized variant (~-14% power)
170tune persist enable
```

## Corrections (phantom conclusions, now disproven)

- "DDLL recal lifts the ceiling 70 -> 75" - a broken-gate-wrapper artifact (a selftest run under
  sudo resolved `~` to /root and never ran, defaulting every sweep to failed). Bare NDIV gates to 76.
- "NDIV 77 is robust 15/15" - that was a COOL run; 77 is a thermal threshold ~62C (11/12 at 64-66C).
- "Read plateaus at 1871 from NDIV 73" - depressed by concurrent power-sampling during the bench;
  clean read climbs monotonically to 76 (both the mem_probe peak read in the grid above and the
  nvidia_bench STREAM read), tracking triad within the thermal-droop band.
