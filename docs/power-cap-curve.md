# The power-cap curve: choosing a sustained delivery envelope

The [tuning guide](tuning-guide.md) and the
[reference matrices](reference-matrices.md) map the offset x clock-ceiling space with
`-lgc`. This document maps the offset x power-cap space with `nvidia-smi -pl`, because for
an unattended, passively cooled card the right binding lever is a hard wattage bound, not
a clock ceiling. Measured on the reference card (serial 1322621047793, GA100, 64 GB HBM2e,
driver 610.43.03, stock 300 W VBIOS, PCIe Gen2 x4), single-card host.

## Why a power cap, not a clock ceiling

A `-lgc` ceiling pins one voltage/frequency point and gives the best GFLOPS/W: the correct
choice when you control cooling and want peak efficiency. But a clock ceiling does not
bound power: a heavier workload at the same clock draws more watts and makes more heat. On
a passive card (no onboard fan; cooling is chassis airflow only) with a GPU max operating
temperature of 85 C and HBM of 95 C, an uncapped high-clock serve heat-soaks past safe on
hour-long runs.

A power cap bounds wattage, and therefore heat, regardless of workload. That is the
property you want for a box that ships somewhere you cannot see. The cost is that the cap
lets clock and voltage float to hold the wattage target instead of pinning one point, so
it is slightly less efficient than an equivalent fixed ceiling. For a delivery box the
trade is worth it.

## Method

- Real serving load: vLLM 0.26.0, Qwen3.8-27B-FP8 (native MTP,
  `num_speculative_tokens=2`), CUDA graphs on, at offset +250, clock ceiling wide so the
  power cap is the sole governor.
- Decode measured two ways: single-stream (one request, uncontended) and under 6-way
  concurrent load (per-request rate while the GPU is shared: the realistic appliance
  case). Tokens counted by `completion_tokens` via `stream_options.include_usage`, not
  stream chunks (MTP packs 2-3 tokens per chunk).
- Prefill measured with unique, uncacheable prompts large enough (~6.6k tokens) that the
  cap actually clamps the clock.
- Correctness checked with known-answer temperature-0 tripwires and a
  non-ASCII/gibberish scan, plus a 10-minute real-load soak watching HBM temperature and
  Xid count. A completed run alone proves nothing (see the measurement notes at the end).

## The offset axis: +250 is the ceiling here too

The capped envelope confirms the
[serving qualification matrix](reference-matrices.md#serving-qualification-matrix):
stepping the offset up under a live 200 W cap, +250 and +265 stayed clean, while +280 and
+290 threw Xid 13 (illegal instruction) on the card's weak SMs at GPC3/TPC6, then Xid 43.
The risk lever is voltage-at-frequency, not offset or clock alone: +250 survives clocks
where +300 dies, and +300 dies even at low clocks. Ship at +250, one step below the fault.

The undervolt also helps thermals directly (lower voltage at a given clock means less
power and less heat), so +250 is simultaneously the fastest-per-watt and the coolest safe
offset. There is no reason to run below it or above it.

## The power/clock staircase (offset +250, real inference)

Sustained SM clock and actual draw as the cap steps down, with the cap active throughout.
This is a pure power-limited slope: there is no ledge where dropping watts holds the
clock; watts and clock move together.

| power cap | sustained clock | actual watts |
|---|---|---|
| 250 W | 1490 MHz | 243 W |
| 230 W | 1419 MHz | 226 W |
| 210 W | 1344 MHz | 209 W |
| 200 W | 1291 MHz | 194 W |
| 190 W | 1230 MHz | 191 W |
| 180 W | 1104 MHz | 179 W |
| 170 W | 1010 MHz | 169 W |
| 160 W | 958 MHz | 161 W |
| 150 W | 901 MHz | 150 W |
| 140 W | 798 MHz | 141 W |
| 130 W | 682 MHz | 127 W |
| 120 W | 560 MHz | 118 W |
| 110 W | 517 MHz | 110 W |

The only flat region (where more watts stop buying clock) is above ~250 W, where the +250
VF curve tops out (~1490-1590 MHz at 243-280 W; the software cap engages around 1600). In
the usable thermal range it is all slope. Per-watt efficiency in MHz/W is best low and
worsens as the clock climbs, so 200 W and above sits on the wasteful upper part of the
curve.

## Performance versus envelope, and the knee

| envelope (offset +250) | sustained clock | prefill (6.6k, uncontended) | decode single-stream | decode under 6-way load |
|---|---|---|---|---|
| 150 W | ~918 MHz | 1,421 tok/s | ~60 tok/s | 45 tok/s |
| **175 W** | **~1,140 MHz** | **1,712 tok/s** | **~78 tok/s** | **60 tok/s** |
| 200 W | ~1,320 MHz | 1,929 tok/s | ~87 tok/s | 62 tok/s |
| 250 W (uncapped-ish) | ~1,490 MHz | - | ~94 tok/s | - |

**175 W is the efficiency knee.** Two effects set it:

- **Decode is kernel-launch-bound**, not clock-bound, at these clocks. Under real
  concurrent load it is flat at 60-62 tok/s from 175 W to 200 W; the extra 180 MHz buys
  nothing. Below 175 W the clock finally becomes the bottleneck and decode falls off
  (60 to 45 tok/s at 150 W).
- **Prefill is compute-bound**, so it does scale with clock: about 11 percent from 175 W
  to 200 W (1,712 to 1,929 tok/s). A prefill-heavy workload (long prompts) pays for the
  lower clock; a decode-heavy one (long generations) barely notices.

So 175 W holds full serving decode throughput while shedding 25 W and running the HBM
about 6 C cooler than 200 W. 175 and 180 W are within measurement noise; pick 175. Drop
below it only if you are power- or thermally starved and can accept the decode cliff.

## Thermal envelope

Passive card: GPU max operating 85 C, hardware slowdown 95 C; HBM max operating 95 C. HBM
is the warmest sensor under load, so watch `temperature.memory`, not the core. A
10-minute continuous 6-way inference soak at 200 W held coherent (known-answer tripwires
clean, no gibberish), HBM steady at 84-85 C, GPU 78 C, zero Xid. 175 W runs several
degrees cooler, widening the margin. Prefer the cooler envelope when airflow at the
deployment site is unknown.

## Recommended sustained delivery configuration

```
offset      +250        # the qualified undervolt; +280 and above fault
power cap    175 W      # the efficiency knee: full decode throughput, coolest envelope that holds it
mem clock    stock      # decode is kernel-launch-bound, so extra bandwidth buys nothing here;
                        # a memory OC would be pure power and heat downside on this workload
```

Raise the cap toward 200 W only for a prefill-heavy workload, and only when cooling
allows. For the memory side of a delivery configuration, see the
[tuning guide](tuning-guide.md) and
[hbm-timing-understanding.md](hbm-timing-understanding.md).

## Measurement notes

These are the traps that produce wrong envelope numbers; avoid them when re-measuring on
your own card.

- **Prefix caching inflates prefill.** Repeated or short prompts hit the cache and report
  impossible rates. Measure with unique content sized so the cap clamps the clock.
- **A synthetic GEMM is not a serving proxy for power.** A dense matmul draws a different
  power/clock profile than a real inference engine and can ignore a power cap that
  inference respects. Measure power and clock under the engine you will actually serve.
- **Short probes are cold.** Clock settles in seconds; temperature does not. Only a
  multi-minute soak gives steady-state HBM temperature. The staircase clocks above are
  settled; short-probe temperatures are not.
- **A completed benchmark is not a passing gate.** Silent corruption completes without a
  fault. Gate with a real-workload rung and known-answer checks, per the tuning guide.
