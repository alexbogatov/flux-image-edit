FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    GIT_TERMINAL_PROMPT=0 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# 1. System utilities, Python 3, and Node.js 20
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    wget \
    aria2 \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

# 2. Python virtual environment & PyTorch 2.4+ cu124
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/venv/bin/pip install --no-cache-dir \
       torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# 3. Clone ComfyUI Core
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /app/ComfyUI \
    && /opt/venv/bin/pip install --no-cache-dir -r /app/ComfyUI/requirements.txt

# 4. Create model storage directories
RUN mkdir -p /app/ComfyUI/models/diffusion_models \
             /app/ComfyUI/models/clip \
             /app/ComfyUI/models/vae \
             /app/ComfyUI/input \
             /app/ComfyUI/output

# 5. Bake Model Weights directly into the container image
# Replace the HuggingFace URLs with your exact model paths/weights
RUN --mount=type=secret,id=HF_TOKEN \
    HF_TOKEN=$(cat /run/secrets/HF_TOKEN 2>/dev/null || true) && \
    AUTH_HEADER=$([ -n "$HF_TOKEN" ] && echo "--header=Authorization: Bearer ${HF_TOKEN}" || echo "") && \
    echo "[Build] Downloading UNet flux-2-klein-base-4b-fp8..." && \
    aria2c -x 8 -s 8 -k 1M $AUTH_HEADER \
      -d /app/ComfyUI/models/diffusion_models -o flux-2-klein-base-4b-fp8.safetensors \
      "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors" || true && \
    echo "[Build] Downloading CLIP qwen_3_4b..." && \
    aria2c -x 8 -s 8 -k 1M $AUTH_HEADER \
      -d /app/ComfyUI/models/clip -o qwen_3_4b.safetensors \
      "https://huggingface.co/Comfy-Org/Qwen2.5-3.4B-Instruct-GGUF/resolve/main/qwen2.5-3.4b-instruct-fp8.safetensors" || true && \
    echo "[Build] Downloading VAE full_encoder_small_decoder..." && \
    aria2c -x 8 -s 8 -k 1M $AUTH_HEADER \
      -d /app/ComfyUI/models/vae -o full_encoder_small_decoder.safetensors \
      "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" || true

# 6. Install Node dependencies
COPY package*.json /app/
RUN if [ -f /app/package.json ]; then npm install --omit=dev; fi

# 7. Copy project files and workflow
COPY . /app/
RUN chmod +x /app/entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/app/entrypoint.sh"]
