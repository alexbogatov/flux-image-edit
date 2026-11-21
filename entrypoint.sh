#!/bin/bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

echo "===================================================="
echo "[Startup] Initializing Dual Flux.2 Klein Image Workers"
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
# 5. Launch Dual ComfyUI & Dual Node Daemons in Parallel
# ==============================================================================
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true
cd /app

# Launch ComfyUI Instance 1 (Port 8188)
/opt/venv/bin/python3 /app/ComfyUI/main.py \
    --listen 0.0.0.0 --port 8188 --gpu-only --fast --use-sage-attention --disable-auto-launch \
    > /var/log/flux/comfy_1.log 2>&1 &
COMFY_PID_1=$!

# Launch ComfyUI Instance 2 (Port 8189)
/opt/venv/bin/python3 /app/ComfyUI/main.py \
    --listen 0.0.0.0 --port 8189 --gpu-only --fast --use-sage-attention --disable-auto-launch \
    > /var/log/flux/comfy_2.log 2>&1 &
COMFY_PID_2=$!

echo "[Startup] Waiting for ComfyUI instances on ports 8188 and 8189..."
until curl -s http://127.0.0.1:8188/history > /dev/null 2>&1 && \
      curl -s http://127.0.0.1:8189/history > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] Both ComfyUI runtimes online."

# Launch Worker Daemon 1
COMFY_PORT=8188 WORKER_SUFFIX="worker_1" node worker.js > /var/log/flux/worker_1.log 2>&1 &
WORKER_PID_1=$!

# Launch Worker Daemon 2
COMFY_PORT=8189 WORKER_SUFFIX="worker_2" node worker.js > /var/log/flux/worker_2.log 2>&1 &
WORKER_PID_2=$!

echo "[Startup] Both workers running. Tail logs with:"
echo "  sudo docker exec -it <container> tail -f /var/log/flux/worker_1.log"
echo "  sudo docker exec -it <container> tail -f /var/log/flux/worker_2.log"

# Wait for both workers to finish
wait $WORKER_PID_1
WORKER_EXIT_CODE_1=$?

wait $WORKER_PID_2
WORKER_EXIT_CODE_2=$?

# Teardown ComfyUI instances
kill -9 $COMFY_PID_1 $COMFY_PID_2 2>/dev/null || true

# Determine exit code
if [ $WORKER_EXIT_CODE_1 -ne 0 ]; then
    WORKER_EXIT_CODE=$WORKER_EXIT_CODE_1
else
    WORKER_EXIT_CODE=$WORKER_EXIT_CODE_2
fi

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

    # Resolve pod id: explicit env, then Lium-injected vars, then hostname
    LIUM_ID="${LIUM_POD_ID:-${LIUM_POD_UUID:-${HOSTNAME}}}"

    if [ -z "$LIUM_API_KEY" ]; then
        echo "[Teardown] LIUM_API_KEY not set; cannot delete pod. Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    else
        echo "[Teardown] Resolving pod ${LIUM_ID} via ${LIUM_API_URL}/pods ..."
        LIUM_RESOLVED_ID=$(curl -s --connect-timeout 5 -H "X-API-Key: ${LIUM_API_KEY}" \
            "${LIUM_API_URL}/pods" | \
            node -e "
                const fs = require('fs');
                const want = String(process.env.LIUM_WANT || '').toLowerCase();
                try {
                    const raw = fs.readFileSync(0, 'utf-8');
                    const parsed = JSON.parse(raw);
                    const list = Array.isArray(parsed) ? parsed : (parsed.pods || parsed.data || []);
                    const pick = list.find(p => {
                        const id = String(p.id ?? p.pod_id ?? p.uuid ?? '');
                        const name = String(p.name ?? p.pod_name ?? '');
                        return id === want || name.toLowerCase() === want;
                    });
                    if (pick) process.stdout.write(String(pick.id ?? pick.pod_id ?? pick.uuid));
                } catch (_) {}
            " LIUM_WANT="$LIUM_ID" 2>/dev/null || true)

        TARGET_ID="${LIUM_RESOLVED_ID:-$LIUM_ID}"

        if [ -n "$TARGET_ID" ]; then
            echo "[Teardown] Deleting Lium pod ${TARGET_ID}..."
            curl -s -X DELETE "${LIUM_API_URL}/pods/${TARGET_ID}" \
                -H "X-API-Key: ${LIUM_API_KEY}" \
                -H "accept: application/json" || true
            echo "[Teardown] Delete requested. Terminating PID 1..."
        else
            echo "[Teardown] Could not resolve a pod id for '${LIUM_ID}'. Set LIUM_POD_ID explicitly."
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