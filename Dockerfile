FROM nvidia/cuda:13.0.0-base-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    GIT_TERMINAL_PROMPT=0 \
    PATH="/opt/venv/bin:$PATH" \
    TRITON_KNOBS_BUILD_IMPL=torch \
    CC=/usr/bin/gcc \
    CXX=/usr/bin/g++ \
    TORCH_CUDA_ARCH_LIST="8.6;8.9;9.0" \
    MAX_JOBS=4

WORKDIR /app

# 1. System utilities, Python 3, Node.js 20, GL libraries, and build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    wget \
    aria2 \
    ca-certificates \
    libx11-6 \
    libgl1 \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    gcc \
    g++ \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

# 2. Python virtual environment, PyTorch cu130, SageAttention & optimized kernels
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/venv/bin/pip install --no-cache-dir \
       torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130 \
    && /opt/venv/bin/pip install --no-cache-dir \
       comfy-kitchen alembic sqlalchemy sageattention triton

# 3. Clone ComfyUI Core and install requirements
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /app/ComfyUI \
    && /opt/venv/bin/pip install --no-cache-dir -r /app/ComfyUI/requirements.txt \
    && rm -rf /root/.cache /tmp/*

# 4. Patch comfy_kitchen na.py directly inside the venv
RUN /opt/venv/bin/python3 -c "\
import importlib.util, os;\
spec = importlib.util.find_spec('comfy_kitchen');\
path = os.path.join(spec.submodule_search_locations[0], 'backends', 'eager', 'na.py');\
code = open(path).read();\
code = code.replace('from typing import', 'from typing import Sequence, Optional, List,') if 'from typing import' in code else 'from typing import Sequence, Optional, List\n' + code;\
code = code.replace('list[int]', 'Sequence[int]').replace('list[bool]', 'Sequence[bool]').replace('float | None', 'Optional[float]');\
open(path, 'w').write(code);\
print('[Build] comfy_kitchen na.py patched successfully')"

# 5. Create base fallback directories
RUN mkdir -p /app/ComfyUI/models/diffusion_models \
             /app/ComfyUI/models/clip \
             /app/ComfyUI/models/vae \
             /app/ComfyUI/input \
             /app/ComfyUI/output

# 6. Install Node dependencies
COPY package*.json /app/
RUN if [ -f /app/package.json ]; then \
      npm install --omit=dev && npm install @aws-sdk/client-s3 @aws-sdk/s3-request-presigner dotenv ws; \
    else \
      npm init -y && npm install @aws-sdk/client-s3 @aws-sdk/s3-request-presigner dotenv ws; \
    fi

# 7. Copy project files and workflow
COPY . /app/
RUN chmod +x /app/entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/app/entrypoint.sh"]
