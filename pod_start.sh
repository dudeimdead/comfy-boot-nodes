#!/bin/bash
# Pod entrypoint (via dockerArgs): boot ComfyUI with the image's own
# entrypoint in the background, run the Forge bootstrap, then stay alive.
( bash /runner-scripts/entrypoint.sh > /workspace/comfy_boot.log 2>&1 & )
sleep 2
curl -fsSL https://raw.githubusercontent.com/dudeimdead/comfy-boot-nodes/main/boot.sh?v=$(date +%s) -o /tmp/forge_boot.sh \
  && bash /tmp/forge_boot.sh
sleep infinity
