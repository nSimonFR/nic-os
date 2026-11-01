#!/usr/bin/env bash
# Silent unless a watched path in the Zen source tree appears or disappears.
export ZEN_STATE_FILE=@hermesHome@/workspace/zen-watch/state.json
exec @bin@/hermes-zen-watch
