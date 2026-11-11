#!/bin/bash
# Unattended build loop on GitHub Issues: each iteration picks the highest-priority
# open story in the sprint milestone, lets Claude implement and commit it, then posts
# a summary comment and closes the issue.
set -e
set -o pipefail

source "$(dirname "$0")/github-ralph-lib.sh"

if [ -z "$1" ]; then
  echo "Usage: $0 <iterations> [sprint milestone]"
  echo "Without a sprint, the most recently created open milestone is used."
  exit 1
fi

require_tools
select_sprint "$2"
ensure_labels
echo "📌 Sprint: $SPRINT"

# If the run is aborted, don't leave the current issue stuck on in-progress.
CURRENT=""
cleanup() { if [ -n "$CURRENT" ]; then remove_label "$CURRENT" in-progress; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

for ((i=1; i<=$1; i++)); do
  n=$(next_issue)
  if [ -z "$n" ]; then
    echo "🏁 Sprint complete: no open stories left in \"$SPRINT\"."
    exit 0
  fi

  echo "=== Iteration $i/$1 ($(date +%H:%M:%S)): #$n ==="
  log="$LOG_DIR/issue-$n-$(date +%Y%m%d-%H%M%S).jsonl"
  start=$(current_head)
  CURRENT="$n"
  add_label "$n" in-progress

  prompt="$(issue_prompt "$n")$(build_rules "$n")"

  claude -p "$prompt" \
    --output-format stream-json --verbose \
    --permission-mode acceptEdits \
    --allowedTools \
      "Bash(npx jest:*)" "Bash(npx tsc:*)" \
      "Bash(npx expo:*)" "Bash(npx expo-doctor:*)" "Bash(npx prettier:*)" "Bash(npx eslint:*)" \
      "Bash(npm install:*)" "Bash(npm uninstall:*)" "Bash(npm run:*)" "Bash(npm ls:*)" \
      "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" \
      "Bash(git rm:*)" "Bash(git mv:*)" "Bash(git show:*)" "Bash(git restore:*)" "Bash(git cat-file:*)" \
      "Bash(ls:*)" "Bash(cp .env.example:*)" \
      "Bash(grep:*)" "Bash(sort:*)" "Bash(uniq:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)" \
      "Bash(cut:*)" "Bash(cat:*)" "Bash(find:*)" "Bash(jq:*)" "Bash(node:*)" \
    | tee "$log" | jq -r --unbuffered "$JQ_FILTER" || echo "⚠️  Claude exited with an error (log: $log)"

  summary=$(jq -r 'select(.type == "result") | .result // ""' "$log" 2>/dev/null || true)
  commits=$(commits_since "$start")

  if [ -n "$commits" ]; then
    complete_issue "$n" "$summary" "$commits"
  else
    fail_issue "$n" "$summary"
  fi
  CURRENT=""
done

echo "Stopped after $1 iterations. Open stories may remain in \"$SPRINT\"."
