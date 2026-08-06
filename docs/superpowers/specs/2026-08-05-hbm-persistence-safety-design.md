# HBM persistence safety design

## Purpose

Prevent an unqualified HBM clock or timing profile from being applied at every
boot. A profile that has already passed the required hot tests remains fixed;
boot does not repeat the full stability test.

This change addresses two gaps in the current implementation:

1. `persist save --ndiv ... --timings ...` accepts HBM settings without evidence
   that the exact settings passed a gate on the current card.
2. `boot-apply` calls a profile healthy after a two-second Xid/wedge check. It
   does not verify that the requested registers were applied, that the CUDA
   context remains usable, or that the qualification evidence still matches
   the hardware and software environment.

## Scope

The change covers HBM qualification receipts, persistence validation, boot-time
profile validation, register readback, and regression tests for those control
flows.

It does not:

- change HBM PLL or timing register values;
- change the documented safe NDIV recommendation;
- run a full-VRAM sweep at every boot;
- unlock BAR0 privilege masks, GPU capacity, GPCs, power limits, or PCIe Gen2;
- replace long-duration workload qualification;
- flash the VBIOS or rebuild the NVIDIA driver.

## Qualification model

### Exact-profile receipt

A successful HBM qualification produces a receipt for the exact active HBM
profile. The identity of a receipt includes:

- GPU serial number;
- PCI device ID;
- NVIDIA driver version;
- VBIOS version;
- NDIV;
- normalized timing field/value pairs;
- sweep count and peak HBM temperature;
- whether the CUDA compute check ran and passed;
- the real-workload command, timeout, and exit status when supplied;
- qualification timestamp.

The receipt is stored below:

```text
/var/lib/170tune/gated-hbm/<serial>/<profile-id>.json
```

`profile-id` is the first 16 hexadecimal characters of the SHA-256 digest of
`ndiv=<N>;timings=<NORMALIZED_TIMINGS>`. The JSON fields remain authoritative;
the file name is only an index.

Timing normalization uses uppercase field names, decimal values, one space
between tokens, and a stable field ordering. A profile containing the same
settings in a different command-line order therefore resolves to the same
receipt.

### Qualification command

Add a single command that tests the combined profile which will later be
persisted:

```text
170tune hbm-gate --ndiv N [--timings "FIELD VALUE ..."] \
                 [--sweeps N] [--workload "COMMAND"]
```

The command:

1. verifies that the card is a supported CMP 170HX and is currently usable;
2. applies the requested timings and NDIV in the existing safe order;
3. verifies PLL lock and timing readback;
4. runs the existing hot full-VRAM sweeps, compute check, and context check;
5. optionally runs the supplied real workload after the hot gate;
6. rejects the profile on a sweep error, compute mismatch, dead CUDA context,
   workload failure, Xid, insufficient gate temperature, or readback mismatch;
7. writes the receipt only after every requested check passes.

The existing `mclk-gate`, `timings-gate`, and `refresh gate` commands remain
available for exploration. They do not independently prove a combined persisted
profile and therefore do not create an exact-profile persistence receipt.

The qualification command leaves the successfully tested profile active so the
operator can continue with a longer external soak. Reverting remains explicit
through the existing recovery or stock commands.

## Persistence behavior

### Save

When `persist save` includes a non-stock `--ndiv` or any `--timings`, it
normalizes the requested HBM profile and requires a matching receipt for the
current GPU.

The save is rejected when:

- no exact-profile receipt exists;
- the receipt belongs to another serial number or PCI device ID;
- driver or VBIOS version differs from the receipt;
- NDIV or normalized timings differ;
- the receipt has fewer than four hot sweeps;
- the recorded peak temperature is below `GATE_TEMP`;
- the compute or context check did not pass;

`--force` remains an explicit expert override for compatibility with the
existing SM persistence workflow. It prints a high-visibility warning and
records `HBM_FORCED=1` in the persisted configuration. A forced profile is not
described as qualified in status or boot logs.

Stock HBM settings do not require a receipt. SM-only persistence continues to
use the existing SM receipt gate.

### Enable

`persist enable` validates the stored profile again. This prevents an old or
manually edited configuration from bypassing the checks performed by
`persist save`.

## Boot behavior

Boot does not repeat hot sweeps or a long workload. It performs a bounded
validation of the fixed, previously qualified profile:

1. load the per-serial persisted configuration;
2. require a matching HBM receipt unless `HBM_FORCED=1` was recorded;
3. refuse the HBM portion when serial, PCI ID, driver, or VBIOS changed;
4. apply timings and verify every timing field by readback;
5. apply NDIV and require PLL lock and NDIV readback;
6. run the existing bounded CUDA context probe;
7. check for a wedge or new Xid;
8. revert to stock and return failure if any check fails.

The existing armed-marker and next-boot self-disarm behavior remains in place.
The boot log distinguishes `qualified`, `forced`, `receipt mismatch`, `readback
failure`, and `runtime health failure`.

This check is intentionally short. Temperature-dependent stability belongs to
the qualification and soak phase; a cold full-memory test at every boot would
delay startup without reproducing the failure mode that matters.

## Compatibility and migration

Existing persisted HBM profiles have no exact-profile receipt. After upgrade:

- SM-only profiles continue to work;
- stock-HBM profiles continue to work;
- non-stock HBM profiles remain stored but are not applied until they are
  qualified with `hbm-gate` and saved again, or explicitly saved with
  `--force`;
- the tool prints the exact qualification command needed for the stored
  profile.

No existing receipt is silently reinterpreted as an HBM receipt. SM receipts
and HBM receipts remain separate because they prove different failure domains.

## Test design

The repository currently has no control-flow test harness. Add shell integration
tests using temporary state directories and stub executables. Production paths
become environment-overridable while retaining their current defaults:

```text
STATE=${STATE:-/var/lib/170tune}
PERSIST=${PERSIST:-$STATE/persist}
PERSIST_UNIT=${PERSIST_UNIT:-/etc/systemd/system/170tune-persist.service}
```

Tests run without a GPU and cover:

1. non-stock HBM persistence is rejected without an exact receipt;
2. a successful combined HBM gate writes a receipt containing the full profile
   and environment fingerprint;
3. a receipt for a different NDIV, timing set, serial, driver, VBIOS, or device
   ID is rejected;
4. fewer than four sweeps or a cold gate is rejected;
5. stock-HBM and SM-only profiles remain compatible;
6. `--force` is explicit and marks the persisted profile forced;
7. `persist enable` revalidates a stored profile;
8. boot refuses a missing or stale receipt;
9. boot rejects NDIV, timing, PLL, CUDA-context, wedge, and Xid failures and
   invokes the stock reversion path;
10. boot accepts a matching qualified profile without invoking the full-VRAM
    self-test.

The shell tests validate control flow. Final hardware validation still requires
a CMP 170HX with the unlock applied and must be run separately before proposing
the change upstream.

## Success criteria

- No non-stock HBM profile is persisted by default without exact qualification
  evidence for that card and environment.
- A qualified fixed profile starts without repeating the expensive stability
  test.
- Boot verifies the values actually applied and CUDA usability.
- Any failed boot check returns the card to the stock recovery path and leaves
  actionable logs.
- Existing SM-only behavior is unchanged.
- All new control-flow tests pass without GPU hardware.
