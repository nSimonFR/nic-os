// Mirrors home/claude.nix's Telegram notify hook for pi-coding-agent.
//
// agent_end is the closest pi event to Claude Code's Notification hook.
// Note: pi only dispatches lifecycle events to extensions in interactive
// REPL mode; `pi -p` one-shot mode loads extensions but never fires them.

import { existsSync, mkdirSync, readFileSync, rmdirSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

const STATE_DIR = "/tmp/pi-notify-state";
const STATE_FILE = `${STATE_DIR}/state`;
const LOCK_DIR = `${STATE_DIR}/lock`;
const WINDOW_SECONDS = 60;
const HEADER = "🤖 *Pi Coding Agent*";

// Bot token may live at three places depending on host:
//  - $PI_TELEGRAM_BOT_TOKEN_FILE  (HM module sets this when known at eval time)
//  - $XDG_RUNTIME_DIR/agenix/telegram-bot-token  (HM-context agenix on every host)
//  - /run/agenix/telegram-bot-token  (system-context agenix, only rpi5)
function tokenCandidatePaths(): string[] {
  const xdg = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? ""}`;
  return [
    process.env.PI_TELEGRAM_BOT_TOKEN_FILE,
    `${xdg}/agenix/telegram-bot-token`,
    "/run/agenix/telegram-bot-token",
  ].filter((p): p is string => typeof p === "string" && p.length > 0);
}

function readBotToken(): string | null {
  for (const path of tokenCandidatePaths()) {
    try {
      const tok = readFileSync(path, "utf8").trim();
      if (tok) return tok;
    } catch {}
  }
  return null;
}

async function acquireLock(): Promise<boolean> {
  for (let i = 0; i < 40; i++) {
    try {
      mkdirSync(LOCK_DIR);
      return true;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return false;
}

function releaseLock() {
  try {
    rmdirSync(LOCK_DIR);
  } catch {}
}

// Stale-lock cleanup on process exit (process death between mkdir and rmdir
// would otherwise orphan the lock dir for ~4s on every subsequent run).
let lockReleaseRegistered = false;
function ensureLockReleaseOnExit() {
  if (lockReleaseRegistered) return;
  lockReleaseRegistered = true;
  for (const sig of ["exit", "SIGINT", "SIGTERM", "SIGHUP"] as const) {
    process.on(sig, releaseLock);
  }
}

async function tg(method: string, token: string, params: Record<string, string>): Promise<any> {
  const body = new URLSearchParams(params).toString();
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  return res.json().catch(() => ({}));
}

async function sendNotification(line: string) {
  const chatId = process.env.PI_TELEGRAM_CHAT_ID ?? "";
  if (!chatId) return;
  const token = readBotToken();
  if (!token) return;

  mkdirSync(STATE_DIR, { recursive: true });
  ensureLockReleaseOnExit();
  if (!(await acquireLock())) return;

  try {
    const now = Math.floor(Date.now() / 1000);
    let msgId = "";
    let lastTs = 0;
    let prevLines: string[] = [];

    if (existsSync(STATE_FILE)) {
      const parts = readFileSync(STATE_FILE, "utf8").split("\n");
      msgId = parts[0] ?? "";
      lastTs = Number(parts[1] ?? "0");
      prevLines = parts.slice(2).filter((l) => l.length > 0);
    }

    if (msgId && now - lastTs < WINDOW_SECONDS) {
      const text = [HEADER, ...prevLines, line].join("\n");
      await tg("editMessageText", token, {
        chat_id: chatId,
        message_id: msgId,
        text,
        parse_mode: "Markdown",
      });
      writeFileSync(STATE_FILE, [msgId, String(now), ...prevLines, line].join("\n"));
    } else {
      const text = [HEADER, line].join("\n");
      const resp = await tg("sendMessage", token, {
        chat_id: chatId,
        text,
        parse_mode: "Markdown",
      });
      const newId = resp?.result?.message_id;
      if (newId) {
        writeFileSync(STATE_FILE, [String(newId), String(now), line].join("\n"));
      }
    }
  } finally {
    releaseLock();
  }
}

export default function (pi: any) {
  const cwd = process.cwd();
  pi.on?.("agent_end", async () => {
    try {
      await sendNotification(`📁 ${cwd ? basename(cwd) : "?"}: waiting for input`);
    } catch {
      // Never let notify failures break the agent.
    }
  });
}
