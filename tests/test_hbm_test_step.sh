#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/tools/hbm-test-1-34-step-by-step.sh"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

if [ ! -x "$SCRIPT" ]; then
    printf 'FAIL: missing executable %s\n' "$SCRIPT" >&2
    exit 1
fi

bash "$SCRIPT" --dry-run \
    --target-ndiv 70 \
    --target-timings 'REFRESH 24' \
    --workload '/root/real-serving-soak.sh' \
    --workload-timeout 28800 >"$OUT"

grep -Fq 'DRY-RUN' "$OUT"
grep -Fq '170tune preflight' "$OUT"
grep -Fq '170tune hbm-gate --ndiv 64 --sweeps 4' "$OUT"
grep -Fq '170tune hbm-gate --ndiv 70 --timings "REFRESH 24" --sweeps 12' "$OUT"
grep -Fq 'persist enable' "$OUT"

if grep -Fq 'systemctl reboot' "$OUT"; then
    printf 'FAIL: dry-run must not schedule a reboot\n' >&2
    exit 1
fi

printf 'PASS: hbm-test-1-34-step-by-step dry-run contract\n'
