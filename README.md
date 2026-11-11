# Ralph Software Factory

A few shell scripts that use [Claude Code](https://claude.com/claude-code) to plan and build software in small steps. You plan the sprint together with Claude. Claude then builds it one user story at a time, and each story gets its own commit.

It follows the "Ralph" loop: give the agent one task, let it finish and commit, then start the next run fresh from the files on disk.

## How it works

```
ralph-plan.sh  ──►  PRD.md  ──►  ralph-once.sh / ralph-afk.sh  ──►  commits + progress.txt
 (you + Claude       (the          (Claude builds one story
  plan the sprint)    backlog)      per run)
```

| File | What it's for |
| --- | --- |
| `ralph-plan.sh` | Plan a sprint: Claude suggests user stories and you accept or reject each one |
| `PRD.md` | The backlog: accepted user stories, their priority and status, and what's out of scope |
| `ralph-once.sh` | Build one story, interactively, so you can watch and step in |
| `ralph-afk.sh` | Build stories unattended in a loop, for a set number of iterations |
| `progress.txt` | A log Claude appends to after each story, so the next run knows what has been done |

## Requirements

- [Claude Code](https://claude.com/claude-code) CLI, logged in (`claude` on your PATH)
- [`jq`](https://jqlang.org/) (`brew install jq`)
- A git repository. The build scripts commit after every story.

Make the scripts executable once:

```bash
chmod +x ralph-plan.sh ralph-once.sh ralph-afk.sh
```

## 1. Plan the sprint

```bash
./ralph-plan.sh
```

1. Enter the **mission** of this sprint, for example *"Users can sign up and log in with email"*.
2. Claude reads the codebase and `PRD.md` in plan mode, so it can't change any files, and suggests **10 user stories**.
3. For each story you choose:

   | Key | Action |
   | --- | --- |
   | `1` / `2` / `3` | Accept as P1 (must have) / P2 / P3 (nice to have) |
   | `Enter` | Accept with Claude's suggested priority |
   | `r` | Reject. The story is added to the PRD's *Out of scope* list and won't be suggested again |
   | `c` | Show the story's full context before you decide |
   | `q` | Quit. Decisions you've already made are saved |

4. After 10 stories you can ask for another 10 for the same mission.

Accepted stories are added to `PRD.md` as `US-001`, `US-002`, … Each one contains its priority, `Status: TODO`, the full project context, acceptance criteria and verification commands. An agent only ever gets a single story, so each story has to make sense on its own.

## 2. Build

**Watch one story being built** (good for the first run, or to check Claude's approach):

```bash
./ralph-once.sh
```

**Let it run unattended**, building up to `N` stories:

```bash
./ralph-afk.sh 5
```

In each iteration Claude picks the highest-priority open story, implements it, runs its verification commands, updates `PRD.md` and `progress.txt`, and commits. The loop stops early when Claude reports that the whole PRD is done.

While it runs you'll see a short live feed of Claude's messages and tool calls. Full logs are saved in `.ralph-logs/iteration-N.jsonl`.

## Things to know

- **Permissions.** `ralph-afk.sh` auto-accepts file edits and only allows a fixed list of shell commands (npm, npx, expo, tsc, eslint, prettier, git, and read-only tools). The list is set up for a JavaScript/Expo project. Edit `--allowedTools` in the script if your stack needs other commands. Anything not on the list is denied, and the denial shows up in the feed as `⚠️ tool error/denied`.
- **Review the commits.** The AFK loop commits straight to the current branch. Run it on a feature branch and look over the history before you merge.
- **Cost.** Each iteration is a full Claude session. `ralph-afk.sh` prints the cost of each iteration when it finishes.
- **Scratch files** go in `.ralph-tmp/` and logs in `.ralph-logs/`. Git ignores both.
- **Editing the PRD by hand** is fine: reorder priorities, tweak stories, or add lines to *Out of scope*. Keep the `### US-NNN: Title` heading format so new stories keep counting up.
