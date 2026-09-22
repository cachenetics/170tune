# CMP 170HX tuning guide

This is the manual: how to take a CMP 170HX from a stock card to a persisted, qualified
tune, on the SM side and the HBM side, without ever trusting a run that merely completed.
It is task-first; the mechanism behind each lever is summarized where you need it and
covered in depth in [mechanism.md](mechanism.md) (SM) and
[hbm-timing-understanding.md](hbm-timing-understanding.md) (memory).

Every number cited here was measured on the reference card (serial 1322621047793: GA100,
70 SM, 64 GB HBM2e, driver 610.43.03, stock 300 W VBIOS 92.00.6D.00.0A, PCIe Gen2 x4).
Per-card silicon varies. The reference numbers tell you where to start and what shape to
expect; only a gate on your own card tells you where to stop. All measured tables live in
[reference-matrices.md](reference-matrices.md).

## 1. Before you start

Check the [requirements in the README](../README.md#requirements) (unlock applied,
`iomem=relaxed`, NVML, CUDA toolkit), then:

```bash
sudo ./install.sh              # build the helpers from source, install to /usr/local/bin
sudo 170tune preflight         # card identity, driver, unlock, BAR0 access, stock clock
sudo 170tune snapshot-stock    # record THIS card's stock values as its revert baseline (once)
```

`preflight` prints exactly what to fix on any failure. `snapshot-stock` matters: it is the
per-serial record of what "stock" means on your card, and every revert path depends on it.
Run it once, before touching any memory lever.

On a box with more than one card, every command takes `-i N` / `--gpu N`; qualification,
receipts, and persistence are all per-serial. See
[Multiple cards in the README](../README.md#multiple-cards).

## 2. How tuning works here, and the caveat that governs it

Every change 170tune makes is volatile: a userspace NVML call or a live BAR0 register
write, lost on reboot or driver reload. The card always boots stock, so a bad experiment
is a reboot away from gone.

The workflow for every lever is the same three steps:

1. **Try** a point and measure it. The output is explicitly marked unverified.
2. **Gate** it: soak the card hot, run full-VRAM write / read-back pattern sweeps plus a
   bit-exact compute check. A passing gate writes a per-serial receipt.
3. **Persist** it: `persist save` demands the receipt, `persist enable` installs the boot
   service.

One caveat governs everything, and it is stated here once because it was learned at full
price: **a passing gate is necessary but not sufficient for serving.** The gate's sweeps
and GEMM are a narrower stress than a real application. On the reference card, SM points
at +300/+350 passed a cool GEMM, passed the full gate, served benchmarks for a day, and
then faulted under an hour-long soak; on the memory side, NDIV 76 gated 12/12 on the
pattern sweep and wedged on the first minute of real serving. Before a point carries real
work, run it under the workload it will actually serve: `gate` and `hbm-gate` both take
`--workload <command>` as the final rung for exactly this reason, and there is a worked
vLLM rung in `vllm_workload_check.sh` to copy. Nothing later in this guide re-litigates
this; every "qualified" below means "gated, then survived the real workload".

## 3. The SM side: undervolt and ceiling

### 3.1 The two levers

The SM tune is two settings applied together:

- **The VF offset** (via NVML): `+X` shifts the voltage/frequency curve so any given clock
  is reached at lower voltage. With the clock pinned it is a pure undervolt: measured on
  the reference card, the same 1350 MHz throughput at -24 percent power.
- **The clock ceiling** (`nvidia-smi -lgc 210,<max>`): the offset alone buys nothing; it
  just lets the clock arbiter climb. Pinning a ceiling banks the saving as watts. The 210
  low end preserves idle downclocking. The power limit stays wide open at 300 W; capping
  the clock beats capping power for efficiency.

Why this works, the two failure regimes, and the NAFLL clock-stretch behavior are in
[mechanism.md](mechanism.md).

### 3.2 Where to start

The serving-qualified offsets on the reference card are **+200 and +250**; they are
equivalent within noise, and +250 is the recommended default. Offsets of +300 and above
are bench-only on this card: they fault under a sustained serving soak at every ceiling
tested. Pick the ceiling by goal:

- **1200 MHz**: peak efficiency (2.03 tok/s per W serving on the reference card).
- **1400 MHz**: peak qualified throughput, still ~29 percent under stock power.

Two rules of thumb from the measured landscape: below a ~1350 ceiling the voltage rail
bottoms out around +250, so ship the lowest offset that reaches the flat, never the
highest that appears to work; above ~1400 the corruption cliff arrives first, and the
margin between clean and silently corrupting can be a single 25 MHz offset step. Full
grids and boundaries: [reference-matrices.md](reference-matrices.md).

Named profiles exist (`170tune apply dense|eff|match|balanced|perf|max`); the ones at
+300/+350 (eff, balanced, perf, max) are bench points for synthetic work, not serving
points. See the [profile table](reference-matrices.md#named-profiles-bench-points).

### 3.3 Walkthrough

```bash
170tune explain                 # the levers and failure modes, on-card
sudo 170tune try 250 1400       # apply one point and measure it (marked UNVERIFIED)
sudo 170tune gate 250 1400 4 \
     --workload /usr/local/bin/vllm_workload_check.sh
                                # the proof: hot soak, 4 full-VRAM sweeps, compute check,
                                # then your real workload as the last rung; writes the receipt
```

To find your own card's edge instead of trusting the reference numbers:

```bash
sudo 170tune ladder 1400        # walk the offset up at one ceiling, gating each rung;
                                # prints the highest gated offset - ship BELOW it, not at it
sudo 170tune qualify            # the whole per-card flow, recorded to
                                # /var/lib/170tune/results/<serial>/oc.json
```

`170tune reset` returns to stock (offset 0, no lock, 250 W). If a point that gated clean
later misbehaves in service, record it: `170tune quarantine <off> <clk> --reason "..."`,
and `persist save` will refuse it from then on even with a passing receipt.

### 3.4 Do not exceed

On the reference card: +250 is the last serving-clean offset (+280/+290 fault under a
power cap; +300 faults everywhere under soak); +375 faults at 1400; +450 hard-crashes the
GPU and can demand a power cycle; ceilings above 1650 deliver nothing (the silicon tops
out at ~1604-1614 MHz). A point that "runs" at a very high offset may simply be
clock-stretching itself slower; see [mechanism.md](mechanism.md). On your card, the
numbers will differ; the ladder and the gate find them.

## 4. Choosing the envelope: clock ceiling or power cap

A `-lgc` ceiling gives the best efficiency when you control cooling. A hard power cap
(`nvidia-smi -pl`) bounds heat regardless of workload, which is the right trade for a
passively cooled card that runs unattended. The measured envelope, the power/clock
staircase, and the 175 W efficiency knee are in
[power-cap-curve.md](power-cap-curve.md). The short version, for a delivery box:

```
offset +250, power cap 175 W, stock memory
```

175 W holds full decode throughput, sheds 25 W against 200 W, and runs the HBM about 6 C
cooler.

## 5. The HBM side: the memory clock

### 5.1 The lever

The memory clock is the FBPA PLL multiplier NDIV: clock = NDIV x 27 MHz, stock NDIV 64 =
1728 MHz. 170tune moves it live over BAR0; the write is volatile and `nvidia-smi` cannot
see it (it reports 1728 MHz at every NDIV; the proof of movement is bandwidth above the
stock theoretical ceiling). How the clock interacts with the DRAM timings, and why the
card has two different kinds of memory ceiling, is the subject of
[hbm-timing-understanding.md](hbm-timing-understanding.md); read it before going past the
recommended point.

### 5.2 Two hard operational rules

1. **Never change NDIV under an active CUDA context.** It wedges the GPU (Xid 45/119,
   power cycle to recover). Set the clock on an idle card, then start serving.
2. **Keep the GPU fan driven by HBM temperature whenever the card serves.** The 170HX is
   passive; on a BIOS-curve fan header it heat-soaks regardless of clock, and an
   overclocked memory point corrupts as HBM passes ~75 C. Watch `temperature.memory`: HBM
   is the warmest sensor on the card (max operating 95 C; GPU core 85 C).

### 5.3 Where to start

The serving ceiling on the reference card is **NDIV 70** (1890 MHz, +10.2 percent read
bandwidth), with **stock timings**: held with zero Xids under sustained and concurrent
inference with HBM at or below 76 C. Above it, NDIV 72 corrupts as the HBM heats and
74-76 crash under serving; NDIV 76 remains a real bench ceiling for gated, memory-bound
synthetic work. NDIV 68 is the ultra-conservative choice, one step of extra guardband.

Set expectations correctly: single-stream decode is only ~40 percent
weight-bandwidth-bound, so the memory overclock buys roughly nothing for decode speed.
NDIV 70 is for the margin and for genuinely bandwidth-bound work.

### 5.4 Walkthrough

```bash
170tune explain-hbm             # the memory model, on-card
sudo 170tune mclk-status        # current NDIV / MHz / PLL lock / unlock state
sudo 170tune mclk-try 70        # set the clock live and prove it moved (UNVERIFIED)
sudo 170tune mclk-gate 70 12    # 12 hot full-VRAM sweeps + compute check (a cold gate
                                # is a failure: HBM corruption is temperature-dependent)
sudo 170tune hbm-matrix         # optional: the bandwidth-per-NDIV grid for your card
sudo 170tune mclk-ladder        # optional: find your card's own pattern-sweep ceiling
```

Then qualify the exact combined profile under your real workload; this is the only flow
that writes the HBM persistence receipt:

```bash
sudo WORKLOAD_TIMEOUT=28800 170tune hbm-gate \
  --ndiv 70 --timings "REFRESH 24" --sweeps 12 \
  --workload "/path/to/your/real-serving-soak.sh"
```

### 5.5 Timings and refresh

**Keep stock DRAM timings in production.** Raising NDIV already tightens every timing in
nanoseconds for free; tighter cycle counts buy nothing measurable and spend the
silent-corruption budget, and looser ones only add latency. The clock is the only change
that pays ([why](hbm-timing-understanding.md)). The exploration tools exist
(`170tune timings`, `timings-gate`, `timings-tune`, `timings-stock`) and are how the model
was measured, but no timing change is on the ship path.

**The refresh interval is an opt-in power lever.** Loosening it to REFRESH 24 (about 4x
the stock interval) cuts idle power ~15 percent and load power up to ~14 percent with no
bandwidth or latency cost, deep inside the measured retention margin
([table](reference-matrices.md#refresh-lever)). It ships opt-in because retention is
temperature-dependent and was validated only to ~66 C: keep stock refresh on any card
above 85 C or with unknown thermals, and gate it on your card with
`170tune refresh gate <us>`, which uses a write / hold / read-back test (a retention bit
flip passes a compute check, so a compute check is not a gate here).
`170tune refresh {status|set <us>|gate <us>|stock}` drives it; persist it only as part of
the combined `hbm-gate ... --timings "REFRESH 24"` profile.

## 6. Persisting a qualified point

```bash
sudo 170tune persist save --offset 250 --clk 1400     # an SM point (demands its gate receipt)
sudo 170tune persist save --ndiv 70 --timings "REFRESH 24"   # the HBM profile (demands hbm-gate's receipt)
sudo 170tune persist enable                            # install + enable the boot service
170tune persist status                                 # profile, service state, quarantine
```

How it behaves:

- One conf per serial, one systemd unit; `170tune boot-apply` re-applies the profile in
  userspace after the driver is up. **The card still boots stock first**, so a bad profile
  is recoverable over ssh (`170tune persist disable`, or
  `systemctl mask 170tune-persist.service`), never a brick.
- Persistence is receipt-gated. A gate writes a per-serial receipt binding the point to
  this card's serial, PCI device ID, driver, and VBIOS, and recording sweep count, peak
  HBM temperature, and the workload result. `persist save` demands it, `persist enable`
  re-checks it, and a driver or VBIOS change invalidates it. `--force` is an expert escape
  hatch and is permanently labeled as one in the stored profile.
- The apply is self-disarming: an armed marker is written before every risky apply and
  cleared when the run checks in. If a boot went down mid-apply, the next boot stays stock
  and records what was in flight (`170tune boot-check`).
- A quarantined point (a point that gated clean but faulted in service) is refused by
  `persist save` regardless of its receipt.

A box still on the retired per-profile `170hx-oc.service` model is migrated automatically
by `170tune install`, loudly, never silently (see [CHANGELOG.md](CHANGELOG.md)).

## 7. Qualifying a new card

The reference numbers transfer as starting points, never as conclusions. On a new card:

1. `sudo 170tune install`, `sudo 170tune preflight`, `sudo 170tune snapshot-stock` (once).
2. Confirm the unlock: `sudo nvml_oc` must show a GPC offset range that is not `[0..0]`,
   and `preflight` must show the FBPA windows open.
3. Baseline stock: `sudo 170tune apply stock` if needed, then measure.
4. SM: `sudo 170tune ladder <clk>` or `sudo 170tune qualify` to walk the offset up with
   the gate at every rung. Stop at the first fault and back off a full step, not one bin.
5. HBM: `mclk-ladder` for the pattern ceiling, then `hbm-gate` with your real workload for
   the serving point. Expect your serving ceiling below your pattern ceiling.
6. Persist deliberately (section 6). Prefer margin over a number that looks equal on
   paper: when two points measure the same, ship the one further from the edge.

## 8. When something goes wrong

- `170tune status`: current settings, armed markers, crash records. It probes usability by
  actually creating a CUDA context; a healthy-looking `nvidia-smi` proves nothing (the
  card can answer queries while no process can get a context).
- `170tune recover`: after a fault or hang, clears offsets and locks, reloads the driver
  if the card is wedged, and escalates honestly to "reboot" or "power cycle" when that is
  what it takes. It does not declare the card recovered until a CUDA context can be
  created on it.
- `170tune selftest`: proves the detectors themselves still work before you trust a PASS.
- **`[FAIL] memory clock source (driver-baked, unsupported for tuning)`** on a driver you
  built with no `--mclk-ndiv`: this tool's stock reference (NDIV 64 / 1728 MHz) was
  measured on one card; a different VBIOS revision can genuinely stock at a different
  NDIV. Confirm with `hbm_mclk get`, then override per-card:
  `STOCK_NDIV=<that value> 170tune snapshot-stock` persists it so nothing after this
  needs the env var again.
- The failure ladder, worst first, is in the [README's Safety section](../README.md#safety).

## 9. Tool inventory

Everything is invoked through `170tune`; the helpers underneath, for reference:

- `nvml_oc`: query/apply GPC and MEM VF offsets; the range query confirms the unlock.
- `oc_eff.cu`: sustained bf16 GEMM with in-process NVML power sampling (TFLOPS, W,
  GFLOPS/W).
- `170hx-oc`: the SM profile applier (`170tune apply` hands off to it); named profiles or
  a per-card `custom <off> <clk>` point.
- `170hx-sweep` + `gpu_selftest.cu`: the integrity gate: full-VRAM unique-pattern
  write/verify plus a compute checksum.
- `compute_check.cu`: deterministic bf16 GEMM compared bit for bit; catches silent compute
  corruption the memory sweep cannot see.
- `ctx_probe.cu`: the smallest proof the card is usable: create a context, allocate,
  launch, read back.
- `mem_probe.cu`, `gemm_probe.cu`: streaming bandwidth/latency and GEMM datatype probes.
- `170hx-soak`: repeats a workload for hours and fails on any new Xid: what decides
  whether a gated point ships.
- `hbm_mclk.c`: live BAR0 control of the FBPA PLL (NDIV), with the PRI fence and PLL-lock
  poll.
- `fbpa_regs.c`: live BAR0 control of the DRAM CONFIG timings and the refresh field.
- `nvidia_bench.cu`: HBM bandwidth/latency bench (read/copy/triad, pointer-chase latency).
- `vllm_workload_check.sh`: the worked example of a real serving workload rung for
  `--workload`.
