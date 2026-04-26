// Telegram notify extension for pi-coding-agent.
//
// Mirrors the Claude Code Notification hook (home/claude.nix:11-90):
//   - fires when pi finishes a turn / is waiting for next user input
//   - aggregates notifications within a 60s window into a single edited message
//   - reads bot token from a file, chat id from env (both injected via HM)
//
// Pi loads this via ~/.pi/agent/extensions/telegram-notify/index.ts (TS only,
// .js files are not auto-discovered per docs/extensions.md).

import { existsSync, mkdirSync, readFileSync, writeFileSync, rmdirSync } from "node:fs";
import { basename } from "node:path";

const BOT_TOKEN_FILE =
  process.env.PI_TELEGRAM_BOT_TOKEN_FILE ?? "/run/agenix/telegram-bot-token";
const CHAT_ID = process.env.PI_TELEGRAM_CHAT_ID ?? "";
const STATE_DIR = "/tmp/pi-notify-state";
const STATE_FILE = `${STATE_DIR}/state`;
const LOCK_DIR = `${STATE_DIR}/lock`;
const WINDOW_SECONDS = 60;

const HEADER = "🤖 *Pi Coding Agent*";

function readBotToken(): string | null {
  try {
    const tok = readFileSync(BOT_TOKEN_FILE, "utf8").trim();
    return tok || null;
  } catch {
    return null;
  }
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

async function tg(
  method: string,
  token: string,
  params: Record<string, string>,
): Promise<any> {
  const body = new URLSearchParams(params).toString();
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  return res.json().catch(() => ({}));
}

async function sendNotification(line: string) {
  if (!CHAT_ID) return;
  const token = readBotToken();
  if (!token) return;

  mkdirSync(STATE_DIR, { recursive: true });
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

    const elapsed = now - lastTs;

    if (msgId && elapsed < WINDOW_SECONDS) {
      const text = [HEADER, ...prevLines, line].join("\n");
      await tg("editMessageText", token, {
        chat_id: CHAT_ID,
        message_id: msgId,
        text,
        parse_mode: "Markdown",
      });
      writeFileSync(
        STATE_FILE,
        [msgId, String(now), ...prevLines, line].join("\n"),
      );
    } else {
      const text = [HEADER, line].join("\n");
      const resp = await tg("sendMessage", token, {
        chat_id: CHAT_ID,
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

function projectFromCwd(cwd: string | undefined): string {
  return cwd ? basename(cwd) : "?";
}

export default function (pi: any) {
  const cwd = process.cwd();

  // Pi has no dedicated "waiting for input" event; agent_end fires when the
  // model finishes generating, which is the closest analogue to Claude Code's
  // Notification hook (see docs/extensions.md).
  pi.on?.("agent_end", async () => {
    try {
      await sendNotification(`📁 ${projectFromCwd(cwd)}: waiting for input`);
    } catch {
      // Never let notify failures break the agent.
    }
  });
}
