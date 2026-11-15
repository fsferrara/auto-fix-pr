#!/bin/sh
# pr_status.sh - one-call status report for a GitHub pull request, plus a tiny state store.
#
# Usage:
#   pr_status.sh status [<pr-number>|<pr-url>|<branch>] [--repo <owner/repo>] [--since <iso8601>]
#   pr_status.sh mine [--repo <owner/repo>]
#   pr_status.sh state get   <pr-number>
#   pr_status.sh state set   <pr-number> <key> <value>
#   pr_status.sh state reset <pr-number>
#
# Needs: gh (authenticated), git. POSIX sh. No jq binary: filtering uses gh's built-in --jq.
# Works with github.com and GitHub Enterprise (the host is taken from the PR URL).
#
# State: <git common dir>/auto-fix-pr/<pr-number>.env (never committed), or
#        $AUTO_FIX_PR_STATE_DIR when set, or ${XDG_STATE_HOME:-$HOME/.local/state}/auto-fix-pr
#        when not inside a git repository.
# Keys used by the skill: last_comment_ts, last_ci_sha, ci_attempts, last_rerun_sha.
#
# Limits: first 100 review threads (50 comments each), first 100 reviews and 100 conversation
# comments. Comment bodies are cut at 600 characters; fetch the full text with gh api if needed.

set -eu

die() { printf 'pr_status: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- state store

state_dir() {
  if [ -n "${AUTO_FIX_PR_STATE_DIR:-}" ]; then
    printf '%s\n' "$AUTO_FIX_PR_STATE_DIR"; return
  fi
  if d=$(git rev-parse --git-common-dir 2>/dev/null); then
    case $d in /*) ;; *) d="$PWD/$d" ;; esac
    printf '%s/auto-fix-pr\n' "$d"; return
  fi
  printf '%s/auto-fix-pr\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

state_file() { printf '%s/%s.env\n' "$(state_dir)" "$1"; }

state_get() {
  f=$(state_file "$1")
  if [ -f "$f" ]; then cat "$f"; fi
}

state_value() { # <pr> <key>
  state_get "$1" | sed -n "s/^$2=//p" | tail -n 1
}

state_set() { # <pr> <key> <value>
  case $2 in *[!A-Za-z0-9_]*|'') die "state key must be [A-Za-z0-9_]+" ;; esac
  f=$(state_file "$1"); mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  {
    if [ -f "$f" ]; then grep -v "^$2=" "$f" || true; fi
    printf '%s=%s\n' "$2" "$3"
  } > "$tmp"
  mv "$tmp" "$f"
}

state_reset() { rm -f "$(state_file "$1")"; }

cmd_state() {
  [ $# -ge 2 ] || die "usage: state get|set|reset <pr-number> [key value]"
  case $1 in
    get)   state_get "$2" ;;
    set)   [ $# -eq 4 ] || die "usage: state set <pr-number> <key> <value>"; state_set "$2" "$3" "$4" ;;
    reset) state_reset "$2" ;;
    *)     die "unknown state command: $1" ;;
  esac
}

# ---------------------------------------------------------------- jq filters

# Shared check normalisation. statusCheckRollup mixes CheckRun (GitHub Actions and apps)
# and StatusContext (external CI) objects.
CHECK_DEFS='
def norm: {
  name: (.name // .context // "?"),
  result: (if .__typename == "CheckRun"
             then (if .status != "COMPLETED" then "PENDING" else (.conclusion // "PENDING") end)
             else (.state // "PENDING") end),
  url: (.detailsUrl // .targetUrl // ""),
  workflow: (.workflowName // "")
};
def cat: .result as $r
  | if any(("FAILURE","ERROR","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","CANCELLED"); . == $r) then "FAIL"
    elif any(("SUCCESS","NEUTRAL","SKIPPED"); . == $r) then "PASS"
    else "PENDING" end;
def runid: ([.url | capture("/actions/runs/(?<id>[0-9]+)")?.id] | .[0] // "");
def checks: [.statusCheckRollup[]? | norm | . + {cat: cat, run: runid}];
def nfail: [checks[] | select(.cat == "FAIL")] | length;
def npend: [checks[] | select(.cat == "PENDING")] | length;
def npass: [checks[] | select(.cat == "PASS")] | length;
def rd: if (.reviewDecision // "") == "" then "NONE" else .reviewDecision end;
'

VIEW_JQ="$CHECK_DEFS"'
"@@\t\(.number)\t\(.url)\t\(.headRefOid)\t\(.headRefName)\t\(.baseRefName)\t\(.author.login // "")",
"PR #\(.number) \(.url)",
"title: \(.title)",
"state: \(.state)  draft: \(.isDraft)  author: \(.author.login // "?")",
"branch: \(.headRefName) -> \(.baseRefName)  head: \(.headRefOid[0:10])",
"mergeable: \(.mergeable)  mergeState: \(.mergeStateStatus)  reviewDecision: \(rd)",
"",
"CHECKS: \(nfail) failing, \(npend) pending, \(npass) passing",
(checks[] | select(.cat != "PASS")
  | "  \(.cat)\t\(.name)\(if .workflow != "" then " [\(.workflow)]" else "" end)\(if .run != "" then "  run=\(.run)" else "" end)  \(.url)")
'

MINE_JQ="$CHECK_DEFS"'
if length == 0 then "(no open pull requests authored by you in this repository)"
else .[] | "#\(.number)\tfailing=\(nfail) pending=\(npend)\tmergeable=\(.mergeable)\treview=\(rd)\tdraft=\(.isDraft)\t\(.headRefName)\t\(.url)\t\(.title)"
end
'

THREADS_QUERY='query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){ pullRequest(number:$number){
    reviewThreads(first:100){ nodes{
      id isResolved isOutdated path line
      comments(first:50){ nodes{ databaseId url createdAt body author{login __typename} } }
    } }
  } }
}'

# __VIEWER__ and __SINCE__ are substituted with sanitised values before use.
THREADS_JQ='
.data.repository.pullRequest.reviewThreads.nodes[]
| select(any(.comments.nodes[]; ((.author.login // "") != "__VIEWER__") and (.createdAt > "__SINCE__")))
| select(("__SINCE__" != "") or (.isResolved | not))
| "[thread] \(.path):\(.line // "?")  resolved=\(.isResolved)  outdated=\(.isOutdated)  reply-to=\(.comments.nodes[0].databaseId)  thread-id=\(.id)",
  (.comments.nodes[]
    | "  \(if ((.author.login // "") != "__VIEWER__") and (.createdAt > "__SINCE__") then "NEW" else "   " end) \(.createdAt) \(.author.login // "ghost")\(if .author.__typename == "Bot" then " [bot]" else "" end): \(.body | gsub("\r?\n"; " / ") | .[0:600])"),
  ""
'

REVIEWS_JQ='
.[] | select(((.user.login // "") != "__VIEWER__") and ((.submitted_at // "") > "__SINCE__")
             and (((.body // "") != "") or (.state == "CHANGES_REQUESTED")))
| "[review] \(.submitted_at) \(.user.login // "ghost")\(if .user.type == "Bot" then " [bot]" else "" end) \(.state) id=\(.id): \((.body // "") | gsub("\r?\n"; " / ") | .[0:600])"
'

COMMENTS_JQ='
.[] | select(((.user.login // "") != "__VIEWER__") and ((.created_at // "") > "__SINCE__"))
| "[comment] \(.created_at) \(.user.login // "ghost")\(if .user.type == "Bot" then " [bot]" else "" end) id=\(.id): \((.body // "") | gsub("\r?\n"; " / ") | .[0:600])"
'

subst() { # <filter> <viewer> <since>
  printf '%s' "$1" | sed "s/__VIEWER__/$2/g; s/__SINCE__/$3/g"
}

# ---------------------------------------------------------------- commands

PR_FIELDS='number,url,title,state,isDraft,author,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup'

cmd_status() {
  target=""; since_override=""; repo_opt=""
  while [ $# -gt 0 ]; do
    case $1 in
      --since)   since_override=${2:-}; shift ;;
      --since=*) since_override=${1#--since=} ;;
      --repo|-R) repo_opt=${2:-}; shift ;;
      --repo=*)  repo_opt=${1#--repo=} ;;
      -*)        die "unknown option: $1" ;;
      *)         target=$1 ;;
    esac
    shift
  done

  set -- --json "$PR_FIELDS" --jq "$VIEW_JQ"
  [ -n "$repo_opt" ] && set -- -R "$repo_opt" "$@"
  if [ -n "$target" ]; then
    out=$(gh pr view "$target" "$@" 2>&1) || die "cannot read PR '$target': $out"
  else
    out=$(gh pr view "$@" 2>&1) || die "no pull request for the current branch (pass a PR number, URL or branch): $out"
  fi

  meta=$(printf '%s\n' "$out" | sed -n '1p')
  printf '%s\n' "$out" | sed '1d'

  number=$(printf '%s' "$meta" | cut -f2)
  url=$(printf '%s' "$meta" | cut -f3)
  head_sha=$(printf '%s' "$meta" | cut -f4)
  head_ref=$(printf '%s' "$meta" | cut -f5)

  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/.*#\1#')
  owner=$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1#')
  repo=$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\2#')

  viewer=$(gh api --hostname "$host" user --jq .login 2>/dev/null || true)
  viewer=$(printf '%s' "$viewer" | tr -cd 'A-Za-z0-9_[]-')

  since=${since_override:-$(state_value "$number" last_comment_ts)}
  since=$(printf '%s' "$since" | tr -cd '0-9TZ:.-')

  printf '\nNEW COMMENTS by others'
  [ -n "$since" ] && printf ' since %s' "$since"
  [ -n "$viewer" ] && printf ' (viewer: %s)' "$viewer"
  printf ':\n'

  threads=$(gh api graphql --hostname "$host" -f query="$THREADS_QUERY" \
              -F owner="$owner" -F name="$repo" -F number="$number" \
              --jq "$(subst "$THREADS_JQ" "$viewer" "$since")" 2>&1) || threads="  (could not read review threads: $threads)"
  reviews=$(gh api --hostname "$host" "repos/$owner/$repo/pulls/$number/reviews?per_page=100" \
              --jq "$(subst "$REVIEWS_JQ" "$viewer" "$since")" 2>&1) || reviews="  (could not read reviews: $reviews)"
  comments=$(gh api --hostname "$host" "repos/$owner/$repo/issues/$number/comments?per_page=100" \
              --jq "$(subst "$COMMENTS_JQ" "$viewer" "$since")" 2>&1) || comments="  (could not read comments: $comments)"

  all=$(printf '%s\n%s\n%s\n' "$threads" "$reviews" "$comments" | sed '/^[[:space:]]*$/d')
  if [ -n "$all" ]; then printf '%s\n' "$all"; else printf '  (none)\n'; fi

  printf '\nLOCAL:\n'
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    lbranch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    lhead=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi
    if [ "$lbranch" = "$head_ref" ]; then on_branch=yes; else on_branch=no; fi
    if [ "$lhead" = "$head_sha" ]; then sync=yes; else sync=no; fi
    printf '  branch: %s (pr branch checked out: %s)  head: %.10s (matches pr head: %s)  dirty: %s\n' \
      "$lbranch" "$on_branch" "$lhead" "$sync" "$dirty"
    wt=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$head_ref" '/^worktree /{w=$2} /^branch /{if ($2 == b) print w}')
    [ -n "$wt" ] && printf '  worktree with pr branch: %s\n' "$wt"
  else
    printf '  not inside a git repository (clone or cd into the repository to make changes)\n'
  fi

  printf '\nSTATE (%s):\n' "$(state_file "$number")"
  s=$(state_get "$number")
  if [ -n "$s" ]; then printf '%s\n' "$s" | sed 's/^/  /'; else printf '  (none: first run for this PR)\n'; fi
  printf '  now=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

cmd_mine() {
  repo_opt=""
  while [ $# -gt 0 ]; do
    case $1 in
      --repo|-R) repo_opt=${2:-}; shift ;;
      --repo=*)  repo_opt=${1#--repo=} ;;
      *)         die "unknown option: $1" ;;
    esac
    shift
  done
  set -- --author @me --state open --limit 50 \
         --json number,url,title,isDraft,headRefName,mergeable,reviewDecision,statusCheckRollup --jq "$MINE_JQ"
  [ -n "$repo_opt" ] && set -- -R "$repo_opt" "$@"
  gh pr list "$@"
}

[ $# -ge 1 ] || die "usage: pr_status.sh status|mine|state ... (see header)"
cmd=$1; shift
case $cmd in
  status) cmd_status "$@" ;;
  mine)   cmd_mine "$@" ;;
  state)  cmd_state "$@" ;;
  -h|--help|help) sed -n '2,20p' "$0" ;;
  *)      die "unknown command: $cmd" ;;
esac
