#!/bin/bash
set -eo pipefail

echo "===================================================="
echo "[Startup] Initializing Flux.2 Klein Image Worker"
echo "===================================================="

# Terminate existing instances and remove stale SQLite locks
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true

mkdir -p /app/ComfyUI/input /app/ComfyUI/output

/opt/venv/bin/python3 /app/ComfyUI/main.py --listen 0.0.0.0 --port 8188 --highvram --fast &

echo "[Startup] Waiting for ComfyUI to bind to port 8188..."
until curl -s http://127.0.0.1:8188/history > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] ComfyUI online. Launching worker daemon..."

exec node worker.js
