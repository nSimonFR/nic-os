#!/usr/bin/env bash
# No args: silent unless a train watch's price rule fires (skill train-watch).
# With args (add/list/remove/history): manages the watches, prints JSON.
export TRAIN_WATCH_DB=@hermesHome@/workspace/train-watch/watch.sqlite3
exec @bin@/hermes-train-watch "$@"
