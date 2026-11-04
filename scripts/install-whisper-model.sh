#!/bin/bash
set -euo pipefail
model_dir="$HOME/Library/Application Support/OpenMacLive/models"
model="$model_dir/ggml-large-v3-turbo-q5_0.bin"
checksum="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
mkdir -p "$model_dir"
if [ -f "$model" ] && printf '%s  %s\n' "$checksum" "$model" | shasum -a 256 -c - >/dev/null 2>&1; then
  printf 'Whisper Turbo Q5_0 模型已安装。\n'
  exit 0
fi
curl --fail --location --retry 3 --continue-at - \
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' \
  --output "$model.partial"
printf '%s  %s\n' "$checksum" "$model.partial" | shasum -a 256 -c -
mv "$model.partial" "$model"
printf '已安装 Whisper large-v3-turbo Q5_0（约 574MB）。OpenMac 下次识别自动使用本地模型。\n'
