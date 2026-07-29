#!/usr/bin/env bash
# setup-vllm-170hx.sh - stand up vLLM on NVIDIA CMP 170HX cards.
#
# The 170HX is a mining card built on GA100 (sm_80, 64 GB). vLLM runs on it well, but four of its
# properties are not what a normal Ampere/A100 guide assumes, and each one has a failure mode that
# looks like something else:
#
#   1. PCIe Gen2 x4.        Tensor parallel across cards is catastrophically slow, NOT merely
#                           suboptimal. Run one independent server per card instead. This script
#                           refuses --tensor-parallel-size > 1 rather than let you find out.
#   2. sm_80 has no FP8.    FP8 *weights* will not run. FP8 *KV cache* does - reads convert in
#                           software, and the halved KV bandwidth wins above ~8 concurrent requests.
#                           So: INT8/AWQ/GPTQ or BF16 weights, and fp8_e4m3 KV is a good default.
#   3. VRAM must be unlocked. A stock CMP VBIOS exposes a fraction of the 64 GB. If nvidia-smi does
#                           not say ~65536 MiB, fix that before touching vLLM - no serving flag
#                           compensates for it.
#   4. No display engine.   Expected. `nvidia-smi` still works; the card just has no outputs.
#
# Usage:
#   ./setup-vllm-170hx.sh --model /path/to/model [--name qwen27b] [--port 8000] [--gpu-uuid GPU-...]
#   ./setup-vllm-170hx.sh --check-only          # run the preflight and exit
#
# Installs into ~/vllm-venv, writes ~/vllm_prod.sh, and (with --install-service) a systemd unit.
set -euo pipefail

VENV="${VLLM_VENV:-$HOME/vllm-venv}"
MODEL=""
SERVED_NAME="model"
PORT=8000
HOST=127.0.0.1
MAX_LEN=8192
GPU_UTIL=0.94
GPU_UUID=""
INSTALL_SERVICE=0
CHECK_ONLY=0
EXTRA=()

# Versions this was validated against on a reference host (2x CMP 170HX, driver 610.43.03, CUDA 13.0).
# Pinned deliberately: vLLM moves fast and sm_80 is not its priority target, so an unpinned
# install is how a working box stops working.
VLLM_VERSION="${VLLM_VERSION:-0.26.0}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu130}"

die() { printf '\n[fail] %s\n' "$*" >&2; exit 1; }
note() { printf '[ok]   %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --name) SERVED_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --max-model-len) MAX_LEN="$2"; shift 2 ;;
    --gpu-memory-utilization) GPU_UTIL="$2"; shift 2 ;;
    --gpu-uuid) GPU_UUID="$2"; shift 2 ;;
    --venv) VENV="$2"; shift 2 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --tensor-parallel-size|-tp)
      [ "${2:-1}" = "1" ] || die "tensor parallel is a trap on this card.
       The 170HX runs at PCIe Gen2 x4. All-reduce over that link dominates the step time, so TP=2
       is SLOWER than a single card, not faster - and it fails as bad throughput rather than as an
       error, which is why it keeps getting tried.
       Run one server per card instead: two copies of this script with different --gpu-uuid/--port."
      shift 2 ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

echo "=== preflight ==="

command -v nvidia-smi >/dev/null || die "nvidia-smi not found - install the NVIDIA driver first."

mapfile -t GPUS < <(nvidia-smi --query-gpu=index,uuid,name,memory.total,compute_cap --format=csv,noheader)
[ "${#GPUS[@]}" -gt 0 ] || die "no NVIDIA GPUs visible."
printf '       %s\n' "${GPUS[@]}"

# (3) VRAM unlock. A locked CMP VBIOS is the single most common "vLLM OOMs immediately" cause.
SMALL=0
for g in "${GPUS[@]}"; do
  mib=$(printf '%s' "$g" | awk -F', *' '{print $4}' | tr -dc '0-9')
  cc=$(printf '%s' "$g" | awk -F', *' '{print $5}')
  [ "${mib:-0}" -lt 60000 ] && SMALL=1
  case "$cc" in
    8.0) ;;
    "") warn "could not read compute capability" ;;
    *)  warn "compute capability $cc is not 8.0 - this script's assumptions are 170HX-specific." ;;
  esac
done
if [ "$SMALL" = 1 ]; then
  die "a GPU reports well under 64 GB.
       On a CMP card that means the VBIOS memory unlock has not been applied. vLLM cannot work
       around it: --gpu-memory-utilization only divides what the driver reports. Unlock first,
       confirm nvidia-smi shows ~65536 MiB, then re-run."
fi
note "64 GB visible on all cards, sm_80"

# (4) Persistence mode. Without it the driver unloads between runs, which costs a long cold start
# and - on this card - occasionally comes back with the clock offsets cleared.
if systemctl is-enabled nvidia-persistenced >/dev/null 2>&1; then
  note "nvidia-persistenced enabled"
else
  warn "nvidia-persistenced is not enabled. Recommended: sudo systemctl enable --now nvidia-persistenced"
fi

# CUDA toolkit: vLLM needs nvcc visible for some kernel paths.
CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
[ -x "$CUDA_HOME/bin/nvcc" ] || {
  for c in /usr/local/cuda /opt/cuda-13.0 /usr/lib/cuda; do
    [ -x "$c/bin/nvcc" ] && CUDA_HOME="$c" && break
  done
}
[ -x "$CUDA_HOME/bin/nvcc" ] || die "no nvcc under \$CUDA_HOME ($CUDA_HOME) - install the CUDA toolkit."
note "CUDA toolkit at $CUDA_HOME"

# (1) Link width, informational but it is the thing people are surprised by.
# NOT piped through `head`: under `set -o pipefail`, head closing the pipe early SIGPIPEs
# nvidia-smi, the assignment inherits the failure, and `set -e` exits the script here - silently,
# because the exit code is 0 by the time anyone looks. Take the first line with an expansion.
gen=$(nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null || true)
gen=${gen%%$'\n'*}
if [ -n "$gen" ]; then
  note "PCIe link: gen $gen  (Gen2 x4 is normal here - do not tensor-parallel)"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "=== preflight passed ==="
  exit 0
fi
[ -n "$MODEL" ] || die "--model is required (a local path or a HF repo id)."

echo
echo "=== install ==="
if [ ! -x "$VENV/bin/vllm" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip wheel
  # torch first, from the CUDA-matched index, so pip cannot resolve a CPU build underneath vLLM.
  "$VENV/bin/pip" install --index-url "$TORCH_INDEX" torch
  "$VENV/bin/pip" install "vllm==$VLLM_VERSION"
  note "installed vllm==$VLLM_VERSION into $VENV"
else
  note "reusing existing venv at $VENV"
fi

"$VENV/bin/python" - <<'PY'
import torch, vllm
cc = torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None
print(f"[ok]   torch {torch.__version__} (cuda {torch.version.cuda}), vllm {vllm.__version__}, device cc {cc}")
assert torch.cuda.is_available(), "torch cannot see a CUDA device - wrong torch build for this driver"
PY

# (2) Pin the card by UUID. Index is not stable: adding a second card renumbers them, which on a
# qualification bench silently moved production onto an unsoaked card.
if [ -z "$GPU_UUID" ]; then
  GPU_UUID=$(printf '%s\n' "${GPUS[0]}" | awk -F', *' '{print $2}')
  warn "no --gpu-uuid given; pinning to the first card: $GPU_UUID"
fi

echo
echo "=== launch script ==="
LAUNCH="$HOME/vllm_prod.sh"
cat > "$LAUNCH" <<EOF
#!/usr/bin/env bash
# Generated by setup-vllm-170hx.sh. Serving config for a CMP 170HX (sm_80, 64 GB, PCIe Gen2 x4).
#
#   --kv-cache-dtype fp8_e4m3  halves KV bytes. sm_80 has no FP8 math so reads convert, but the
#                              bandwidth saved outweighs the conversion above ~8 concurrent, and
#                              the freed memory is what keeps first-token latency flat under load.
#   NO tensor parallel         Gen2 x4 makes the all-reduce dominate. One server per card.
set -euo pipefail
export CUDA_HOME=$CUDA_HOME
export PATH=\$CUDA_HOME/bin:\$PATH
export CUDA_VISIBLE_DEVICES=$GPU_UUID
exec $VENV/bin/vllm serve $MODEL \\
  --host $HOST --port $PORT --served-model-name $SERVED_NAME \\
  --max-model-len $MAX_LEN \\
  --gpu-memory-utilization $GPU_UTIL \\
  --kv-cache-dtype fp8_e4m3 \\
  "\$@"
EOF
chmod +x "$LAUNCH"
note "wrote $LAUNCH"

if [ "$INSTALL_SERVICE" = 1 ]; then
  echo
  echo "=== systemd unit (needs sudo) ==="
  sudo tee /etc/systemd/system/vllm.service >/dev/null <<EOF
[Unit]
Description=vLLM serving $SERVED_NAME on the CMP 170HX
After=network-online.target nvidia-persistenced.service
Wants=network-online.target
Requires=nvidia-persistenced.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Group=$(id -gn)
ExecStart=$LAUNCH
# Restart=always, NOT on-failure. When the GPU faults, vLLM shuts its engine down cleanly and
# exits 0; systemd then sees a success and leaves the box unserved. A serving process that has
# stopped serving is a failure whatever its exit code.
Restart=always
RestartSec=30
TimeoutStartSec=900
KillMode=mixed
KillSignal=SIGINT
TimeoutStopSec=60
OOMPolicy=continue

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  note "installed vllm.service (start with: sudo systemctl enable --now vllm)"
fi

cat <<EOF

=== done ===
  start manually : $LAUNCH
  health         : curl -s http://$HOST:$PORT/v1/models
  first request  : curl -s http://$HOST:$PORT/v1/chat/completions \\
                     -H 'Content-Type: application/json' \\
                     -d '{"model":"$SERVED_NAME","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'

  A second card is a SECOND SERVER, not tensor parallel:
    $0 --model $MODEL --name ${SERVED_NAME}-b --port $((PORT+1)) --gpu-uuid <other GPU-...>
EOF
