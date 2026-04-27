// Forwards pi's `agent_end` event to the shared bash notify script
// ($PI_TELEGRAM_NOTIFY_SCRIPT, set by the HM module). The bash script
// handles token resolution, 60s coalescing window, and Telegram I/O.
//
// pi only dispatches lifecycle events to extensions in interactive REPL
// mode; `pi -p` one-shot mode loads extensions but never fires them.

import { spawn } from "node:child_process";

export default function (pi: any) {
  const script = process.env.PI_TELEGRAM_NOTIFY_SCRIPT;
  if (!script) return;
  const cwd = process.cwd();

  pi.on?.("agent_end", () => {
    const child = spawn(script, { stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", () => {});
    child.stdin.end(JSON.stringify({ cwd }));
  });
}
