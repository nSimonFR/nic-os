#!/usr/bin/env bash
# Silent while NousResearch/hermes-agent#103048 (resume a turn when the usage
# limit resets) is open. Once it merges or closes, one line each week until
# job d13d9435b8d7 is deleted.
set -euo pipefail
pr=103048
state=$(gh pr view "$pr" -R NousResearch/hermes-agent --json state --jq .state)
[ "$state" = OPEN ] && exit 0
echo "hermes auto-resume: #$pr is $state — https://github.com/NousResearch/hermes-agent/pull/$pr"
echo "Bump the hermes-agent pin in flake.nix once a release contains it, then delete cron job d13d9435b8d7."
