#!/bin/bash
# Forge (SD WebUI) bootstrap for the Agnai backend pod — v2, PORTABLE.
# Auto-installs ALL models at spinup; no manual ingest step afterwards.
#   - Juggernaut XL v9 checkpoint (HuggingFace, public)
#   - Orchid / EmmyGirl / MollyGirl LoRAs (Civitai, public)
#   - z0ya LoRA (zoya-flux-v31-step1680.safetensors, 344 MB) — private
#     GitHub repo dudeimdead/zoya-comfy-image, weights/lora-parts-v31/
#     (48 parts, Contents API, ref main), fetched with the pod env var
#     ZOYA_GH_TOKEN. If the token is unset the z0ya fetch logs a clear
#     skip and boot continues with the other four models.
#   - FLUX.1-dev FP8 stack (HuggingFace, public) — checkpoint, T5-XXL
#     FP8 + CLIP-L text encoders, FLUX VAE. Single Forge instance serves
#     both SDXL and FLUX; Agnai switches the checkpoint per request.
# Idempotent: safe to re-run (present files with matching size are skipped).
# Everything logs to /workspace/forge_boot.log.
exec >> /workspace/forge_boot.log 2>&1
nohup python3 -m http.server 8888 --directory /workspace > /workspace/http_server.log 2>&1 &
disown # MUST disown: the bare `wait` below (after the downloads) would
      # otherwise wait on this never-exiting server forever (2026-11-13
      # first live run stalled here: all downloads ok, script never moved on).
echo "=== boot-v2.sh start $(date) ==="
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

# --- auto-install models at spinup (portable) ---
# dl(): public URL download with retry + size check + atomic rename.
# (fetch-models.sh semantics: fail on HTTP error, retry 3x, .part file.)
dl() { # $1=url  $2=dest  $3=expected_bytes
  local dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" = "$want" ]; then
    echo "BOOT-V2: skip (present) $dest"; return 0
  fi
  mkdir -p "$(dirname "$dest")"
  echo "BOOT-V2: downloading $dest"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 5 -o "$dest.part" "$1"
  else
    wget --tries=3 --waitretry=5 -O "$dest.part" "$1"
  fi \
    && [ "$(stat -c%s "$dest.part" 2>/dev/null || echo 0)" = "$want" ] \
    && mv "$dest.part" "$dest" \
    && echo "BOOT-V2: ok $dest" \
    || echo "BOOT-V2: FAILED $dest (wanted $want bytes)"
}
# ghfetch(): private GitHub Contents API, raw bytes (fetch-models.sh v2.3
# pattern). $1=contents path (under weights/), $2=dest file. Needs
# ZOYA_GH_TOKEN in env; exits 2 without it.
ghfetch() {
  python3 - "$1" "$2" <<'PYEOF'
import os, sys, urllib.request, urllib.error
url = ("https://api.github.com/repos/dudeimdead/zoya-comfy-image/contents/"
       + sys.argv[1] + "?ref=main")
dest = sys.argv[2]
token = os.environ.get("ZOYA_GH_TOKEN", "")
if not token:
    sys.exit(2)
class NoRedir(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a):
        return None
req = urllib.request.Request(url, headers={
    "Authorization": "Bearer " + token,
    "Accept": "application/vnd.github.raw",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "zoya-boot-v2"})
opener = urllib.request.build_opener(NoRedir())
try:
    with opener.open(req, timeout=300) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
except urllib.error.HTTPError as e:
    if e.code in (301, 302, 303, 307, 308):
        loc = e.headers.get("Location")
        if not loc:
            sys.exit(1)
        with urllib.request.urlopen(loc, timeout=300) as r, open(dest, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
    else:
        sys.exit(1)
PYEOF
}
# ghlora_v31(): z0ya LoRA, 48 parts -> concat -> size + SHA-256 check.
# NOTE: this is a FLUX.1 LoRA (ss_base_model_version flux.1). Forge lists
# it under the name z0ya, but it CANNOT be applied to the SDXL Juggernaut
# checkpoint — it is staged here so the file is present and listed, and
# so a future FLUX setup can use it without re-sourcing.
ghlora_v31() {
  local dest="$COMFY/models/loras/zoya-flux-v31-step1680.safetensors"
  local want=343805400
  local sha="5edabf85c2f97753b2bb6865ba77f829910528334eb8b019eb2ea7051df16e05"
  if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" = "$want" ]; then
    echo "BOOT-V2: skip (present) $dest"; return 0
  fi
  if [ -z "${ZOYA_GH_TOKEN:-}" ]; then
    echo "BOOT-V2: SKIP z0ya LoRA (ZOYA_GH_TOKEN unset in pod env)"
    return 0
  fi
  mkdir -p "$(dirname "$dest")" "$COMFY/models/loras/.lora-parts-v31"
  echo "BOOT-V2: downloading $dest (48 parts)"
  local ok=1 i p
  : > "$dest.part"
  for i in $(seq -w 0 47); do
    p="$COMFY/models/loras/.lora-parts-v31/part-$i"
    if ghfetch "weights/lora-parts-v31/part-$i" "$p"; then
      cat "$p" >> "$dest.part" || { ok=0; break; }
    else
      ok=0; break
    fi
  done
  if [ "$ok" = 1 ] && [ "$(stat -c%s "$dest.part" 2>/dev/null || echo 0)" = "$want" ] \
     && echo "$sha  $dest.part" | sha256sum -c - >/dev/null 2>&1; then
    mv "$dest.part" "$dest"
    echo "BOOT-V2: ok $dest (sha256 verified)"
  else
    rm -f "$dest.part"
    echo "BOOT-V2: FAILED $dest (wanted $want bytes, sha256 $sha)"
  fi
}
dl "https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors" \
   "$COMFY/models/checkpoints/SDXL/sd_xl_base_1.0.safetensors" 7105348188 &
dl "https://civitai.com/api/download/models/2688246?fileId=2575053" \
   "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" 228453476 &
dl "https://civitai.com/api/download/models/2759180?fileId=2645720" \
   "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" 228465468 &
dl "https://civitai.com/api/download/models/2781151?fileId=2667497" \
   "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" 228465468 &
# --- FLUX.1-dev FP8 stack (Kijai FP8 checkpoint; FP8 text encoders) ---
# z0ya was trained on dev, not schnell — dev checkpoint only.
dl "https://huggingface.co/Kijai/flux-fp8/resolve/main/flux1-dev-fp8.safetensors" \
   "$COMFY/models/checkpoints/flux1-dev-fp8.safetensors" 11901525888 &
dl "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
   "$COMFY/models/text_encoders/t5xxl_fp8_e4m3fn.safetensors" 4893934904 &
dl "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
   "$COMFY/models/text_encoders/clip_l.safetensors" 246144152 &
dl "https://huggingface.co/foxmail/flux_vae/resolve/main/ae.safetensors" \
   "$COMFY/models/vae/ae.safetensors" 335304388 &
ghlora_v31 &
wait
ls -la "$COMFY/models/checkpoints/SDXL" "$COMFY/models/loras" 2>/dev/null

# --- clone Forge ---
FORGE=/workspace/webui-forge
if [ ! -d "$FORGE" ]; then
  git clone --depth 1 https://github.com/lllyasviel/stable-diffusion-webui-forge "$FORGE"
fi
cd "$FORGE" || exit 1

# --- wait for the checkpoint + LoRAs (guard; downloads above should have them) ---
CKPT="$COMFY/models/checkpoints/SDXL/sd_xl_base_1.0.safetensors"
for i in $(seq 1 120); do
  [ -f "$CKPT" ] && break
  sleep 15
done
ls -la "$COMFY/models/checkpoints/SDXL" "$COMFY/models/loras/SDXL" "$COMFY/models/loras/DMD2" "$COMFY/models/loras/HyperSD/SDXL" 2>/dev/null

# --- model symlinks: Forge side (real persona names) ---
# Only link files that actually exist; a missing download logs FAILED
# above and surfaces as an absent LoRA instead of a dangling symlink.
mkdir -p models/Stable-diffusion models/Lora models/text_encoder models/VAE
if [ -n "$COMFY" ]; then
  [ -f "$CKPT" ] && ln -sf "$CKPT" models/Stable-diffusion/JuggernautXL-v9.safetensors
  [ -f "$COMFY/models/checkpoints/flux1-dev-fp8.safetensors" ] && ln -sf "$COMFY/models/checkpoints/flux1-dev-fp8.safetensors" models/Stable-diffusion/flux1-dev-fp8.safetensors
  [ -f "$COMFY/models/text_encoders/t5xxl_fp8_e4m3fn.safetensors" ] && ln -sf "$COMFY/models/text_encoders/t5xxl_fp8_e4m3fn.safetensors" models/text_encoder/t5xxl_fp8_e4m3fn.safetensors
  [ -f "$COMFY/models/text_encoders/clip_l.safetensors" ] && ln -sf "$COMFY/models/text_encoders/clip_l.safetensors" models/text_encoder/clip_l.safetensors
  [ -f "$COMFY/models/vae/ae.safetensors" ] && ln -sf "$COMFY/models/vae/ae.safetensors" models/VAE/ae.safetensors
  [ -f "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" ] && ln -sf "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" models/Lora/Orchid.safetensors
  [ -f "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" ] && ln -sf "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" models/Lora/EmmyGirl.safetensors
  [ -f "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" ] && ln -sf "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" models/Lora/MollyGirl.safetensors
  [ -f "$COMFY/models/loras/zoya-flux-v31-step1680.safetensors" ] && ln -sf "$COMFY/models/loras/zoya-flux-v31-step1680.safetensors" models/Lora/z0ya.safetensors
  # --- ComfyUI side friendly names ---
  [ -f "$COMFY/models/loras/SDXL/sd_xl_offset_example-lora_1.0.safetensors" ] && ln -sf "SDXL/sd_xl_offset_example-lora_1.0.safetensors" "$COMFY/models/loras/Orchid.safetensors"
  [ -f "$COMFY/models/loras/DMD2/dmd2_sdxl_4step_lora.safetensors" ] && ln -sf "DMD2/dmd2_sdxl_4step_lora.safetensors" "$COMFY/models/loras/EmmyGirl.safetensors"
  [ -f "$COMFY/models/loras/HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" ] && ln -sf "HyperSD/SDXL/Hyper-SDXL-1step-lora.safetensors" "$COMFY/models/loras/MollyGirl.safetensors"
  [ -f "$COMFY/models/loras/zoya-flux-v31-step1680.safetensors" ] && ln -sf "zoya-flux-v31-step1680.safetensors" "$COMFY/models/loras/z0ya.safetensors"
fi
ls -la models/Stable-diffusion models/Lora

# --- system build deps for sdists that must compile on cp312 ---
# Pillow 9.5.0 (pinned by Forge; blendmodes==2022 caps Pillow<10) has no
# cp312 wheel and its build dies without zlib headers on this image.
if command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive --gpg-auto-import-keys refresh >> /workspace/forge_boot.log 2>&1 || true
  for pkg in zlib-devel libjpeg8-devel libjpeg62-devel libjpeg-turbo-devel gcc python312-devel; do
    zypper --non-interactive install -y "$pkg" >> /workspace/forge_boot.log 2>&1 || true
  done
fi

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
echo "=== boot-v2.sh end $(date) ==="
