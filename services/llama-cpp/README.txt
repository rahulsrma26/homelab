llama.cpp inference server with CUDA 13 support.

Services:
  llama-cpp  :8080  OpenAI-compatible HTTP API (profile: server)
  llama-run          One-shot CLI inference       (profile: run)

Before deployment:
  .env — set MODEL_FILE (and optionally MODELS_DIR)

--- Server mode ---

  docker compose --profile server up -d

  API endpoints:
    GET  /health
    POST /completion
    POST /v1/chat/completions   (OpenAI-compatible)

  Test:
    curl http://localhost:8080/health

--- One-shot inference ---

  docker compose --profile run run --rm llama-run \
    --run -m /models/model.gguf \
    -p "Building a website can be done in 10 simple steps:" \
    -n 512 --n-gpu-layers 99

--- Tuning ---

  GPU_LAYERS   — layers offloaded to GPU (99 = all, reduce if VRAM runs out)
  CONTEXT_SIZE — token context window
  PARALLEL     — concurrent request slots (server mode, each uses ~context_size VRAM)
