# Idle power

A 170HX has one performance state. The driver never lowers the HBM clock, and it holds the SM at
1140 MHz whenever a CUDA context exists, so a card with an inference server resident and idle
draws about 41 W doing nothing. `170tune idle` gives the card the idle state it lacks: while it is
quiet its HBM drops to 810 MHz and its SM is locked low, and the first sign of work puts it back
on its own profile.

It is opt-in, per card, and receipt-gated like everything else here.

## Where the idle floor is

Measured on a 0x20C2 card (NDIV 64 stock, VBIOS 92.00.6D.00.0A), no CUDA context, 10 s averages:

| state | draw |
|---|---|
| stock (NDIV 64, REFRESH 6) | 38.5 W |
| REFRESH 12 / 24 / 48 at NDIV 64 | 34.6 / 32.5 / 31.4 W |
| NDIV 54 / 45 / 40 / 34 / 30 at REFRESH 6 | 37.4 / 36.3 / 35.7 / 34.9 / 34.4 W |
| **NDIV 30 + REFRESH 24** | **29.4 W** |
| NDIV 30 + REFRESH 48 | 28.5 W |

With a context resident the SM sits at 1140 MHz instead of 405; locking it to 210 (it lands at
450 with a context) is worth about 2.6 W. So the floor is mostly the HBM - its refresh and its
clock - not the core, which is why locking clocks low on its own (the usual answer for
single-P-state datacenter cards) buys so little here. A power cap below the VBIOS minimum does
nothing at idle either: the card is already far below any cap.

Refresh power falls as 1/field: at NDIV 30 and REFRESH 24 about 1.5 W of refresh is left. A
card that also passes a third gate (REFRESH 48 at NDIV 30) idles on 48 and gets most of it back
(29.33 -> 28.56 W on the reference card); a card that fails it simply idles on 24. Going further
buys fractions of a watt for a rapidly shrinking retention margin.

With a model resident on two cards (pipeline-parallel): **82.5 W -> 59.1 W for the
pair** (29.6-30.3 W per card). The first request after an idle period pays for the wake-up: time
to first token went from 48-50 ms to 88-133 ms; decode speed is unchanged.

## What it does

| | HBM clock | refresh | SM |
|---|---|---|---|
| busy | the card's busy NDIV | busy refresh, or 24 while cool | 210..busy ceiling |
| idle (quiet for 60 s) | NDIV 30, while cool | busy refresh, or 24 (48 if gated) while cool | locked to 210 |

The busy profile is exactly what `boot-apply` leaves the card on: the persisted NDIV, REFRESH and
clock ceiling when `170tune-persist` is enabled, else stock with no clock lock. Stopping the
daemon puts every card back on it.

A card is busy the moment NVML reports any SM or memory utilization, or - while idle - its draw
rises 12 W above the draw it settled at when it went idle (utilization is averaged over up to a
second; the power sensor reacts in about 20 ms). It goes idle after 60 quiet seconds
(`--idle-after S`). The saving that matters is the long idle stretch - overnight, between
sessions - not the few seconds between two requests: an agent or chat client leaves gaps of 5-30 s
between tool calls, and a short timer makes each one pay the wake-up and puts the card through an
HBM clock and refresh change every time (one tenant's 25 s duty cycle meant ~140 transitions an
hour). A minute keeps interactive use at full clocks and costs a few watt-minutes per session. Each card
moves on its own, which is also right for a model split pipeline- or tensor-parallel across cards:
while it serves, every card shows utilization every second and none reaches 60 quiet seconds, and
at the start of a burst the second card's own wake-up is lost in the first one's (first token from
idle 88-124 ms independent vs 88-133 ms grouped, two-card pipeline-parallel). `--group` (wake and
idle together) exists for setups where that does not hold; its cost is that one busy card keeps
the others awake, e.g. an image job on one card holding an idle inference card at full clocks.

## Why it is gated, and how

Two things here can corrupt memory, and neither shows up as a crash:

- **Retention.** A longer refresh interval holds only while the cells are cool enough; retention
  time falls steeply with temperature (JEDEC halves the interval above 85 C). A receipt proves an
  interval up to the HBM temperature its gate reached, no further.
- **The idle clock.** The PHY eye was trained at the stock clock. 810 MHz runs on it bare, and has
  to be proven like any other NDIV.

`170tune -i N idle gate` runs `hbm-gate` twice on the card: REFRESH 24 at its busy NDIV and
REFRESH 24 at NDIV 30 (12 hot sweeps each by default), then an optional third gate, REFRESH 48 at
NDIV 30, for the deeper idle-only refresh. Both receipts are what lets `idle enable`
touch that card's HBM, and it derives the temperature ceiling from them: refresh is loosened and
the clock dropped only at or below the lower of the two receipts' peak HBM temperature minus 3 C,
and both back off as soon as the HBM reaches that peak. Like every HBM receipt they are bound to
the serial, driver and VBIOS; the daemon re-checks the driver and VBIOS at start and runs a card
SM-only if either changed. A card with no receipts still idles its SM - an underclock needs no
proof.

### The trade-off of the deeper idle refresh

REFRESH 48 at NDIV 30 is a ~61 us interval, about 15x the JEDEC 3.9 us (REFRESH 24 at NDIV 30 is
~30 us). What it risks is a retention bit flip, and on this card that would be silent: the 170HX
has no ECC, so there is no Xid and no crash - at idle the resident data is mostly model weights,
so a flip shows up as slightly worse output until the model is reloaded. What bounds the risk:

- the gate is a real retention test at exactly this point: 12 full-VRAM write-then-read-back
  sweeps, data resident for tens of seconds between write and read, at 59-67 C;
- 48 is only used at or below the receipts' peak minus 3 C, i.e. cooler than it was proven;
- the measured edge is far away: clean out to ~192 us at 64 C, wedged at ~383 us.

What the gate cannot rule out is rare variable-retention events over hours of idle, so the gain
(~0.8 W per card) is traded for a small, unquantified residual risk. Set `IDLE_DEEP_REFRESH=24`
before `idle enable` to keep idle cards on REFRESH 24 instead.

The transition itself was tested separately: about 390 live NDIV 30 <-> 64, clock-lock and
REFRESH 6 <-> 24 flips at 0.1-1.4 s intervals during full-VRAM write/read-back sweeps, on two
cards: zero memory errors, zero PLL lock failures, zero Xids.

## Using it

```bash
170tune -i 0 idle gate          # per card, card free (it sweeps ~95% of VRAM)
170tune -i 1 idle gate
170tune idle enable [--group]   # conf for every 170HX, starts 170tune-idle.service
170tune idle status
```

`idle disable` stops the service; `idle pause` / `idle resume` hand every card back and take them
again. You do not need to pause for tuning: every mutating 170tune command takes its own card back
for as long as it runs (the daemon restores the card's busy profile and stops touching it).
`apply` and `reset` hand off to `170hx-oc` and never come back, so their card stays out of idle
management until `idle resume`.

Safety nets: a new Xid on a card, a PLL that does not lock or a refresh readback mismatch disarms
that card (busy profile, left alone until the service restarts). The service's `ExecStopPost`
restores every managed card even if the daemon crashed.

## Requirements

- The cmpunlocker HBM control PLMs open (`FBPA_MEM` and the FBPA PLL). A card where they are
  closed drops every HBM write, so `idle gate` fails on it - run it SM-only.
- 170tune's own requirements (`iomem=relaxed`, a stock memory clock, NVML).

The daemon is `tools/idle_power.c`; its decisions live in `tools/idle_policy.h`, unit-tested by
`tests/idle_policy_test.c`. It shells out to `hbm_mclk` and `fbpa_regs` for every register write,
so the PLL sequence and its lock guard stay in one place. It polls at 10 Hz and costs about 0.17%
of one core and 8.5 MB, most of it NVML and the 30 s health check (dmesg, a helper readback).
