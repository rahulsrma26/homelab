Assistant agent — local LLM (llama.cpp) for Home Assistant voice and chat, with
speech-to-text through the model's audio projector and a Wyoming bridge for HA.

Services:
  llama-cpp       :5050   OpenAI-compatible API (chat, vision, /v1/audio/transcriptions)
  wyoming-openai  :10300  Wyoming for Home Assistant: STT by the LLM, and TTS
  parakeet                Parakeet TDT speech-to-text (stt_engine=parakeet*, internal)
  wyoming-parakeet :10301 Wyoming STT by Parakeet (stt_engine=parakeet*)
  embeddings      :5051   OpenAI-compatible /v1/embeddings, EmbeddingGemma 2 (embeddings=embeddinggemma-2)
  reranker        :5052   /v1/rerank (Jina-style), Qwen3-Reranker 0.6B (reranker=qwen3-reranker)

Text-to-speech engine (COMPOSE_FILE, asked at install): paradee runs Paradee 1.1 on
two CPU cores (~74x real time, ~40 ms per short reply, one English voice, no VRAM);
omnivoice runs audio.cpp with OmniVoice f16 on the GPU (most natural, voice design,
600+ languages; ~2 GB VRAM, ~0.6 s per short sentence; split into <=8 s pieces, as
longer pieces lose quality). Either way Wyoming streams sentence by sentence.
The voice is OMNIVOICE_VOICE (OmniVoice's fixed vocabulary, e.g. "female, young
adult"; unknown words are rejected).

Speech-to-text: the LLM's audio projector is always there, on port 10300 (no extra
VRAM; a voice command takes ~0.3 s with gemma-e4b, ~0.6 s with gemma-12b). A second engine (stt_engine, asked at install)
gets its own Wyoming server on 10301, and Home Assistant picks one per pipeline:
parakeet runs Parakeet TDT 1.1B in parakeet.cpp's server on the GPU (built from its
CUDA 12 release; ~100 ms, ~2.4 GB VRAM in f16); parakeet-cpu runs Parakeet TDT 0.6B v3
(q8_0, 4 threads) on the CPU (~370 ms, no VRAM, 25 European languages); parakeet-igpu
runs the same model on an Intel or AMD iGPU through Vulkan (~250 ms, same transcripts,
needs /dev/dri on the host; an iGPU used by other containers is shared); none adds
nothing. Switch by changing COMPOSE_FILE in .env and restarting.

Chat model (COMPOSE_FILE, asked at install; both with their MTP draft head, draft
length 2, 64k context, q8_0 KV cache, two requests at a time (PARALLEL, 32k each), thinking off; chosen by
benchmark on a 16 GB card): gemma-12b runs Gemma 4 12B QAT UD-Q4_K_XL (~9 GB VRAM,
~45 tok/s, best quality and tool calls); gemma-e4b runs Gemma 4 E4B Q4_K_M for smaller
cards (~6 GB VRAM, ~75 tok/s, a few points lower on tests, and it sometimes asks a
question back instead of calling a Home Assistant tool). With a small card, pair
gemma-e4b with parakeet-cpu (or parakeet-igpu) and paradee: no other VRAM is needed. A smaller
CONTEXT_SIZE lowers the VRAM further.

Before deployment:
  .env — models folder (MODELS_DIR), image tag, context size
  Needs an NVIDIA GPU with the NVIDIA container toolkit (docker run --gpus all works).
  The default image is the CUDA 12 build; server-cuda13 needs driver 580+.

Home Assistant: Wyoming integration → host:10300 (STT by the LLM, TTS), and with a
parakeet engine another one → host:10301 (STT); an OpenAI-compatible
conversation integration → http://host:5050/v1, model = gemma-4-12b-it or
gemma-4-e4b-it (the server answers with its one model whatever the name).

Embeddings (COMPOSE_FILE, asked at install; optional): embeddinggemma-2 runs EmbeddingGemma 2
(Q8_0, 310 MB, with its Q8_0 projector, 555 MB: text, images, video and audio in one 768d space)
on its own llama.cpp server on port 5051, ~1 GB VRAM. For semantic search: Frigate 0.18
(genai provider llamacpp, role embeddings, semantic_search.model set to it), Paperless and n8n
(OpenAI-compatible). Text works best with the model's prefixes (task: search result | query: ...
for questions, title: ... | text: ... for documents); images need none. none adds nothing.
Images over llama.cpp's own /embeddings: the prompt is the server's media marker (GET /props:
media_marker) with the image in multimodal_data. Tested: a query matches its document at 0.81
(unrelated ones ~0.5), an image matches its description at ~0.78 (others ~0.59).

Reranker (COMPOSE_FILE, asked at install; optional): qwen3-reranker runs Qwen3-Reranker 0.6B
(Q8_0, ~640 MB) on its own llama.cpp server on port 5052, ~1.4 GB VRAM (4096 tokens per
query + document, KV cache q8_0: the context is most of the memory; 16384 at f16 takes ~3 GB). POST /v1/rerank with
{"query": ..., "documents": [...], "top_n": N} returns each document's index and relevance_score
(0..1), best first. That is Jina's format: LibreChat's web search uses it as rerankerType jina
with jinaApiUrl http://host:5052/v1/rerank and any non-empty jinaApiKey (the server checks none;
without a key LibreChat skips reranking); n8n and others call it the same way. Compared with
bge-reranker-v2-m3 (CPU, same build): both rank the relevant documents first; Qwen3's scores
separate them more clearly (0.99 and 0.91 vs 0.0001 for an unrelated one). none adds nothing.
