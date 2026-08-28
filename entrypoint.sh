#!/bin/bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

echo "===================================================="
echo "[Startup] Initializing Flux.2 Klein Image Worker"
echo "===================================================="

# ==============================================================================
# 1. Platform & GPU Auto-Discovery
# ==============================================================================
if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ] || [ -n "$MODAL_ENVIRONMENT" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$HYPERSTACK_API_KEY" ]; then
    export RUNNER_PLATFORM="hyperstack"
elif [ -n "$RUNPOD_POD_ID" ]; then
    export RUNNER_PLATFORM="runpod"
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
# 2. CALL /v1/worker/on (Register session before heavy work starts)
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
         "${PERSISTENT_DIR}/ComfyUI/output"

rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

# ==============================================================================
# 4. Model Downloads (Flux.2 Klein Assets)
# ==============================================================================
AUTH_HEADER=""
if [ -n "$HF_TOKEN" ]; then
    AUTH_HEADER="--header=Authorization: Bearer ${HF_TOKEN}"
fi

download_if_missing() {
    local target_dir="$1"
    local file_name="$2"
    local url="$3"

    if [ -f "${target_dir}/${file_name}" ]; then
        echo "[Storage] Found '${file_name}' on persistent storage. Skipping download."
    else
        echo "[Storage] Missing '${file_name}'. Downloading via aria2..."
        
        # 1. Attempt with aria2c
        if ! aria2c -x 8 -s 8 -k 1M \
            --async-dns=false \
            --max-tries=5 \
            --retry-wait=2 \
            $AUTH_HEADER \
            -d "${target_dir}" -o "${file_name}" "${url}"; then
            
            echo "[Storage Warning] aria2c download failed. Falling back to wget..."
            
            # 2. Fallback to wget
            local WGET_AUTH=$([ -n "$HF_TOKEN" ] && echo "--header=Authorization: Bearer ${HF_TOKEN}" || echo "")
            wget --quiet --show-progress -c $WGET_AUTH -O "${target_dir}/${file_name}" "${url}"
        fi
    fi
}

# 1. UNet
download_if_missing \
    "${MODEL_DIR}/diffusion_models" \
    "flux-2-klein-base-4b-fp8.safetensors" \
    "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4b-fp8/resolve/main/flux-2-klein-base-4b-fp8.safetensors"

# 2. Text Encoder (CLIP/Qwen)
download_if_missing \
    "${MODEL_DIR}/clip" \
    "qwen_3_4b.safetensors" \
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"

# 3. VAE
download_if_missing \
    "${MODEL_DIR}/vae" \
    "full_encoder_small_decoder.safetensors" \
    "https://huggingface.co/black-forest-labs/FLUX.2-small-decoder/resolve/main/full_encoder_small_decoder.safetensors"

# ==============================================================================
# 5. Launch ComfyUI & Worker Daemon
# ==============================================================================
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true

cd /app
/opt/venv/bin/python3 /app/ComfyUI/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --gpu-only \
    --fast \
    --use-sage-attention \
    --disable-auto-launch &
COMFY_PID=$!

echo "[Startup] Waiting for ComfyUI to bind to port 8188..."
until curl -s http://127.0.0.1:8188/history > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] ComfyUI online. Launching worker daemon..."

# Execute worker daemon and wait for completion/inactivity exit
node worker.js
WORKER_EXIT_CODE=$?

# Teardown ComfyUI process
kill -9 $COMFY_PID 2>/dev/null || true

# ==============================================================================
# 6. CALL /v1/worker/off & Handle Hibernation
# ==============================================================================
echo "[Billing] Finalizing worker session via /v1/worker/off..."

STATS_FILE="/tmp/worker_stats.json"
JOBS_PROCESSED=0
TOTAL_GEN_TIME=0

if [ -f "$STATS_FILE" ]; then
    JOBS_PROCESSED=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).jobs_processed || 0); } catch(_) { console.log(0); }")
    TOTAL_GEN_TIME=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).total_generation_time_sec || 0); } catch(_) { console.log(0); }")
fi

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

echo "[Billing] Session closed."

# Trigger Hyperstack VM Hibernation if running on Hyperstack
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
fi

exit $WORKER_EXIT_CODE