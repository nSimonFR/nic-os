#!/usr/bin/env python3
"""Poll the Proton 'Papra' folder (via the local hydroxide IMAP bridge) and drop
document attachments into Papra's ingestion drop-zone. Papra then ingests them and
the on-prem papra-tag sweeper tags them.

Processed messages are tracked by Message-ID in a state file, so the mailbox is
never mutated (your read/unread state is untouched) and nothing is reprocessed.
Only document-like attachments (PDF, images) are taken — calendar invites (.ics),
signatures and other cruft are skipped. Papra also dedups by content hash, so a
re-filed attachment is harmless.

Config via env:
  PROTON_USER          default nsimon@protonmail.com
  PROTON_PASS_FILE     default /run/agenix/protonmail-bridge-password
  PROTON_MAILBOX       default All Mail
  PROTON_LABEL         default papra
  PAPRA_PROTON_DEST    required: /mnt/data/papra/ingestion/<orgId>
  PAPRA_PROTON_STATE_DIR default /var/lib/papra-proton-poll
"""

import email
import grp
import imaplib
import os
import pwd
import re
import sys
from dataclasses import dataclass

from ..secrets import env_int, env_str, read_secret

HOST = "127.0.0.1"
PORT = 1143

DEFAULT_USER = "nsimon@protonmail.com"
DEFAULT_PASS_FILE = "/run/agenix/protonmail-bridge-password"
DEFAULT_MAILBOX = "All Mail"
DEFAULT_LABEL = "papra"
DEFAULT_STATE_DIR = "/var/lib/papra-proton-poll"

DOC_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp", ".heic", ".heif", ".gif"}
DOC_CT = {"application/pdf"}
MIN_IMG_BYTES = 30000  # skip decorative email images (footer/social icons are <2KB)


@dataclass(frozen=True)
class Config:
    dest: str = ""
    user: str = DEFAULT_USER
    pass_file: str = DEFAULT_PASS_FILE
    mailbox: str = DEFAULT_MAILBOX
    # Proton *label* to match. Hydroxide surfaces Proton labels as lowercase IMAP
    # keywords (NOT as folders), so we select the mailbox and SEARCH KEYWORD <label>.
    # The label is additive → mail stays in the Inbox; we never mutate it.
    label: str = DEFAULT_LABEL
    state_dir: str = DEFAULT_STATE_DIR
    host: str = HOST
    port: int = PORT

    @classmethod
    def from_env(cls, env=None):
        return cls(
            # Was `os.environ["PAPRA_PROTON_DEST"]` at module level — a KeyError on
            # import, which is why this file could not even be loaded off-host.
            dest=env_str("PAPRA_PROTON_DEST", "", env),
            user=env_str("PROTON_USER", DEFAULT_USER, env),
            pass_file=env_str("PROTON_PASS_FILE", DEFAULT_PASS_FILE, env),
            mailbox=env_str("PROTON_MAILBOX", DEFAULT_MAILBOX, env),
            label=env_str("PROTON_LABEL", DEFAULT_LABEL, env),
            state_dir=env_str("PAPRA_PROTON_STATE_DIR", DEFAULT_STATE_DIR, env),
            port=env_int("PROTON_IMAP_PORT", PORT, env),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "seen")


def is_doc(ct, fn, disp, size):
    ct = (ct or "").lower()
    ext = os.path.splitext((fn or "").lower())[1]
    is_attach = bool(disp and "attachment" in disp.lower())
    if ext == ".ics" or ct == "text/calendar":
        return False
    # PDFs are essentially always real documents.
    if ct in DOC_CT or ext == ".pdf":
        return True
    # Images: only real attachments above a size floor — this drops the logo /
    # social / footer icons that marketing emails attach inline.
    if ct.startswith("image/") or ext in DOC_EXT:
        return is_attach and size >= MIN_IMG_BYTES
    return False


def safe(fn):
    """Filename for the drop-zone. Basename + a strict allowlist, because this name
    comes from an email attachment header — i.e. from anyone who can mail you."""
    fn = os.path.basename((fn or "attachment"))
    return re.sub(r"[^A-Za-z0-9._ -]", "_", fn) or "attachment"


def unique_dest(dest, exists=os.path.exists):
    """`name.pdf` -> `name-1.pdf` -> `name-2.pdf` … so a re-filed attachment never
    overwrites the earlier one (Papra dedups by content hash afterwards)."""
    base, ext = os.path.splitext(dest)
    i = 1
    while exists(dest):
        dest = f"{base}-{i}{ext}"
        i += 1
    return dest


def chown_papra(path):
    try:
        os.chown(path, pwd.getpwnam("papra").pw_uid, grp.getgrnam("papra").gr_gid)
    except Exception:  # noqa: BLE001 - best effort; papra's own umask handles the rest
        pass


def load_seen(path):
    try:
        with open(path) as fh:
            return {line.strip() for line in fh if line.strip()}
    except FileNotFoundError:
        return set()


def attachments(msg):
    """-> [(content_type, filename, disposition, payload)] for the doc-like parts."""
    out = []
    for part in msg.walk():
        ct = part.get_content_type()
        fn = part.get_filename()
        disp = part.get("Content-Disposition")
        if not (fn or (disp and "attachment" in disp.lower())):
            continue
        payload = part.get_payload(decode=True)
        if not payload:
            continue
        if not is_doc(ct, fn, disp, len(payload)):
            continue
        out.append((ct, fn, disp, payload))
    return out


def save_attachment(cfg, payload, filename, chown=chown_papra):
    """Write one attachment into the drop-zone via a `.incoming` rename, so Papra's
    inotify watcher never sees a partially-written file."""
    dest = unique_dest(os.path.join(cfg.dest, safe(filename)))
    tmp = dest + ".incoming"
    with open(tmp, "wb") as fh:
        fh.write(payload)
    chown(tmp)
    os.replace(tmp, dest)
    chown(dest)
    return dest


def poll(cfg, imap, log=print, chown=chown_papra):
    """Fetch labelled mail and drop its attachments. -> (saved, newly_seen).

    `imap` is the seam: an imaplib.IMAP4 in production, a fake in tests.
    """
    seen = load_seen(cfg.state_file)
    # Quote mailbox names containing spaces (e.g. "All Mail") for IMAP.
    mbox = f'"{cfg.mailbox}"' if " " in cfg.mailbox else cfg.mailbox
    typ, _ = imap.select(mbox, readonly=True)
    if typ != "OK":
        raise RuntimeError(f"cannot select mailbox {cfg.mailbox!r}")

    # Match messages carrying the Proton label (hydroxide exposes it as a keyword).
    if cfg.label:
        typ, ids = imap.search(None, "KEYWORD", cfg.label)
    else:
        typ, ids = imap.search(None, "ALL")

    saved, newseen = 0, []
    for num in ids[0].split():
        typ, d = imap.fetch(num, "(RFC822)")
        msg = email.message_from_bytes(d[0][1])
        mid = (msg.get("Message-ID") or "").strip()
        if mid and mid in seen:
            continue
        for ct, fn, _disp, payload in attachments(msg):
            dest = save_attachment(cfg, payload, fn, chown=chown)
            log(f"saved: {os.path.basename(dest)} ({ct}, {len(payload)}B) "
                f"from {msg.get('From')}")
            saved += 1
        if mid:
            # Recorded even with 0 doc attachments, to avoid re-scanning.
            newseen.append(mid)
    return saved, newseen


def main(env=None, imap=None):
    cfg = Config.from_env(env)
    if not cfg.dest:
        print("error: PAPRA_PROTON_DEST is not set", file=sys.stderr)
        return 1
    os.makedirs(cfg.state_dir, exist_ok=True)
    os.makedirs(cfg.dest, exist_ok=True)

    if imap is None:
        imap = imaplib.IMAP4(cfg.host, cfg.port)
        imap.login(cfg.user, read_secret(cfg.pass_file))
    try:
        saved, newseen = poll(cfg, imap)
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if newseen:
        with open(cfg.state_file, "a") as fh:
            for mid in newseen:
                fh.write(mid + "\n")
    imap.logout()
    print(f"done: {saved} attachment(s) queued for Papra from '{cfg.mailbox}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
