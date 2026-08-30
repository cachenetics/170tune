# 170tune

Clock, undervolt, and memory tuning for the NVIDIA CMP 170HX (GA100), from userspace, live.

`170tune` is a single tool that measures, qualifies, applies, and persists tuning on a 170HX: the
SM clock and undervolt, the HBM memory clock (NDIV), the DRAM timings, and the refresh interval.
Every change is a live BAR0 register write. There is no driver rebuild and no VBIOS flash, and **the
card always boots stock**, so a bad profile is a reboot away from gone, never a brick you have to
drive to.

## The one rule

**"It did not crash" is not a result.**

On this card the failure that matters is silent. An overclock can pass every benchmark, throw no
Xid, never hang, and still return wrong bytes: intermittently, and worse when hot. A run that
completes proves nothing on its own. The only thing that qualifies an operating point is a gate that
looks for the corruption directly: a hot, full-VRAM write / read-back sweep plus a bit-exact compute
check, and for a memory point, a rung under your real workload. That gate is what the tool is built
around. Everything else is convenience.

## Quick start

Stand the tool up, then apply and persist the recommended serving configuration.

```bash
git clone https://github.com/cachenetics/170tune && cd 170tune
sudo ./install.sh              # build the helpers from source, install to /usr/local/bin
sudo 170tune preflight         # check card, driver, unlock, iomem access, stock clock
sudo 170tune snapshot-stock    # record THIS card's stock values as its revert baseline (once)
```

Qualify and persist the serving memory clock under your own workload:

```bash
sudo WORKLOAD_TIMEOUT=28800 170tune hbm-gate \
  --ndiv 70 --timings "REFRESH 24" --sweeps 12 \
  --workload "/path/to/your/real-serving-soak.sh"
sudo 170tune persist save --ndiv 70 --timings "REFRESH 24"
sudo 170tune persist enable    # re-applies at boot; the card still boots stock first
```

Before turning any knob by hand, read the levers: `170tune explain` for the SM side and
`170tune explain-hbm` for memory. Every number in this repo was measured on one reference card;
`qualify` and gate on your own silicon before trusting an offset or an NDIV.

## Requirements

- **A CMP 170HX** (GA100, 70 SM, sm_80) with the NVIDIA driver loaded. Both SKUs are recognized:
  the 8 GB `0x20C2` (64 GB unlock) and the 10 GB `0x2082` (40 GB unlock). Any other GPU is refused.
- **The memory unlock applied.** 170tune tunes registers a stock driver keeps locked; it needs the
  cmpunlocker unlock (patched driver or hammer service) that opens the FBPA privilege masks.
  Reference driver: 610.43.03. See [Unlock compatibility](#unlock-compatibility) - not every unlock
  variant exposes the register the live memory-clock lever uses.
- **A genuinely stock memory clock.** A driver built with cmpunlocker's `--mclk-ndiv` flag bakes a
  non-stock clock into its own init; that is a different mechanism, and 170tune refuses to tune on
  top of it (see [Safety](#safety)).
- **`iomem=relaxed`** on the kernel command line (GRUB), so userspace can map BAR0.
- **NVML** and a **CUDA toolkit** to build the sm_80 probes. `nvcc` is optional, but the integrity
  gate needs `gpu_selftest`, so a missing toolkit is a loud warning, not a silent skip.
- root, bash, `nvidia-smi`.

`sudo 170tune preflight` checks every one of these and prints exactly what to fix on any failure.

### Unlock compatibility

170tune's live memory-clock lever (`hbm_mclk`) reads and writes the **unicast FBPA0 PLL** window
(`0x00903c7c` / `0x00903c98`). It needs an unlock that opens that window to host writes. Not every
unlock lineage does: a broadcast-only unlock leaves those reads returning a PRI error (`0xBADF...`),
and `preflight` will report the PLL register window as fenced.

If your card is unlocked but the memory lever cannot read the current NDIV, you have two clean paths:

- use the cmpunlocker lineage 170tune targets, which opens the unicast PLL window, and get the full
  live ladder plus the hot correctness gate; or
- set the memory clock through your unlock's own driver bake (`--mclk-ndiv=N`) and use 170tune only
  for the SM side.

The two cannot be mixed: a broadcast-only unlock plus 170tune's live memory lever is the one
combination that fails this way.

## What you can tune

| Lever | Command family | What it moves |
|---|---|---|
| SM clock + undervolt | `try` / `gate` / `ladder` / `qualify` / `apply` | GPC clock ceiling and the VF offset (undervolt) |
| HBM memory clock | `mclk-try` / `mclk-gate` / `mclk-ladder` / `hbm-matrix` | the FBPA PLL multiplier (NDIV): memory clock = NDIV x 27 MHz |
| DRAM timings | `timings` / `timings-gate` | the CONFIG timing fields |
| Refresh interval | `refresh` | the refresh power / heat lever |

The SM undervolt lowers power at a fixed clock (measured up to -24% at 1350 MHz for the same work).
The memory clock raises delivered bandwidth. The refresh lever trades retention margin for idle
power. The full command list is in `170tune help`; the mechanism behind the SM levers is in
[`docs/mechanism.md`](docs/mechanism.md) and behind the memory levers in
[`docs/hbm-timing-understanding.md`](docs/hbm-timing-understanding.md).

## Recommended configurations

Start from one of these, then qualify it on your own card. The gap between "passes a cool memory
sweep" and "survives real serving" is wide on this part, and only the qualification gate closes it.

| Goal | Configuration | Why |
|---|---|---|
| **Serving (default)** | SM offset +250, HBM NDIV 70, REFRESH 24, GPU fan driven by HBM temp | The validated serving ceiling: +10% read bandwidth, held with zero Xids under sustained and concurrent load with HBM at or below 76 C. The fan is required - a passive card heat-soaks and corrupts an OC point above ~75 C. |
| **Sustained / unattended delivery** | SM offset +250, power cap 175 W, stock memory | 175 W is the efficiency knee: full decode throughput, coolest envelope that holds it. A hard wattage bound caps heat regardless of workload - the right lever for a box that runs somewhere you cannot see. See [`docs/power-cap-curve.md`](docs/power-cap-curve.md). |
| **Bench / synthetic bandwidth** | HBM up to NDIV 76 | Peak memory read (+19%) for a memory-bound benchmark. **Not serving-safe**: NDIV 72 corrupts as it heats and 74-76 crash on the first real load. Gate under your own workload before trusting it. |

**On the SM offset:** the serving-qualified undervolt on the reference card is +250. Offsets of +300
and above pass a cool GEMM and can serve for a while, then fault under a long soak (Xid 13 on the
weak SMs). The named `170hx-oc` profiles that sit at +300 / +350 are bench points, not serving
points. When in doubt, ship +250. The full offset-vs-ceiling and qualification matrices are in
[`docs/reference-matrices.md`](docs/reference-matrices.md).

Single-stream decode is not bandwidth-bound, so the memory OC buys close to nothing there; it pays
only on a genuinely bandwidth-bound workload. Raise NDIV for the margin and the bandwidth, not for
decode speed.

## Persist across reboots

A one-shot systemd service re-applies the qualified profile - SM offset and ceiling, HBM NDIV, DRAM
timings, or any combination - in userspace after the driver is up. The box still boots stock, and the
apply is self-disarming: if a previous boot's apply did not check in (the machine went down
mid-apply), the card stays stock rather than re-applying a point that might be the reason it went
down.

```bash
170tune gate 250 1400 4 --workload /usr/local/bin/vllm_workload_check.sh
170tune persist save --offset 250 --clk 1400    # refuses without a passing receipt (-f overrides)
170tune persist enable                          # install and enable the boot service
170tune persist status                          # show the profile and service state
```

Persistence is receipt-gated. A gate writes a per-serial receipt; `persist save` demands it, and
`persist enable` checks it again, so a deleted, stale, or hand-edited profile cannot bypass
qualification. A driver or VBIOS change invalidates the receipt. Recover a misbehaving profile
remotely with `170tune persist disable` or `systemctl mask 170tune-persist.service`; the card boots
stock either way.

## Multiple cards

Every command takes an `-i N` / `--gpu N` selector (or `GPU=N`); the default is index 0 as
`nvidia-smi` numbers them. Selection is order-proof: the tool binds NVML by index, pins the CUDA
helpers by UUID, and addresses the register tools by PCI BDF, so the card a gate proves is always the
card the overclock lands on. Qualification is per-card - a receipt, a persisted profile, and a
quarantine are all keyed to the card serial, because a point that soaks clean on one card says
nothing about another. Tune each card under its own selector.

## Safety

The failure modes, worst first:

1. **Silent corruption** - the run completes, no Xid, no hang, memory comes back wrong.
   Intermittent and temperature-dependent. Only the gate catches it.
2. **Device fault** - CUDA dies with an illegal instruction or memory access. Recoverable, usually
   with a driver reload (`170tune recover`).
3. **Hang** - the GPU stops answering. Needs a reboot, sometimes a power cycle.
4. **Context wedge** - `nvidia-smi` answers and clocks read fine, but no process can create a CUDA
   context. The tool probes for this by actually creating one; do not trust a healthy-looking
   `nvidia-smi` alone.

Two guards sit under the gate. A driver with a baked non-stock memory clock is refused outright,
because it would poison the stock revert target every other check depends on. And every risky apply
is bracketed by an armed marker written before the point is applied and cleared only after the run
checks back in, so a hang mid-run is caught and reverted at the next boot. The full safety model is
in [`docs/tuning-guide.md`](docs/tuning-guide.md).

## Documentation

- [`docs/tuning-guide.md`](docs/tuning-guide.md) - the manual: how to run a 170HX well, SM and HBM,
  install to persisted qualified overclock.
- [`docs/reference-matrices.md`](docs/reference-matrices.md) - every measured table: SM offset x
  ceiling, the serving qualification matrix, the HBM NDIV grid, the refresh lever.
- [`docs/power-cap-curve.md`](docs/power-cap-curve.md) - choosing a sustained delivery envelope with
  a power cap, and the 175 W efficiency knee.
- [`docs/mechanism.md`](docs/mechanism.md) - the SM "why": the VF-offset undervolt, the clock
  ceiling, the two failure regimes, and the NAFLL clock-stretch behavior.
- [`docs/hbm-timing-understanding.md`](docs/hbm-timing-understanding.md) - the memory "why": how HBM
  timing works on this card, the constraint stack, the data-eye and retention ceilings, and the
  refresh triangle.
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) - dated history and the corrections worth keeping visible.

## License

MIT, see LICENSE. This repo is the tuning, measurement, and recovery harness. The memory unlock and
the PCIe Gen2 retrain it assumes are separate projects with their own licenses; none of their code is
included here.

## Attribution

Almost everything this tool stands on was worked out by other people.

**[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)** is the foundation: a
runtime memory unlock through patched open GPU kernel modules, no VBIOS flash. Without it the card
exposes a fraction of its capacity and host register writes are dropped.

**bendy2** worked out the PCIe Gen2 retrain and moved it into the driver via an `ioremap` of BAR0,
which fixed the mmap failure that had blocked userspace attempts. Merged upstream as PR #18.

**[asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock)**
mapped the FBPA memory PLL: the per-partition register locations, the coefficient encoding, and the
`FBPA_PLL` priv-level-mask entry that opens in the post-BooterLoad window. The memory-clock tooling
here is built on that map, and finding it independently would have cost weeks.

**This project** contributes what sits on top: the tuning of both the SM and the HBM, the measurement
discipline, the integrity gate, the receipt and quarantine safety net, and the recovery path. The
link-training half lives separately in
[cmp170hx-gen2](https://github.com/studebaker8/cmp170hx-gen2).

If you take one idea from this repo, take the gate rule: on this card, "it did not crash" is not a
result.
