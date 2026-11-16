# Pi coding agent with the local LLM

[Pi](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) is a terminal coding agent (read, write, edit and bash tools) that works with any OpenAI-compatible server. This guide points it at the [`capy-flash`](../../services/capy-flash/) service (Qwen3.8-27B on two GPUs) and sets it up for **several agents at once**: the server shares one 262k-token context pool and 3 request slots among all of them.

## Install

Node.js 20 or newer, on Linux or macOS:

```bash
# Linux (Debian/Ubuntu): Node from the distribution, or from nodesource for a newer one
sudo apt install nodejs npm
# macOS
brew install node

npm install -g @mariozechner/pi-coding-agent
pi --version
```

## The API key

The service's key is in its `.env` (`API_KEY`). Keep it in your password manager and give it to Pi as an environment variable, not in a file Pi reads:

```bash
# Linux and macOS: read it without echo (not into the shell history)
read -rs CAPY_API_KEY && export CAPY_API_KEY
```

For a permanent setup, put the export in a file only you can read (`chmod 600`) and source it from `~/.bashrc` / `~/.zshrc`, or use Pi's `"!command"` form below with your password manager's CLI.

## The model: `~/.pi/agent/models.json`

```json
{
  "providers": {
    "capy": {
      "baseUrl": "http://<llm-host>:8123/v1",
      "api": "openai-completions",
      "apiKey": "CAPY_API_KEY",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": true },
      "models": [
        {
          "id": "qwen3.8-27b",
          "name": "Qwen3.8 27B (local)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 81920,
          "maxTokens": 32768
        }
      ]
    }
  }
}
```

| Field | Why |
|---|---|
| `apiKey: "CAPY_API_KEY"` | the name of the environment variable holding the key (Pi resolves it); `"!<command>"` runs a command instead, e.g. your password manager's CLI |
| `supportsReasoningEffort: true` | Pi then sends the thinking level as `reasoning_effort`. Without it the server's chat template falls back to its own default, **xhigh**, which thinks much longer for little gain |
| `reasoning: true`, `input: [text, image]` | the model thinks, and the service has vision on: pasted screenshots work |
| `contextWindow: 81920` | **80k per agent**, not the model's 262k: three agents then fit the server's shared pool together. Pi compacts the conversation before it gets there |
| `maxTokens: 32768` | must stay **above the server's thinking budget** (16k, `THINKING_BUDGET`): when thinking hits the budget, the answer still needs room; with the two equal, a long think ends the reply before any code is written |

## The defaults: `~/.pi/agent/settings.json`

```json
{
  "defaultProvider": "capy",
  "defaultModel": "qwen3.8-27b",
  "defaultThinkingLevel": "medium",
  "compaction": { "enabled": true, "reserveTokens": 16384, "keepRecentTokens": 20000 }
}
```

- **`medium`** is the measured sweet spot for coding: `low` is fine for quick edits, `high`/`xhigh` take much longer for rare gains (change it in Pi per session).
- **Compaction** starts at `contextWindow - reserveTokens` (about 65k): Pi summarises the older turns and keeps the last ~20k. That keeps every agent well inside its 80k.

## A time limit for shell commands

Pi's bash tool runs a command for as long as it takes unless the model sets a timeout. An agent that starts a server, a script waiting for input or an endless loop then blocks for good. [`bash-timeout.ts`](bash-timeout.ts) gives every call a limit (default 300 s; the model may ask for less, never more):

```bash
mkdir -p ~/.pi/agent/extensions
curl -fsSL -o ~/.pi/agent/extensions/bash-timeout.ts \
  https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/guides/pi-agent/bash-timeout.ts
# a different limit:  export PI_BASH_TIMEOUT=600
```

Pi loads everything in `~/.pi/agent/extensions/` at start (`/reload` in a running session).

## Using it

```bash
cd <project> && pi                      # interactive
pi -p "Fix the failing test in tests/test_parser.py"     # one task, then exit
```

**Several agents:** run one Pi per terminal (or tmux pane). Up to three answer at the same time; a fourth waits for a free slot. Each keeps its own conversation in the server's cache, so its next turn starts in well under a second even at 60k+ tokens of context.

**Long single files:** a prompt the server hasn't seen before (e.g. pasting 100k tokens) is processed at roughly 2,000 tokens/s and makes the other agents wait while it runs; prefer letting the agent read files with its tools.

## Checks

```bash
curl -s http://<llm-host>:8123/health                                  # {"status":"ok"}
curl -s http://<llm-host>:8123/v1/models -H "Authorization: Bearer $CAPY_API_KEY"
pi -p "Say hello"                                                      # one short answer
```

| Symptom | Cause |
|---|---|
| `401` | wrong or missing key (`echo ${#CAPY_API_KEY}` should print 64) |
| very long thinking, slow answers | `supportsReasoningEffort` missing: the template's xhigh default is used |
| a reply that stops before the answer | `maxTokens` not above the server's thinking budget |
| an agent that never finishes a command | the timeout extension isn't loaded (`ls ~/.pi/agent/extensions`) |
