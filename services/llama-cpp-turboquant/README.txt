llama-cpp-turboquant — custom build of llama.cpp with turbo quant KV cache support.

Source: https://github.com/TheTom/llama-cpp-turboquant
Base:   nvidia/cuda:13.3.0-cudnn-devel-ubuntu24.04

Services:
  llama-cpp-turboquant  :8123  OpenAI-compatible HTTP API (host port 8123 → container 8080)

Build notes:
  - Single-stage devel image (includes nvcc + headers needed to compile)
  - libcuda.so stub symlinked before build to satisfy linker (real driver injected at runtime)
  - CUDA_ARCHITECTURES not set — auto-detected at build time
  - Build takes ~5 min on first run

Build and start:
  docker compose up -d --build

Rebuild after upstream changes:
  docker compose build --no-cache && docker compose up -d

Test:
  curl http://localhost:8123/health
  curl http://localhost:8123/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3.6-28b-reap","messages":[{"role":"user","content":"Hello"}]}'

API endpoints:
  GET  /health
  POST /v1/chat/completions   (OpenAI-compatible)
  POST /completion

Model:
  Downloaded from HF on first start via -hf flag, cached to /models (LLAMA_CACHE)
  Current model: barozp/Qwen3.6-28B-REAP20-A3B-GGUF:Q4_K_M
  Alias: qwen3.6-28b-reap

Key params (optimized for 16GB VRAM GPU):
  --n-cpu-moe 6     MoE expert layers on CPU (tune based on VRAM)
  -ctk turbo4       KV cache key quant (turboquant-specific)
  -ctv turbo2       KV cache value quant (turboquant-specific)
  --cache-reuse 256 KV cache reuse across requests
  --threads 8       CPU threads for MoE layers
