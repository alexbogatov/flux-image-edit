#!/bin/bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

echo "===================================================="
echo "[Startup] Initializing Flux.2 Klein Image Worker(s)"
echo "===================================================="

# ==============================================================================
# 1. Platform & GPU Auto-Discovery
# ==============================================================================

is_hyperstack() {
    # 1. Check for Hyperstack / NexGen Cloud metadata via cloud-init or OpenStack service
    if curl -s --connect-timeout 1 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    # 2. Check local DMI BIOS / Product identifiers exposed to Linux
    local dmi_data
    dmi_data="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || true)"
    if echo "$dmi_data" | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    # 3. Check for Hyperstack agent / provision flags created during VM bootstrap
    if [ -d "/etc/hyperstack" ] || [ -f "/var/log/hyperstack-init.log" ]; then
        return 0
    fi

    return 1
}

# Auto-Discovery Priority
if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ] || [ -n "$MODAL_ENVIRONMENT" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$VAST_CONTAINERLABEL" ] || [ -n "$CONTAINER_ID" ] || [ -n "$VAST_TCP_PORT_22" ]; then
    export RUNNER_PLATFORM="vastai"
elif [ -n "$RUNPOD_POD_ID" ]; then
    export RUNNER_PLATFORM="runpod"
elif [ -n "$LIUM_API_KEY" ] || [ -n "$LIUM_POD_ID" ] || [ -f "/etc/lium/pod.json" ]; then
    export RUNNER_PLATFORM="lium"
elif is_hyperstack; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="generic"
fi

if command -v nvidia-smi &> /dev/null; then
    export RUNNER_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)
    export RUNNER_GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | xargs)
    export RUNNER_GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1 | xargs)
else
    export RUNNER_GPU_NAME="None"
    export RUNNER_GPU_COUNT="0"
    export RUNNER_GPU_VRAM="0"
fi

MACHINE_ID=$(hostname)
API_BASE_URL="${API_BASE_URL:-https://api.runltx.com}"

echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($RUNNER_GPU_COUNT detected, $RUNNER_GPU_VRAM VRAM)"
echo "[Config]   Instances: ${COMFY_INSTANCES:-1} (override with COMFY_INSTANCES)"
echo "===================================================="

# ==============================================================================
# 2. CALL /v1/worker/on (Register startup session)
# ==============================================================================
echo "[Billing] Registering worker startup session via /v1/worker/on..."
SESSION_PAYLOAD=$(cat <<EOF
{
  "machine_id": "${MACHINE_ID}",
  "provider": "${RUNNER_PLATFORM}",
  "gpu_name": "${RUNNER_GPU_NAME}",
  "gpu_count": ${RUNNER_GPU_COUNT},
  "gpu_vram": "${RUNNER_GPU_VRAM}"
}
EOF
)

SESSION_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/v1/worker/on" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${SESSION_PAYLOAD}" || echo '{"success":false}')

export WORKER_SESSION_ID=$(echo "$SESSION_RESPONSE" | node -e "
    const fs = require('fs');
    try {
        const res = JSON.parse(fs.readFileSync(0, 'utf-8'));
        if (res.success && res.session_id) process.stdout.write(res.session_id);
    } catch (_) {}
")

if [ -n "$WORKER_SESSION_ID" ]; then
    echo "[Billing] Active Worker Session ID: ${WORKER_SESSION_ID}"
else
    echo "[Billing Warning] Could not initialize session tracking."
fi

# ==============================================================================
# 3. Storage Setup & Symlinks
# ==============================================================================
PERSISTENT_DIR="${PERSISTENT_STORAGE_DIR:-/workspace}"
MODEL_DIR="${PERSISTENT_DIR}/ComfyUI/models"

mkdir -p "${MODEL_DIR}/diffusion_models" \
         "${MODEL_DIR}/clip" \
         "${MODEL_DIR}/vae" \
         "${PERSISTENT_DIR}/ComfyUI/input" \
         "${PERSISTENT_DIR}/ComfyUI/output" \
         /var/log/flux

rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

# Clean up stale stats files from previous runs
rm -f /tmp/worker_stats_*.json /tmp/worker_stats.json

# ==============================================================================
# 4. Model Downloads (Flux.2 Klein Assets)
# ==============================================================================
download_if_missing() {
    local target_dir="$1"
    local file_name="$2"
    local url="$3"

    mkdir -p "${target_dir}"

    if [ -f "${target_dir}/${file_name}" ]; then
        echo "[Storage] Found '${file_name}' on persistent storage. Skipping download."
    else
        echo "[Storage] Missing '${file_name}'. Downloading via aria2..."
        
        # Safe header expansion: pass the arg only if HF_TOKEN is present
        local ARIA_AUTH=()
        if [ -n "$HF_TOKEN" ]; then
            ARIA_AUTH=(--header="Authorization: Bearer ${HF_TOKEN}")
        fi

        if ! aria2c -x 8 -s 8 -k 1M \
            --async-dns=false \
            --max-tries=5 \
            --retry-wait=2 \
            "${ARIA_AUTH[@]}" \
            -d "${target_dir}" -o "${file_name}" "${url}"; then
            
            echo "[Storage Warning] aria2c failed. Falling back to wget..."
            
            if [ -n "$HF_TOKEN" ]; then
                wget --quiet --show-progress -c --header="Authorization: Bearer ${HF_TOKEN}" -O "${target_dir}/${file_name}" "${url}"
            else
                wget --quiet --show-progress -c -O "${target_dir}/${file_name}" "${url}"
            fi
        fi
    fi
}

download_if_missing "${MODEL_DIR}/diffusion_models" "flux-2-klein-base-4b-fp8.safetensors" "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4b-fp8/resolve/main/flux-2-klein-base-4b-fp8.safetensors"
download_if_missing "${MODEL_DIR}/clip" "qwen_3_4b.safetensors" "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
download_if_missing "${MODEL_DIR}/vae" "full_encoder_small_decoder.safetensors" "https://huggingface.co/black-forest-labs/FLUX.2-small-decoder/resolve/main/full_encoder_small_decoder.safetensors"

# ==============================================================================
# 5. Launch ComfyUI Instances & Node Daemons
# ==============================================================================
# Instance count is explicit: COMFY_INSTANCES, default 1.
#
# Why default 1: this image is deployed on single-GPU pods (L40S 46 GB). Two
# ComfyUI instances on one GPU each hold a ~15 GB copy of UNET+text encoder and
# time-slice the SMs. Measured on an L40S: two instances -> ~31s/job, one
# instance -> ~14.7s/job. Throughput is the same either way, but per-job
# latency doubles and VRAM headroom halves. Only raise this to 2 when the pod
# genuinely has 2+ GPUs and you pin one instance per GPU.
COMFY_INSTANCES="${COMFY_INSTANCES:-1}"
if ! [[ "$COMFY_INSTANCES" =~ ^[0-9]+$ ]] || [ "$COMFY_INSTANCES" -lt 1 ]; then
    echo "[Startup] Invalid COMFY_INSTANCES='${COMFY_INSTANCES}' (expected >= 1). Falling back to 1."
    COMFY_INSTANCES=1
fi

GPU_COUNT_NUM=$(echo "${RUNNER_GPU_COUNT:-1}" | grep -oE '^[0-9]+' || echo 1)
if [ "$COMFY_INSTANCES" -gt "$GPU_COUNT_NUM" ]; then
    echo "[Startup] WARNING: COMFY_INSTANCES=${COMFY_INSTANCES} but only ${GPU_COUNT_NUM} GPU(s) detected."
    echo "[Startup]          Instances will share the GPU(s) and render slower per job."
fi

# Kill any stale ComfyUI from a previous run. `pkill` is NOT available in this
# image (no procps package), so use the bash builtin over /proc cmdlines.
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$$" ] && continue
    if tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "ComfyUI/main.py"; then
        kill -9 "$pid" 2>/dev/null || true
    fi
done
rm -f /app/ComfyUI/user/comfyui.db.lock || true
cd /app

COMFY_PIDS=()
WORKER_PIDS=()

for i in $(seq 1 "$COMFY_INSTANCES"); do
    PORT=$((8187 + i))
    /opt/venv/bin/python3 /app/ComfyUI/main.py \
        --listen 0.0.0.0 --port "$PORT" --gpu-only --fast --use-sage-attention --disable-auto-launch \
        > "/var/log/flux/comfy_${i}.log" 2>&1 &
    COMFY_PIDS+=($!)
    echo "[Startup] ComfyUI instance ${i}/${COMFY_INSTANCES} launched on port ${PORT} (pid $!)."
done

echo "[Startup] Waiting for ComfyUI instance(s)..."
for i in $(seq 1 "$COMFY_INSTANCES"); do
    PORT=$((8187 + i))
    until curl -s "http://127.0.0.1:${PORT}/history" > /dev/null 2>&1; do
        sleep 1
    done
done
echo "[Startup] All ${COMFY_INSTANCES} ComfyUI runtime(s) online."

for i in $(seq 1 "$COMFY_INSTANCES"); do
    PORT=$((8187 + i))
    COMFY_PORT="$PORT" WORKER_SUFFIX="worker_${i}" node worker.js \
        > "/var/log/flux/worker_${i}.log" 2>&1 &
    WORKER_PIDS+=($!)
done

echo "===================================================="
echo "[Startup] ${COMFY_INSTANCES} worker(s) running. Follow logs with:"
# ${HOSTNAME} is the container id, which docker accepts as the container name.
for i in $(seq 1 "$COMFY_INSTANCES"); do
    echo "  docker exec -it ${HOSTNAME} tail -f /var/log/flux/worker_${i}.log"
    echo "  docker exec -it ${HOSTNAME} tail -f /var/log/flux/comfy_${i}.log"
done
echo "  (all at once) docker exec -it ${HOSTNAME} tail -f /var/log/flux/comfy_1.log /var/log/flux/worker_1.log"
echo "  (from host)   docker logs -f ${HOSTNAME}"
echo "===================================================="

# COMFY_TAIL_LOGS=1 streams ComfyUI logs into `docker logs` so no exec is needed.
# Off by default: the stream is verbose (tqdm progress bars) and would bloat the
# container log rotation.
if [ "${COMFY_TAIL_LOGS:-0}" = "1" ]; then
    echo "[Startup] COMFY_TAIL_LOGS=1 - streaming ComfyUI logs into docker logs."
    for i in $(seq 1 "$COMFY_INSTANCES"); do
        ( tail -F "/var/log/flux/comfy_${i}.log" 2>/dev/null | sed -u "s/^/[comfy_${i}] /" ) &
    done
fi

# Wait for every worker daemon to finish
WORKER_EXIT_CODE=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid"
    code=$?
    if [ "$code" -ne 0 ] && [ "$WORKER_EXIT_CODE" -eq 0 ]; then
        WORKER_EXIT_CODE=$code
    fi
done

# Teardown ComfyUI instances
kill -9 "${COMFY_PIDS[@]}" 2>/dev/null || true

# ==============================================================================
# 6. Aggregate Stats & Finalize Session
# ==============================================================================
echo "[Billing] Finalizing worker session via /v1/worker/off..."

STATS_DATA=$(node -e "
    const fs = require('fs');
    const globFiles = ['/tmp/worker_stats_worker_1.json', '/tmp/worker_stats_worker_2.json', '/tmp/worker_stats.json'];
    let jobs = 0;
    let duration = 0;
    for (const f of globFiles) {
        try {
            if (fs.existsSync(f)) {
                const data = JSON.parse(fs.readFileSync(f, 'utf8'));
                jobs += data.jobs_processed || 0;
                duration += data.total_generation_time_sec || 0;
            }
        } catch (_) {}
    }
    console.log(JSON.stringify({ jobs, duration: Math.round(duration) }));
")

JOBS_PROCESSED=$(echo "$STATS_DATA" | node -e "const d=JSON.parse(fs.readFileSync(0,'utf-8')); console.log(d.jobs);")
TOTAL_GEN_TIME=$(echo "$STATS_DATA" | node -e "const d=JSON.parse(fs.readFileSync(0,'utf-8')); console.log(d.duration);")

OFF_PAYLOAD=$(cat <<EOF
{
  "session_id": "${WORKER_SESSION_ID}",
  "machine_id": "${MACHINE_ID}",
  "jobs_processed": ${JOBS_PROCESSED},
  "total_generation_time_sec": ${TOTAL_GEN_TIME}
}
EOF
)

curl -s -X POST "${API_BASE_URL}/v1/worker/off" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${OFF_PAYLOAD}" || true

echo "[Billing] Session closed. Jobs: ${JOBS_PROCESSED}, Total Time: ${TOTAL_GEN_TIME}s."

# ==============================================================================
# 7. Cloud Teardown & Auto-Shutdown
# ==============================================================================

# --- Hyperstack Hibernation ---
if [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
    echo "[Teardown] Requesting Hyperstack VM Hibernation for host: ${MACHINE_ID}..."
    HYPERSTACK_API_URL="${HYPERSTACK_API_URL:-https://infrahub-api.nexgencloud.com/v1}"
    
    VM_ID=$(curl -s -H "api_key: ${HYPERSTACK_API_KEY}" -H "accept: application/json" \
        "${HYPERSTACK_API_URL}/core/virtual-machines" | \
        node -e "
            const fs = require('fs');
            try {
                const data = JSON.parse(fs.readFileSync(0, 'utf-8'));
                const match = (data.instances || []).find(v => v.name && v.name.toLowerCase() === '${MACHINE_ID}'.toLowerCase());
                if (match) process.stdout.write(String(match.id));
            } catch (_) {}
        ")

    if [ -n "$VM_ID" ]; then
        echo "[Teardown] Hibernating VM ${VM_ID}..."
        curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
            "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true
    fi

# --- Lium Pod Deletion ---
elif [ "$RUNNER_PLATFORM" = "lium" ]; then
    echo "[Teardown] Shutting down Lium pod to prevent idle compute charges..."
    LIUM_API_URL="${LIUM_API_URL:-https://lium.io/api}"

    if [ -z "$LIUM_API_KEY" ]; then
        echo "[Teardown] LIUM_API_KEY not set; cannot delete pod. Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    else
        # Identity comes only from LIUM_POD_ID, written by the deploy script. It
        # is never inferred: $HOSTNAME is a 12-char container id that the API
        # rejects (422 uuid_parsing), and a name lookup from inside the pod
        # cannot reliably single this pod out - guessing wrong would delete
        # somebody else's pod on idle teardown.
        LIUM_ID="${LIUM_POD_ID:-${LIUM_POD_UUID:-}}"

        if [ -z "$LIUM_ID" ]; then
            echo "[Teardown] LIUM_POD_ID is empty; skipping Lium API delete."
            echo "[Teardown] Set LIUM_POD_ID in .env at deploy time to enable self-deletion."
            echo "[Teardown] The pod will keep billing until stopped from the Lium dashboard."
        elif [[ "$LIUM_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "[Teardown] Deleting Lium pod ${LIUM_ID}..."
            RESP=$(curl -s -X DELETE "${LIUM_API_URL}/pods/${LIUM_ID}" \
                -H "X-API-Key: ${LIUM_API_KEY}" \
                -H "accept: application/json" || true)
            echo "[Teardown] Response: ${RESP}"
        else
            echo "[Teardown] LIUM_POD_ID is not a valid 36-char UUID (got '${LIUM_ID}')."
            echo "[Teardown] Refusing to delete; stop the pod from the Lium dashboard."
        fi

        kill -s TERM 1 2>/dev/null || true
    fi

# --- Vast.ai Stop Instance ---
elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
    echo "[Teardown] Shutting down Vast.ai instance to prevent idle compute charges..."
    
    # Resolve instance ID: checks CONTAINER_ID, VAST_CONTAINERLABEL, or hostname
    VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"

    if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling Vast.ai REST API for instance ${VAST_ID}..."
        curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
            -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"state": "stopped"}' || true
    elif command -v vastai >/dev/null 2>&1 && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling vastai CLI for instance ${VAST_ID}..."
        vastai stop instance "$VAST_ID" || true
    else
        echo "[Teardown] No Vast API key or CLI found inside container. Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    fi
fi

exit $WORKER_EXIT_CODE
