# CMP 170HX power-cap curve: choosing a sustained serving envelope

Card 1322621047793 (GA100, 70 SM, 64 GB HBM2e, driver 610.43.03, stock 300W VBIOS, PCIe Gen2 x4),
single-card host. Companion to [`measurement-matrix.md`](measurement-matrix.md) and
[`tuning-guide.md`](tuning-guide.md): those map the offset x clock-CEILING space with `-lgc`; this
maps the offset x POWER-CAP space with `nvidia-smi -pl`, because for an unattended, passively-cooled
card the binding lever is a hard wattage bound, not a clock ceiling.

## Why a power cap, not a clock ceiling

A `-lgc` ceiling pins one voltage/frequency point and gives the best GFLOPS/W - correct when you
control cooling and want peak efficiency. But a clock ceiling does NOT bound power: a heavier
workload at the same clock draws more watts and more heat. On a PASSIVE card (no onboard fan; cooling
is chassis airflow only) with GPU max-op 85C and HBM 95C, an uncapped high-clock serve heat-soaks
past safe on hour-long runs. A power cap bounds wattage - and therefore heat - regardless of
workload. That is the property you want for a box that ships somewhere and runs unattended.

The cost is that the cap lets clock/voltage float to hold the wattage target instead of pinning one
point, so it is slightly less efficient than an equivalent fixed ceiling. For a delivery box that
trade is worth it.

## Method

- Real serving load: vLLM 0.26.0, Qwen3.8-27B-FP8 (native MTP, num_speculative_tokens=2), CUDA
  graphs on, at offset **+250** (see below), clock ceiling wide so the power cap is the sole governor.
- Decode measured two ways: single-stream (one request, uncontended) and under 6-way concurrent load
  (per-request rate while the GPU is shared - the realistic appliance case). Counted by
  `completion_tokens` via `stream_options.include_usage`, NOT stream chunks (MTP packs 2-3 tok/chunk).
- Prefill measured with UNIQUE, uncacheable prompts large enough (~6.6k tokens) that the cap actually
  clamps the clock. Short or repeated prompts boost past the cap and hit the prefix cache - those
  numbers are meaningless for comparing envelopes; do not use them.
- A completed run is not proof of correctness (silent corruption completes happily). Coherence was
  checked with known-answer temp-0 tripwires and a non-ASCII/gibberish scan; a 10-min real-load soak
  watched HBM temp + Xid. See the caveats at the end.

## The offset axis: +250 is the ceiling

Consistent with the qualification matrix in `measurement-matrix.md`: **+250 is the highest safe
undervolt on this card; +300 faults.** Re-confirmed here at the capped operating point - stepping the
offset up under a live 200W cap, +250 and +265 stayed clean but **+280/+290 threw Xid-13 (Illegal
Instruction) on the weak SMs at GPC3/TPC6**, then Xid-43. The risk lever is voltage-at-frequency, not
offset or clock alone: +250 survives clocks where +300 dies, and +300 dies even at low clocks. Ship
at +250, one step below the fault.

Undervolt HELPS thermals (lower voltage at a given clock = less power = less heat), so +250 is both
the fastest-per-watt and the coolest safe offset. There is no reason to run below it or above it.

## The power/clock staircase (offset +250, real inference)

Sustained SM clock and actual draw as the cap steps down, cap Active throughout (pure power-limited
slope - there is no ledge where dropping watts holds the clock; watts and clock move together):

| power cap | sustained clock | actual watts |
|-----------|-----------------|--------------|
| 250 W     | 1490 MHz        | 243 W        |
| 230 W     | 1419 MHz        | 226 W        |
| 210 W     | 1344 MHz        | 209 W        |
| 200 W     | 1291 MHz        | 194 W        |
| 190 W     | 1230 MHz        | 191 W        |
| 180 W     | 1104 MHz        | 179 W        |
| 170 W     | 1010 MHz        | 169 W        |
| 160 W     |  958 MHz        | 161 W        |
| 150 W     |  901 MHz        | 150 W        |
| 140 W     |  798 MHz        | 141 W        |
| 130 W     |  682 MHz        | 127 W        |
| 120 W     |  560 MHz        | 118 W        |
| 110 W     |  517 MHz        | 110 W        |

The only flat (where more watts stop buying clock) is ABOVE ~250W, where the +250 V/F curve tops out
(~1490-1590 MHz at 243-280W; the SW power cap engages around 1600). In the usable thermal range it is
all slope. Per-watt efficiency (MHz/W) is best low and worsens as the clock climbs, so 200W+ sits on
the wasteful upper part of the curve.

## Performance vs envelope, and the knee

| envelope (offset +250) | sustained clock | prefill (6.6k, uncontended) | decode single-stream | decode under 6-way load |
|------------------------|-----------------|-----------------------------|----------------------|-------------------------|
| 150 W                  | ~918 MHz        | 1,421 tok/s                 | ~60 tok/s            | 45 tok/s                |
| **175 W**              | **~1,140 MHz**  | **1,712 tok/s**             | **~78 tok/s**        | **60 tok/s**            |
| 200 W                  | ~1,320 MHz      | 1,929 tok/s                 | ~87 tok/s            | 62 tok/s                |
| 250 W (uncapped-ish)   | ~1,490 MHz      | -                           | ~94 tok/s            | -                       |

**175W is the efficiency knee.** Two effects set it:

- **Decode is kernel-launch-bound**, not clock-bound, at these clocks. Under real concurrent load it is
  FLAT at 60-62 tok/s from 175W to 200W - the extra 180 MHz buys nothing. Below 175W the clock finally
  becomes the bottleneck and decode falls off (60 -> 45 at 150W).
- **Prefill is GEMM/compute-bound**, so it DOES scale with clock: ~11% from 175W to 200W (1,712 ->
  1,929). A prefill-heavy workload (long prompts) pays for the lower clock; a decode-heavy one
  (long generations) barely notices.

So 175W holds full serving decode throughput while shedding 25W and running the HBM ~6C cooler than
200W. 175 and 180W are within measurement noise - pick 175. Drop below it only if you are power- or
thermal-starved and can accept the decode cliff.

## Thermal envelope

Passive card: GPU max-op 85C, HW slowdown 95C; HBM max-op 95C. HBM is the warmest sensor under load -
watch `temperature.memory`, not the core. A 10-minute continuous 6-way-inference soak at 200W held
coherent (known-answer tripwires clean, no gibberish), HBM steady at 84-85C, GPU 78C, zero Xid. 175W
runs several degrees cooler, widening the margin. Prefer the cooler envelope when airflow at the
deployment site is unknown.

## Recommended sustained/delivery config

```
offset      +250          # max safe undervolt; +300 = Xid-13 on the weak SMs
power cap    175 W        # the efficiency knee: full decode throughput, coolest that holds it
mem clock    stock        # bandwidth does not help decode on this kernel-launch-bound workload;
                          # the mem OC was pure power/heat downside for zero decode gain
```

Raise the cap toward 200W only for a prefill-heavy workload AND when cooling allows. Never exceed +250
offset. For the memory side (timings, refresh) see [`hbm-timing-understanding.md`](hbm-timing-understanding.md).

## Caveats (learned the hard way)

- **Prefix caching inflates prefill.** Repeated/short prompts hit the cache and report impossible
  rates. Measure with unique content sized so the cap clamps the clock.
- **A synthetic GEMM is not a serving proxy for power.** A dense fp32 matmul draws a different
  power/clock profile than gated-DeltaNet inference and can ignore a power cap that inference
  respects. Measure power/clock under the engine you will actually serve.
- **Short probes are cold.** Clock settles in seconds but temperature does not; only a multi-minute
  soak gives steady-state HBM temp. The staircase clocks are settled; the "under load" temps in short
  probes are NOT steady-state - trust the soak for thermal numbers.
- **A completed benchmark is not a passing gate.** Silent corruption completes without a fault. Gate
  with a real-workload rung and known-answer checks, per the tuning guide.
