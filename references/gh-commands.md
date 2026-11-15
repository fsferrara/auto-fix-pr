# gh commands behind auto-fix-pr

Manual equivalents of `scripts/pr_status.sh`, plus every write the skill performs. Replace `<owner>`, `<repo>`, `<n>` (PR number) and the ids the status output prints. On GitHub Enterprise add `--hostname <host>` to `gh api` calls; `gh pr ...` commands infer the host from the repository.

## Read

| Need | Command |
|---|---|
| PR header, mergeability, checks | `gh pr view <n> --json number,url,title,state,isDraft,author,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup` |
| Checks, one line each | `gh pr checks <n>` (add `--watch --fail-fast` only for a one-off manual run, never inside a loop) |
| Which job failed | `gh run view <run-id> --json jobs --jq '.jobs[] \| select(.conclusion=="failure") \| .name'` |
| Failed step logs | `gh run view <run-id> --log-failed \| tail -n 200` |
| Review threads with resolution state | GraphQL query below |
| Reviews (approve / request changes / comment) | `gh api repos/<owner>/<repo>/pulls/<n>/reviews?per_page=100` |
| Conversation comments | `gh api repos/<owner>/<repo>/issues/<n>/comments?per_page=100` |
| Full body of one review comment | `gh api repos/<owner>/<repo>/pulls/comments/<comment-id> --jq .body` |
| Your own login (to skip your comments) | `gh api user --jq .login` |
| Your open PRs | `gh pr list --author @me --state open --json number,title,url,mergeable,statusCheckRollup` |

Review threads, with `isResolved` and the ids the skill needs (`databaseId` of the first comment is `reply-to`, `id` is `thread-id`):

```
gh api graphql -F owner=<owner> -F name=<repo> -F number=<n> -f query='
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){ pullRequest(number:$number){
    reviewThreads(first:100){ nodes{
      id isResolved isOutdated path line
      comments(first:50){ nodes{ databaseId url createdAt body author{login __typename} } }
    } }
  } }
}'
```

## Write

| Action | Command |
|---|---|
| Reply inside a review thread | `gh api repos/<owner>/<repo>/pulls/<n>/comments/<reply-to>/replies -f body='Done in <sha>: <one line>.'` |
| Conversation comment | `gh pr comment <n> --body '<text>'` |
| Resolve a thread (only when the repository expects the author to) | `gh api graphql -F id=<thread-id> -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }'` |
| Re-run only the failed jobs, once per head | `gh run rerun <run-id> --failed` |
| Bring the branch up to date when there are no conflicts | `gh pr update-branch <n>` |
| Check the PR branch out locally | `gh pr checkout <n>` |
| Push | `git push` (after a convention-required rebase only: `git push --force-with-lease`) |

## State store

Set `SKILL_DIR` to the resolved absolute directory containing this skill's `SKILL.md`, as described in section 2 of the skill. Run these commands from the target repository.

```
sh "${SKILL_DIR}/scripts/pr_status.sh" state get   <n>
sh "${SKILL_DIR}/scripts/pr_status.sh" state set   <n> last_comment_ts 2026-01-31T12:00:00Z
sh "${SKILL_DIR}/scripts/pr_status.sh" state set   <n> ci_attempts 1
sh "${SKILL_DIR}/scripts/pr_status.sh" state reset <n>
```

Keys: `last_comment_ts` (comments at or before this time were handled), `last_ci_sha` (head the last CI fix was pushed for), `ci_attempts` (consecutive fix pushes without a green run), `last_rerun_sha` (head whose failed jobs were already re-run).
