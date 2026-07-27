#!/usr/bin/env bash
# A worked example of a workload rung for `170tune gate --workload`, using vLLM.
#
# THE POINT IS THE ENGINE, NOT THIS SCRIPT. Gate against the engine that will actually serve. A
# rung that runs a different engine certifies the point against a load it will never see, and it
# can reject a good point for a fault that only the untested engine has: on the reference card
# +300/1400 was nearly gated with an sglang rung while production had already moved to vLLM, and
# sglang had never been run at that point at all. Copy this, point it at your own service and
# benchmark, and keep the shape: start the real service, push real traffic through the real port,
# assert every request completed AND the server is still alive, stop it again.
#
# Exit 0 = survived, non-zero = FAILED (the gate will reject and tell you to quarantine).
#
# env: MODEL, PROMPTS, CONC, PORT, UNIT, BENCH_PY
set -uo pipefail
RUN_AS=${SUDO_USER:-$(id -un)}
USER_HOME=$(getent passwd "$RUN_AS" | cut -d: -f6); : "${USER_HOME:=$HOME}"
MODEL=${MODEL:-$USER_HOME/models/hf/Qwen3.6-27B-INT8-MTP}
BENCH_PY=${BENCH_PY:-$USER_HOME/sgl-venv/bin/python}
UNIT=${UNIT:-vllm.service}
PORT=${PORT:-8000}
PROMPTS=${PROMPTS:-96}
CONC=${CONC:-24}
HEALTH="http://127.0.0.1:$PORT/health"

alive() { curl -s -m 5 "$HEALTH" >/dev/null 2>&1; }

systemctl start "$UNIT" || { echo "workload: could not start $UNIT"; exit 1; }
for _ in $(seq 1 90); do alive && break; sleep 5; done
alive || { echo "workload: $UNIT never came up on port $PORT"; systemctl stop "$UNIT"; exit 1; }

out=$(runuser -u "$RUN_AS" -- "$BENCH_PY" -m sglang.bench_serving --backend vllm \
      --host 127.0.0.1 --port "$PORT" --model "$MODEL" --served-model-name qwen27b --tokenizer "$MODEL" \
      --dataset-name random --random-input-len 1024 --random-output-len 256 \
      --num-prompts "$PROMPTS" --max-concurrency "$CONC" 2>&1)
ok=$(printf '%s' "$out" | grep -i "^Successful requests" | grep -oE "[0-9]+" | tail -1)
tok=$(printf '%s' "$out" | grep -i "^Output token throughput" | grep -oE "[0-9.]+" | tail -1)
# Check health AFTER the load, not just before: a card that faults under real traffic often leaves
# the server up but dead, and counting completions alone would call that a pass.
healthy=$(alive && echo yes || echo no)
systemctl stop "$UNIT"

if [ "${ok:-0}" != "$PROMPTS" ] || [ -z "$tok" ] || [ "$healthy" != "yes" ]; then
    echo "workload: FAILED (served ${ok:-0}/$PROMPTS, healthy after=$healthy)"
    exit 1
fi
echo "workload: vLLM served $ok/$PROMPTS at $tok tok/s, healthy after"
