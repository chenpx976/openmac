#!/bin/bash
set -euo pipefail
model_dir="$HOME/Library/Application Support/OpenMacLive/models"
mkdir -p "$model_dir"

install_model() {
  local name="$1" checksum="$2" url="$3"
  local model="$model_dir/$name"
  if [ -f "$model" ] && printf '%s  %s\n' "$checksum" "$model" | shasum -a 256 -c - >/dev/null 2>&1; then
    printf '%s 已安装并通过校验。\n' "$name"
    return
  fi
  curl --fail --location --retry 3 --continue-at - "$url" --output "$model.partial"
  printf '%s  %s\n' "$checksum" "$model.partial" | shasum -a 256 -c -
  mv "$model.partial" "$model"
}

install_model 'ggml-large-v3-turbo-q5_0.bin' \
  '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2' \
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin'
install_model 'ggml-silero-v6.2.0.bin' \
  '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987' \
  'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin'
printf 'Turbo Q5_0（约 574MB）和语音检测模型（约 885KB）已就绪。\n'
