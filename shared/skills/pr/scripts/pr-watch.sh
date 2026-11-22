#!/usr/bin/env bash
# pr-watch.sh <owner/repo> <pr> [deploy-workflow]
#
# Run in the background. It polls a PR and exits, printing one verdict line and
# its context, as soon as someone has to act:
#   FIX    a review-bot thread the agent has not answered, or a failing check:
#          the agent fixes, replies, pushes and starts the watch again
#   HUMAN  the bot reviewed the head and nothing is left to fix, but the merge
#          still waits: a human approval (or the bot withholds its own)
#   DONE   merged (and, if given, the deploy workflow on the base branch finished)
#
# Env: PR_WATCH_BOT (default coderabbitai), PR_WATCH_IGNORE (regex of check names
# that only mirror the review state, default nic-os's gates), PR_WATCH_GRACE
# (seconds an approved head may wait for its gate, default 1200).
set -uo pipefail

repo=${1:?owner/repo} pr=${2:?pr number} deploy=${3:-}
owner=${repo%/*} name=${repo#*/}
bot=${PR_WATCH_BOT:-coderabbitai}
ignore=${PR_WATCH_IGNORE:-^(gate|review-gate|Entire Gates|arm auto-merge|report failure)$}
grace=${PR_WATCH_GRACE:-1200}
approved_at=""

checks() { gh pr checks "$pr" --repo "$repo" 2>/dev/null | awk -F'\t' -v s="$1" '$2==s{print $1"\t"$4}'; }

while :; do
  state=$(gh pr view "$pr" --repo "$repo" --json state -q .state)
  if [ "$state" = MERGED ]; then
    if [ -n "$deploy" ]; then
      sleep 60
      base=$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName)
      id=$(gh run list --repo "$repo" --branch "$base" --workflow "$deploy" --limit 1 --json databaseId -q '.[0].databaseId')
      gh run watch "$id" --repo "$repo" --exit-status --interval 30 >/dev/null 2>&1
      echo "DONE merged; $deploy run $id rc=$?"
    else
      echo "DONE merged"
    fi
    exit 0
  fi
  [ "$state" = CLOSED ] && { echo "HUMAN closed without merge"; exit 0; }

  head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)

  # Unresolved bot threads whose last word is still the bot's.
  open=$(gh api graphql -f query="query{repository(owner:\"$owner\",name:\"$name\"){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved path line comments(last:20){nodes{author{login} body}}}}}}}" \
    -q "[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)
         | select(.comments.nodes[0].author.login==\"$bot\")
         | select(.comments.nodes[-1].author.login==\"$bot\")
         | \"### \(.path):\(.line)\n\(.comments.nodes[-1].body[0:2500])\"] | join(\"\n\n\")")
  if [ -n "$open" ]; then
    echo "FIX $bot threads on $head:"; echo "$open"; exit 0
  fi

  failed=$(checks fail | grep -Pv "$ignore\t" || true)
  if [ -n "$failed" ]; then
    echo "FIX failing checks on $head:"; echo "$failed"; exit 0
  fi

  pending=$(checks pending | cut -f1 | grep -Pv "$ignore" || true)
  review=$(gh api "repos/$repo/pulls/$pr/reviews" \
    -q "[.[] | select(.user.login==\"$bot[bot]\" and .commit_id==\"$head\")] | last // {} | [.state // \"\", .body // \"\"] | @tsv")
  verdict=${review%%$'\t'*}
  merge=$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus -q .mergeStateStatus)

  if [ -z "$pending" ] && [ -n "$verdict" ] && [ "$merge" != CLEAN ] && [ "$merge" != UNKNOWN ]; then
    if [ "$verdict" = APPROVED ]; then
      approved_at=${approved_at:-$(date +%s)}
      if [ $(( $(date +%s) - approved_at )) -gt "$grace" ]; then
        echo "HUMAN $bot approved $head but the PR is still $merge after ${grace}s: needs an approval"; exit 0
      fi
    else
      echo "HUMAN $bot left $head $verdict with nothing open to fix; PR is $merge: needs an approval"
      printf '%s\n' "${review#*$'\t'}" | head -c 1500; echo
      exit 0
    fi
  fi
  sleep 30
done
