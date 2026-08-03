# 170tune - CMP 170HX clock and memory tuning

`170tune` is a single tool that measures, qualifies, applies, and persists overclock and
undervolt settings on a CMP 170HX (GA100), and tunes the HBM memory clock and DRAM timings.
Everything is live userspace BAR0 register writes - no driver rebuild, no VBIOS flash. The card
always boots stock, so a bad profile is masked over ssh, never a brick.

The one thing to internalize: on this card the failure that matters is not a crash. An overclock
or a memory setting can complete every benchmark, throw no Xid, never hang, and silently return
wrong bytes - intermittently, and worse when hot. So `170tune` separates "it ran" from "it is
safe": only `gate` (a hot, full-VRAM write/read-back pattern sweep plus a bit-exact compute check)
can call a point safe. A benchmark that merely completes proves nothing. Two further layers back
that up: `quarantine` records a point the gate missed but service caught, and a hung CUDA context
(a card that answers `nvidia-smi` while no process can create a context) is treated as a wedge
everywhere the tool checks for one, not just when a query happens to notice.

## Setup (new card or new box)

```
git clone <this repo> && cd <repo>
sudo ./install.sh             # build the helper tools from source, install to /usr/local/bin
sudo 170tune preflight        # verify the card, driver, mclk is stock, iomem access, the unlock
sudo 170tune snapshot-stock   # capture THIS card's stock values as its revert baseline (once)
170tune explain               # the SM levers, before you turn any knobs
170tune explain-hbm           # the HBM levers, before you turn those knobs either
```

Prerequisites `preflight` checks for you (with remediation text on any failure):

- A CMP 170HX (8GB 0x20C2 or 10GB 0x2082) with the NVIDIA driver loaded.
- The memory clock is genuinely stock, not baked non-stock by a driver built with cmpunlocker's
  `--mclk-ndiv` flag. That is a different mechanism from this tool's own live NDIV control, and
  170tune refuses to tune on top of one - see [Safety](#safety) below.
- The **cmpunlocker unlock** applied (the patched driver / hammer service that opens the FBPA
  privilege masks). Without it, host register writes are silently dropped.
- `iomem=relaxed` on the kernel command line (GRUB), so userspace can mmap BAR0. Without it the
  register tools cannot map the aperture.

`install` (`./install.sh` is a thin shim for `170tune install`) builds the gcc tools (`hbm_mclk`,
`fbpa_regs`, `nvml_oc`) and, if `nvcc` is present, the CUDA tools (`gpu_selftest`, `compute_check`,
`oc_eff`, `mem_probe`, `gemm_probe`, `ctx_probe`, `nvidia_bench`); a missing `nvcc` is a loud
warning, not a silent skip (the gate needs `gpu_selftest`). It also installs `170hx-oc`,
`170hx-sweep`, `170hx-soak`, `vllm_workload_check.sh` and the boot-check unit, and migrates a box
still on the old `170hx-oc.service` persist model to the current one - see
[Persist across reboots](#persist-across-reboots-and-what-to-adopt) below. Installing to
`/usr/local/bin` (the default) means the tool and the persist boot service locate everything with
no PATH/HOME config.

`snapshot-stock` reads the card's live NDIV / refresh / timings into
`/var/lib/170tune/stock/<serial>.conf` and uses those as the revert target, so a card whose VBIOS
stock differs from the built-in defaults is handled correctly. Run it once, with the card at stock.

**Upgrading:** `git pull`, then re-run `sudo ./install.sh` from the checkout. It is upgrade-safe
(it unlinks each old binary before copying the new one, so overwriting an in-use tool or the
running script is clean) and it does **not** touch your saved state - persist profiles, stock
snapshots, gate receipts, quarantine entries and qualification records under `/var/lib/170tune/`
are left untouched. No remove step.

## Learn the levers

```
170tune explain       # the SM clock/voltage levers, the two regimes, the failure modes
170tune explain-hbm   # the HBM levers: clock, timings, the data eye, refresh, how they interact
```

## Tune the SM (GPC clock + voltage)

```
170tune try   <off> <clk> [secs]           apply one point and measure it (UNVERIFIED)
170tune gate  <off> <clk> [n] [--workload <cmd>]   prove it: n hot sweeps + compute + your workload
170tune ladder <clk> [start step max]      walk the offset up at one ceiling, gating each rung
170tune qualify [clk]                      the whole per-card flow, recorded per serial
170tune apply <profile>                    make a named profile live now (see 'explain'/help)
170tune reset                              back to stock
```

`gate` writes a per-serial receipt on a pass; `persist save` later demands that receipt (not
thin, not cold, not stale against a memory-clock change) before it will let the point survive a
reboot. If a point passes the gate and still misbehaves in service - three profiles did, on the
reference card, after passing 4/4 hot sweeps plus a real workload rung - record it:

```
170tune quarantine <off> <clk> --reason "..."     # persist then refuses it even with a receipt
170tune quarantine list | unquarantine <off> <clk>
```

## Tune the memory (HBM)

```
170tune mclk-status                    # current NDIV / MHz / PLL lock / PLM state
170tune mclk-try   <NDIV>              # set the memory clock live (NDIV x 27 MHz), prove it moved
170tune mclk-gate  <NDIV> [n]          # prove it: core pinned, n hot sweeps + compute
170tune mclk-ladder [start step max]   # walk NDIV up, gating each rung hot, stop at the cliff
170tune hbm-matrix [start step max]    # bandwidth/latency per NDIV (fast, UNVERIFIED measurement)
170tune timings [dump|get|set|save|load] ...   # drive the DRAM CONFIG timings directly
170tune timings-gate <FIELD> <cyc> [n] # set one timing and prove it hot
170tune refresh {status|set <us>|gate <us> [n]|stock}   # the refresh power/heat lever
```

The refresh lever trades retention for power: a looser interval means fewer refreshes, so less
power and heat, at the cost of retention margin (which shrinks with temperature). `refresh set`
takes a target interval in microseconds and computes the register field from the live clock;
`refresh gate` proves an interval hot. See `explain-hbm` for the full retention/power/bandwidth
picture and the temperature caveat. A hung CUDA context during `mclk-gate`/`timings-gate` is a
gate failure, not a silent pass - see [Safety](#safety).

## Production profile

The only change from stock that pays is the clock. Raising NDIV already tightens every timing in
nanoseconds for free (real time = cycles / clock), so stock timings at NDIV 76 are both valid and
maximally margined; tightening buys nothing measurable and spends the silent-corruption safety
budget, and loosening only adds latency. So production keeps stock timings.

- **Robust (default):** NDIV 76, stock timings, stock refresh. About +16% triad / +13% read / -5%
  latency versus stock, gated 12/12 hot on any thermal.
- **Power-optimized:** NDIV 76, stock timings, refresh field 24 (about -14% power, roughly 16x
  inside the measured retention margin). Gate it on the target card; keep the HBM within normal
  thermals.
- **Ultra-conservative:** NDIV 75. Near-identical performance, one extra step of guardband.

Prove it on the card, then persist it (see below). The canonical grid, ceilings, and the tested
non-levers are in [`docs/hbm-matrix.md`](docs/hbm-matrix.md).

## Persist across reboots (and what to adopt)

A one-shot systemd service re-applies the qualified profile - SM offset/ceiling, HBM NDIV,
DRAM timings, or any combination - in userspace after the driver is up. The box still boots
stock, and the apply is self-disarming: if a prior boot's apply did not check in (the machine
went down mid-apply), it stays stock rather than re-applying a possibly-bad point.

```
170tune gate 200 1400 4 --workload /usr/local/bin/vllm_workload_check.sh
170tune persist save --offset 200 --clk 1400        # refuses without a passing receipt (-f overrides)
170tune persist save --profile eff                  # or: a named profile, resolved at save time
170tune mclk-gate 76 12                              # prove the HBM point on THIS card, hot
170tune persist save --ndiv 76                       # combine with the SM save above, or alone
170tune persist enable                               # install + enable the boot service
170tune persist status                               # show the profile and service state
```

Recover a misbehaving profile remotely with `systemctl mask 170tune-persist.service` (boot stays
stock), or `170tune persist disable`. A box still running the earlier per-profile
`170hx-oc.service` model is migrated automatically the next time `170tune install` runs - it
prints exactly what it moved, never silently.

## Safety

### Silent corruption is the failure that matters

A run that completes proves nothing. `+325/1400` completes happily, posts 186.7 TF at 135 W (the
best GFLOPS/W in its column), and silently corrupts memory. Never accept an operating point on
"it did not crash". The failure modes, in order of nastiness:

1. **SILENT CORRUPTION** - the run completes, no Xid, no hang, memory comes back wrong.
   Intermittent and temperature dependent. Only `gate` can catch it.
2. **DEVICE FAULT** - CUDA dies with `illegal instruction` / `illegal memory access` / cublas 14.
   Recoverable with `170tune recover`, usually via a driver reload.
3. **HANG** - the GPU stops answering (`GPU requires reset`). Needs a reboot, sometimes a power
   cycle.
4. **CONTEXT WEDGE** - `nvidia-smi` answers, clocks read fine, NVML reports nothing wrong, and no
   process can create a CUDA context. Seen after a hard kill of an inference server mid-context;
   the application-side signature is torch reporting `device_count()=1` with
   `is_available()=False`. `status`, `recover`, and the HBM gate paths all probe for this by
   actually creating a context - do not trust a healthy-looking `nvidia-smi` alone.

A gate receipt is necessary but not sufficient: on the reference card `balanced`, `perf` and `max`
each passed a full 4-sweep hot gate and still could not run an inference server for 30 seconds.
`gate --workload <cmd>` closes part of that hole by running your own engine as an extra rung;
`quarantine` records what survives even that and then faults in service anyway.

### The mclk misclassification guard

A driver compiled with cmpunlocker's `--mclk-ndiv` flag bakes a non-stock memory clock into the
driver's own devinit sequence, so `nvidia-smi` reports that as the card's genuine "current" state
- there is no way to tell it apart from stock by asking the driver alone. If `snapshot-stock`
recorded a baked non-stock clock as "stock", or a live `mclk-try`/`mclk-gate` write layered a
userspace NDIV on top of it, the revert target - and every safety check built on it - would be
silently wrong. `170tune status` reports the memory clock with a source tag (`stock`,
`userspace (NDIV N)`, or `driver-baked (unsupported for tuning)`); `preflight`,
`snapshot-stock`, `mclk-try`/`mclk-gate`, and `persist save` all check it and hard-refuse on a
driver-baked clock, with the same remediation: rebuild a stock driver and use this tool's
userspace mclk control instead.

### Recovery, the armed marker, and boot-check

`170tune recover` clears offsets and clock locks and resets the power limit; if the card is
wedged it stops the persistence daemon and reloads the driver modules, and if that still does not
bring the card back it says so honestly: the next step is a real power cycle, because a warm
reboot leaves the card powered. It will not call the card recovered until a CUDA context can
actually be created on it.

Every risky apply is bracketed by an armed marker (`armed.json`: offset, ceiling, serial,
timestamp, boot id), written and synced BEFORE the point is applied and cleared only after the
run checks back in, so it survives a hang or reboot mid-run. `170tune boot-check`, a systemd
oneshot at boot, finds a marker from a previous boot, reverts the card to stock, logs what was in
flight to `last_crash.json`, and reports it in `170tune status`.

`selftest` closes the loop on trust: a PASS only means something if the harness can still detect
a failure, so it deterministically checks the detector plumbing (corruption parser, incomplete-
sweep handling, compute checker, thermal soak). `--physical` additionally runs a known-bad point
and reports what happens, but a clean result there is NOT evidence the harness is broken - the
underlying fault is intermittent.

## How the SM undervolt works

Two levers, both required.

**1. GPC clock VF offset**, applied through NVML (`nvmlDeviceSetGpcClkVfOffset`, wrapped by
`nvml_oc`). `nvidia-smi` on this driver exposes only the negative direction, which is why OC
looks unavailable; NVML exports the full API and on an unlocked card the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [    0 ..     0] MHz    <- refused by the driver (see explain-hbm
                                                                 for the LIVE BAR0 mclk lever instead)
```

The offset is an undervolt expressed as a frequency offset: `+X` shifts the curve so every
voltage point reaches a clock X MHz higher, the same statement as "a given clock is now reached
at a lower voltage". Pin the clock so frequency is held constant and the saving shows up directly
as watts:

```
pinned SM clock | offset +0 | offset +300 | delta   | bf16 throughput
1200 MHz        | 130.6 W   | 120.6 W     |  -7.7%  | unchanged (160.4 / 160.6 TF)
1350 MHz        | 174.6 W   | 132.0 W     | -24.4%  | unchanged (179.7 / 180.7 TF)
```

**2. Clock ceiling.** The offset alone buys nothing; it only lets the arbiter climb higher. You
must also pin where it lands, and capping the clock measures better than capping power everywhere
it was tried. Two regimes govern where to sit. Below about 1350 MHz the rail bottoms out: past
roughly +250 power goes flat and extra offset is inert, so ship the LOWEST offset that reaches the
floor, not the highest that appears to work. Above about 1400 the corruption cliff arrives before
the floor does, and the best efficiency point sits at the floor of a lower ceiling rather than
near the cliff of a higher one.

For the HBM side (the memory clock, DRAM timings, and the refresh power lever) see `explain-hbm`
and [`docs/hbm-matrix.md`](docs/hbm-matrix.md).

## Requirements

- CMP 170HX: GA100, 70 SM, sm_80. Both shipped SKUs are detected: 8GB (0x20C2, 64GB unlock) and
  10GB (0x2082, 40GB unlock). Non-170HX GPUs are detected and refused / skipped.
- The cmpunlocker patched driver for the memory unlock and the FBPA privilege masks the HBM
  levers need. A stock card exposes a fraction of its real VRAM; the full-VRAM sweep and these
  profiles assume the unlocked capacity. Reference environment: driver 610.43.03.
- NVML (libnvidia-ml) for `nvml_oc` and in-process power sampling, and a CUDA toolkit to build the
  sm_80 probes.
- Nothing external: the integrity sweep the gate runs (`170hx-sweep` + `gpu_selftest`, or
  `gpu_selftest` directly for the HBM gates) ships here and `install.sh` builds it. Point `BENCH=`
  at a fuller bench harness if you have one; it only has to print
  `mem_errors=<n> compute_ok=<0|1>` on a single line.
- root, bash, `nvidia-smi`.

Per-card silicon varies. Every number in this file and in `docs/` is from one reference card; do
not assume its offsets or NDIV on another card. Run `qualify`/`mclk-ladder` per serial, stop at
the first fault and back off one full step, gate the candidate hot with four-plus soaked sweeps,
and gate with your real workload (`gate --workload`) before persisting.

## Environment knobs

```
GATE_TEMP=60          HBM temperature to soak to before every sweep
GATE_SOAK_MAX=180     give up soaking after this many seconds
GATE_COMPUTE=45       seconds of bit-exact GEMM checking per gate (0 disables)
MEASURE_TIMEOUT=180   a measurement exceeding this is treated as a HANG
WORKLOAD_TIMEOUT=900  'gate --workload': a workload that hangs counts as a FAILURE
CTX_TIMEOUT=60        context probe timeout; a probe that hangs is treated as a wedge
CTXPROBE=/path        the context probe (default: the ctx_probe installed here)
BENCH=/path           the SM integrity sweep (default: the 170hx-sweep installed here)
SWEEP_FRAC=0.95       fraction of FREE VRAM 170hx-sweep writes and verifies
COMPUTE=/path         the compute checker        NVML=/path        nvml_oc
MCLK_GATE_SOAK_MAX=360  soak budget for mclk-gate/mclk-ladder (mclk rungs cool faster)
MCLK_TUNE=1            apply the per-NDIV timing tune during mclk-gate/ladder (extends 76->77)
```

## Repo contents

```
tools/170tune             the harness (every command above)
tools/170hx-oc             SM profile applier: named profiles plus 'custom <off> <clk>'
tools/170hx-sweep          the SM integrity gate: runs gpu_selftest, prints the one result line
                          170tune's SM 'gate' parses
tools/170hx-soak           repeat a workload for hours and fail on any new Xid; what decides
                          whether a gated point can actually be shipped
systemd/170tune-bootcheck.service  reverts a setting that was in flight at a crash
tools/nvml_oc.c            query/apply GPC and MEM VF offsets via NVML
tools/hbm_mclk.c           live BAR0 control of the HBM PLL (NDIV) - the memory clock lever
tools/fbpa_regs.c          live BAR0 control of the DRAM CONFIG timings and refresh field
tools/nvidia_bench.cu      HBM bandwidth/latency bench (read/copy/triad) used by hbm-matrix
tools/compute_check.cu     deterministic bf16 GEMM repeated and compared bit for bit; catches
                          silent COMPUTE corruption the memory sweep cannot see
tools/gpu_selftest.cu      full-VRAM sweep: unique-per-address 64-bit pattern verified exactly;
                          catches silent MEMORY corruption and aliased backing. Also the HBM gate.
tools/ctx_probe.cu         the smallest proof the card is USABLE: create a context, allocate,
                          launch, read back. Catches the wedge nvidia-smi cannot see
tools/mem_probe.cu         streaming bandwidth + dependent-load latency probes
tools/gemm_probe.cu        FP16/BF16/TF32/FP32 cublas GEMM throughput probe
tools/oc_eff.cu            sustained bf16 GEMM with in-process NVML power sampling
tools/vllm_workload_check.sh  worked 'gate --workload' rung against a real vLLM service
tools/setup-vllm-170hx.sh     stand vLLM up on a 170HX from scratch; refuses tensor parallel
                          over Gen2 x4, fails on a still-locked VBIOS, pins the card by UUID
docs/tuning-guide.md          the long-form SM findings
docs/measurement-matrix.md    the full SM offset x clock-ceiling measurement matrix
docs/hbm-matrix.md            the canonical HBM tuning matrix: NDIV grid, ceilings, refresh lever
install.sh                 thin shim for 'tools/170tune install' (build + install everything)
```

## License

MIT, see LICENSE. Note what that does and does not cover: this repo is the tuning, measurement
and recovery harness. The memory unlock and the PCIe Gen2 retrain it assumes are separate
projects with their own licenses, and none of their code is included here.

## Attribution

Almost everything this tool stands on was worked out by other people, in this order.

**[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)** is the
foundation. The memory unlock is his: a runtime unlock through patched open GPU kernel modules,
no VBIOS flash. Without it this card exposes a fraction of its real capacity and none of the rest
of this matters. His Gen2 patch (`0007`) is also what makes the endpoint advertise `CAP2=0x06` at
all, which is the opening every later attempt aims at.

**bendy2** worked out the PCIe Gen2 retrain: target speed in LNKCTL2 on both the endpoint and the
upstream bridge, Retrain Link bit, then poll LnkSta and only claim success on a genuinely
negotiated Gen2. He also moved it into the driver via `ioremap` of BAR0, which fixed the mmap
failure that had blocked userspace attempts. Merged upstream as PR #18.

**[asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock)**
mapped the FBPA memory PLL, in a fork of amogh's repo: the per-partition register locations (cfg
at `+0x3C90`, coefficient at `+0x3C98`, base `0x900000 + i*0x4000`), the coefficient encoding, and
the `FBPA_PLL` priv-level-mask entry `0x009a3c7c` that opens in the post-BooterLoad window. The
memory-clock tooling in this repo (`hbm_mclk`, `fbpa_regs`) is built on that map, and finding it
independently would have cost weeks.

**They were right and an earlier version of this project was wrong, and the correction is worth
stating plainly.** An earlier finding claimed measurements disagreed with that fork: that raising
the memory PLL did not raise delivered bandwidth, because the DRAM runs at the rate it was trained
at. That conclusion is retracted. The memory clock does move - the bandwidth is real, proven by
exceeding the theoretical ceiling of the stock clock, which is impossible unless the clock
changed. The earlier measurement had been taken against the wrong write: the correct one lands
**post-GSP** (after `kgspStartLogPolling` - a pre-GSP write is reprogrammed by GSP's own devinit),
is **multicast** to all FBPAs rather than unicast to one partition, and needs a **PRI fence and a
PLL-lock poll** before the clock can be trusted. The post-GSP insight is the same shape as the
Gen2 transient window, arrived at independently: the register was never the problem, the moment
was.

**This project** contributes what sits on top of all of that: the tuning (both SM and HBM), the
measurement discipline, the integrity gate, the receipt/quarantine safety net, and the recovery
path. The link-training half of this work lives separately in
[cmp170hx-gen2](https://github.com/studebaker8/cmp170hx-gen2), which is bendy2's sequence fired at
the one moment it works.

If you take one idea from this repo, take the gate rule: on this card, "it did not crash" is not
a result.
