#!/bin/bash
# Forge (SD WebUI) bootstrap for the Agnai backend pod.
# Idempotent: safe to re-run. Everything logs to /workspace/forge_boot.log.
exec >> /workspace/forge_boot.log 2>&1
nohup python3 -m http.server 8888 --directory /workspace > /workspace/http_server.log 2>&1 &
echo "=== boot.sh start $(date) ==="
set -x
python3 --version
which python3 git curl wget
nvidia-smi | head -12
df -h /workspace | tail -1
free -g | head -2

# --- wait for ComfyUI (entrypoint copies the bundle to /workspace) ---
COMFY=""
for i in $(seq 1 60); do
  for d in /root/ComfyUI /workspace/ComfyUI /ComfyUI /opt/ComfyUI; do
    if [ -d "$d/models" ]; then COMFY="$d"; break; fi
  done
  [ -n "$COMFY" ] && break
  sleep 10
done
echo "COMFY=$COMFY"
ls "$COMFY/models/checkpoints" "$COMFY/models/loras" 2>/dev/null

# --- clone Forge ---
FORGE=/workspace/webui-forge
if [ ! -d "$FORGE" ]; then
  git clone --depth 1 https://github.com/lllyasviel/stable-diffusion-webui-forge "$FORGE"
fi
cd "$FORGE" || exit 1

# --- wait for the checkpoint + LoRAs to be ingested into ComfyUI ---
CKPT="$COMFY/models/checkpoints/SDXL/sd_xl_base_1.0.safetensors"
for i in $(seq 1 120); do
  [ -f "$CKPT" ] && break
  sleep 15
done
ls -la "$COMFY/models/checkpoints/SDXL" "$COMFY/models/loras/SDXL" "$COMFY/models/loras/DMD2" "$COMFY/models/loras/HyperSD/SDXL" 2>/dev/null

# --- model symlinks: Forge side (real persona names) ---
mkdir -p models/Stable-diffusion models/Lora
if [ -n "$COMFY" ]; then
  ln -sf "$CKPT" models/Stable-diffusion/JuggernautXL-v9.safetensors
  ln -sf "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" models/Lora/Orchid.safetensors
  ln -sf "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" models/Lora/EmmyGirl.safetensors
  ln -sf "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" models/Lora/MollyGirl.safetensors
  # --- ComfyUI side friendly names ---
  ln -sf "SDXL/sd_xl_offset_example-lora_1.0.safetensors" "$COMFY/models/loras/Orchid.safetensors"
  ln -sf "DMD2/dmd2_sdxl_4step_lora.safetensors" "$COMFY/models/loras/EmmyGirl.safetensors"
  ln -sf "HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" "$COMFY/models/loras/MollyGirl.safetensors"
fi
ls -la models/Stable-diffusion models/Lora

# --- launch Forge WebUI ---
# NOTE: webui.sh refuses to run as root, so build the venv by hand and
# call launch.py directly with the venv python (it self-installs deps).
if ! pgrep -f "launch.py" >/dev/null; then
  cd "$FORGE" || exit 1
  # Python 3.12 fixes: Forge's pins predate cp312 wheels for these two
  # (scikit-image 0.21.0 is sdist-only for cp312; its meson build fails).
  sed -i 's/^scikit-image==.*/scikit-image==0.24.0/' requirements_versions.txt
  # NOTE: Pillow stays at Forge's 9.5.0 pin - blendmodes==2022 requires
  # Pillow<10, and 9.5.0's sdist is the only sub-10 option on cp312.
  if [ ! -x venv/bin/python ]; then python3 -m venv venv; fi
  ./venv/bin/pip install --upgrade "setuptools<81" wheel
  export PIP_NO_BUILD_ISOLATION=1
  nohup ./venv/bin/python launch.py --api --listen --port 7860 --skip-torch-cuda-test > /workspace/forge_server.log 2>&1 &
  echo "forge launch started pid $!"
else
  echo "forge already running"
fi
echo "=== boot.sh end $(date) ==="
