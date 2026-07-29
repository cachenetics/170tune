# 170tune

Tuning, qualification and recovery harness for the NVIDIA CMP 170HX (GA100, 70 SM, sm_80,
PCI id 0x20C2, 64 GB HBM2e after the community memory unlock). It undervolts the card by
shifting the voltage/frequency curve, then proves the result is not silently corrupting
memory. The proof is the point: past a certain offset the card corrupts memory with no
crash, no Xid, no hang. Every stability test that only asks "did the kernel finish"
passes, and the data is wrong. 170tune separates "it ran" from "it is safe".

What tuning buys, on the reference card (serial 1322621047793):

* Dense GEMM bench: near-stock throughput at about a third less power (`match`: 186.5
  TFLOPS at 142.2 W, vs stock 184.3 TFLOPS at 199.2 W).
* Real inference serving: about +5% throughput, and 342 tok/s decode at +200/1400.

The two benchmarks rank the profiles differently, and **four** profiles that pass the GEMM
gate go on to kill a real server - one of them only after an hour of clean serving. Read
[Profiles](#profiles) before choosing, and soak whatever you choose.

## Quick start

```
./install.sh                       # build the probes, install, enable boot-check. Overclocks nothing.
sudo 170tune selftest              # prove the corruption detectors work before trusting any PASS
sudo 170tune gate 200 1400 4 --workload /usr/local/bin/vllm_workload_check.sh
sudo 170hx-soak 12 /usr/local/bin/vllm_workload_check.sh    # the step that actually decides
sudo 170tune persist custom 200 1400
```

That gates, soaks and ships `+200/1400`, the point that has held on the reference card
across two hour-long soaks. **Do not skip the soak line.** On this card `+300/1350` passed
the gate *including* the workload rung and then faulted in the first round of the soak; see
[Even a workload rung is not enough](#even-a-workload-rung-is-not-enough-soak-before-you-ship).

Those numbers come from one card and silicon varies, so on yours prefer the per-card flow:
`170tune explain`, `sudo 170tune ladder 1400` to find your safe offset, `sudo 170tune
qualify`, then `sudo 170tune persist custom <off> <clk>` to adopt what it recommended, and
soak it before you believe it. `qualify` records to
`/var/lib/170tune/results/<serial>/oc.json` and changes nothing permanently: a
measurement can never promote itself into production by accident, adopting one is a
separate, deliberate verb.

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

Offsets and clock locks are volatile: the driver forgets them on every reload and reboot.
`apply` is live now and gone at the next reload; `persist` is live now AND at every boot.
`persist status` shows what is persisted vs what the card is running. `persist off`
reverts to stock and disables the boot unit explicitly, rather than relying on `ExecStop`
having run: if the unit was never active, stopping it reverts nothing.

`persist` writes `/etc/170tune/profile` (`PROFILE=`, plus `OC_OFFSET=`/`OC_CLK=` for a
custom point), enables the `170hx-oc.service` oneshot that reads it at boot, applies the
point immediately, and reads the card back to confirm it actually took, rather than
trusting that a unit exiting 0 means the silicon changed.

`persist` refuses a point when:

* this card has no gate receipt for this exact offset and ceiling (`gate` writes a
  receipt per serial; another card's receipt does not count);
* the receipt has fewer than four sweeps;
* the receipt was gated cold, peak HBM never reaching `GATE_TEMP`: a cold gate is
  precisely how +325/1400 got blessed before it corrupted memory at 59 C;
* the point is quarantined on this card. Quarantine wins even over a passing receipt,
  because a receipt can be honestly earned and still wrong (see
  [A gate receipt is not enough](#a-gate-receipt-is-not-enough)); `unquarantine` lifts it.

`--force` overrides the receipt checks, loudly, and says so in the output.

## Profiles

Applied by `170hx-oc <profile>` (which `170tune apply` calls). Every profile sets a VF
offset, pins a clock ceiling with `-lgc 210,<max>` (that form, not `<max>,<max>`, lets
the card still idle down to 210 MHz), and opens the power limit to 300 W so it never binds
(`stock` puts it back to 250 W). The cap is not what does the work here: the highest draw
measured on any profile is stock's own 199.2 W. Capping power does hold the card under a
number, but it lets the clock oscillate around the cap and smears you across voltage
points; pinning the clock holds one point, and measures better. Every row passed the
full-VRAM pattern sweep with `mem_errors=0` at least twice.

Dense GEMM bench (sustained bf16 tensor-core GEMM, NVML power sampled in-process):

```
profile   offset  clk max   bf16 TFLOPS   watts     GFLOPS/W   note
stock       +0    (none)       184.3      199.2 W      925     baseline
dense      +250    1200        160.8      120.2 W     1337     lowest draw, most cards per PSU
eff        +300    1350        180.8      131.2 W     1378     QUARANTINED on the reference card
match      +250    1400        186.5      142.2 W     1311     stock throughput, -29% power
balanced   +300    1470        196.2      149.7 W     1311     QUARANTINED on the reference card
perf       +350    1590        212.2      181.2 W     1171     QUARANTINED on the reference card
max        +350    1650        215.3      186.1 W     1157     QUARANTINED on the reference card
```

**`eff` is no longer safe to ship on the reference card, and the GFLOPS/W column is why it
took so long to find out.** +300/1350 is the most efficient row in this table, gated hot
3/3 and then 4/4, passed a workload rung, served every benchmark in these notes for a full
day, and then faulted with Xid 13 in the first round of an hour-long soak. It is
quarantined here. `+300` has now faulted at 1650, 1400 and 1350; on this card the offset,
not the ceiling, is the risk lever.

Two soak-qualified replacements, each clean over a 12-round soak (1,800 multi-step
generations and 480 long-context retrievals, 0 Xid, 0 request errors):

```
point       offset  clk max   cap     serving decode   power    note
+200/1400    +200    1400     300 W     342 tok/s      181 W    highest stable throughput
+200/1200    +200    1200     200 W     303 tok/s      149 W    89% of the speed, 82% of the power
```

The second exists for cards sharing a room with people: it removes about 64 W of continuous
room heat per pair. Note what it does NOT do - temperature and fan speed barely move across
the whole cap range, because the fan curve is a thermostat. A power cap buys room heat, not
quiet.

### What the table is worth under a real server

The TFLOPS and watts above are dense GEMM numbers. They do not carry over to a real
inference server. Measured on the same card, sglang serving Qwen3.6-27B-INT8-MTP
(173k tokens of KV cache, 56.5 GB resident, 1024 in / 256 out, 32 prompts, concurrency 8):

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

`eff` looks fine here and is not. This table is a three-minute benchmark; +300/1350 went on
to serve a full day of them before faulting with Xid 13 under an hour-long soak of longer
prompts and longer generations. A serving benchmark is a better probe than a GEMM, and it
is still not a soak.

Be precise about what was captured. Only `perf` has a verbatim signature, at graph
capture during server startup:

```
Exception: Capture cuda graph failed: CUDA error: an illegal instruction was encountered
torch.AcceleratorError: CUDA error: an illegal instruction was encountered
```

For `balanced` and `max` the server-side traceback was lost to a log truncated on
restart. What is attested is the observable: a healthy server, requests completing, then
the process dies and `/health` stops answering. Recorded that way in the quarantine book
too, rather than assuming they failed the same way `perf` did.

A longer run at `eff` (+300/1350) since: 128 prompts at concurrency 16, 82 s, 204.87
tok/s output, mean TTFT 795 ms, mean TPOT 72 ms, 157.1 W, 1332 MHz mean, peak HBM 68 C,
all 128 requests served and the server still up afterwards. That is about three minutes
of load. It is evidence, not a soak.

Since then the reference card has been gated and persisted at **+300/1400** with vLLM as
the serving engine (4 hot sweeps, 56,680 GEMMs, then 96/96 requests served at concurrency
24). It beats `eff` on both halves of the job, and costs power to do it:

```
point            decode      prefill      TTFT     draw
eff +300/1350    292.9 tok/s 2670 tok/s   492 ms   157 W
+300/1400        298.9 tok/s 2744 tok/s   481 ms   170 W
```

A 31-minute burn-in there at concurrency 24 served 3552 requests with zero failures, zero
throttle samples, throughput flat within 0.6%, HBM plateauing at 68 C. Note that this is
a per-card result under one engine, and one step below the quarantined +300/1470.

Two further results worth carrying:

* **+300/1470 crashes vLLM exactly as it crashed sglang.** That quarantine is
  engine-independent: the point is bad, not merely mismatched to one server.
* **Capping power does not make this card cooler or quieter.** The fan curve is a
  thermostat, so a cap just makes the fan lazier at the same temperature: fan 2665 ->
  2494 rpm with HBM steady at 62-64 C. What the cap buys is room heat, 172 W against
  113 W per card. "Cap it to run cooler" is the intuitive move and it is wrong here.

Two honest conclusions:

* Under real serving, tuning is worth about +5% (`match`), and the GFLOPS/W ordering
  INVERTS: `dense`, the efficiency champion on the GEMM bench, is worse than stock when
  serving, because clamping to 1200 MHz hurts a workload that alternates prefill bursts
  with memory-bound decode.
* `balanced`, `perf` and `max` PASSED the 4-sweep hot gate and still could not serve for
  30 seconds. A gate receipt is necessary but not sufficient; that is exactly why
  `gate --workload` and `quarantine` exist, and why those three profiles are quarantined
  on the reference card.

The generalisable lesson, and it is not specific to this card: the GEMM numbers are not
wrong, they are narrow. A dense GEMM is one instruction mix at a steady current draw,
while an engine alternates prefill bursts, memory-bound decode and graph replay, so it
asks the rail for current transients a GEMM bench never produces. Any GPU tuned for
inference on a GEMM bench alone is qualified against the wrong load.

Memory notes: the MEM VF offset is refused by the driver and memory overclock is closed
by measurement (the PLL follows down but not up). Streaming bandwidth is essentially
profile-independent (spread under 1%); what the core profile moves is memory latency:
253.2 ns at `max` against 296.1 ns at `eff`, a 17% spread. Pick high-clock profiles for
latency-bound work; any profile for bandwidth-bound work.

## Safety

### Silent corruption is the failure that matters

A run that completes proves nothing. `+325/1400` completes happily, posts 186.7 TF at
135 W (the best GFLOPS/W in its column), and silently corrupts memory. Never accept an
operating point on "it did not crash". The three failure modes, in order of nastiness:

1. SILENT CORRUPTION - the run completes, no Xid, no hang, memory comes back wrong.
   Intermittent and temperature dependent. Only `gate` can catch it.
2. DEVICE FAULT - CUDA dies with `illegal instruction` / `illegal memory access` /
   cublas 14. Recoverable with `170tune recover`, usually via a driver reload.
3. HANG - the GPU stops answering (`GPU requires reset`). Needs a reboot, sometimes a
   power cycle.

The corruption cliff, measured at a 1400 MHz ceiling with the full-VRAM pattern sweep as
the gate:

```
offset | draw    | pattern sweeps
+250   | 142.2 W | 3 sweeps, 0 memory errors
+300   | 138.5 W | 4 sweeps, 0 memory errors
+325   | 132.7 W | 3 sweeps: 6 errors, 3 errors, 0 errors
+375   | -       | CUDA device fault under load
```

The safe window at 1400 is one 25 MHz step wide above +300. The corruption events at
+325/1400 are real and measured (sweeps there have returned `mem_errors` of 6, 3, 4 and 1
at different times) and NOT reproducible on demand: the same point has since passed
repeated gates, including at 60 C HBM, and passed 4/4 sweeps on a cold card before ever
failing. The cliff cannot be characterised precisely, only a region in which corruption
has been observed. The mitigation is margin plus repeated gating, not a single clean
result: `gate` defaults to four sweeps, and the shipped profiles sit a full step back
from the last point that ever looked clean.

### Why a cold gate lies

Corruption at +325/1400 is temperature dependent. The point passed 4 out of 4 sweeps at
37-43 C, then returned `mem_errors=1` at 50 C and again at 52 C after a sustained soak,
and `mem_errors=4` in a run driven to 51 C core / 59 C HBM. Hot silicon needs more
voltage for the same clock, so an undervolt that is stable cold corrupts hot: any
validation on an idle card is optimistic.

`gate` therefore soaks under load to a TEMPERATURE before every sweep, not for a fixed
duration (how hot 60 seconds gets you depends on ambient), and targets HBM temperature
(`GATE_TEMP=60`), not core: the core reaches 52 C in seconds while the stacks are still
cold, and it is the memory side the sweep is sensitive to. The run that first caught
+325/1400 had been driven to 59 C HBM; targeting core temperature passed that same point.

### A gate receipt is not enough

The gate's instruction mix is narrower than an inference engine's: on the reference card,
`balanced`, `perf` and `max` each passed the full 4-sweep hot gate (pattern sweeps plus
56,688 bit-exact GEMMs) and still could not run an inference server for 30 seconds. Two
tools close that hole:

* `gate <off> <clk> --workload <cmd>` runs your own command, the thing you will actually
  deploy, as an extra gate step and records on the receipt that the point survived a real
  workload. Gate with the workload you intend to run.
* `quarantine <off> <clk> --reason "..."` records a point as known-bad on this card;
  `persist` then refuses it even if it holds a passing gate receipt. `quarantine list`
  shows the book, `unquarantine` lifts an entry.

**The rung has to be the engine that will serve.** A workload rung running a different
engine certifies the point against a load it will never see, and it cuts the other way
too: a fault peculiar to the untested engine rejects a point the production one handles
fine. On the reference card +300/1400 was nearly gated with an sglang rung after
production had already moved to vLLM, and sglang had never been run at that point at all.
A receipt naming a workload that is not the production engine is closer to no workload
than to a real one, and `persist` prints the workload from the receipt so you can check.
`tools/vllm_workload_check.sh` is a worked example: start the real unit, push real traffic
through the real port, assert every request completed AND the server is still healthy
afterwards, stop it again. Copy its shape, point it at your own service.

Match the workload's DURATION to what you are claiming, too. The three profiles above
failed within thirty seconds, so a short run does discriminate, but a point that survived
three minutes of serving has been shown to survive three minutes of serving and nothing
more. If it is going to run for days, gate it for longer than a benchmark takes.

### Even a workload rung is not enough: soak before you ship

On the reference card `+300/1350` passed the full 4-sweep hot gate, ~55,000 bit-exact
GEMMs **and** a production-engine workload rung, was persisted on the strength of that,
and then faulted with Xid 13 (Illegal Instruction Encoding, GPC 3) in the **first round**
of an hour-long soak. A sibling point, `+300/1400`, had passed the same gate plus a
232-request throughput sweep, a 31-minute 3,552-request burn-in and a hand-checked chat
completion before it faulted the same way. Nothing shorter than a soak found either one.

```
170hx-soak 12 /usr/local/bin/my_workload.sh      # run it 12 times, fail on any Xid
```

`170hx-soak` repeats your workload and checks the kernel ring for new Xid lines between
rounds. That second check matters independently: an engine that retries, or a client with
a generous timeout, can absorb a fault that the card is reporting plainly to dmesg.

Two dimensions decide whether a soak discriminates:

* **Duration.** The two profiles above needed tens of minutes of continuous serving.
* **Instruction mix.** The fault appeared under long prompts and long multi-step
  generations, not under the short-prompt benchmark that the throughput sweeps and the
  burn-in used. Same engine, same port, different code paths through it. If your service
  will see long contexts, soak it with long contexts.

One trap, because it silently disarms the whole thing: **run the Xid guard as root.**
Under `kernel.dmesg_restrict=1` an unprivileged `dmesg` returns nothing and exits 0, so a
guard reads "0 Xid" indefinitely. That happened here, and the soak reported `xid_delta=0`
through 29 real Xid lines; only the request-error count caught the failure. `170hx-soak`
refuses to start rather than run blind.

Finally, on this card the OFFSET is the risk lever, not the ceiling. `+300` faulted at
1650, at 1400 and at 1350; `+200` has held at every ceiling asked of it, across two
hour-long soaks. The offset is an undervolt, so a larger one means less voltage margin at
every frequency, and instruction decode is what fails first - before memory, before
arithmetic, and therefore before anything the pattern sweeps or the GEMM check can see.
If a point faults, lower the offset before you lower the ceiling.

A fourth signature worth knowing: past the wall the clock stretcher engages and the card
runs SLOWER while reporting a higher clock (+400/1650 reports a higher clock than
+375/1650 and delivers 4% less). Running slower there is the hardware protecting itself,
not headroom.

Measured boundaries on the reference card, do not exceed: +350 is the highest offset
validated clean, and only at the high-clock profiles where RM selects a higher voltage.
+355 at 1650 faults by the third run; +360 and +375 at 1650 fault within one or two runs;
+375 at a 1700 ceiling hangs the GPU; +450 hard-crashes it and a warm reboot is not
always enough.

### Recovery, the armed marker, and boot-check

`170tune recover` clears offsets and clock locks and resets the power limit; if the card
is wedged it stops the persistence daemon and reloads the driver modules, and if that
still does not bring the card back it says so honestly: the next step is a real power
cycle, because a warm reboot leaves the card powered.

**Querying the card is not the same as using it.** There is a wedge that every
query-based check misses, seen after hard kills of an inference server mid-CUDA-context:
`nvidia-smi` answers normally, NVML does not report `requires reset`, the clocks read
fine, and no process can create a CUDA context. The signature from the application side
is torch reporting `device_count()=1` with `is_available()=False`. An earlier `recover`
cleared the offsets, saw a healthy card and printed "recovered" over exactly that state;
the GPU stayed useless to every process on the box until the driver was reloaded by hand.

So `recover` and `status` now run `ctx_probe`, which creates a context, allocates,
launches a one-thread kernel and reads the result back. If that fails while `nvidia-smi`
is healthy, `recover` goes straight to the driver reload instead of declaring success,
and it will not call the card recovered until a context can actually be created.
`ctx_probe` distinguishes out-of-memory (exit 3) from a refused context (exit 2), so a
running server holding the VRAM is never mistaken for a wedge and never triggers a reload.

Every risky apply is bracketed by an armed marker: `armed.json` (offset, ceiling, serial,
timestamp, boot id) is written and synced BEFORE the point is applied and cleared only
after the run checks back in, so it survives a hang or reboot mid-run. `170tune
boot-check`, a systemd oneshot at boot, finds a marker from a previous boot, reverts the
card to stock, logs what was in flight to `last_crash.json`, and reports it in `170tune
status`. A tuning crash is recorded, never lost, and a crashed setting is never silently
re-applied.

`selftest` closes the loop on trust: a PASS only means something if the harness can still
detect a failure, so it deterministically checks the detector plumbing (corruption
parser, incomplete-sweep handling, compute checker, thermal soak). The physical positive
control is separate (`--physical`) on purpose: the +325/1400 corruption is intermittent,
so a clean physical result is NOT evidence the harness is broken.

## How the undervolt works

Two levers, both required.

**1. GPC clock VF offset**, applied through NVML (`nvmlDeviceSetGpcClkVfOffset`, wrapped
by `nvml_oc`). `nvidia-smi` on this driver exposes only the negative direction, which is
why OC looks unavailable; NVML exports the full API and on an unlocked card the GPC range
is open:

```
GPC clock VF offset : allowed range [-1000 .. +1000] MHz    <- open
MEM clock VF offset : allowed range [    0 ..     0] MHz    <- refused by the driver
```

The offset is an undervolt expressed as a frequency offset: `+X` shifts the curve so
every voltage point reaches a clock X MHz higher, the same statement as "a given clock is
now reached at a lower voltage". Pin the clock so frequency is held constant and the
saving shows up directly as watts (this SKU reports no voltage telemetry, so
watts-at-fixed-clock is the proxy, and it is unambiguous):

```
pinned SM clock | offset +0 | offset +300 | delta   | bf16 throughput
1200 MHz        | 130.6 W   | 120.6 W     |  -7.7%  | unchanged (160.4 / 160.6 TF)
1350 MHz        | 174.6 W   | 132.0 W     | -24.4%  | unchanged (179.7 / 180.7 TF)
```

**2. Clock ceiling.** The offset alone buys nothing; it only lets the arbiter climb
higher. You must also pin where it lands, and capping the clock measures better than
capping power everywhere it was tried. Two regimes govern where to sit. Below about
1350 MHz the rail bottoms out: past roughly +250 power goes flat and extra offset is
inert, so ship the LOWEST offset that reaches the floor, not the highest that appears to
work. Above about 1400 the corruption cliff arrives before the floor does, and the best
efficiency point sits at the floor of a lower ceiling rather than near the cliff of a
higher one.

## Requirements

- CMP 170HX: GA100, 70 SM, sm_80, PCI device id 0x20C2. Non-170HX GPUs are detected and
  refused / skipped; the applier loops over every 170HX on the host and never touches
  anything else.
- The cmpunlocker patched driver for the 64 GB unlock. A stock card exposes 8 GB; the
  full-VRAM sweep and these profiles assume the unlocked 64 GB. Reference environment:
  driver 610.43.03, VBIOS 92.00.6D.00.0A.
- NVML (libnvidia-ml) for `nvml_oc` and in-process power sampling, and a CUDA toolkit to
  build the sm_80 probes.
- Nothing external: the integrity sweep the gate runs (`170hx-sweep` + `gpu_selftest`)
  ships here and `install.sh` builds it. Point `BENCH=` at a fuller bench harness if you
  have one; it only has to print `mem_errors=<n> compute_ok=<0|1>` on a single line.
- root, bash, `nvidia-smi`.

Per-card silicon varies. Every number above is from serial 1322621047793; do not assume
its offsets on another card. Run `qualify` per serial, stop the ladder at the first
device fault and back off one full step, gate the candidate with four soaked sweeps, and
gate with your real workload (`gate --workload`) before persisting.

## Environment knobs

```
GATE_TEMP=60          HBM temperature to soak to before every sweep
GATE_SOAK_MAX=180     give up soaking after this many seconds
GATE_COMPUTE=45       seconds of bit-exact GEMM checking per gate (0 disables)
MEASURE_TIMEOUT=180   a measurement exceeding this is treated as a HANG
WORKLOAD_TIMEOUT=900  'gate --workload': a workload that hangs counts as a FAILURE
CTX_TIMEOUT=60        context probe timeout; a probe that hangs is treated as a wedge
CTXPROBE=/path        the context probe (default: the ctx_probe installed here)
BENCH=/path           the integrity sweep (default: the 170hx-sweep installed here)
SWEEP_FRAC=0.95       fraction of FREE VRAM 170hx-sweep writes and verifies
COMPUTE=/path         the compute checker        NVML=/path   nvml_oc
```

## Repo contents

```
tools/170tune           the harness (every command above)
tools/170hx-oc          profile applier: named profiles plus 'custom <off> <clk>'
systemd/170hx-oc.service           boot persistence; reads /etc/170tune/profile
systemd/170tune-bootcheck.service  reverts a setting that was in flight at a crash
tools/nvml_oc.c         query/apply GPC and MEM VF offsets via NVML
tools/compute_check.cu  deterministic bf16 GEMM repeated and compared bit for bit;
                        catches silent COMPUTE corruption the memory sweep cannot see
tools/170hx-sweep       the integrity gate: runs gpu_selftest, prints the one result
                        line 170tune gates on
tools/gpu_selftest.cu   full-VRAM sweep: unique-per-address 64-bit pattern verified
                        exactly; catches silent MEMORY corruption and aliased backing
tools/ctx_probe.cu      the smallest proof the card is USABLE: create a context, allocate,
                        launch, read back. Catches the wedge nvidia-smi cannot see
tools/vllm_workload_check.sh  worked 'gate --workload' rung against a real vLLM service
tools/170hx-soak        repeat a workload for hours and fail on any new Xid; what decides
                        whether a gated point can actually be shipped
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

**They were right and we were wrong, and the correction is worth stating plainly.** An earlier
version of this section claimed our measurements disagreed with that fork: that raising the
memory PLL did not raise delivered bandwidth, because the DRAM runs at the rate it was trained
at. That conclusion is retracted. The memory clock does move - 1728 to 1890 MHz - and the
bandwidth is real, proven by exceeding the theoretical ceiling of the stock clock (1782 GB/s
measured against a 1769 GB/s peak at 1728 MHz, which is impossible unless the clock changed).

We had been measuring the wrong write. Their implementation differs from the naive approach in
three ways, and any one of them alone is enough to make the register appear to accept a value
while the clock never moves:

* the write must land **post-GSP**, after `kgspStartLogPolling` - a pre-GSP write is
  reprogrammed by GSP's own devinit;
* it must be **multicast** to all eight FBPAs (`0x0098BC98`), not unicast per partition
  (`0x00903C98`, which is the read address);
* it needs a **PRI fence and a PLL-lock poll** before the clock can be trusted.

The post-GSP insight is the same shape as the Gen2 transient window, arrived at independently:
the register was never the problem, the moment was. Their patch also keeps the VBIOS MDIV/PDIV
and swaps only NDIV so it is VBIOS-independent, and leaves the NDIV literal uncompilable until
substituted so an unpatched tree cannot silently build stock - both good engineering we have
since copied.

On this card the lever buys about 2% of serving throughput, because an INT8 inference workload is
compute-bound at these clocks rather than bandwidth-bound. That is a statement about our workload,
not about their work.

**This project** contributes what sits on top of all of that: the tuning, the
measurement discipline, the integrity gate and the recovery path. The link-training
half of our work lives separately in
[cmp170hx-gen2](https://github.com/studebaker8/cmp170hx-gen2), which is bendy2's
sequence fired at the one moment it works.

If you take one idea from this repo, take the gate rule: on this card, "it did not
crash" is not a result.
