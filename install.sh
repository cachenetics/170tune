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
"$CUDA/bin/nvcc" -O2 -arch=$ARCH -o tools/gpu_selftest  tools/gpu_selftest.cu
"$CUDA/bin/nvcc" -O2 -arch=$ARCH -o tools/ctx_probe     tools/ctx_probe.cu
cc -O2 -o tools/nvml_oc tools/nvml_oc.c -I"$CUDA/include" -lnvidia-ml

say "installing to /usr/local/bin"
sudo install -m 755 tools/170tune tools/170hx-oc tools/170hx-sweep tools/170hx-soak /usr/local/bin/
sudo install -m 755 tools/oc_eff tools/compute_check tools/mem_probe tools/gemm_probe tools/gpu_selftest tools/ctx_probe tools/nvml_oc /usr/local/bin/
# A worked --workload rung. Installed as an example to copy, not as something 170tune calls: the
# rung has to be YOUR engine, and this one knows about a particular vLLM unit and model path.
sudo install -m 755 tools/vllm_workload_check.sh /usr/local/bin/
sudo mkdir -p /var/lib/170tune

if [ -d /etc/systemd/system ]; then
  say "installing units (boot-check enabled; the profile applier is installed but NOT enabled -"
  say "  '170tune persist <profile>' is what puts a profile in the boot path, and it wants a gate"
  say "  receipt from this card first. Installing overclocks nothing.)"
  sudo install -m 644 systemd/170tune-bootcheck.service /etc/systemd/system/
  sudo install -m 644 systemd/170hx-oc.service /etc/systemd/system/
  sudo install -d -m 755 /usr/share/170tune
  sudo install -m 644 systemd/170hx-oc.service /usr/share/170tune/
  sudo systemctl daemon-reload
  sudo systemctl enable 170tune-bootcheck.service
fi

say ""
say "installed. Next:"
say "  170tune explain      what the levers are"
say "  sudo 170tune selftest    prove the detectors work on this box"
say "  sudo 170tune gate 300 1350 4   prove a point on THIS card"
say "  sudo 170tune persist eff       adopt it, now and at every boot"
say ""
say "The gate runs 170hx-sweep (installed above): a full-VRAM unique-pattern write/verify plus"
say "an exact compute checksum. Substitute a fuller bench harness with BENCH=/path if you have"
say "one - it just has to print 'mem_errors=<n>  compute_ok=<0|1>' on one line."
