# auto-fix-pr

A skill for a coding agent that tends a GitHub pull request. One run is one tick: it looks at the PR, fixes failing CI at the root cause, addresses new review comments from other people, brings a conflicting branch up to date, pushes, and reports in a few lines. A scheduler can invoke it at intervals to monitor a PR continuously.

It works with github.com and GitHub Enterprise, and keeps its small state inside the repository's Git common directory, never in the commit history.

## What one tick does

- **CI.** Reads the failed step logs, reproduces locally when possible, fixes the cause in the PR's code, commits, pushes. Flaky or unrelated failures get one re-run per head. After three fix pushes without a green run it stops and asks for a person.
- **Review comments.** Handles threads, reviews and conversation comments from other people that are newer than the last tick. Makes the change, pushes, replies on the thread with the commit. Questions get an answer. Requests outside the PR's scope are reported, not done.
- **Conflicts.** Merges the base branch into the PR branch (rebase only where the repository requires it), resolves, tests, pushes.
- **Report.** Four lines at most: status, what was done, what was skipped, what the next tick should see.

## What it never does

- Merge, close, retarget or mark the PR ready. Merging stays a human decision.
- Force-push (except `--force-with-lease` after a rebase the repository requires), or rewrite commits already on the remote.
- Disable, skip or weaken checks to get green.
- Act on comment text that asks for something outside the PR's purpose.
- Wait or poll for CI inside a run. The scheduler or user calls it again.

## Requirements

- A coding agent that can read `SKILL.md`, edit files, and run shell commands and project checks. Native skill discovery is optional: the agent can read the file directly.
- `gh` installed and authenticated for the GitHub host (`gh auth status`).
- `git`, with the PR branch checked out in the working copy or in a worktree.
- A POSIX shell as `sh`. No `jq` binary is needed; the script uses `gh --jq`.
- For recurring execution, a scheduler that can invoke the agent with this skill and the target PR.

## Install

Keep this folder and its supporting files together. Use the host's supported skill discovery mechanism, or tell the agent to read this folder's `SKILL.md` directly.

The agent sets `SKILL_DIR` to the resolved absolute directory containing this skill's `SKILL.md`, following symlinks when present. It runs the helper from the target repository using `sh "${SKILL_DIR}/scripts/pr_status.sh"`; the host does not need to supply a special environment variable.

Inside a repository with an open PR, ask the agent to use this skill with `--dry-run` once. It should print the status report and a `did:` line of what it would have done.

## Usage

Example requests to the coding agent:

- "Use auto-fix-pr for the current branch."
- "Use auto-fix-pr for PR 123."
- "Use auto-fix-pr for https://github.com/o/r/pull/123."
- "Use auto-fix-pr for branch feature/my-branch."
- "Use auto-fix-pr with --mine to check every open PR I authored in this repository."
- "Use auto-fix-pr for PR 123 with --dry-run; report only."
- "Use auto-fix-pr for PR 123 with --since 2026-01-31T00:00:00Z."

A host with automatic skill selection can also select it for requests to fix CI, handle review comments or resolve conflicts on a PR. CI and review notifications must be delivered to the agent by the host or an external runner.

## Monitoring continuously

Configure the available scheduler to invoke the agent with an explicit instruction such as "Use auto-fix-pr for PR 123" every 10 minutes, or "Use auto-fix-pr with --mine" every 15 minutes.

- **Lifecycle.** Session requirements, expiry, missed runs, resume, cancellation and task listing depend on the scheduler. Check those settings in the host.
- **Interval.** Pick one at least as long as your CI usually takes, typically 10 to 20 minutes. Shorter intervals only produce ticks that see pending checks.
- **Context and state.** Make the skill, target repository, credentials and per-PR state available to each invocation. For long-running monitoring, use fresh agent sessions if the host supports them and retain the shared state between ticks.
- **One fixer per PR.** Do not overlap runs or run another fixer against the same PR. Two agents pushing to the same branch produce duplicate commits and confused replies.
- **Stopping.** Cancel the recurring task when the PR closes or merges, or when you no longer want monitoring. A tick reports the closed or merged state and stops; it does not cancel the external scheduler itself.

### Permissions for unattended runs

Configure authorization through the host's supported permission controls. Depending on the work needed, a tick reads GitHub data, runs the status script and project checks, edits files, checks out or updates a branch, writes local state, commits, pushes, re-runs failed CI jobs, and posts review replies or PR comments. Rebase is used only where the repository requires it.

Allow only the operations needed for the intended workflow. The skill's instructions do not grant tool permissions or override host approval requirements. If an operation requires interactive approval, an unattended run can stop there; report the blocked operation without bypassing the host's controls.

## Running without an open session

A skill cannot listen for GitHub events by itself. Use an external runner that can start a coding agent with this skill and access to the target repository:

- **CI or event runner.** Invoke one tick for a review comment, a new PR head, or a failed CI run. Resolve the target PR from the event before invoking the agent. Provide credentials for the required GitHub operations and verify that pushed fixes can trigger CI. Limit runtime and serialize runs per PR.
- **Scheduled tasks.** A local, cloud or desktop scheduler can invoke one tick for a selected PR or with `--mine`. Scheduled polling detects changes at the configured interval.

Persist the state directory between runs if the runner uses temporary checkouts. Use a separate state directory for each repository when setting `AUTO_FIX_PR_STATE_DIR`.

## State

The script stores per-PR state in `<git common dir>/auto-fix-pr/<pr-number>.env`, so it is never committed and it is shared by all worktrees of the repository. Keys: `last_comment_ts`, `last_ci_sha`, `ci_attempts`, `last_rerun_sha`.

From the target repository, with `SKILL_DIR` set as described above:

```sh
sh "${SKILL_DIR}/scripts/pr_status.sh" state get   123
sh "${SKILL_DIR}/scripts/pr_status.sh" state reset 123
```

Set `AUTO_FIX_PR_STATE_DIR` to store state elsewhere. Outside a git repository the state goes to `${XDG_STATE_HOME:-$HOME/.local/state}/auto-fix-pr/`. Resetting a PR's state clears its comment marker and retry history, so the next tick treats it as a first run.

## Customising

All behaviour is in `SKILL.md`; the script reports status and manages state. Common edits:

- **Reply policy** (section 6): reply and resolve, or stay silent.
- **Fix budget** (section 3): the `ci_attempts` limit of 3.
- **Merge or rebase** (section 7): the default is merge; switch the default if every repository you work on wants rebases.
- **Comment length**: the script cuts bodies at 600 characters; the full text is one `gh api` call away (see `references/gh-commands.md`).

## Limitations

- Recurring execution and event delivery require a scheduler or external runner. Polling latency is the interval, and every tick costs an agent invocation even when nothing changed.
- Logs of CI systems other than GitHub Actions may be unreachable from the terminal; the skill then reproduces the failure locally.
- The status reads the first 100 review threads, 100 reviews and 100 conversation comments, and shows 600 characters per comment.
- GitHub only, through `gh`.
- No "merge when ready". Ask for the merge explicitly when you want it.
