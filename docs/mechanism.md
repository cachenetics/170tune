# How the SM tuning works

This document explains the mechanism behind the core-side levers: what the VF offset
actually does, why the clock ceiling is the right second lever, where the two failure
regimes come from, and why the card sometimes runs slower to protect itself. The
[tuning guide](tuning-guide.md) tells you what to run; this tells you why it works. The
memory-side counterpart is [HBM timing on the CMP 170HX](hbm-timing-understanding.md).

All figures are from the reference card (serial 1322621047793, GA100, 70 SM, driver
610.43.03, stock 300 W VBIOS). Silicon varies per card; the model transfers, the exact
numbers do not.

## The VF offset is an undervolt

The GPU runs on a voltage/frequency curve: each clock is paired with the voltage the
silicon is believed to need at that clock. The one open lever on this card is the GPC clock
VF offset, applied through NVML (`nvmlDeviceSetGpcClkVfOffset`). `nvidia-smi` on this
driver exposes only the negative direction, which is why overclocking looks unavailable;
NVML exports the full API, and the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    (open)
MEM clock VF offset : allowed range [    0 ..     0] MHz    (refused by the driver)
```

A positive offset shifts the whole curve: at every voltage point the clock is X MHz higher,
which is the same statement as "any given clock is now reached at a lower voltage". Applied
with the clock pinned, the offset is therefore a pure undervolt: same frequency, same work,
fewer watts.

This SKU reports no voltage telemetry (`nvidia-smi -q -d VOLTAGE` is empty), so
watts-at-fixed-clock is the proxy for voltage, and it is unambiguous:

| pinned SM clock | offset +0 | offset +300 | delta | bf16 throughput |
|---|---|---|---|---|
| 1200 MHz | 130.6 W | 120.6 W | -7.7% | 160.4 / 160.6 TFLOPS (unchanged) |
| 1350 MHz | 174.6 W | 132.0 W | -24.4% | 179.7 / 180.7 TFLOPS (unchanged) |

The saving grows with frequency because dynamic power tracks V^2 x f and the stock curve
climbs steeply in voltage near the top.

Note that the memory offset really is closed on the NVML path; the memory clock is tuned by
an entirely different mechanism (a live BAR0 PLL write), covered in the
[HBM document](hbm-timing-understanding.md).

## Why the clock ceiling is the second lever

The offset alone buys no efficiency. It only reshapes the curve; the clock arbiter responds
by climbing higher, spending the headroom on frequency instead of watts. To bank the saving
you must also pin where the clock lands. There are two ways to pin it, and they measure
differently:

- **Cap power** (`nvidia-smi -pl`): works, but the clock oscillates around the cap.
  Measured: 198.0 TFLOPS at 159.7 W mean (163.8 W peak), 1240 GFLOPS/W.
- **Cap the clock** (`nvidia-smi -lgc 210,<max>`): holds one voltage point. Measured at a
  1470 ceiling: 196.3 TFLOPS at 152.7 W, 1286 GFLOPS/W.

Capping the clock wins on efficiency, so the shipped profiles set the offset, leave the
power limit wide open at 300 W, and pin a clock ceiling. The ceiling is written as
`210,<max>`, not `<max>,<max>`: the low end at 210 MHz preserves idle downclocking (the
card rests at 210 MHz and roughly 40-54 W when unused), which a hard lock at the maximum
would forfeit.

The power cap still has one property the ceiling does not: it bounds heat regardless of
workload, which makes it the right lever for an unattended, passively cooled box. That
trade is quantified in [the power-cap curve](power-cap-curve.md).

One more piece of context: this card never draws its stock 250 W cap on a dense GEMM. It is
voltage-limited around 190-200 W, which is why raising the power cap changes nothing on its
own. Voltage, not the power limit, is the constraint the offset relaxes.

Effective sustained clocks under offset (the VBIOS table's maximum graphics clock is
1695 MHz):

| offset | sustained effective SM clock |
|---|---|
| +0 (stock) | ~1425 MHz |
| +150 | ~1571 MHz |
| +300 | ~1647 MHz |

## The two regimes: the floor and the cliff

The offset-versus-ceiling space has two distinct regions, and which one you are in decides
how to pick a point.

**Below about 1350 MHz: the voltage floor.** The rail bottoms out. From roughly +250
upward, more offset changes nothing: power is flat (at a 1350 ceiling, +250 through +450
all draw within a watt of 132 W). The correct choice here is the lowest offset that reaches
the floor, not the highest that appears to work. Everything above the floor draws identical
power while sitting closer to the failure edge; extra offset is pure risk with zero return.

**Above about 1400 MHz: the corruption cliff.** The failure edge arrives before the floor
does. The failure mode past the edge is the dangerous one: the run completes, nothing
crashes, and memory comes back wrong, intermittently. At a 1400 ceiling the window between
clean and corrupting is a single 25 MHz offset step. This is the regime the integrity gate
exists for.

Efficiency peaks in a broad plateau at ceilings of 1350-1400 MHz (roughly 1369-1390
GFLOPS/W on this card) and falls away in both directions. The silicon clock ceiling is
about 1604-1614 MHz at +350: requesting 1700 or 1740 delivers no more than requesting 1650.
The complete measured grid is in the
[reference matrices](reference-matrices.md#sm-offset-x-ceiling-grid).

## The risk lever is voltage-at-frequency

Serving qualification on this card produced a result worth internalizing: the risk is
neither the offset nor the clock alone. +250 survives ceilings where +300 dies, and +300
dies even at low ceilings; +300 and +350 both pass a cool GEMM, pass the full-VRAM gate,
and can serve for a day, then fault under an hour-long soak (Xid 13 on the card's weakest
SMs). What decides survival is the voltage margin at the operating frequency, and an offset
that crosses that margin crosses it everywhere.

Two practical consequences:

- A point qualifies at an offset, not at a profile name. The serving-qualified offsets on
  the reference card are +200 and +250; +300 and +350 are bench-only.
- No amount of benchmarking substitutes for a soak under the real workload. The
  qualification matrix in the [reference matrices](reference-matrices.md#serving-qualification-matrix)
  exists because benchmarks passed where serving failed.

## NAFLL droop stretch: why running is not the same as being safe

Ampere's clock generator (NAFLL) has droop detection: when supply voltage sags below what
the requested frequency needs, it stretches the clock, slowing the chip within the cycle to
ride out the sag.

This produces a counterintuitive measured result: +400 "runs" where +375 faults. It is not
safer at +400; it is slower. The requested VF point is so far past the curve that the
stretcher engages continuously: the clock reads 1650 MHz while delivered work drops about 4
percent below +375. Between roughly +355 and +390 the part runs at full requested speed
with too little margin, which is exactly where the intermittent faults live. Past the wall,
behavior stops being orderly altogether: +400 at 1650 runs (stretched) while +400 at 1590
hangs the GPU.

Running slower is the hardware protecting itself, not headroom. It is one more face of the
rule the whole tool is built on: completing is not a result. Measure delivered work, gate
for corruption, and sit below the edge with margin, not at it.
