# How the CMP 170HX HBM timings work - the constraint structure

2026-08-03. The mechanistic understanding of HBM2e memory tuning on this GA100 (8 FBPA / 4096-bit),
derived the way earlier memory-tuning work was: decode the full timing map, compute each field's
absolute ns at the target clock, and identify which binds - by physics, then verified by isolating
each lever
on the card. All levers are live userspace BAR0 (`fbpa_regs` for timings, `hbm_mclk` for NDIV + the
DDLL eye recal). Card 1322621047793, driver 610.43.03 patched unlock.

## The core principle

Every timing is a fixed CYCLE count; its absolute time is cycles x 1000/mclk_MHz ns. Raising NDIV
shrinks tCK, so EVERY timing tightens in ns simultaneously. Stability = every timing staying at or
above its DRAM's real minimum (tau_min). The stock cycle counts were set near JEDEC ns at 1728, but
these stacks BEAT the JEDEC guardband (bare NDIV holds to 76 = well sub-JEDEC ns), so tau_min is
EMPIRICAL, not the datasheet. Equation: to hold clock f, set `C(t,f) = ceil(tau_min(t) x f / 1000)`.

## The ns decode at the target (live, NDIV 64 stock vs NDIV 77 = 2079 MHz)

| field | reg | cyc | ns@1728 | ns@2079 | role |
|---|---|---:|---:|---:|---|
| tRC | CONFIG0 | 67 | 38.8 | 32.2 | row cycle |
| tRFC | CONFIG0/10 | 657 | 380 | 316 | all-bank refresh |
| tRAS | CONFIG0 | 43 | 24.9 | 20.7 | row active |
| tRP | CONFIG0 | 24 | 13.9 | 11.5 | precharge |
| tRCD_rd/wr | CONFIG1 | 27/18 | 15.6/10.4 | 13.0/8.7 | RAS->CAS |
| **tCL** | CONFIG1 | 37 | 21.4 | **17.8** | **CAS latency / data sampling (the EYE)** |
| tWL | CONFIG1 | 10 | 5.8 | 4.8 | write latency |
| tWR | CONFIG2 | 25 | 14.5 | 12.0 | write recovery |
| **tW2R_BUS / tR2W_BUS** | CONFIG2 | 8 | 4.6 | **3.85** | **bus turnaround** |
| CDLR | CONFIG2 | 9 | 5.2 | 4.3 | CAS-to-CAS data-path |
| tFAW | CONFIG3 | 22 | 12.7 | 10.6 | four-activate window |
| tCCD_L / _S | CONFIG3 | 4/2 | 2.3/1.2 | 1.9/1.0 | column-to-column (burst floor) |
| tRRD | CONFIG4 | 5 | 2.9 | 2.4 | activate-to-activate |
| REFRESH (tREFI) | CONFIG4 | 6* | encoded | encoded | refresh interval |

## The constraint LAYERS (which binds first, as NDIV rises) - measured by isolating each on the card

The path past the bare ceiling has an ordered stack; each layer has its own lever:

1. **Bare ceiling = NDIV 76.** Stock cycle counts still clear tau_min to 76 (the stacks beat JEDEC).
   No tuning, rock-solid 12/12. This is the robust ship point.
2. **The hang (NDIV 77).** One or more ROW/command timing (tRC/tRAS/tRP/tRCD/tRFC) crosses its real
   floor -> the controller HARD-HANGS (reboot to recover). Lever: loosen the command set x(f/f_stock)
   to hold stock ns. Fixes the hang - 77 runs (but 1/8).
3. **The data EYE (tCL).** tCL = 17.8 ns @2079 is the CAS data-sampling point; the eye drifts
   off-center at the higher clock. Lever: the DDLL recal (`hbm_mclk ddll`) re-centers the delay lines
   at the live clock - the single biggest fix, 1/8 -> 6/8. But it is NON-DETERMINISTIC (does not
   center perfectly every time). tCL itself cannot be raised without re-issuing the DRAM MR2 CL code
   (the read pointer desyncs otherwise) - that is the deep, risky lever.
4. **Bus turnaround (tW2R_BUS / tR2W_BUS).** 3.85 ns @2079. Loosen 8 -> 12: 6/8 -> 9/10.
5. **Fine data-path (CDLR) + eye precision.** CDLR 9 -> 13 + a second recal: 9/10 -> 11/12.
6. **Floors that do NOT bind here:** tCCD_S/L (burst floor, CCDL=3 hangs), refresh (tREFI/tRFC had
   margin). Do not touch tCCD; refresh is a bandwidth/power lever, not the 77 binder.

Measured NDIV-77 progression (each lever additive): loose command 1/8 -> +eye recal 6/8 ->
+bus turnaround 9/10 -> +CDLR + double recal 11/12. triad ~1930 GB/s throughout.

## What this means (CORRECTED - see the RETENTION section; 77 is NOT robust)

The recal-based analysis in layers 3+5 above was a red herring - the DDLL recal's contribution was
noise. But so was the follow-on "77 is robust 15/15" conclusion: that 15/15 was a COOLER / luckier run.
On a fresh reboot + cooled card, a proper hot gate gives bare-76 = 12/12 but tuned-77 = REJECTED
(11/12 fail, ~1 error each). 77's hot failure is RETENTION (temperature-dependent cell leakage),
proven below. So:
- **Bare robust ceiling = NDIV 76** (12/12 hot, zero tuning). THE honest ship point.
- **NDIV 77 is temperature-marginal, NOT robust.** The command tune makes 77 RUN (vs a bare hang), but
  it does not survive a hot gate. The only thing that stabilises it hot is tighter refresh, which costs
  more bandwidth than the clock gains (net loss - see RETENTION). 78 is a hard cliff.
- The DDLL recal / tCL / MR2 eye-lever chase was NOT the 77 binder - retention was. (The tCL/MR2 frame
  is still correct IF a FUTURE clock is eye-limited; 78 may be, and MR2 Read-Latency is that lever.)

## Method summary (how to work the HBM)

1. `fbpa_regs` dump the full CONFIG/TIMING map; compute each field's ns at the target clock.
2. The tightest-ns fields that are NOT already at a hard floor (tCCD) are the binders.
3. Loosen command/row timings to kill the hang; loosen bus turnaround for the next margin.
4. If a residual persists after command/turnaround margin, ask whether it is RETENTION (temperature-
   dependent, fixed by tighter refresh - but that costs bandwidth) or the EYE (tCL, fixed only by
   re-issuing the MR2 Read-Latency code). The DDLL recal is non-deterministic and NOT a reliable lever.
5. Gate hot with a WRITE/HOLD/READ-BACK pattern sweep (never a compute benchmark - a retention bit-flip
   the kernel never reads passes a compute check), 12+ sweeps, bare where possible. tau_min per field =
   the failing edge in cycles x 1000/f; C(t,f)=ceil(tau_min x f/1000) predicts every clock.

## RESULT: NDIV 77 is temperature-marginal (retention); bare 76 is the ceiling

Fresh reboot + cooled card, proper hot gate (2026-08-03): bare-76 = GATED 12/12, tuned-77 = REJECTED
11/12. The earlier "77 robust 15/15" was a cooler/lucky run; the marathon heat had masked the marginality.
The 77 command tune (loosen x77/64 + turnaround 8->12 + CDLR 9->13) makes 77 RUN, but the residual ~1
hot error is RETENTION, not command/data-path margin.

## RETENTION: the refresh axis - the 77 mechanism AND the power/heat lever

Refresh is a fourth axis and it is a RETENTION <-> POWER <-> BANDWIDTH triangle. The refresh interval
(CONFIG4 field, linear clock count, granularity ~1024 mem-clocks, ns = field x 1024 x 1000/MHz; stock
6 ~= 3.9us at 1728, matching JEDEC). SMALLER = more frequent = better retention, MORE power, LESS BW.

**77's hot failure IS retention** (measured, hot 77 + tune): tighten REFRESH 6->3 turned the gate 1/8
into 8/8 - but triad collapsed 1930 -> 1298 (below stock 1611). So robust-77-via-refresh is a NET LOSS:
the refresh overhead needed to hold retention hot costs more bandwidth than NDIV 77 buys. Confirms 76.

**The reverse is the power/heat lever** (measured at NDIV 76, mem 62-64C, 8 hot pattern sweeps each):
| REFRESH | interval | lat ns | triad | idle W | load W | gate |
|---|---|---|---|---|---|---|
| 6 (stock) | ~3us | 342.7 | 1921 | 41.0 | 78.7 | 8/8 |
| 16 | ~8us | - | - | 36.0 | 73.3 | 8/8 |
| 24 | ~12us | 343.5 | 1927 | 34.9 | 67.7 | 8/8 |
| 96 | ~48us | 340.6 | 1930 | - | 66.4 | 8/8 |
| 384 | ~192us (~49x JEDEC) | 340.4 | 1935 | - | 69.7 | 8/8 |
| 768 | ~383us | - | - | - | - | WEDGED |

Looser refresh at 76: idle -15%, load -14%, latency flat-to-slightly-better (fewer refresh stalls),
bandwidth flat. Retention margin at 64C is enormous (~49x JEDEC before the 768 wedge).

**SHIP CAVEAT (temperature).** All retention data is 62-70C - the bench can't reach 85C, and JEDEC
halves the interval above 85C (hot cells leak faster). So a value safe at 64C may corrupt hot. Ship the
refresh power-lever OPT-IN and MODERATE (target interval a few x JEDEC, e.g. REFRESH 16-24 for most of
the idle-power win deep inside the margin), gate it with a WRITE/HOLD/READ-BACK pattern test on the
user's own card (a retention bit-flip passes a compute check), keep STOCK refresh for hot/unknown
thermals, and ship it as a target INTERVAL (compute the field from current mclk - the interval is
clock-relative). A continuous temp-governor would close the hot gap but needs a daemon (declined).
Minor: looser refresh also slightly shrinks row-disturb margin (negligible on a single-tenant card).

## The FBPA register window (read-only dump, stock, NDIV 64)

CONFIG0-4 (0x009A0290-02A0) fully decoded, cross-validated 1:1 vs nouveau timing_10_* names. The rest
of the window is MAPPED but field packing UNCONFIRMED - no public NVIDIA bit-field map exists for GA100
FBPA, and the block is shared across GDDR/HBM generations so magnitudes can be vestigial:
  02A4=A6B3A002 (CONFIG5, holds PHY RDRET_OFFSET) 02A8=11008000 02AC=00C35000(=50000, periodic-cal?)
  02B0/B4/B8=TIMING0/1/2_GEN mirrors  02BC=003B242A 02C0=016B0B0B 02C4=489B2718 02C8=29380101
  02CC=0C023900 02D0=0B240202 02D4=11330501 02D8=180E1024 02DC=01001232 02E0=00180C27 02E4=0A000033
  02E8=12400389 (0x40=64 -> tZQCS-like, GDDR heritage, maybe inert on HBM: HYPOTHESIS)
  02EC=08000200 (0x08=8 -> tCKE/power-down-like: HYPOTHESIS, HBM2e tCKE is ns-based ~13tCK not 8)
  02F0=0006A0E2 (large counter) 02F4=CONFIG10(ext=0x11) 02F8=0A000080 (self-refresh/ASR reg?: GUESS)
  02FC=00000002
ASR would only govern SELF-REFRESH (idle power-down state), not the active-mode refresh above, so it
does NOT make the loose-refresh lever safe hot - naming it was declined (poking wedged the card once
for ~zero payoff). MR2 holds the Read-Latency (tCL) code = the eye-retrain lever for a possible 78.

**Ceilings:** bare robust = NDIV 76 (ship this). NDIV 77 = temperature-marginal (retention), net loss.
78 = hard cliff (possibly eye-limited; MR2 is the untested deep lever). Refresh is a separate power/heat
axis, best shipped as a conservative opt-in loosening at any qualified clock.
