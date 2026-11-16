capy-flash: a CUDA inference server for Qwen3.8-27B (NVFP4) on two RTX 50-series 16 GB cards (tensor parallel),
with vision, MTP speculative decoding, a context cache across turns and an OpenAI- and Anthropic-compatible API.
Upstream: https://github.com/ValerioDolci/capy-flash (Apache-2.0). Model: Feyd89's QUASAR QAT NVFP4 artifact.

Containers:
  capy-flash-model  one-shot: downloads the model (~17 GB) into MODELS_DIR/capy-flash and checks its SHA-256
  capy-flash        :8123  /v1/chat/completions, /v1/responses, /v1/messages (Anthropic); /health without a key

Needs: two sm_120 GPUs with 16 GB (RTX 5060 Ti / 5070 Ti / 5080), NVIDIA driver 580+ and the container toolkit,
about 22 GB of free RAM (16 GiB of it pinned for the context cache: HOST_KV_MIB), and disk for the model (~17 GB)
and the disk cache (DISK_CACHE_GIB).

Before deployment:
  .env — PORT, API_KEY (generated), MAX_CONCURRENCY (requests at once), MODELS_DIR, CACHE_DIR
  MODELS_DIR/capy-flash and CACHE_DIR must be writable by UID 1000 (the container's user).

Clients:
  base URL http://<host>:8123/v1, the key as Bearer token (OpenAI) or x-api-key (Anthropic: http://<host>:8123)
  Thinking is on; requests should send reasoning_effort "medium" (without it the chat template uses xhigh) and an
  output limit above THINKING_BUDGET, or a capped answer has no room left. Sampling defaults come from the server.

Tuning (2x RTX 5060 Ti, measured): DRAFT_TOKENS=4 with --lm-head-draft and --embedding-host is about 20 % faster
than the release profile (~134 / 121 / 113 tok/s per request at 1 / 2 / 3 at once); DEVICE_STATE_SLOTS=16 keeps
growing agent conversations in the cache (the profile's 4 made them recompute). Three conversations together must
fit KV_CAPACITY tokens, so cap each client's context (e.g. 80k for 3 agents).

Updating capy-flash: set CAPY_VERSION and CAPY_SHA256 (the release's .sha256 file) in the Dockerfile, then
  labber capy-flash rebuild
Releases are frequent; read the release notes first, and keep the version pinned.
