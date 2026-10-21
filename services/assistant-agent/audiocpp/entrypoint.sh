#!/bin/sh
# Fetch the model on first start, write the server config from the environment, start the server.
set -e
mkdir -p /models/audiocpp
model="/models/audiocpp/$(basename "$TTS_MODEL_URL")"
[ -s "$model" ] || { echo "downloading $TTS_MODEL_URL"; curl -fL --retry 3 -o "$model.part" "$TTS_MODEL_URL" && mv "$model.part" "$model"; }
cat > /tmp/server.json <<JSON
{"host": "0.0.0.0", "port": 8080, "backend": "${TTS_BACKEND:-cuda}", "device": 0, "threads": ${TTS_THREADS:-4},
 "lazy_load": false, "max_loaded_models": 1, "ui": false, "ui_management": false,
 "models": [{"id": "${TTS_MODEL_ID}", "family": "${TTS_FAMILY}", "path": "$model", "task": "tts", "mode": "offline"}]}
JSON
exec /opt/audiocpp/audiocpp_server --config /tmp/server.json
