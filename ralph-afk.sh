#!/bin/bash
set -e
set -o pipefail

if [ -z "$1" ]; then
  echo "Usage: $0 <iterations>"
  exit 1
fi

LOG_DIR=".ralph-logs"
SCRATCH_DIR=".ralph-tmp"
mkdir -p "$LOG_DIR" "$SCRATCH_DIR"

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

for ((i=1; i<=$1; i++)); do
  echo "=== Iteration $i/$1 ($(date +%H:%M:%S)) ==="
  log="$LOG_DIR/iteration-$i.jsonl"

  claude -p "@PRD.md @progress.txt \
  1. Find the highest-priority task and implement it. \
  2. Run the verification steps the PRD lists for that task (e.g. 'npx tsc --noEmit', 'npm run lint', 'npx expo export --platform ios'). Never run jest in watch mode. \
  3. Update the PRD with what was done. \
  4. Append your progress to progress.txt. \
  5. Commit your changes. \
  ONLY WORK ON A SINGLE TASK. \
  Rules for this unattended run: never use /tmp; put temporary files in ./$SCRATCH_DIR (gitignored). \
  Create and edit files with the Write/Edit tools, never with shell heredocs or echo redirects. \
  If the PRD is complete, output <promise>COMPLETE</promise>." \
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
    | tee "$log" | jq -r --unbuffered "$JQ_FILTER"

  if jq -r 'select(.type == "result") | .result // ""' "$log" | grep -q '<promise>COMPLETE</promise>'; then
    echo "PRD complete after $i iterations."
    exit 0
  fi
done