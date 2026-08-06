// Forwards pi's `agent_end` event to the shared agent-notification seam
// ($PI_AGENT_NOTIFY_SCRIPT, set by the HM module — shared/agent-notify.nix
// wrapping shared/scripts/agent-notify.sh). That script POSTs the event to
// rpi5's :8088 aggregator, which owns the bot token and the debouncing; nothing
// here talks to Telegram.
//
// pi only dispatches lifecycle events to extensions in interactive REPL
// mode; `pi -p` one-shot mode loads extensions but never fires them.

import { spawn } from "node:child_process";

export default function (pi: any) {
  const script = process.env.PI_AGENT_NOTIFY_SCRIPT;
  if (!script) return;
  const cwd = process.cwd();

  pi.on?.("agent_end", () => {
    const child = spawn(script, { stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", () => {});
    child.stdin.end(JSON.stringify({ cwd }));
  });
}
