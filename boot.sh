#!/bin/bash
# Forge (SD WebUI) bootstrap for the Agnai backend pod.
# Idempotent: safe to re-run. Everything logs to /workspace/forge_boot.log.
exec >> /workspace/forge_boot.log 2>&1
echo "=== boot.sh start $(date) ==="
set -x
python3 --version
which python3 git curl wget
nvidia-smi | head -12
df -h /workspace | tail -1
free -g | head -2

# --- locate ComfyUI ---
COMFY=""
for d in /workspace/ComfyUI /ComfyUI /opt/ComfyUI; do
  if [ -d "$d/models" ]; then COMFY="$d"; break; fi
done
echo "COMFY=$COMFY"
ls "$COMFY/models/checkpoints" "$COMFY/models/loras" 2>/dev/null
ls -la "$COMFY/models/checkpoints/SDXL" "$COMFY/models/loras/SDXL" "$COMFY/models/loras/DMD2" "$COMFY/models/loras/HyperSD/SDXL" 2>/dev/null

# --- clone Forge ---
FORGE=/workspace/webui-forge
if [ ! -d "$FORGE" ]; then
  git clone --depth 1 https://github.com/lllyasviel/stable-diffusion-webui-forge "$FORGE"
fi
cd "$FORGE" || exit 1

# --- model symlinks: Forge side (real persona names) ---
mkdir -p models/Stable-diffusion models/Lora
if [ -n "$COMFY" ]; then
  ln -sf "$COMFY/models/checkpoints/SDXL/sd_xl_base_1.0.safetensors" models/Stable-diffusion/JuggernautXL-v9.safetensors
  ln -sf "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" models/Lora/Orchid.safetensors
  ln -sf "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" models/Lora/EmmyGirl.safetensors
  ln -sf "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" models/Lora/MollyGirl.safetensors
  # --- ComfyUI side friendly names ---
  ln -sf "SDXL/sd_xl_offset_example-lora_1.0.safetensors" "$COMFY/models/loras/Orchid.safetensors"
  ln -sf "DMD2/dmd2_sdxl_4step_lora.safetensors" "$COMFY/models/loras/EmmyGirl.safetensors"
  ln -sf "HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" "$COMFY/models/loras/MollyGirl.safetensors"
fi
ls -la models/Stable-diffusion models/Lora

# --- launch Forge WebUI (webui.sh builds the venv + installs deps) ---
if ! pgrep -f "launch.py" >/dev/null; then
  export COMMANDLINE_ARGS="--api --listen --port 7860 --skip-torch-cuda-test"
  nohup bash webui.sh > /workspace/forge_server.log 2>&1 &
  echo "forge launch started pid $!"
else
  echo "forge already running"
fi
echo "=== boot.sh end $(date) ==="
