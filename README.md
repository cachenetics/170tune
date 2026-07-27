# 170tune

Tuning, qualification and recovery harness for the NVIDIA CMP 170HX (GA100, 70 SM,
sm_80, PCI id 0x20C2, 64 GB HBM2e after the community memory unlock). It undervolts
the card by shifting the voltage/frequency curve, then proves the result is not
silently corrupting memory. That second half is the point: past a certain offset the
card corrupts memory with no crash, no Xid, no hang. Every stability test that only
asks "did the kernel finish" passes, and the data is wrong. 170tune separates
"it ran" from "it is safe".

What tuning buys, on the reference card (serial 1322621047793):

* Dense GEMM bench: near-stock throughput at about a third less power
  (`eff`: 180.8 TFLOPS at 131.2 W, vs stock 184.3 TFLOPS at 199.2 W).
* Real inference serving: about +5% throughput (`match`). The two benchmarks rank
  the profiles differently, and three profiles that pass the GEMM gate kill a
  server. Read [Profiles](#profiles) before choosing.

## Quick start

```
./install.sh                    # build the probes, install, enable boot-check. Overclocks nothing.
sudo 170tune selftest           # prove the corruption detectors work before trusting any PASS
sudo 170tune gate 300 1350 4    # 4 temperature-soaked full-VRAM sweeps + bit-exact compute check
sudo 170tune persist eff        # exit 0 above = gated; now apply +300/1350 at boot and right now
```

That gates and ships the `eff` profile. Its numbers were measured on one card and
silicon varies, so on your card prefer the per-card flow: `170tune explain`, then
`sudo 170tune ladder 1350` to find your safe offset, then `sudo 170tune qualify`,
then `sudo 170tune persist custom <off> <clk>` to adopt what it recommended.
`qualify` records to `/var/lib/170tune/results/<serial>/oc.json` without changing
anything permanently: a good measurement can never promote itself into production
by accident, adopting one is a separate, deliberate verb.

## Commands

```
170tune explain                            the levers, the regimes, the failure modes
170tune status                             card state, armed marker, crash records
170tune try <off> <clk> [secs]             measure one point; prints UNVERIFIED, proves nothing
170tune gate <off> <clk> [n] [--workload <cmd>]   n soaked sweeps + compute check; exit 0 = gated
170tune ladder <clk> [start] [step] [max]  raise the offset until it breaks, gating each rung
170tune qualify [clk]                      full per-card flow, recorded, nothing persisted
170tune apply <profile> [--persist]        live now; volatile unless --persist
170tune persist <profile>|custom <off> <clk>|status|off  [--force]
170tune quarantine <off> <clk> --reason "..."     record a point as known-bad on THIS card
170tune quarantine list | unquarantine <off> <clk>
170tune selftest [--physical]              prove the detectors still detect
170tune recover                            clear offsets and locks after a fault
170tune reset                              back to stock now
170tune boot-check                         at boot: revert if the last run never checked in
```

Exit codes: 0 success / gated, 1 rejected / faulted / failed, 2 usage error or hang.

## Making it stick

Offsets and clock locks are volatile: the driver forgets them on every reload and
reboot. `apply` is live now and gone at the next reload; `persist` is live now AND
at every boot. `persist status` shows what is persisted vs what the card is running;
`persist off` reverts to stock and disables the boot unit explicitly, rather than
relying on `ExecStop` having run (if the unit was never active, stopping it reverts
nothing).

`persist` writes `/etc/170tune/profile` (`PROFILE=`, plus `OC_OFFSET=`/`OC_CLK=` for
a custom point), enables the `170hx-oc.service` oneshot that reads it at boot,
applies the point immediately, and then reads the card back to confirm it actually
took, rather than trusting that a unit exiting 0 means the silicon changed.

`persist` refuses a point when:

* this card has no gate receipt for this exact offset and ceiling (`gate` writes a
  receipt per serial; another card's receipt does not count);
* the receipt has fewer than four sweeps;
* the receipt was gated cold, peak HBM never reaching `GATE_TEMP`: a cold gate is
  precisely how +325/1400 got blessed before it corrupted memory at 59 C;
* the point is quarantined on this card. Quarantine wins even over a passing gate
  receipt, because a receipt can be honestly earned and still wrong (see
  [A gate receipt is not enough](#a-gate-receipt-is-not-enough)); `unquarantine`
  lifts it.

`--force` overrides the receipt checks, loudly, and says so in the output.

## Profiles

Applied by `170hx-oc <profile>` (which `170tune apply` calls). Every profile sets a
VF offset, pins a clock ceiling with `-lgc 210,<max>` (that form, not
`<max>,<max>`, lets the card still idle down to 210 MHz), and sets a 250 W power
limit that never binds (peak measured draw is stock's 199.2 W). Every row passed the
full-VRAM pattern sweep with `mem_errors=0` at least twice.

Dense GEMM bench (sustained bf16 tensor-core GEMM, NVML power sampled in-process):

```
profile   offset  clk max   bf16 TFLOPS   watts     GFLOPS/W   note
stock       +0    (none)       184.3      199.2 W      925     baseline
dense      +250    1200        160.8      120.2 W     1337     lowest draw, most cards per PSU
eff        +300    1350        180.8      131.2 W     1378     near-stock speed, a third less power
match      +250    1400        186.5      142.2 W     1311     stock throughput, -29% power
balanced   +300    1470        196.2      149.7 W     1311     QUARANTINED on the reference card
perf       +350    1590        212.2      181.2 W     1171     QUARANTINED on the reference card
max        +350    1650        215.3      186.1 W     1157     QUARANTINED on the reference card
```

One number to be careful with: `eff` ships at +300/1350, re-gated hot (3/3 clean
sweeps at 51-52 C HBM). Earlier drafts of the measurement notes named +250/1350;
both sit on the flat part of the voltage floor and draw within a watt of each
other, so the difference is margin, not performance. The applier and this README
are authoritative.

### What the table is worth under a real server

The TFLOPS and watts above are dense GEMM numbers. They do not carry over to a real
inference server. Measured on the same card, sglang serving Qwen3.6-27B-INT8-MTP
(173k tokens of KV cache, 56.5 GB resident, 1024 in / 256 out, 32 prompts,
concurrency 8):

```
profile    tok/s     TTFT     power     note
stock      134.60    773 ms   126.7 W   repeat run 135.09, so +-0.4%
dense      126.52    761 ms   143.2 W   SLOWER than stock, drawing MORE power
eff        137.93    683 ms   152.5 W
match      140.80    669 ms   156.7 W   best
balanced   -         -        -         killed the server mid-inference
perf       -         -        -         never got that far: dies at CUDA graph capture
max        -         -        -         killed the server mid-inference
```

Be precise about what was captured. Only `perf` has a verbatim signature, at graph
capture during server startup:

```
Exception: Capture cuda graph failed: CUDA error: an illegal instruction was encountered
torch.AcceleratorError: CUDA error: an illegal instruction was encountered
```

For `balanced` and `max` the server-side traceback was lost to a log truncated on
restart. What is attested is the observable: a healthy server, requests completing,
then the process dies and `/health` stops answering. Recorded that way in the
quarantine book too, rather than assuming they failed the same way `perf` did.

A longer run at `eff` (+300/1350) since: 128 prompts at concurrency 16, 82 s,
204.87 tok/s output, mean TTFT 795 ms, mean TPOT 72 ms, 157.1 W, 1332 MHz mean,
peak HBM 68 C, all 128 requests served and the server still up afterwards. That is
about three minutes of load. It is evidence, not a soak.

Two honest conclusions:

* Under real serving, tuning is worth about +5% (`match`), and the GFLOPS/W
  ordering INVERTS: `dense` is the efficiency champion on the GEMM bench and worse
  than stock when serving, because clamping to 1200 MHz hurts a workload that
  alternates prefill bursts with memory-bound decode.
* `balanced`, `perf` and `max` PASSED the 4-sweep hot gate and still could not
  serve for 30 seconds. A gate receipt is necessary but not sufficient; that is
  exactly why `gate --workload` and `quarantine` exist, and why those three
  profiles are quarantined on the reference card.

The generalisable lesson, and it is not specific to this card: the GEMM numbers are
not wrong, they are narrow. A dense GEMM is one instruction mix at a steady current
draw, while an engine alternates prefill bursts, memory-bound decode and graph
replay, so it asks the rail for current transients a GEMM bench never produces. Any
GPU tuned for inference on a GEMM bench alone is qualified against the wrong load.

Memory notes: the MEM VF offset is refused by the driver and memory overclock is
closed by measurement (the PLL follows down but not up). Streaming bandwidth is
essentially profile-independent (spread under 1%); what the core profile moves is
memory latency: 253.2 ns at `max` against 296.1 ns at `eff`, a 17% spread. Pick
high-clock profiles for latency-bound work; any profile for bandwidth-bound work.

## Safety

### Silent corruption is the failure that matters

A run that completes proves nothing. `+325/1400` completes happily, posts 186.7 TF
at 135 W (the best GFLOPS/W in its column), and silently corrupts memory. Never
accept an operating point on "it did not crash".

The three failure modes, in order of nastiness:

1. SILENT CORRUPTION - the run completes, no Xid, no hang, memory comes back wrong.
   Intermittent and temperature dependent. Only `gate` can catch it.
2. DEVICE FAULT - CUDA dies with `illegal instruction` / `illegal memory access` /
   cublas 14. Recoverable with `170tune recover`, usually via a driver reload.
3. HANG - the GPU stops answering (`GPU requires reset`). Needs a reboot, sometimes
   a power cycle.

The corruption cliff, measured at a 1400 MHz ceiling with the full-VRAM pattern
sweep as the gate:

```
offset | draw    | pattern sweeps
+250   | 142.2 W | 3 sweeps, 0 memory errors
+300   | 138.5 W | 4 sweeps, 0 memory errors
+325   | 132.7 W | 3 sweeps: 6 errors, 3 errors, 0 errors
+375   | -       | CUDA device fault under load
```

The safe window at 1400 is one 25 MHz step wide above +300. The corruption events
at +325/1400 are real and measured (sweeps there have returned `mem_errors` of 6,
3, 4 and 1 at different times) and NOT reproducible on demand: the same point has
since passed repeated gates, including at 60 C HBM, and passed 4/4 sweeps on a cold
card before ever failing. The cliff cannot be characterised precisely, only a
region in which corruption has been observed. The mitigation is margin plus
repeated gating, not a single clean result: `gate` defaults to four sweeps, and the
shipped profiles sit a full step back from the last point that ever looked clean.

### Why a cold gate lies

Corruption at +325/1400 is temperature dependent. The point passed 4 out of 4
sweeps at 37-43 C, then returned `mem_errors=1` at 50 C and again at 52 C after a
sustained soak, and `mem_errors=4` in a run driven to 51 C core / 59 C HBM. Hot
silicon needs more voltage for the same clock, so an undervolt that is stable cold
corrupts hot: any validation on an idle card is optimistic.

`gate` therefore soaks under sustained load to a TEMPERATURE before every sweep,
not for a fixed duration (how hot 60 seconds gets you depends on ambient). It
targets HBM temperature (`GATE_TEMP=60`), not core: the core reaches 52 C in
seconds while the stacks are still cold, and it is the memory side the sweep is
sensitive to. The run that first caught +325/1400 had been driven to 59 C HBM;
targeting core temperature passed that same point.

### A gate receipt is not enough

The gate's instruction mix is narrower than an inference engine's. On the reference
card, `balanced`, `perf` and `max` each passed the full 4-sweep hot gate (pattern
sweeps plus 56,688 bit-exact GEMMs) and still could not run an inference server for
30 seconds. Two tools close that hole:

* `gate <off> <clk> --workload <cmd>` runs your own command, the thing you will
  actually deploy, as an extra gate step and records on the receipt that the point
  survived a real workload. Gate with the workload you intend to run.
* `quarantine <off> <clk> --reason "..."` records a point as known-bad on this
  card; `persist` then refuses it even if it holds a passing gate receipt.
  `quarantine list` shows the book, `unquarantine` lifts an entry.

Match the workload's DURATION to what you are claiming, too. The three profiles
above failed within thirty seconds, so a short run does discriminate, but a point
that survived three minutes of serving has been shown to survive three minutes of
serving and nothing more. If it is going to run for days, gate it for longer than a
benchmark takes.

A fourth signature worth knowing: past the wall the clock stretcher engages and the
card runs SLOWER while reporting a higher clock (+400/1650 reports a higher clock
than +375/1650 and delivers 4% less). Running slower there is the hardware
protecting itself, not headroom.

Measured boundaries on the reference card, do not exceed: +350 is the highest
offset validated clean, and only at the high-clock profiles where RM selects a
higher voltage. +355 at 1650 faults by the third run; +360 and +375 at 1650 fault
within one or two runs; +375 at a 1700 ceiling hangs the GPU; +450 hard-crashes it
and a warm reboot is not always enough.

### Recovery, the armed marker, and boot-check

`170tune recover` clears offsets and clock locks and resets the power limit; if the
card is wedged it stops the persistence daemon, reloads the driver modules, and if
that still does not bring the card back it says so honestly: the next step is a
real power cycle, because a warm reboot leaves the card powered.

Every risky apply is bracketed by an armed marker: `armed.json` (offset, ceiling,
serial, timestamp, boot id) is written and synced BEFORE the point is applied and
cleared only after the run checks back in. If the box hangs or reboots mid-run, the
marker survives. `170tune boot-check` runs as a systemd oneshot at boot: a marker
from a previous boot reverts the card to stock, is logged to `last_crash.json`, and
shows in `170tune status`. A tuning crash is recorded, never lost, and a crashed
setting is never silently re-applied.

`selftest` closes the loop on trust: a PASS from the harness only means something
if the harness can still detect a failure, so it deterministically checks the
detector plumbing (corruption parser, incomplete-sweep handling, compute checker,
thermal soak). The physical positive control is separate (`--physical`) on purpose:
the +325/1400 corruption is intermittent, so a clean physical result is NOT
evidence the harness is broken.

## How the undervolt works

Two levers, both required.

**1. GPC clock VF offset**, applied through NVML (`nvmlDeviceSetGpcClkVfOffset`,
wrapped by `nvml_oc`). `nvidia-smi` on this driver exposes only the negative
direction, which is why OC looks unavailable; NVML exports the full API and on an
unlocked card the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [    0 ..     0] MHz    <- refused by the driver
```

The offset is an undervolt expressed as a frequency offset: `+X` shifts the curve
so every voltage point reaches a clock X MHz higher, which is the same statement as
"a given clock is now reached at a lower voltage". Pin the clock so frequency is
held constant and the saving shows up directly as watts:

```
pinned SM clock | offset +0 | offset +300 | delta   | bf16 throughput
1200 MHz        | 130.6 W   | 120.6 W     |  -7.7%  | unchanged (160.4 / 160.6 TF)
1350 MHz        | 174.6 W   | 132.0 W     | -24.4%  | unchanged (179.7 / 180.7 TF)
```

This SKU reports no voltage telemetry, so watts-at-fixed-clock is the proxy, and it
is unambiguous.

**2. Clock ceiling.** The offset alone buys nothing; it only lets the arbiter climb
higher. You must also pin where it lands, and capping the clock measures better
than capping power everywhere it was tried. Two regimes govern where to sit. Below
about 1350 MHz the rail bottoms out: past roughly +250 power goes flat and extra
offset is inert, so ship the LOWEST offset that reaches the floor, not the highest
that appears to work. Above about 1400 the corruption cliff arrives before the
floor does, and the best efficiency point sits at the floor of a lower ceiling
rather than near the cliff of a higher one.

## Requirements

- CMP 170HX: GA100, 70 SM, sm_80, PCI device id 0x20C2. Non-170HX GPUs are
  detected and refused / skipped; the applier loops over every 170HX on the host
  and never touches anything else.
- The cmpunlocker patched driver for the 64 GB unlock. A stock card exposes 8 GB;
  the full-VRAM sweep and these profiles assume the unlocked 64 GB. Reference
  environment: driver 610.43.03, VBIOS 92.00.6D.00.0A.
- NVML (libnvidia-ml) for `nvml_oc` and in-process power sampling, and a CUDA
  toolkit to build the sm_80 probes.
- Nothing external: the integrity sweep the gate runs (`170hx-sweep` +
  `gpu_selftest`) ships here and `install.sh` builds it. Point `BENCH=` at a fuller
  bench harness if you have one; it only has to print `mem_errors=<n>
  compute_ok=<0|1>` on a single line.
- root, bash, `nvidia-smi`.

Per-card silicon varies. Every number above is from serial 1322621047793; do not
assume its offsets on another card. Run `qualify` per serial, stop the ladder at
the first device fault and back off one full step, gate the candidate with four
soaked sweeps, and gate with your real workload (`gate --workload`) before
persisting.

## Environment knobs

```
GATE_TEMP=60          HBM temperature to soak to before every sweep
GATE_SOAK_MAX=180     give up soaking after this many seconds
GATE_COMPUTE=45       seconds of bit-exact GEMM checking per gate (0 disables)
MEASURE_TIMEOUT=180   a measurement exceeding this is treated as a HANG
BENCH=/path           the integrity sweep (default: the 170hx-sweep installed here)
SWEEP_FRAC=0.95       fraction of FREE VRAM 170hx-sweep writes and verifies
COMPUTE=/path         the compute checker        NVML=/path   nvml_oc
```

## Repo contents

```
tools/170tune           the harness: explain, status, try, gate, ladder, qualify,
                        quarantine, selftest, apply, persist, reset, recover, boot-check
tools/170hx-oc          profile applier: named profiles plus 'custom <off> <clk>'
systemd/170hx-oc.service           boot persistence; reads /etc/170tune/profile
systemd/170tune-bootcheck.service  reverts a setting that was in flight at a crash
tools/nvml_oc.c         query/apply GPC and MEM VF offsets via NVML
tools/compute_check.cu  bit-exact GEMM checker: the same deterministic bf16 GEMM
                        compared bit for bit, catches silent COMPUTE corruption
tools/170hx-sweep       the integrity gate: runs gpu_selftest, prints the one
                        result line 170tune gates on
tools/gpu_selftest.cu   full-VRAM sweep: unique-per-address 64-bit pattern, verified
                        exactly; catches silent MEMORY corruption and aliased backing
tools/oc_eff.cu         sustained bf16 GEMM with in-process NVML power sampling
tools/mem_probe.cu      streaming bandwidth + dependent-load latency probes
docs/tuning-guide.md         the long-form findings
docs/measurement-matrix.md   the full offset x clock-ceiling measurement matrix
install.sh              build the probes, install the tools, enable boot-check
```

## License

MIT, see LICENSE. Note what that does and does not cover: this repo is the tuning,
measurement and recovery harness. The 64 GB memory unlock and the PCIe Gen2 retrain it
assumes are separate projects with their own licenses, and none of their code is included
here.


## Attribution

Almost everything this tool stands on was worked out by other people, in this order.

**[amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)** is the
foundation. The 64 GB memory unlock is his: a runtime unlock through patched open GPU
kernel modules, no VBIOS flash. Without it this card exposes 8 GB and none of the rest
of this matters. His Gen2 patch (`0007`) is also what makes the endpoint advertise
`CAP2=0x06` at all, which is the opening every later attempt aims at.

**bendy2** worked out the PCIe Gen2 retrain: target speed in LNKCTL2 on both the
endpoint and the upstream bridge, Retrain Link bit, then poll LnkSta and only claim
success on a genuinely negotiated Gen2. He also moved it into the driver via `ioremap`
of BAR0, which fixed the mmap failure that had blocked userspace attempts. Merged
upstream as PR #18.

**[asm64-hooligan/cmpunlocker@mem_overclock](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock)**
mapped the FBPA memory PLL, in a fork of amogh's repo: the per-partition register
locations (cfg at `+0x3C90`, coefficient at `+0x3C98`, base `0x900000 + i*0x4000`), the
coefficient encoding, and the `FBPA_PLL` priv-level-mask entry `0x009a3c7c` that opens
in the post-BooterLoad window. The memory-clock section of the guide is built on that
map, and finding it independently would have cost weeks.

Our measurements disagree with that fork's conclusion: raising the memory PLL does not
raise delivered bandwidth on this part, because the DRAM runs at the rate it was
trained at and the stacks already ship at 3.456 Gbps per pin, above HBM2e nominal. That
is a disagreement about what the lever buys, not about the register work, which is
sound. Running the same lever downward is what proved the PLL genuinely reaches the
DRAM, and it is a usable power saving in its own right.

**This project** contributes what sits on top of all of that: the tuning, the
measurement discipline, the integrity gate and the recovery path. The link-training
half of our work lives separately in
[cmp170hx-gen2](https://github.com/studebaker8/cmp170hx-gen2), which is bendy2's
sequence fired at the one moment it works.

If you take one idea from this repo, take the gate rule: on this card, "it did not
crash" is not a result.
