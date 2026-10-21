Assistant agent — local LLM (llama.cpp) for Home Assistant voice and chat, with
speech-to-text through the model's audio projector and a Wyoming bridge for HA.

Services:
  llama-cpp       :5050   OpenAI-compatible API (chat, vision, /v1/audio/transcriptions)
  parakeet                Parakeet TDT 1.1B speech-to-text (stt_engine=parakeet, internal only)
  wyoming-openai  :10300  Wyoming STT for Home Assistant

Text-to-speech engine (COMPOSE_FILE, asked at install): omnivoice (default) runs
audio.cpp with OmniVoice f16 on the GPU (~2 GB VRAM; ~0.6 s per short sentence; split
into <=8 s pieces, longer pieces lose quality), or paradee: Paradee 1.1 on one CPU core
(~50x real time, one English voice). Either way Wyoming streams sentence by sentence.
The voice is OMNIVOICE_VOICE (OmniVoice's fixed vocabulary, e.g. "female, young
adult"; unknown words are rejected).

Speech-to-text engine (COMPOSE_FILE, asked at install): parakeet (default) runs
parakeet.cpp's server (built from its CUDA 12 release; ~95 ms for a voice command,
~2.4 GB VRAM in f16), or gemma, which uses the LLM's audio projector (~370 ms, no
extra VRAM). Switch by changing COMPOSE_FILE in .env and restarting.

Defaults (chosen by benchmark on a 16 GB card): Gemma 4 12B QAT UD-Q4_K_XL with its
MTP draft head (Q4_0, draft length 2: ~45 tok/s vs ~27 without), 64k context,
q8_0 KV cache, one request at a time, thinking off. Uses ~9 GB of VRAM.

Before deployment:
  .env — model, draft head, models folder (MODELS_DIR), image tag
  Needs an NVIDIA GPU with the NVIDIA container toolkit (docker run --gpus all works).
  The default image is the CUDA 12 build; server-cuda13 needs driver 580+.

Home Assistant: Wyoming integration → host:10300 (STT); an OpenAI-compatible
conversation integration → http://host:5050/v1, model = MODEL_ALIAS.
