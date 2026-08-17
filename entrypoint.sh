#!/bin/bash
set -eo pipefail

echo "===================================================="
echo "[Startup] Initializing Flux.2 Klein Image Worker"
echo "===================================================="

# Determine workspace root (RunPod persistent volume mount or fallback)
PERSISTENT_DIR="${PERSISTENT_STORAGE_DIR:-/workspace}"
MODEL_DIR="${PERSISTENT_DIR}/ComfyUI/models"

mkdir -p "${MODEL_DIR}/diffusion_models" \
         "${MODEL_DIR}/clip" \
         "${MODEL_DIR}/vae" \
         "${PERSISTENT_DIR}/ComfyUI/input" \
         "${PERSISTENT_DIR}/ComfyUI/output"

# Symlink ComfyUI paths to persistent volume storage
rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

# HuggingFace token authorization header
AUTH_HEADER=""
if [ -n "$HF_TOKEN" ]; then
    AUTH_HEADER="--header=Authorization: Bearer ${HF_TOKEN}"
fi

# Download helper function
download_if_missing() {
    local target_dir="$1"
    local file_name="$2"
    local url="$3"

    if [ -f "${target_dir}/${file_name}" ]; then
        echo "[Storage] Found '${file_name}' on persistent storage. Skipping download."
    else
        echo "[Storage] Missing '${file_name}'. Downloading via aria2..."
        aria2c -x 8 -s 8 -k 1M $AUTH_HEADER \
            -d "${target_dir}" -o "${file_name}" "${url}"
    fi
}

# 1. UNet
download_if_missing \
    "${MODEL_DIR}/diffusion_models" \
    "flux-2-klein-base-4b-fp8.safetensors" \
    "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors"

# 2. Text Encoder (CLIP/Qwen)
download_if_missing \
    "${MODEL_DIR}/clip" \
    "qwen_3_4b.safetensors" \
    "https://huggingface.co/Comfy-Org/Qwen2.5-3.4B-Instruct-GGUF/resolve/main/qwen2.5-3.4b-instruct-fp8.safetensors"

# 3. VAE
download_if_missing \
    "${MODEL_DIR}/vae" \
    "full_encoder_small_decoder.safetensors" \
    "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors"

# Clean up stale locks & processes
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true

# Launch ComfyUI with strict GPU residency
/opt/venv/bin/python3 /app/ComfyUI/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --gpu-only \
    --fast &

echo "[Startup] Waiting for ComfyUI to bind to port 8188..."
until curl -s http://127.0.0.1:8188/history > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] ComfyUI online. Launching worker daemon..."

exec node worker.js
