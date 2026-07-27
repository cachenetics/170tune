#!/usr/bin/env bash
# Build and install 170tune. Needs: CUDA toolkit (nvcc), a C compiler, an NVIDIA driver with NVML.
# Installs to /usr/local/bin and enables the boot-check unit. Nothing is overclocked by installing.
set -euo pipefail
cd "$(dirname "$0")"
CUDA=${CUDA:-/opt/cuda}
ARCH=${ARCH:-sm_80}          # GA100. Change only if you know what you are doing.
say() { printf '%s\n' "$*"; }

command -v "$CUDA/bin/nvcc" >/dev/null || { echo "nvcc not found at $CUDA/bin/nvcc - set CUDA=..."; exit 1; }
say "building probes for $ARCH"
"$CUDA/bin/nvcc" -O3 -arch=$ARCH -o tools/oc_eff        tools/oc_eff.cu        -lcublas -lnvidia-ml
"$CUDA/bin/nvcc" -O3 -arch=$ARCH -o tools/compute_check tools/compute_check.cu -lcublas
"$CUDA/bin/nvcc" -O3 -arch=$ARCH -o tools/mem_probe     tools/mem_probe.cu
"$CUDA/bin/nvcc" -O3 -arch=$ARCH -o tools/gemm_probe    tools/gemm_probe.cu    -lcublas
cc -O2 -o tools/nvml_oc tools/nvml_oc.c -I"$CUDA/include" -lnvidia-ml

say "installing to /usr/local/bin"
sudo install -m 755 tools/170tune tools/170hx-oc /usr/local/bin/
sudo install -m 755 tools/oc_eff tools/compute_check tools/mem_probe tools/gemm_probe tools/nvml_oc /usr/local/bin/
sudo mkdir -p /var/lib/170tune

if [ -d /etc/systemd/system ]; then
  say "installing units (boot-check enabled; the profile applier is NOT enabled by default)"
  sudo install -m 644 systemd/170tune-bootcheck.service /etc/systemd/system/
  sudo install -m 644 systemd/170hx-oc.service /etc/systemd/system/ 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable 170tune-bootcheck.service
fi

say ""
say "installed. Next:"
say "  170tune explain      what the levers are"
say "  sudo 170tune selftest    prove the detectors work on this box"
say ""
say "NOTE: 170tune needs a full-VRAM integrity sweep to gate against. It looks for"
say "170hx-test.sh; point it at your own with BENCH=/path/to/sweep. Without one, gate"
say "degrades to a compute-only check and cannot catch silent MEMORY corruption."
