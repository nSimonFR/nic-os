#!/usr/bin/env bash
# Pre-run script of an AGENT job (skill airbnb-pricing): stdout is the model's
# context, and `{"wakeAgent": false}` as the last line skips the run.
exec @bin@/hermes-airbnb-pricing "$@"
