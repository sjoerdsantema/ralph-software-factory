#!/bin/bash
# Sprint planning: asks for the sprint mission, has Claude (in plan mode, read-only)
# propose 10 user stories per round, and lets you accept (with priority) or reject
# each one. Accepted stories are appended to PRD.md; rejected ones are added to the
# PRD's "Out of scope" list so they are not proposed again.
set -e
set -o pipefail

PRD="PRD.md"
BATCH_SIZE=10
SCRATCH_DIR=".ralph-tmp"
mkdir -p "$SCRATCH_DIR"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI is required"; exit 1; }

if [ ! -f "$PRD" ]; then
  cat > "$PRD" <<'EOF'
How to use this file Each user story below is self-contained: an agent receives one story, and only that story. Every story therefore repeats the project context and rules it needs.


Out of scope for the whole PRD (rejected during review):

EOF
fi

# ---------- helpers ----------

# Highest existing US-NNN number in the PRD (0 if none).
last_story_number() {
  { grep -oE 'US-[0-9]+' "$PRD" || true; } | sed 's/US-0*//' | sort -n | tail -1 | sed 's/^$/0/'
}

# Insert one line at the end of the "Out of scope" list.
add_out_of_scope() {
  local item="$1" tmp="$SCRATCH_DIR/prd.tmp"
  awk -v item="$item" '
    state == 0 { print; if ($0 ~ /^Out of scope/) state = 1; next }
    state == 1 { if ($0 != "") state = 2; print; next }
    state == 2 {
      if ($0 == "" || $0 ~ /^#/ || $0 ~ /^---/) { print item; state = 3 }
      print; next
    }
    { print }
    END {
      if (state == 0) { print ""; print "Out of scope for the whole PRD (rejected during review):"; print ""; print item }
      else if (state == 1 || state == 2) print item
    }
  ' "$PRD" > "$tmp" && mv "$tmp" "$PRD"
}

# Append an accepted story (JSON object on stdin-less arg) to the PRD.
add_story() {
  local story_json="$1" id="$2" prio="$3"
  grep -q '^## User stories' "$PRD" || printf '\n\n## User stories\n' >> "$PRD"
  jq -r --arg id "$id" --arg prio "$prio" '
    "\n---\n\n### \($id): \(.title)\n\n" +
    "**Priority:** \($prio) · **Status:** TODO\n\n" +
    "**Story:** As \(.as_a), I want \(.i_want), so that \(.so_that).\n\n" +
    "**Context:**\n\n\(.context)\n\n" +
    "**Acceptance criteria:**\n\n" + (.acceptance_criteria | map("- [ ] " + .) | join("\n")) + "\n\n" +
    "**Verification:**\n\n" + (.verification | map("- `" + . + "`") | join("\n"))
  ' <<<"$story_json" >> "$PRD"
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

# ---------- mission ----------

echo "🧭 What is the mission of this sprint?"
read -r -p "> " MISSION </dev/tty
[ -z "$MISSION" ] && { echo "No mission given, aborting."; exit 1; }

round=0
while true; do
  round=$((round + 1))
  out="$SCRATCH_DIR/plan-round-$round.json"
  echo
  echo "🤔 Round $round: Claude is exploring the codebase and drafting $BATCH_SIZE user stories..."

  claude -p "@$PRD \
  You are running in plan mode: research only. Do not modify any files and do not call ExitPlanMode. \
  Sprint mission: \"$MISSION\" \
  Explore the codebase to understand the project, its stack and conventions. \
  Then propose exactly $BATCH_SIZE NEW user stories that move this mission forward. \
  Do not duplicate stories already in the PRD, and do not propose anything matching the PRD's 'Out of scope' list. \
  Each story must be small enough for one agent to implement in a single iteration. \
  Each story must be fully self-contained: an agent will receive ONLY that one story, so its context must repeat \
  the project context it needs (stack, relevant files and directories, conventions, rules such as 'never use /tmp'). \
  Verification must be concrete shell commands (e.g. 'npx tsc --noEmit', 'npm run lint'); never jest in watch mode. \
  Order stories by dependency where relevant and suggest a priority (P1 = must have, P3 = nice to have)." \
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
        q|Q) echo "👋 Stopped. Decisions so far are saved in $PRD."; exit 0 ;;
        *)   echo "Please answer 1, 2, 3, Enter, r, c or q." ;;
      esac
    done

    if [ "$prio" = "REJECT" ]; then
      add_out_of_scope "$(jq -r '.title' <<<"$story")"
      rejected=$((rejected + 1))
      echo "🗑  Rejected (added to Out of scope)."
    else
      id=$(printf 'US-%03d' $(( $(last_story_number) + 1 )))
      add_story "$story" "$id" "$prio"
      accepted=$((accepted + 1))
      echo "✅ Added $id with priority $prio."
    fi
  done

  echo
  echo "Round $round done: $accepted accepted, $rejected rejected → $PRD"
  read -r -p "Generate $BATCH_SIZE more stories for this mission? [y/N] " again </dev/tty
  [[ "$again" =~ ^[yY] ]] || break
done

echo "🏁 Sprint planning finished. Run ./ralph-afk.sh <iterations> to start building."
