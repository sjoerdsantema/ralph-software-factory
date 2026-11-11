#!/bin/bash
# Build one GitHub-issue story interactively, so you can watch and step in.
# Usage: ./github-ralph-once.sh [issue number]
# Without a number, it picks the highest-priority open story in the latest open milestone.
set -e
set -o pipefail

source "$(dirname "$0")/github-ralph-lib.sh"

require_tools
ensure_labels

if [ -n "$1" ]; then
  n="$1"
  SPRINT=$(gh issue view "$n" --json milestone --jq '.milestone.title // empty')
else
  select_sprint ""
  n=$(next_issue)
  if [ -z "$n" ]; then
    echo "🏁 No open stories left in \"$SPRINT\"."
    exit 0
  fi
fi

echo "📌 Working on #$n: $(gh issue view "$n" --json title --jq .title)"

CURRENT="$n"
cleanup() { if [ -n "$CURRENT" ]; then remove_label "$CURRENT" in-progress; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

start=$(current_head)
add_label "$n" in-progress
summary_file="$SCRATCH_DIR/issue-$n-summary.md"
rm -f "$summary_file"

prompt="$(issue_prompt "$n")$(build_rules "$n")
5. Also write that summary to ./$summary_file with the Write tool."

claude --permission-mode acceptEdits "$prompt" || true

summary=$(cat "$summary_file" 2>/dev/null || true)
commits=$(commits_since "$start")

echo
if [ -n "$commits" ]; then
  echo "Commits made:"
  echo "$commits"
  read -r -p "Close issue #$n with a summary comment? [Y/n] " answer </dev/tty
  if [[ ! "$answer" =~ ^[nN] ]]; then
    complete_issue "$n" "$summary" "$commits"
  else
    echo "Left #$n open."
  fi
else
  read -r -p "No commits were made. Mark #$n as needs-attention? [y/N] " answer </dev/tty
  [[ "$answer" =~ ^[yY] ]] && fail_issue "$n" "$summary"
fi
CURRENT=""
