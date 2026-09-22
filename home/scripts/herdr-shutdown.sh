#!/usr/bin/env bash
# Wait for an agent to stop working, then close the pane hosting it.
#
# Usage: herdr-shutdown [target] [--timeout-min N]
#   target: a live agent name or a pane id; defaults to the calling pane.
#
# `herdr agent wait` reports a timeout as JSON with EXIT CODE 0, so the outcome
# has to be read from the payload, never from $?. It also caps a single wait, so
# this loops until the budget runs out.
#
# `idle` and `done` both mean "ready for input" — that is as close to "finished"
# as herdr exposes, and the pair is what the CLI offers.
set -euo pipefail

target="${1:-${HERDR_PANE_ID:-}}"
budget_min=30
[ "${2:-}" = "--timeout-min" ] && budget_min="${3:-30}"

[ "${HERDR_ENV:-}" = "1" ] || { echo "not running inside herdr" >&2; exit 1; }
[ -n "$target" ] || { echo "no target, and HERDR_PANE_ID is unset" >&2; exit 1; }

# An agent name has to be resolved to the pane that currently hosts it, because
# `pane close` takes a pane id only.
# `|| true`: with pipefail, a miss here would otherwise trip `set -e` and kill
# the script before it can say what went wrong.
pane=$(herdr agent get "$target" 2>/dev/null | jq -r '.result.agent.pane_id // empty' || true)
[ -n "$pane" ] || { echo "no live agent at '$target'" >&2; exit 1; }

# Detached, and it outlives the pane it is about to close: nohup keeps the
# SIGHUP that closing sends from reaching it before the request is delivered.
# shellcheck disable=SC2016  # the body is deliberately unexpanded; $1/$2 are its own args
nohup bash -c '
  pane="$1"; deadline=$(( $(date +%s) + $2 * 60 ))
  # Let it reach "working" first. herdr can still report the PREVIOUS idle/done
  # for a second or two after a prompt lands, and without this the watcher reads
  # that stale state as "finished" and closes a pane that never started. A
  # timeout here is fine: the work was simply too quick to catch.
  herdr agent wait "$pane" --until working --timeout 10000 >/dev/null 2>&1 || true
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out=$(herdr agent wait "$pane" --until idle --until done --timeout 60000 2>/dev/null || true)
    case $(printf "%s" "$out" | jq -r ".error.code // empty") in
      timeout) continue ;;      # still working, keep waiting
      "")      break ;;         # reached idle or done
      *)       exit 1 ;;        # agent or pane went away; leave the pane alone
    esac
  done
  herdr pane close "$pane" >/dev/null 2>&1
' _ "$pane" "$budget_min" >/dev/null 2>&1 &

echo "watching $pane; it closes when the agent goes idle (giving up after ${budget_min}m)"
