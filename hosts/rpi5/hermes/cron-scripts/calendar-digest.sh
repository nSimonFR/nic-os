#!/usr/bin/env bash
# Plain text on stdout, which Hermes delivers verbatim. Reads the Nextcloud
# password straight from /run/agenix (owner nsimon, mode 0400) — no env plumbing.
# Its progress line goes to stderr, so it stays out of the message.
set -euo pipefail

exec @bin@/hermes-calendar-digest
