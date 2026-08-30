# HBM timing on the CMP 170HX

This document explains how the HBM2e memory system on this card works: what the memory clock
is, what the DRAM timings are, why raising the clock tightens every timing at once, and why
the card has two fundamentally different kinds of memory-clock ceiling. The
[tuning guide](tuning-guide.md) tells you what to run; this document tells you why the memory
behaves the way it does, so that when your card differs from the reference card you can reason
about it instead of guessing.

All figures were measured on the reference card (serial 1322621047793, GA100, 8 active FBPAs,
4096-bit HBM2e, driver 610.43.03). Timing floors are properties of the individual memory
stacks and vary between cards. Treat the numbers as one card's characterization; the model is
the transferable part.

## 1. The memory clock is a multiplier

Each FBPA (frame buffer partition) generates the HBM clock with a PLL that multiplies a
27 MHz reference by an integer field called NDIV:

```
memory clock (MHz) = NDIV x 27
```

Stock is NDIV 64, or 1728 MHz. Each NDIV step moves the clock 27 MHz. 170tune changes the
clock by rewriting the PLL coefficient over BAR0 while the system runs. Three things make
that write valid:

- it must land after GSP initialization, because an earlier write is overwritten by GSP's
  own device init;
- it must be multicast to all eight FBPAs, so every partition changes together;
- it is followed by a PRI fence and a poll for PLL lock before the new clock is trusted.

The change is volatile. A reboot or driver reload restores stock, which is the safety
property the whole tool leans on: no memory-clock experiment can outlive a power cycle.

`nvidia-smi` cannot see any of this. Its memory-clock field reports the driver's belief,
which is 1728 MHz at every NDIV. The proof that the clock moved is physical: delivered read
bandwidth above the stock clock's theoretical ceiling of 1769 GB/s is impossible unless the
DRAM clock actually rose, and that is exactly what the measured grid shows (see the
[NDIV bandwidth grid](reference-matrices.md#hbm-ndiv-bandwidth-grid)).

## 2. Timings are cycle counts, so the clock tightens all of them

Every DRAM timing on this card is stored as a fixed count of memory-clock cycles. The DRAM
itself does not care about cycles; it cares about real time. A timing's real-time value is:

```
t (ns) = cycles x 1000 / mclk_MHz
```

The cycle counts do not change when you raise NDIV, but the clock period shrinks, so every
timing gets shorter in nanoseconds simultaneously. Raise the clock 8 percent and tRC, tCL,
tRP, the refresh interval, the bus turnaround gaps, all of them, are 8 percent tighter in
real time at once.

This single fact drives every practical conclusion in this document:

- An overclock never needs tighter timings. The clock already tightened all of them for
  free. Tightening cycle counts on top of an overclock buys nothing measurable and spends
  stability margin (section 8 shows this was tested, not assumed).
- The failure point of an overclock is whichever timing's real-time value crosses its
  silicon minimum first. Finding the ceiling is finding the first timing to bind.
- Loosening a timing (raising its cycle count) is how you buy back real time at a higher
  clock, at the cost of the cycles themselves.

## 3. What "stable" means: the real floor, not the datasheet

Call the true minimum real-time value a given timing needs tau_min. Stability means every
timing stays at or above its tau_min. The stock cycle counts were chosen so that at
1728 MHz each timing sits near its JEDEC nanosecond specification.

JEDEC values carry guardband, and this silicon beats it by a wide margin: the stock cycle
counts still clear every floor at NDIV 76 (2052 MHz), where every timing runs well below its
JEDEC nanosecond value. The true floors are therefore empirical, discovered by testing, not
read from a datasheet.

Once you know a timing's tau_min, its required cycle count at any clock f follows directly:

```
C(t, f) = ceil(tau_min(t) x f / 1000)
```

This is the predictive equation for the whole timing space: measure the failing edge once,
in cycles, convert to nanoseconds, and you can compute the correct cycle count for every
other clock.

## 4. The timing map in nanoseconds

The table below is the card's timing map decoded into real time, at stock (NDIV 64,
1728 MHz) and at NDIV 77 (2079 MHz) to show how the same cycle counts compress as the clock
rises. Fields live in the FBPA CONFIG0-4 registers, driven by `170tune timings`.

| field | reg | cycles | ns at 1728 | ns at 2079 | role |
|---|---|---:|---:|---:|---|
| tRC | CONFIG0 | 67 | 38.8 | 32.2 | row cycle |
| tRFC | CONFIG0/10 | 657 | 380 | 316 | all-bank refresh duration |
| tRAS | CONFIG0 | 43 | 24.9 | 20.7 | row active |
| tRP | CONFIG0 | 24 | 13.9 | 11.5 | precharge |
| tRCD_rd/wr | CONFIG1 | 27/18 | 15.6/10.4 | 13.0/8.7 | RAS-to-CAS |
| tCL | CONFIG1 | 37 | 21.4 | 17.8 | CAS latency: the data-sampling point (the eye) |
| tWL | CONFIG1 | 10 | 5.8 | 4.8 | write latency |
| tWR | CONFIG2 | 25 | 14.5 | 12.0 | write recovery |
| tW2R_BUS / tR2W_BUS | CONFIG2 | 8 | 4.6 | 3.85 | bus turnaround |
| CDLR | CONFIG2 | 9 | 5.2 | 4.3 | CAS-to-CAS data path |
| tFAW | CONFIG3 | 22 | 12.7 | 10.6 | four-activate window |
| tCCD_L / tCCD_S | CONFIG3 | 4/2 | 2.3/1.2 | 1.9/1.0 | column-to-column (burst floor) |
| tRRD | CONFIG4 | 5 | 2.9 | 2.4 | activate-to-activate |
| REFRESH (tREFI) | CONFIG4 | 6 | encoded | encoded | refresh interval (section 7) |

CONFIG0-4 are fully decoded and cross-validated one-to-one against nouveau's `timing_10_*`
field names. The rest of the FBPA register window is mapped but its field packing is
unconfirmed; no public bit-field map exists for the GA100 FBPA, and the block is shared
across GDDR and HBM generations, so unidentified fields may be vestigial on HBM2e.

## 5. The constraint stack: what binds as the clock rises

As NDIV rises, the timings do not all reach their floors together. They bind in a fixed
order, and each layer has its own failure signature and its own lever. On the reference
card, measured by isolating each layer:

**Layer 0: nothing binds through NDIV 76.** The stock cycle counts clear every floor up to
2052 MHz. No tuning, no loosening: 12 of 12 hot pattern sweeps clean, bare. This is the
robust bench ceiling on stock timings.

**Layer 1: the row and command timings (first to bind, at NDIV 77).** When a row timing
(tRC, tRAS, tRP, tRCD, tRFC) crosses its floor, the failure is not subtle: the memory
controller hard-hangs and the machine needs a reboot. The lever is to loosen the command
set by the clock ratio, holding each field at its stock nanosecond value, per the equation
in section 3. That removes the hang and lets NDIV 77 run.

**Layer 2: the data eye (tCL and the read delay lines).** tCL sets where in the clock cycle
the controller samples read data. The valid sampling window is called the eye, and it
narrows as the clock rises. Two levers exist here. A DDLL recalibration re-centers the read
delay lines at the live clock, but it is non-deterministic: it does not land on center
every time, which disqualifies it from any ship path. Raising tCL itself is not a
controller-side change alone; the DRAM's own read-latency code (mode register MR2) must be
re-issued to match, or the read pointer desynchronizes.

**Layer 3: bus turnaround and the fine data path.** tW2R_BUS / tR2W_BUS (the gap when the
bus reverses direction between a write and a read) and CDLR are the next margins to shave
close, at 3.85 ns and 4.3 ns respectively at 2079 MHz. Loosening them buys the next
increment of margin after the command set.

**Floors that do not bind in this range:** tCCD, the burst floor, is already at its hard
minimum at stock; do not touch it (tightening it hangs the controller outright). The
refresh interval has margin to spare and is not what limits the clock; it is a separate
axis entirely (section 7).

One caution about this stack: making a clock run is not the same as making it hold.
Loosening the command set makes NDIV 77 boot and sweep, but what limits 77 in sustained
hot operation is retention, not any timing in the stack above. That distinction is the
subject of the next section, and it is the most important idea in this document.

## 6. Two ceilings with different physics: the data eye and retention

A memory overclock on this card runs into two independent walls, and they behave nothing
alike. Telling them apart is what separates a qualified operating point from a lucky run.

### The data-eye ceiling

Read data is valid on the bus only for a window within each clock cycle: the eye. The
controller must strobe inside it. As the clock rises the eye narrows, and it also narrows
with electrical stress: the access pattern of a real workload (concurrent readers, mixed
attention and KV traffic, GSP activity on the same fabric) closes the eye further than a
clean linear test pattern ever does.

An eye failure has a distinct signature:

- it is temperature-independent: it fails just as hard on a cold card;
- it is immediate and loud: Xid errors, CUDA faults, a wedged controller within the first
  real load, not a slow degradation;
- it is pattern-dependent: a linear pattern sweep can pass 12 of 12 at a clock where a
  serving workload dies on first contact.

On the reference card, NDIV 76 is exactly this. It is rock-solid under the memory-only
pattern sweep at 60-71 C, and it threw 4 Xids and wedged on the very first serving load
started cold at 56 C. Heat had nothing to do with it: the serving access pattern is what
its read eye cannot sample at 2052 MHz.

There is also a hard hardware bound underneath. The DRAM's MR2 read-latency field is 5 bits
wide and caps at 31 cycles. Holding the stock read latency in nanoseconds at 2052 MHz would
require about 34 cycles. The card ships at RL 29; raising it to the field maximum of 31,
together with tCL 37 to 39 and a DDLL recalibration, was tested and still crashed
identically under serving. So the eye at NDIV 76 and above is ultimately a field-width
wall: the read-latency register runs out of range before it can re-center the eye. NDIV 78
is the same wall visible even to the pattern sweep: it runs, but gates 0 of 8, and an
exhaustive centering hunt (repeated DDLL recalibration, the full RDRET_OFFSET range, tCL
35-40) found no working point.

### The retention ceiling

DRAM cells are capacitors and they leak. Refresh exists to recharge every cell before its
contents decay, and the hotter the silicon, the faster the leakage: JEDEC halves the
required refresh interval above 85 C for exactly this reason.

A retention failure has the opposite signature:

- it is temperature-dependent: clean cool, failing hot, with a sharp threshold;
- it is silent: single bit flips in data that nothing is currently reading, no Xid, no
  crash, no hang;
- it is invisible to compute checks: a flipped bit in memory the kernel never touches
  passes every benchmark. Only a write / hold / read-back test sees it.

On the reference card, NDIV 77 is exactly this. With the command set loosened (layer 1) it
runs, and it gates 16 of 16 clean with the HBM held at or below 61 C. At 64-66 C it fails
11 of 12 sweeps with about one bit error each: hot cells leaking faster than the stock
refresh rate cycles them. Tightening refresh does hold it (interval field 6 to 3 turned a
1-of-8 gate into 8 of 8), but the refresh overhead collapses bandwidth from roughly 1930 to
1298 GB/s, below stock. Holding NDIV 77 hot costs more bandwidth than the clock gains. It
is a net loss, robust only on a card chilled to 61 C or below, and not a general operating
point.

### How to tell which wall you hit

| symptom | eye | retention |
|---|---|---|
| fails on a cold card | yes | no |
| fails only past a temperature threshold | no | yes |
| Xid / fault / wedge on first load | yes | rarely |
| intermittent single-bit errors, no fault | no | yes |
| caught by a compute benchmark | sometimes | no |
| caught by write / hold / read-back | yes | yes |

This is why the gate is built the way it is: a hot, full-VRAM write / read-back sweep plus
a bit-exact compute check, and for any memory point, a rung under the real workload. A
compute benchmark alone cannot see retention at all, and a cool pattern sweep cannot see a
serving-pattern eye failure at all.

### The ceiling map on the reference card

| NDIV | MHz | standing |
|---|---|---|
| 70 | 1890 | serving ceiling: held with zero Xids under sustained and concurrent inference, HBM at or below 76 C |
| 72 | 1944 | thermal wall: serves clean cool (~67 C), corrupts as HBM passes ~75 C, wedges uncooled at 90 C |
| 74-76 | 1998-2052 | crash under serving; 76 is the temperature-independent eye wall described above |
| 76 | 2052 | pattern-sweep ceiling: 12/12 on stock timings, memory-only load, 60-71 C |
| 77 | 2079 | retention-marginal: needs command loosening to run, fails hot, net loss to hold |
| 78 | 2106 | eye wall even for the pattern sweep: 0/8, no centering exists |

Two ceilings, then, and neither is "the" ceiling without a qualifier. NDIV 76 is the bench
ceiling: real, reproducible, and honest for a memory-bound benchmark that has been gated.
NDIV 70 is the serving ceiling, and it is the number that matters for a card doing work.
The full bandwidth grid behind these rows is in the
[reference matrices](reference-matrices.md#hbm-ndiv-bandwidth-grid).

## 7. The refresh axis: retention, power, bandwidth

Refresh is a separate axis from the clock, and it is a three-way trade. The refresh
interval lives in the CONFIG4 REFRESH field as a linear clock count:

```
interval (us) = field x 1024 / mclk_MHz        (stock field 6 is ~3.9 us at 1728 MHz)
```

Note the interval is clock-relative: the same field value means a shorter real interval at
a higher NDIV. A smaller field means more frequent refresh: better retention, more power,
less bandwidth. A larger field is the reverse. That triangle is the whole model:

- **As a power lever, loosening is real and repeatable.** Measured at every NDIV tested:
  idle power fell from 41 to 35 W (-15 percent) and steady load from about 56 to 49-50 W
  (-11 to -14 percent), with latency flat to slightly better (fewer refresh stalls) and
  bandwidth flat. At idle, refresh is most of the card's draw, which is why the idle saving
  is so large; under a serving load compute dominates and the same loosening is worth only
  about 2.5 percent of board power.
- **The retention margin is enormous when cool.** At 64 C the card held clean out to field
  384, roughly 49 times the JEDEC interval, and only wedged at 768. This margin belongs to
  the temperature it was measured at: it was validated only to about 66 C, and JEDEC halves
  the interval above 85 C. A loose value that is deeply safe at 64 C can leak hot.
- **Refresh duration is not the same lever.** The interval (how often) matters; tRFC (how
  long each refresh takes) measurably does not (section 8).

The shipped compromise is field 24, about 4 times the stock interval: it captures most of
the power saving (-14 percent at the bench ceiling), holds 12 of 12 hot to 66 C, and sits
roughly 16 times inside the measured retention edge. It ships as an opt-in, not a default.
Keep stock refresh on any card that runs above 85 C or whose thermals are unknown, and gate
any loosening with a write / hold / read-back pattern test on your own card: a retention
bit flip passes a compute check, so a compute check is not a gate here. The measured table
is in the [reference matrices](reference-matrices.md#refresh-lever); the commands are in the
[tuning guide](tuning-guide.md).

A minor secondary effect: a looser interval slightly shrinks row-disturb margin. On a
single-tenant card this is negligible.

## 8. What does not help, and why

Each of these was tested on the card and moved nothing worth having. Knowing why saves
repeating them.

- **Tightening tRFC (refresh duration).** Cut 657 to 440 cycles, 33 percent tighter:
  bandwidth dead flat, all gates clean. Refresh duration is not on the bandwidth path at
  these intervals; the interval is what matters, and that is a different field.
- **Tightening activation timings (tRRD, tFAW, tRC).** All gated clean and moved read
  bandwidth not at all. Streaming read on this card is bus-, controller-, and
  temperature-bound, not activation-bound; the row engine is not the bottleneck.
- **Tightening tCL for latency.** tCL 37 to 33 (the floor is 33; CL 31 hard-wedges) moved
  measured latency about 2 ns. Pointer-chase latency is dominated by the access and TLB
  path, not the CAS timing. Latency's real lever is the clock itself: the higher NDIV rows
  in the grid show latency falling with clock while every timing tightening left it flat.
- **The DDLL eye recalibration.** Non-deterministic: it does not center the delay lines the
  same way twice, which makes it unusable for anything that must hold. It is relevant only
  as a probe on a genuinely eye-limited clock, and even there it topped out at 1 pass in 4.

The general lesson generalizes past this card: on a controller whose stock cycle counts
already beat the silicon's real floors, the only change that pays is the clock, because the
clock is the only knob that changes every timing's real-time value in the profitable
direction at once.

## 9. Putting it to work

For production the model collapses to something simple:

- **Keep stock timings.** Raising NDIV already tightened every timing in nanoseconds for
  free; tighter cycle counts buy nothing measurable and spend the silent-corruption budget,
  and looser ones only add latency. The clock is the only change that pays.
- **Ship the serving ceiling, not the bench ceiling.** NDIV 70 with stock timings, with the
  GPU fan driven by HBM temperature, is the qualified serving point on the reference card.
  Refresh field 24 is the opt-in power saving on top.
- **Gate for both walls.** Hot full-VRAM write / read-back sweeps catch retention; a rung
  under your real workload catches the eye. Neither substitutes for the other.

To characterize a different memory stack from scratch, the method is the model in reverse:

1. Dump the full timing map (`170tune timings dump`) and compute each field's nanosecond
   value at the target clock.
2. Walk NDIV up with hot gates (`170tune mclk-ladder`) until something binds. A hard hang
   is a command timing; loosen the command set by the clock ratio.
3. If a residual failure persists, classify it with the table in section 6: temperature-
   dependent and intermittent is retention (the fix is tighter refresh, and it costs
   bandwidth); temperature-independent and immediate is the eye (there may be no fix, as
   the MR2 field-width wall shows).
4. Gate hot with write / hold / read-back, 12 or more sweeps, bare where possible. The
   failing edge in cycles, times 1000 over the clock, is that field's tau_min; from there
   the equation in section 3 predicts every other clock.

The step-by-step commands, the serving qualification flow, and persistence are in the
[tuning guide](tuning-guide.md). Every measured table lives in the
[reference matrices](reference-matrices.md).
