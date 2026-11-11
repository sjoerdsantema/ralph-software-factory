#!/bin/bash
# Shared helpers for github-ralph-*.sh. Source this file, don't run it.
#
# Mapping:
#   user story      -> open issue labelled `user-story` + `P1|P2|P3`, in a milestone (= sprint)
#   sprint mission  -> milestone description
#   rejected story  -> issue labelled `rejected`, closed as "not planned"
#   being worked on -> `in-progress` label
#   done            -> summary comment + closed issue
#   failed attempt  -> `needs-attention` label (skipped by the loop until you remove it)
#
# Env:
#   GH_REPO=owner/name   use another repo than the current git remote (read by gh itself)
#   RALPH_ANY_AUTHOR=1   also build issues not created by you (off by default: prompt-injection guard)

SCRATCH_DIR=".ralph-tmp"
LOG_DIR=".ralph-logs"
mkdir -p "$SCRATCH_DIR" "$LOG_DIR"

# Same live feed as ralph-afk.sh.
JQ_FILTER='
  if .type == "assistant" then
    .message.content[]? |
      if .type == "text" then "💬 " + .text
      elif .type == "tool_use" then
        "🔧 " + .name + ": " + (
          .input.command // .input.file_path // .input.pattern // .input.description // (.input | tostring)
        )[0:200]
      else empty end
  elif .type == "user" then
    .message.content[]? | select(.type == "tool_result" and .is_error == true) |
      "   ⚠️  tool error/denied: " + ((.content | tostring)[0:200])
  elif .type == "result" then
    "\n✅ Done in " + ((.duration_ms / 1000 | floor) | tostring) + "s, cost $" + ((.total_cost_usd // 0) * 100 | round / 100 | tostring)
  else empty end
'

require_tools() {
  local t
  for t in gh jq claude git; do
    command -v "$t" >/dev/null || { echo "❌ $t is required"; exit 1; }
  done
  gh auth status >/dev/null 2>&1 || { echo "❌ gh is not logged in. Run: gh auth login"; exit 1; }
  ME=$(gh api user --jq .login)
}

ensure_labels() {
  gh label create user-story      --color 1D76DB --description "Ralph user story"            --force >/dev/null
  gh label create P1              --color B60205 --description "Priority 1: must have"       --force >/dev/null
  gh label create P2              --color FBCA04 --description "Priority 2: should have"     --force >/dev/null
  gh label create P3              --color 0E8A16 --description "Priority 3: nice to have"    --force >/dev/null
  gh label create in-progress     --color 5319E7 --description "Ralph is working on this"    --force >/dev/null
  gh label create needs-attention --color D93F0B --description "Ralph attempt failed"        --force >/dev/null
  gh label create rejected        --color CCCCCC --description "Rejected during planning"    --force >/dev/null
}

# All milestones (open and closed) as a JSON array.
list_milestones() {
  gh api "repos/{owner}/{repo}/milestones?state=all&per_page=100"
}

# Sets SPRINT to the given name, or to the most recently created open milestone.
select_sprint() {
  if [ -n "$1" ]; then
    SPRINT="$1"
  else
    SPRINT=$(list_milestones | jq -r 'map(select(.state == "open")) | sort_by(.created_at) | last | .title // empty')
  fi
  if [ -z "$SPRINT" ]; then
    echo "❌ No open milestone found. Run ./github-ralph-plan.sh first, or pass a sprint name."
    exit 1
  fi
}

# Prints the number of the highest-priority open story in $SPRINT that is free to pick up.
next_issue() {
  local author=(--author @me)
  [ "${RALPH_ANY_AUTHOR:-0}" = "1" ] && author=()
  gh issue list --label user-story --state open --milestone "$SPRINT" "${author[@]}" \
    --limit 200 --json number,labels \
  | jq -r '
      map(. + {names: [.labels[].name]})
      | map(select((.names | index("in-progress") or index("needs-attention")) | not))
      | sort_by(
          (if (.names | index("P1")) then 1
           elif (.names | index("P2")) then 2
           elif (.names | index("P3")) then 3
           else 4 end),
          .number)
      | .[0].number // empty'
}

# Prints the prompt text for issue $1: the issue itself plus the summaries of the
# last few completed stories in the sprint (this replaces progress.txt).
issue_prompt() {
  local n="$1"
  gh issue view "$n" --json number,title,body --jq '"# Issue #\(.number): \(.title)\n\n\(.body)"'
  gh issue list --label user-story --state closed --milestone "$SPRINT" --limit 10 \
    --json number,title,labels,comments \
  | jq -r --arg me "$ME" '
      map(select([.labels[].name] | index("rejected") | not)) | .[0:5]
      | if length == 0 then empty else
          "\n\n# Recently completed stories in this sprint (context only, do not redo them)\n" +
          (map("\n## #\(.number): \(.title)\n" +
               (([.comments[] | select(.author.login == $me)] | last | .body // "(no summary)")[0:1500]))
           | join("\n"))
        end'
}

add_label()    { gh issue edit "$1" --add-label "$2"    >/dev/null; }
remove_label() { gh issue edit "$1" --remove-label "$2" >/dev/null 2>&1 || true; }

current_head() { git rev-parse -q --verify HEAD 2>/dev/null || true; }

# Commits made since $1 (a SHA, or empty when the repo had no commits yet), one per line.
commits_since() {
  if [ -n "$1" ]; then
    git log --format='- %h %s' "$1..HEAD" 2>/dev/null || true
  else
    git log --format='- %h %s' 2>/dev/null || true
  fi
}

# Comment the summary + commits on issue $1 and close it.
complete_issue() {
  local n="$1" summary="$2" commits="$3" body="$SCRATCH_DIR/issue-$1-comment.md"
  [ -z "$summary" ] && summary="(no summary)"
  printf '🤖 **Implemented by Ralph**\n\n**Commits:**\n%s\n\n**Summary:**\n\n%s\n' "$commits" "$summary" > "$body"
  gh issue comment "$n" --body-file "$body" >/dev/null
  remove_label "$n" in-progress
  gh issue close "$n" --reason completed >/dev/null
  echo "✅ Closed #$n"
}

# Comment the failure on issue $1 and park it with `needs-attention`.
fail_issue() {
  local n="$1" summary="$2" body="$SCRATCH_DIR/issue-$1-comment.md"
  [ -z "$summary" ] && summary="(no output)"
  printf '⚠️ **Ralph attempt failed:** no commit was made.\n\nRemove the `needs-attention` label to let Ralph try again.\n\n**Last output:**\n\n%s\n' "$summary" > "$body"
  gh issue comment "$n" --body-file "$body" >/dev/null
  remove_label "$n" in-progress
  add_label "$n" needs-attention
  echo "⚠️  #$n marked needs-attention"
}

# Rules both build scripts give Claude.
build_rules() {
  local n="$1"
  cat <<EOF


# Your task
You are working on GitHub issue #$n above. ONLY WORK ON THIS ONE STORY.
1. Implement the story.
2. Run the verification commands the story lists. Never run jest in watch mode.
3. Commit your changes. The commit message must end with "Closes #$n".
4. Finish with a short summary: what you changed, and anything the next story should know.
Do not use gh or change anything on GitHub; the script updates the issue for you.
Never use /tmp; put temporary files in ./$SCRATCH_DIR (gitignored).
Create and edit files with the Write/Edit tools, never with shell heredocs or echo redirects.
EOF
}
