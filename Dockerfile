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

# 3. Clone ComfyUI Core and pin compatible comfy-kitchen
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /app/ComfyUI \
    && /opt/venv/bin/pip install --no-cache-dir -r /app/ComfyUI/requirements.txt \
    && /opt/venv/bin/pip install --no-cache-dir "comfy-kitchen<=0.2.26"

# 4. Create base fallback directories
RUN mkdir -p /app/ComfyUI/models/diffusion_models \
             /app/ComfyUI/models/clip \
             /app/ComfyUI/models/vae \
             /app/ComfyUI/input \
             /app/ComfyUI/output

# 5. Install Node dependencies
COPY package*.json /app/
RUN if [ -f /app/package.json ]; then npm install --omit=dev; fi

# 6. Copy project files and workflow
COPY . /app/
RUN chmod +x /app/entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/app/entrypoint.sh"]