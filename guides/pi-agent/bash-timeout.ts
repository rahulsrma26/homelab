// Pi extension: a time limit for every bash tool call. Pi's bash tool has none unless the model sets one, so a
// command that never ends (a server, a script waiting on stdin, an endless loop) blocks the agent for good.
// Calls without a timeout get PI_BASH_TIMEOUT seconds (default 300); longer ones are cut down to it.
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";

const LIMIT_SECONDS = Number(process.env.PI_BASH_TIMEOUT ?? 300);

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (isToolCallEventType("bash", event)) {
      const asked = event.input.timeout;
      if (!asked || asked > LIMIT_SECONDS) event.input.timeout = LIMIT_SECONDS;
    }
  });
}
