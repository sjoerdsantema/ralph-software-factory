#!/bin/bash
# Sprint planning with GitHub Issues: creates (or reuses) a milestone for the sprint,
# has Claude (in plan mode, read-only) propose 10 user stories per round, and lets you
# accept (with priority) or reject each one. Accepted stories become open issues in the
# milestone; rejected ones become closed "not planned" issues so they aren't proposed again.
set -e
set -o pipefail

source "$(dirname "$0")/github-ralph-lib.sh"

BATCH_SIZE=10

require_tools
ensure_labels

# ---------- sprint + mission ----------

default_sprint="Sprint $(date +%Y-%m-%d)"
read -r -p "🏷  Sprint name [$default_sprint]: " SPRINT </dev/tty
SPRINT="${SPRINT:-$default_sprint}"

existing_mission=$(list_milestones | jq -r --arg t "$SPRINT" 'map(select(.title == $t)) | .[0].description // empty')
milestone_exists=$(list_milestones | jq -r --arg t "$SPRINT" 'any(.[]; .title == $t)')

echo "🧭 What is the mission of this sprint?"
if [ -n "$existing_mission" ]; then
  echo "   (existing: $existing_mission; press Enter to keep it)"
fi
read -r -p "> " MISSION </dev/tty
MISSION="${MISSION:-$existing_mission}"
[ -z "$MISSION" ] && { echo "No mission given, aborting."; exit 1; }

if [ "$milestone_exists" = "true" ]; then
  if [ "$MISSION" != "$existing_mission" ]; then
    number=$(list_milestones | jq -r --arg t "$SPRINT" 'map(select(.title == $t)) | .[0].number')
    gh api -X PATCH "repos/{owner}/{repo}/milestones/$number" -f description="$MISSION" >/dev/null
  fi
  echo "📌 Using milestone \"$SPRINT\""
else
  gh api -X POST "repos/{owner}/{repo}/milestones" -f title="$SPRINT" -f description="$MISSION" >/dev/null
  echo "📌 Created milestone \"$SPRINT\""
fi

# ---------- helpers ----------

# Markdown issue body for a story JSON object.
render_body() {
  jq -r '
    "**Story:** As \(.as_a), I want \(.i_want), so that \(.so_that).\n\n" +
    "## Context\n\n\(.context)\n\n" +
    "## Acceptance criteria\n\n" + (.acceptance_criteria | map("- [ ] " + .) | join("\n")) + "\n\n" +
    "## Verification\n\n" + (.verification | map("- `" + . + "`") | join("\n"))
  ' <<<"$1"
}

# Creates an issue for story $1 with extra labels $2 (comma separated); prints its number.
create_issue() {
  local story="$1" labels="$2" body_file="$SCRATCH_DIR/new-issue.md" url
  render_body "$story" > "$body_file"
  url=$(gh issue create \
    --title "$(jq -r '.title' <<<"$story")" \
    --body-file "$body_file" \
    --label "user-story,$labels" \
    --milestone "$SPRINT")
  echo "${url##*/}"
}

SCHEMA=$(cat <<EOF
{
  "type": "object",
  "properties": {
    "stories": {
      "type": "array", "minItems": $BATCH_SIZE, "maxItems": $BATCH_SIZE,
      "items": {
        "type": "object",
        "properties": {
          "title": {"type": "string"},
          "as_a": {"type": "string", "description": "e.g. 'a returning user'"},
          "i_want": {"type": "string"},
          "so_that": {"type": "string"},
          "context": {"type": "string", "description": "Self-contained project context, relevant files, constraints and rules"},
          "acceptance_criteria": {"type": "array", "items": {"type": "string"}},
          "verification": {"type": "array", "items": {"type": "string"}, "description": "Shell commands that verify the story"},
          "suggested_priority": {"type": "string", "enum": ["P1", "P2", "P3"]}
        },
        "required": ["title", "as_a", "i_want", "so_that", "context", "acceptance_criteria", "verification", "suggested_priority"]
      }
    }
  },
  "required": ["stories"]
}
EOF
)

# ---------- rounds ----------

round=0
while true; do
  round=$((round + 1))
  out="$SCRATCH_DIR/gh-plan-round-$round.json"

  backlog=$(gh issue list --label user-story --state all --limit 300 --json number,title,state,labels \
    | jq -r '
        map("- #\(.number) [\(if ([.labels[].name] | index("rejected")) then "REJECTED"
                              elif .state == "CLOSED" then "DONE" else "OPEN" end)] \(.title)")
        | if length == 0 then "(no stories yet)" else join("\n") end')

  echo
  echo "🤔 Round $round: Claude is exploring the codebase and drafting $BATCH_SIZE user stories..."

  claude -p "You are running in plan mode: research only. Do not modify any files and do not call ExitPlanMode. \
  Sprint mission: \"$MISSION\" \
  Explore the codebase to understand the project, its stack and conventions. \
  Then propose exactly $BATCH_SIZE NEW user stories that move this mission forward. \
  Below is the existing backlog (GitHub issues). Do not duplicate OPEN or DONE stories, \
  and do not propose anything similar to a REJECTED story. \
  Each story must be small enough for one agent to implement in a single iteration. \
  Each story must be fully self-contained: an agent will receive ONLY that one story, so its context must repeat \
  the project context it needs (stack, relevant files and directories, conventions, rules such as 'never use /tmp'). \
  Verification must be concrete shell commands (e.g. 'npx tsc --noEmit', 'npm run lint'); never jest in watch mode. \
  Order stories by dependency where relevant and suggest a priority (P1 = must have, P3 = nice to have).

Existing backlog:
$backlog" \
    --permission-mode plan \
    --output-format json \
    --json-schema "$SCHEMA" \
    --disallowedTools "ExitPlanMode" "Write" "Edit" "NotebookEdit" \
    --allowedTools "Read" "Glob" "Grep" \
      "Bash(ls:*)" "Bash(cat:*)" "Bash(find:*)" "Bash(grep:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)" \
      "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" "Bash(jq:*)" \
    > "$out"

  # Output is either a single result object or an array of events ending in one.
  stories=$(jq -c '
    (if type == "array" then map(select(.type == "result")) | last else . end) as $r
    | $r.structured_output.stories // ($r.result | fromjson? | .stories) // empty
  ' "$out")
  if [ -z "$stories" ]; then
    echo "❌ Could not parse stories from Claude's output. Raw output saved in $out"
    exit 1
  fi
  count=$(jq 'length' <<<"$stories")

  accepted=0; rejected=0
  for ((i = 0; i < count; i++)); do
    story=$(jq -c ".[$i]" <<<"$stories")
    suggested=$(jq -r '.suggested_priority' <<<"$story")

    echo
    echo "────────────────────────────────────────────────────────────"
    jq -r --arg n "$((i + 1))/$count" '
      "📝 [\($n)] \(.title)\n\n" +
      "As \(.as_a), I want \(.i_want), so that \(.so_that).\n\n" +
      "Acceptance criteria:\n" + (.acceptance_criteria | map("  • " + .) | join("\n")) + "\n\n" +
      "Suggested priority: \(.suggested_priority)"
    ' <<<"$story"
    echo

    while true; do
      read -r -p "Accept with [1] P1 / [2] P2 / [3] P3, [Enter] = $suggested, [r] reject, [c] show context, [q] quit: " choice </dev/tty
      case "$choice" in
        "")  prio="$suggested"; break ;;
        1|2|3) prio="P$choice"; break ;;
        r|R) prio="REJECT"; break ;;
        c|C) echo; jq -r '.context' <<<"$story"; echo ;;
        q|Q) echo "👋 Stopped. Decisions so far are saved as issues in \"$SPRINT\"."; exit 0 ;;
        *)   echo "Please answer 1, 2, 3, Enter, r, c or q." ;;
      esac
    done

    if [ "$prio" = "REJECT" ]; then
      n=$(create_issue "$story" "rejected")
      gh issue close "$n" --reason "not planned" >/dev/null
      rejected=$((rejected + 1))
      echo "🗑  Rejected (#$n closed as not planned)."
    else
      n=$(create_issue "$story" "$prio")
      accepted=$((accepted + 1))
      echo "✅ Created #$n with priority $prio."
    fi
  done

  echo
  echo "Round $round done: $accepted accepted, $rejected rejected → milestone \"$SPRINT\""
  read -r -p "Generate $BATCH_SIZE more stories for this mission? [y/N] " again </dev/tty
  [[ "$again" =~ ^[yY] ]] || break
done

echo "🏁 Sprint planning finished. Run ./github-ralph-afk.sh <iterations> \"$SPRINT\" to start building."
