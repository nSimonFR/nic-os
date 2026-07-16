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
  PROTON_MAILBOX       default Papra
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

HOST = "127.0.0.1"
PORT = 1143
USER = os.environ.get("PROTON_USER", "nsimon@protonmail.com")
PASS_FILE = os.environ.get("PROTON_PASS_FILE", "/run/agenix/protonmail-bridge-password")
MAILBOX = os.environ.get("PROTON_MAILBOX", "Papra")
DEST = os.environ["PAPRA_PROTON_DEST"]
STATE_DIR = os.environ.get("PAPRA_PROTON_STATE_DIR", "/var/lib/papra-proton-poll")
STATE = os.path.join(STATE_DIR, "seen")

DOC_EXT = {".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp", ".heic", ".heif", ".gif"}
DOC_CT = {"application/pdf"}


def is_doc(ct, fn):
    ct = (ct or "").lower()
    ext = os.path.splitext((fn or "").lower())[1]
    if ext == ".ics" or ct == "text/calendar":
        return False
    if ct in DOC_CT or ct.startswith("image/"):
        return True
    return ext in DOC_EXT


def safe(fn):
    fn = os.path.basename((fn or "attachment"))
    return re.sub(r"[^A-Za-z0-9._ -]", "_", fn) or "attachment"


def chown_papra(path):
    try:
        os.chown(path, pwd.getpwnam("papra").pw_uid, grp.getgrnam("papra").gr_gid)
    except Exception:
        pass


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    open(STATE, "a").close()
    os.makedirs(DEST, exist_ok=True)
    seen = {l.strip() for l in open(STATE) if l.strip()}

    pw = open(PASS_FILE).read().strip()
    M = imaplib.IMAP4(HOST, PORT)
    M.login(USER, pw)
    typ, _ = M.select(MAILBOX, readonly=True)
    if typ != "OK":
        print(f"error: cannot select mailbox {MAILBOX!r} (does the Proton folder exist?)",
              file=sys.stderr)
        return 1

    typ, ids = M.search(None, "ALL")
    n = 0
    newseen = []
    for num in ids[0].split():
        typ, d = M.fetch(num, "(RFC822)")
        msg = email.message_from_bytes(d[0][1])
        mid = (msg.get("Message-ID") or "").strip()
        if mid and mid in seen:
            continue
        for part in msg.walk():
            ct = part.get_content_type()
            fn = part.get_filename()
            disp = part.get("Content-Disposition")
            if not (fn or (disp and "attachment" in disp.lower())):
                continue
            if not is_doc(ct, fn):
                continue
            payload = part.get_payload(decode=True)
            if not payload:
                continue
            dest = os.path.join(DEST, safe(fn))
            base, ext = os.path.splitext(dest)
            i = 1
            while os.path.exists(dest):
                dest = f"{base}-{i}{ext}"
                i += 1
            tmp = dest + ".incoming"
            with open(tmp, "wb") as fh:
                fh.write(payload)
            chown_papra(tmp)
            os.replace(tmp, dest)
            chown_papra(dest)
            print(f"saved: {os.path.basename(dest)} ({ct}, {len(payload)}B) from {msg.get('From')}")
            n += 1
        if mid:
            newseen.append(mid)  # record even if 0 doc attachments, to avoid re-scanning

    if newseen:
        with open(STATE, "a") as fh:
            for mid in newseen:
                fh.write(mid + "\n")
    M.logout()
    print(f"done: {n} attachment(s) queued for Papra from '{MAILBOX}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
