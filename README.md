# 170tune

Tuning and qualification harness for the NVIDIA CMP 170HX: GA100, 70 SM, sm_80,
64 GB HBM2e after the community memory unlock. It measures, qualifies, applies and
recovers clock/voltage settings, and it treats "the benchmark finished" as evidence
of nothing.

The headline, and the reason this tool exists: on this card the failure that matters
is not a crash. Past a point, an undervolt corrupts memory silently - the run
completes, no Xid, no hang, every stability test that only asks "did the kernel
finish" passes, and the data is wrong. 170tune separates "it ran" from "it is safe":
`try` measures a point and prints UNVERIFIED, only `gate` (temperature-soaked
full-VRAM pattern sweeps plus a bit-exact compute check) can call a point safe, and
an armed-marker / boot-check pair makes sure a run that kills the box is recorded
instead of lost.

What tuning buys, measured (sustained bf16 tensor-core GEMM, NVML power sampled
in-process, reference card serial 1322621047793):

```
stock : 184.3 TFLOPS at 199.2 W ( 925 GFLOPS/W)
eff   : 180.8 TFLOPS at 131.2 W (1378 GFLOPS/W)   -2% perf, -34% power
max   : 215.3 TFLOPS at 186.1 W (1157 GFLOPS/W)   +17% perf at under stock power
```

## Quick start

```
# build the probes (CUDA toolkit, sm_80)
nvcc -O2 -arch=sm_80 tools/compute_check.cu -o compute_check -lcublas
nvcc -O2 -arch=sm_80 tools/oc_eff.cu        -o oc_eff        -lcublas -lnvidia-ml
nvcc -O2 -arch=sm_80 tools/mem_probe.cu     -o mem_probe
cc   -O2 tools/nvml_oc.c -o nvml_oc -lnvidia-ml

# install the scripts and binaries where 170tune expects them
sudo install tools/170tune tools/170hx-oc nvml_oc /usr/local/bin/

# then, in this order
170tune explain          # the levers, the two regimes, the failure modes
sudo 170tune selftest    # prove the detectors work before trusting any PASS
sudo 170tune ladder 1350 # walk the offset up at one ceiling, gating each rung
sudo 170tune gate 300 1350 4   # 4 soaked sweeps + compute check; exit 0 = gated
sudo 170tune apply eff   # make a gated profile live (not persistent by itself)
```

`qualify [clk]` runs the whole per-card flow and records it to
`/var/lib/170tune/results/<serial>/oc.json` without changing anything permanently.
Adopting a result is a separate, deliberate step: edit `ExecStart` in
`/etc/systemd/system/170hx-oc.service`. A good measurement can never promote itself
into production by accident.

Exit codes: 0 success / gated, 1 rejected / faulted / failed, 2 usage error or hang.

## The two levers

**1. GPC clock VF offset** - applied through NVML (`nvmlDeviceSetGpcClkVfOffset`,
wrapped by `nvml_oc`). `nvidia-smi` on this driver exposes only the negative
direction, which is why OC looks unavailable; NVML exports the full API and on an
unlocked card the GPC range is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [    0 ..     0] MHz    <- refused by the driver
```

The offset is an undervolt expressed as a frequency offset. `+X` shifts the
voltage/frequency curve so that at every voltage point the clock is X MHz higher,
which is the same statement as "a given clock is now reached at a lower voltage".
Pin the clock so frequency is held constant and the saving shows up directly as
watts:

```
pinned SM clock | offset +0 | offset +300 | delta   | bf16 throughput
1200 MHz        | 130.6 W   | 120.6 W     |  -7.7%  | unchanged (160.4 / 160.6 TF)
1350 MHz        | 174.6 W   | 132.0 W     | -24.4%  | unchanged (179.7 / 180.7 TF)
```

This SKU reports no voltage telemetry, so watts-at-fixed-clock is the proxy, and it
is unambiguous.

**2. Clock ceiling** - the offset alone buys nothing; it only lets the arbiter climb
higher. You must also pin where it lands. Capping the clock (`-lgc 210,<max>`)
measures better than capping power everywhere it was tried, so every profile sets
the offset, leaves the power limit wide open at 300 W, and pins a ceiling. The
`210,<max>` form (not `<max>,<max>`) lets the card still idle down to 210 MHz.

Two regimes govern where to sit. Below about 1350 MHz the rail bottoms out: past
roughly +250 power goes flat and extra offset is inert, so ship the LOWEST offset
that reaches the floor, not the highest that appears to work. Above about 1400 the
corruption cliff arrives before the floor does, and the best efficiency point sits
at the floor of a lower ceiling rather than near the cliff of a higher one.

## Profiles

Applied by `170hx-oc <profile>` (which `170tune apply` calls). Every row passed the
full-VRAM pattern sweep with `mem_errors=0` at least twice; these are the only
settings that carry the integrity gate.

```
profile   offset  clk max   bf16 TFLOPS   watts    GFLOPS/W   use for
stock       +0    (none)       184.3      199.2 W     925     baseline; 250 W cap
dense      +250    1200        160.8      120.2 W    1337     most cards per PSU
eff        +300    1350        180.8      131.2 W    1378     default: near-stock
                                                              speed, a third less
                                                              power
match      +250    1400        186.5      142.2 W    1311     stock throughput,
                                                              -29% power
balanced   +300    1470        196.2      149.7 W    1311     more throughput,
                                                              still under 150 W
perf       +350    1590        212.2      181.2 W    1171     throughput first,
                                                              still under stock
                                                              power
max        +350    1650        215.3      186.1 W    1157     peak validated
                                                              throughput
```
One number to be careful with: `eff` ships at +300/1350, and that point was re-gated
hot (3/3 clean sweeps at 51-52 C HBM). Earlier drafts of the measurement notes named
+250/1350 instead. Both sit on the flat part of the voltage floor and draw within a
watt of each other, so the difference is margin rather than performance; the applier
and this README are authoritative.

Memory notes: the MEM VF offset is refused by the driver and memory overclock is
closed by measurement (the PLL follows down but not up). Streaming bandwidth is
essentially profile-independent (spread under 1%); what the core profile moves is
memory latency: 253.2 ns at `max` against 296.1 ns at `eff`, a 17% spread. Pick
high-clock profiles for latency-bound work; any profile for bandwidth-bound work.

## Safety

### The rule that dominates everything

A run that completes proves nothing. `+325/1400` completes happily, posts 186.7 TF
at 135 W (the best GFLOPS/W in its column), and silently corrupts memory. Never
accept an operating point on "it did not crash". Gate it on the full-VRAM pattern
sweep, run the sweep more than once, and when two settings measure equal, take the
one with more margin.

### The corruption cliff, honestly stated

Measured at a 1400 MHz ceiling with the full-VRAM pattern sweep as the gate:

```
offset | draw    | pattern sweeps
+250   | 142.2 W | 3 sweeps, 0 memory errors
+300   | 138.5 W | 4 sweeps, 0 memory errors
+325   | 132.7 W | 3 sweeps: 6 errors, 3 errors, 0 errors
+375   | -       | CUDA device fault under load
```

The safe window at 1400 is one 25 MHz step wide above +300.

Be clear about what the evidence does and does not support. The corruption events at
+325/1400 are real and measured: sweeps at that point have returned `mem_errors` of
6, 3, 4 and 1 at different times. They are also NOT reproducible on demand: the same
point has since passed repeated gates, including at 60 C HBM, and it passed 4/4
sweeps on a cold card before ever failing. So the cliff cannot be characterised
precisely: there is no temperature or offset at which corruption is guaranteed to
show, only a region in which it has been observed. The mitigation is therefore
margin plus repeated gating, not a single clean result. A single clean gate proves
much less than people assume; that is why `gate` defaults to four sweeps and why the
shipped profiles sit a full step back from the last point that ever looked clean.

### Why a cold gate lies

Corruption at +325/1400 is temperature dependent. The point passed 4 out of 4 sweeps
at 37-43 C, then returned `mem_errors=1` at 50 C and again at 52 C after a sustained
soak, and `mem_errors=4` in a separate run driven to 51 C core / 59 C HBM. Hot
silicon needs more voltage for the same clock, so an undervolt that is stable cold
corrupts hot: any validation on an idle card is optimistic.

`gate` therefore soaks under sustained load to a TEMPERATURE before every sweep, not
for a fixed duration (how hot 60 seconds gets you depends on ambient and on what ran
before). It targets HBM temperature (`GATE_TEMP=60`), not core: the core reaches
52 C in seconds while the stacks are still cold, and it is the memory side the sweep
is sensitive to. The run that first caught +325/1400 had been driven to 59 C HBM;
targeting core temperature passed that same point.

### The three failure modes, in order of nastiness

1. SILENT CORRUPTION - the run completes, no Xid, no hang, memory comes back wrong.
   Intermittent and temperature dependent. Only `gate` can catch it.
2. DEVICE FAULT - CUDA dies with `illegal instruction` / `illegal memory access` /
   cublas 14. Recoverable with `170tune recover`, usually via a driver reload.
3. HANG - the GPU stops answering (`GPU requires reset`). Needs a reboot, sometimes
   a power cycle.

A fourth signature worth knowing: past the wall the clock stretcher engages and the
card runs SLOWER while reporting a higher clock (+400/1650 reports a higher clock
than +375/1650 and delivers 4% less). Running slower there is the hardware
protecting itself, not headroom.

Measured boundaries on the reference card, do not exceed: +350 is the highest offset
validated clean, and only at the high-clock profiles where RM selects a higher
voltage. +355 at 1650 faults by the third run; +360 and +375 at 1650 fault within
one or two runs; +375 at a 1700 ceiling hangs the GPU; +450 hard-crashes it and a
warm reboot is not always enough.

### Recovery, the armed marker, and boot-check

`170tune recover` clears offsets and clock locks and resets the power limit; if the
card is wedged it stops the persistence daemon, reloads the driver modules, and if
that still does not bring the card back it says so honestly: the next step is a real
power cycle, because a warm reboot leaves the card powered. That last step is
hands-on-the-box work.

Every risky apply is bracketed by an armed marker: `armed.json` (offset, ceiling,
serial, timestamp, boot id) is written and synced BEFORE the point is applied and
cleared only after the run checks back in. If the box hangs or reboots mid-run, the
marker survives. `170tune boot-check` runs as a systemd oneshot at boot: if a marker
from a previous boot is found, it reverts the card to stock, logs what was in flight
to `last_crash.json`, and reports it in `170tune status`. A tuning crash is recorded,
never lost, and a crashed setting is never silently re-applied.

`selftest` closes the loop on trust: a PASS from the harness only means something if
the harness can still detect a failure, so it deterministically checks the detector
plumbing (corruption parser, incomplete-sweep handling, compute checker, thermal
soak). The physical positive control is intentionally separate (`--physical`),
because the +325/1400 corruption is intermittent: a clean physical result is NOT
evidence the harness is broken.

## Requirements

- CMP 170HX: GA100, 70 SM, sm_80, PCI device id 0x20C2. Non-170HX GPUs are detected
  and refused / skipped; the applier loops over every 170HX on the host and never
  touches anything else.
- The cmpunlocker patched driver for the 64 GB unlock. A stock card exposes 8 GB;
  the full-VRAM sweep and these profiles assume the unlocked 64 GB. Reference
  environment: driver 610.43.03, VBIOS 92.00.6D.00.0A.
- NVML (libnvidia-ml) for `nvml_oc` and in-process power sampling, and a CUDA
  toolkit to build the sm_80 probes.
- A full-VRAM integrity sweep binary (`BENCH=` env; default is the local
  `170hx-test.sh --no-unlock`). The gate does not exist without it.
- root, bash, `nvidia-smi`.

Per-card silicon varies. Every number above is from serial 1322621047793; do not
assume its offsets on another card. Run `qualify` per serial, stop the ladder at the
first device fault and back off one full step, and gate the candidate with four
soaked sweeps.

## Environment knobs

```
GATE_TEMP=60          HBM temperature to soak to before every sweep
GATE_SOAK_MAX=180     give up soaking after this many seconds
GATE_COMPUTE=45       seconds of bit-exact GEMM checking per gate (0 disables)
MEASURE_TIMEOUT=180   a measurement exceeding this is treated as a HANG
BENCH=/path           the full-VRAM integrity sweep
COMPUTE=/path         the compute checker        NVML=/path   nvml_oc
```

## Repo contents

```
tools/170tune           the harness: explain, status, try, gate, ladder, qualify,
                        selftest, apply, reset, recover, boot-check
tools/170hx-oc          profile applier (+ systemd unit for boot persistence)
tools/nvml_oc.c         query/apply GPC and MEM VF offsets via NVML
tools/compute_check.cu  bit-exact GEMM checker: same deterministic bf16 GEMM
                        repeated and compared bit for bit, catches silent COMPUTE
                        corruption the memory sweep cannot see
tools/oc_eff.cu         sustained bf16 GEMM with in-process NVML power sampling
tools/mem_probe.cu      streaming bandwidth + dependent-load latency probes
docs/170hx-tuning-guide.md   the long-form findings
analysis/oc_matrix.md        the full offset x clock-ceiling measurement matrix
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
