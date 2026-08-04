# 170tune - CMP 170HX clock and memory tuning

`170tune` is a single tool that measures, qualifies, applies, and persists tuning on a CMP 170HX
(GA100): the SM clock and undervolt, the HBM memory clock, and the DRAM timings. Everything is a
live userspace BAR0 register write - no driver rebuild, no VBIOS flash. **The card always boots
stock**, so a bad profile is masked over ssh, never a brick.

> **The one rule: "it did not crash" is not a result.** On this card the failure that matters is
> silent - an overclock can pass every benchmark, throw no Xid, never hang, and still return wrong
> bytes (intermittently, worse when hot). Only `gate` - a hot, full-VRAM write/read-back sweep plus
> a bit-exact compute check - can call a point safe. See [Safety](#safety) for why, and for the
> quarantine / wedge-detection layers behind it.

## Contents

- [Quick start](#quick-start) - zero to a persisted overclock
- [Requirements](#requirements) - card, driver, kernel flags
- [Install and upgrade](#install-and-upgrade)
- [Tune the SM](#tune-the-sm-gpc-clock--voltage) / [Tune the memory (HBM)](#tune-the-memory-hbm)
- [Production profiles](#production-profiles) - what to actually ship
- [Persist across reboots](#persist-across-reboots)
- [Safety](#safety) - the failure modes and the guards
- [How the SM undervolt works](#how-the-sm-undervolt-works) - the mechanism, with numbers
- [Environment knobs](#environment-knobs) / [Repo contents](#repo-contents)
- [License](#license) / [Attribution](#attribution)

## Quick start

Stand the tool up on a card, then apply and persist the recommended memory overclock:

```
git clone <this repo> && cd 170tune
sudo ./install.sh            # build the helper tools from source, install to /usr/local/bin
sudo 170tune preflight       # check the card, driver, stock mclk, iomem access, the unlock
sudo 170tune snapshot-stock  # record THIS card's stock values as its revert baseline (once)

sudo 170tune mclk-gate 76 12         # prove NDIV 76 on THIS card: 12 hot sweeps + compute
sudo 170tune persist save --ndiv 76  # save the robust default profile
sudo 170tune persist enable          # re-apply it after every boot (the card still boots stock)
```

Before turning knobs by hand, read the levers: `170tune explain` (SM) and `170tune explain-hbm`
(HBM). Every number in this repo is from one reference card - `qualify` and `mclk-ladder` on your
own silicon, do not assume these offsets or NDIV carry over.

## Requirements

- **A CMP 170HX** (GA100, 70 SM, sm_80) with the NVIDIA driver loaded. Both SKUs are detected: 8GB
  (`0x20C2`, 64GB unlock) and 10GB (`0x2082`, 40GB unlock). Non-170HX GPUs are refused.
- **The cmpunlocker unlock** applied (the patched driver / hammer service that opens the FBPA
  privilege masks). Without it a card exposes a fraction of its VRAM and host register writes are
  silently dropped. Reference driver: 610.43.03.
- **A genuinely stock memory clock** - not baked non-stock by a driver built with cmpunlocker's
  `--mclk-ndiv` flag. That is a different mechanism from this tool's live NDIV control, and 170tune
  hard-refuses to tune on top of it (see [the misclassification guard](#the-mclk-misclassification-guard)).
- **`iomem=relaxed`** on the kernel command line (GRUB), so userspace can mmap BAR0.
- **NVML** (libnvidia-ml) and a **CUDA toolkit** to build the sm_80 probes. `nvcc` is optional but
  the gate needs `gpu_selftest`, so a missing toolkit is a loud warning, not a silent skip.
- root, bash, `nvidia-smi`.

`preflight` checks all of these for you and prints remediation text on any failure.

## Install and upgrade

`./install.sh` is a thin shim for `170tune install`. It:

- builds the gcc tools (`hbm_mclk`, `fbpa_regs`, `nvml_oc`) and, if `nvcc` is present, the CUDA
  tools (`gpu_selftest`, `compute_check`, `oc_eff`, `mem_probe`, `gemm_probe`, `ctx_probe`,
  `nvidia_bench`);
- installs `170hx-oc`, `170hx-sweep`, `170hx-soak`, `vllm_workload_check.sh` and the boot-check unit;
- migrates a box still on the old `170hx-oc.service` persist model to the current one, printing
  exactly what it moved.

Installing to `/usr/local/bin` (the default) means the tool and the persist boot service find every
helper with no PATH/HOME config. Run `install` from the source checkout - not the installed copy.

`snapshot-stock` reads the card's live NDIV / refresh / timings into
`/var/lib/170tune/stock/<serial>.conf` and uses those as the revert target, so a card whose VBIOS
stock differs from the built-in defaults is handled correctly. Run it once, with the card at stock.

**Upgrading:** `git pull`, then re-run `sudo ./install.sh` from the checkout. It is upgrade-safe
(each old binary is unlinked before the new one is copied, so overwriting an in-use tool or the
running script is clean) and it does **not** touch your saved state - persist profiles, stock
snapshots, gate receipts, quarantine entries and qualification records under `/var/lib/170tune/`
are left as they are. There is no remove step.

## Tune the SM (GPC clock + voltage)

```
170tune try   <off> <clk> [secs]                    apply one point and measure it (UNVERIFIED)
170tune gate  <off> <clk> [n] [--workload <cmd>]    prove it: n hot sweeps + compute + your workload
170tune ladder <clk> [start step max]               walk the offset up at one ceiling, gating each rung
170tune qualify [clk]                               the whole per-card flow, recorded per serial
170tune apply <profile>                             make a named profile live now (see 'explain'/help)
170tune reset                                       back to stock
```

`gate` writes a per-serial receipt on a pass; `persist save` later demands that receipt (not thin,
not cold, not stale against a memory-clock change) before it will let a point survive a reboot.

A receipt is necessary but not sufficient. If a point passes the gate and still misbehaves in
service - three profiles did on the reference card, after 4/4 hot sweeps plus a real workload rung -
record it so persist refuses it thereafter:

```
170tune quarantine <off> <clk> --reason "..."       # persist then refuses it even with a receipt
170tune quarantine list | unquarantine <off> <clk>
```

## Tune the memory (HBM)

```
170tune mclk-status                          current NDIV / MHz / PLL lock / PLM state
170tune mclk-try   <NDIV>                    set the memory clock live (NDIV x 27 MHz), prove it moved
170tune mclk-gate  <NDIV> [n]                prove it: core pinned, n hot sweeps + compute
170tune mclk-ladder [start step max]         walk NDIV up, gating each rung hot, stop at the cliff
170tune hbm-matrix [start step max]          bandwidth/latency per NDIV (fast, UNVERIFIED measurement)
170tune timings [dump|get|set|save|load] ... drive the DRAM CONFIG timings directly
170tune timings-gate <FIELD> <cyc> [n]       set one timing and prove it hot
170tune refresh {status|set <us>|gate <us> [n]|stock}   the refresh power/heat lever
```

The refresh lever trades retention for power: a looser interval means fewer refreshes, so less
power and heat, at the cost of retention margin (which shrinks with temperature). `refresh set`
takes a target interval in microseconds and computes the register field from the live clock;
`refresh gate` proves an interval hot. See `explain-hbm` for the full retention/power/bandwidth
picture and the temperature caveat.

The canonical grid, ceilings, and tested non-levers are in [`docs/hbm-matrix.md`](docs/hbm-matrix.md).

## Production profiles

The only change from stock that pays is the clock. Raising NDIV already tightens every timing in
nanoseconds for free (real time = cycles / clock), so stock timings at NDIV 76 are both valid and
maximally margined: tightening buys nothing measurable and spends the silent-corruption safety
budget, and loosening only adds latency. So production keeps stock timings.

| Profile | Setting | Gain vs stock | Notes |
|---|---|---|---|
| **Robust (default)** | NDIV 76, stock timings, stock refresh | ~+16% triad / +13% read / -5% latency | gated 12/12 hot on any thermal |
| **Power-optimized** | NDIV 76, stock timings, refresh field 24 | above, plus ~-14% power | ~16x inside the measured retention margin; keep HBM in normal thermals |
| **Ultra-conservative** | NDIV 75 | near-identical performance | one extra step of guardband |

Prove the point on the card, then persist it (below).

## Persist across reboots

A one-shot systemd service re-applies the qualified profile - SM offset/ceiling, HBM NDIV, DRAM
timings, or any combination - in userspace after the driver is up. The box still boots stock, and
the apply is self-disarming: if a prior boot's apply did not check in (the machine went down
mid-apply), it stays stock rather than re-applying a possibly-bad point.

```
170tune gate 200 1400 4 --workload /usr/local/bin/vllm_workload_check.sh
170tune persist save --offset 200 --clk 1400   # refuses without a passing receipt (-f overrides)
170tune persist save --profile eff             # or: a named profile, resolved at save time
170tune mclk-gate 76 12                         # prove the HBM point on THIS card, hot
170tune persist save --ndiv 76                  # combine with the SM save above, or alone
170tune persist enable                          # install + enable the boot service
170tune persist status                          # show the profile and service state
```

Recover a misbehaving profile remotely with `systemctl mask 170tune-persist.service` (boot stays
stock) or `170tune persist disable`. A box still on the earlier per-profile `170hx-oc.service` model
is migrated automatically the next time `170tune install` runs.

## Safety

### Silent corruption is the failure that matters

A run that completes proves nothing. `+325/1400` completes happily, posts 186.7 TF at 135 W (the
best GFLOPS/W in its column), and silently corrupts memory. Never accept a point on "it did not
crash". The failure modes, in order of nastiness:

1. **Silent corruption** - the run completes, no Xid, no hang, memory comes back wrong. Intermittent
   and temperature dependent. Only `gate` can catch it.
2. **Device fault** - CUDA dies with `illegal instruction` / `illegal memory access` / cublas 14.
   Recoverable with `170tune recover`, usually via a driver reload.
3. **Hang** - the GPU stops answering (`GPU requires reset`). Needs a reboot, sometimes a power cycle.
4. **Context wedge** - `nvidia-smi` answers, clocks read fine, NVML reports nothing wrong, and no
   process can create a CUDA context. Seen after a hard kill of an inference server mid-context; the
   application-side signature is torch reporting `device_count()=1` with `is_available()=False`.
   `status`, `recover`, and the HBM gate paths all probe for this by actually creating a context -
   do not trust a healthy-looking `nvidia-smi` alone.

`gate --workload <cmd>` closes part of the receipt-is-not-sufficient gap by running your own engine
as an extra rung; `quarantine` records what survives even that and then faults in service anyway.

### The mclk misclassification guard

A driver compiled with cmpunlocker's `--mclk-ndiv` flag bakes a non-stock memory clock into the
driver's own devinit sequence, so `nvidia-smi` reports that as the card's genuine "current" state -
there is no way to tell it from stock by asking the driver alone. If `snapshot-stock` recorded a
baked clock as "stock", or a live `mclk-try` layered a userspace NDIV on top of it, the revert
target - and every safety check built on it - would be silently wrong.

`170tune status` reports the memory clock with a source tag (`stock`, `userspace (NDIV N)`, or
`driver-baked (unsupported for tuning)`); `preflight`, `snapshot-stock`, `mclk-try`/`mclk-gate`, and
`persist save` all check it and hard-refuse on a driver-baked clock, with the same remediation:
rebuild a stock driver and use this tool's userspace mclk control instead.

### Recovery, the armed marker, and boot-check

`170tune recover` clears offsets and clock locks and resets the power limit; if the card is wedged
it stops the persistence daemon and reloads the driver modules, and if that still does not bring the
card back it says so honestly - the next step is a real power cycle, because a warm reboot leaves
the card powered. It will not call the card recovered until a CUDA context can actually be created.

Every risky apply is bracketed by an armed marker (`armed.json`: offset, ceiling, serial, timestamp,
boot id), written and synced BEFORE the point is applied and cleared only after the run checks back
in, so it survives a hang or reboot mid-run. `170tune boot-check`, a systemd oneshot at boot, finds
a marker from a previous boot, reverts the card to stock, logs what was in flight to
`last_crash.json`, and reports it in `170tune status`.

`selftest` closes the loop on trust: a PASS only means something if the harness can still detect a
failure, so it deterministically checks the detector plumbing (corruption parser, incomplete-sweep
handling, compute checker, thermal soak). `--physical` additionally runs a known-bad point, but a
clean result there is NOT evidence the harness is broken - the underlying fault is intermittent.

## How the SM undervolt works

Two levers, both required.

**1. GPC clock VF offset**, applied through NVML (`nvmlDeviceSetGpcClkVfOffset`, wrapped by
`nvml_oc`). `nvidia-smi` on this driver exposes only the negative direction, which is why OC looks
unavailable; NVML exports the full API and on an unlocked card the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [    0 ..     0] MHz    <- refused by the driver
                                                               (use the LIVE BAR0 mclk lever instead)
```

The offset is an undervolt expressed as a frequency offset: `+X` shifts the curve so every voltage
point reaches a clock X MHz higher - equivalently, a given clock is now reached at a lower voltage.
Pin the clock so frequency is held constant and the saving shows up directly as watts:

```
pinned SM clock | offset +0 | offset +300 | delta   | bf16 throughput
1200 MHz        | 130.6 W   | 120.6 W     |  -7.7%  | unchanged (160.4 / 160.6 TF)
1350 MHz        | 174.6 W   | 132.0 W     | -24.4%  | unchanged (179.7 / 180.7 TF)
```

**2. Clock ceiling.** The offset alone buys nothing; it only lets the arbiter climb higher. You must
also pin where it lands, and capping the clock measures better than capping power everywhere it was
tried. Two regimes:

- **Below ~1350 MHz** the rail bottoms out: past roughly +250 power goes flat and extra offset is
  inert, so ship the lowest offset that reaches the floor, not the highest that appears to work.
- **Above ~1400 MHz** the corruption cliff arrives before the floor does, so the best efficiency
  point sits at the floor of a lower ceiling rather than near the cliff of a higher one.

For the HBM side (memory clock, DRAM timings, refresh lever) see `explain-hbm` and
[`docs/hbm-matrix.md`](docs/hbm-matrix.md). The long-form SM findings are in
[`docs/tuning-guide.md`](docs/tuning-guide.md); the full offset x ceiling matrix is in
[`docs/measurement-matrix.md`](docs/measurement-matrix.md).

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

`BENCH=` can point at a fuller bench harness if you have one; it only has to print
`mem_errors=<n> compute_ok=<0|1>` on a single line.

## Repo contents

```
tools/170tune             the harness (every command above)
tools/170hx-oc            SM profile applier: named profiles plus 'custom <off> <clk>'
tools/170hx-sweep         the SM integrity gate: runs gpu_selftest, prints the one result line
                          170tune's SM 'gate' parses
tools/170hx-soak          repeat a workload for hours and fail on any new Xid; what decides
                          whether a gated point can actually be shipped
systemd/170tune-bootcheck.service  reverts a setting that was in flight at a crash
tools/nvml_oc.c           query/apply GPC and MEM VF offsets via NVML
tools/hbm_mclk.c          live BAR0 control of the HBM PLL (NDIV) - the memory clock lever
tools/fbpa_regs.c         live BAR0 control of the DRAM CONFIG timings and refresh field
tools/nvidia_bench.cu     HBM bandwidth/latency bench (read/copy/triad) used by hbm-matrix
tools/compute_check.cu    deterministic bf16 GEMM repeated and compared bit for bit; catches
                          silent COMPUTE corruption the memory sweep cannot see
tools/gpu_selftest.cu     full-VRAM sweep: unique-per-address 64-bit pattern verified exactly;
                          catches silent MEMORY corruption and aliased backing. Also the HBM gate.
tools/ctx_probe.cu        the smallest proof the card is USABLE: create a context, allocate,
                          launch, read back. Catches the wedge nvidia-smi cannot see
tools/mem_probe.cu        streaming bandwidth + dependent-load latency probes
tools/gemm_probe.cu       FP16/BF16/TF32/FP32 cublas GEMM throughput probe
tools/oc_eff.cu           sustained bf16 GEMM with in-process NVML power sampling
tools/vllm_workload_check.sh  worked 'gate --workload' rung against a real vLLM service
tools/setup-vllm-170hx.sh     stand vLLM up on a 170HX from scratch; refuses tensor parallel
                          over Gen2 x4, fails on a still-locked VBIOS, pins the card by UUID
docs/tuning-guide.md          the long-form SM findings
docs/measurement-matrix.md    the full SM offset x clock-ceiling measurement matrix
docs/hbm-matrix.md            the canonical HBM tuning matrix: NDIV grid, ceilings, refresh lever
install.sh                the thin shim for 'tools/170tune install'
```

## License

MIT, see LICENSE. Note what that does and does not cover: this repo is the tuning, measurement and
recovery harness. The memory unlock and the PCIe Gen2 retrain it assumes are separate projects with
their own licenses, and none of their code is included here.

## Attribution

Almost everything this tool stands on was worked out by other people, in this order.

**[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)** is the foundation. The
memory unlock is his: a runtime unlock through patched open GPU kernel modules, no VBIOS flash.
Without it this card exposes a fraction of its real capacity and none of the rest of this matters.
His Gen2 patch (`0007`) is also what makes the endpoint advertise `CAP2=0x06` at all, which is the
opening every later attempt aims at.

**bendy2** worked out the PCIe Gen2 retrain: target speed in LNKCTL2 on both the endpoint and the
upstream bridge, Retrain Link bit, then poll LnkSta and only claim success on a genuinely negotiated
Gen2. He also moved it into the driver via `ioremap` of BAR0, which fixed the mmap failure that had
blocked userspace attempts. Merged upstream as PR #18.

**[asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock)**
mapped the FBPA memory PLL, in a fork of amogh's repo: the per-partition register locations (cfg at
`+0x3C90`, coefficient at `+0x3C98`, base `0x900000 + i*0x4000`), the coefficient encoding, and the
`FBPA_PLL` priv-level-mask entry `0x009a3c7c` that opens in the post-BooterLoad window. The
memory-clock tooling here (`hbm_mclk`, `fbpa_regs`) is built on that map, and finding it
independently would have cost weeks.

**They were right and an earlier version of this project was wrong, and the correction is worth
stating plainly.** An earlier finding claimed that raising the memory PLL did not raise delivered
bandwidth, because the DRAM runs at the rate it was trained at. That is retracted. The memory clock
does move, and the bandwidth is real - proven by exceeding the theoretical ceiling of the stock
clock, which is impossible unless the clock changed. The earlier measurement had been taken against
the wrong write: the correct one lands **post-GSP** (after `kgspStartLogPolling`; a pre-GSP write is
reprogrammed by GSP's own devinit), is **multicast** to all FBPAs rather than unicast to one
partition, and needs a **PRI fence and a PLL-lock poll** before the clock can be trusted. The
post-GSP insight is the same shape as the Gen2 transient window, arrived at independently: the
register was never the problem, the moment was.

**This project** contributes what sits on top of all of that: the tuning (both SM and HBM), the
measurement discipline, the integrity gate, the receipt/quarantine safety net, and the recovery
path. The link-training half of this work lives separately in
[cmp170hx-gen2](https://github.com/studebaker8/cmp170hx-gen2), which is bendy2's sequence fired at
the one moment it works.

If you take one idea from this repo, take the gate rule: on this card, "it did not crash" is not a
result.
