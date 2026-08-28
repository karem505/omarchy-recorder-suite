#!/usr/bin/env bash
# Deployer for omarchy-recorder-suite, shaped after the wardiya deploy
# function: a fixed menu of recipes — no free-form shell — and dry-run as
# the default for the one step that changes anything. Want a new step?
# It gets written here by hand.
#
#   ./deploy.sh status   what's installed vs what's on GitHub
#   ./deploy.sh pull     fetch + preview incoming commits (read-only)
#   ./deploy.sh deploy   fast-forward to origin/master and re-run install.sh
#   ./deploy.sh logs     last 60 recorder-related lines from the user journal
#
# DRY_RUN=true is the default: `deploy` prints the exact commands instead
# of running them. Flip it explicitly:  DRY_RUN=false ./deploy.sh deploy
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE="origin"
BRANCH="master"
STATE_DIR="${RECORDER_SUITE_STATE_DIR:-$HOME/.local/state/omarchy-recorder-suite}"
STATE_FILE="$STATE_DIR/deployed"
FETCH_TIMEOUT=60

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }

# Anything but an explicit "false" stays in dry-run.
dry_run() { local v="${DRY_RUN:-true}"; [[ "${v,,}" != "false" ]]; }

# Commits that look experimental get flagged — a warning, not a decision.
SUSPECT='(^|[^a-z])(wip|experiment|spike|tmp|revert me|do ?not ?deploy|تجريبي)([^a-z]|$)'

fetch()    { timeout "$FETCH_TIMEOUT" git -C "$HERE" fetch "$REMOTE" --quiet; }
incoming() { git -C "$HERE" log --oneline "HEAD..$REMOTE/$BRANCH"; }
head_sha() { git -C "$HERE" rev-parse --short HEAD; }

warn_suspects() {
  local sus
  sus="$(incoming | grep -iE "$SUSPECT" || true)"
  if [[ -n "$sus" ]]; then
    warn "These incoming commits look experimental:"
    printf '  %s\n' "$sus"
  fi
}

recipe_status() {
  say "Repo:      $(head_sha) on $(git -C "$HERE" rev-parse --abbrev-ref HEAD)"
  if [[ -n "$(git -C "$HERE" status --porcelain)" ]]; then
    warn "Working tree has local changes."
  fi
  if [[ -f "$STATE_FILE" ]]; then
    say "Deployed:  $(<"$STATE_FILE")"
  else
    say "Deployed:  no marker yet (first deploy.sh run will write one)"
  fi
  if ! fetch; then
    warn "Could not reach $REMOTE — showing local state only."
    return 0
  fi
  local behind ahead
  behind="$(git -C "$HERE" rev-list --count "HEAD..$REMOTE/$BRANCH")"
  ahead="$(git -C "$HERE" rev-list --count "$REMOTE/$BRANCH..HEAD")"
  say "Remote:    $behind behind, $ahead ahead of $REMOTE/$BRANCH"
  if [[ "$behind" -gt 0 ]]; then
    incoming | head -6 | sed 's/^/  /'
    warn_suspects
  fi
}

recipe_pull() {
  fetch || die "Could not reach $REMOTE"
  local n
  n="$(git -C "$HERE" rev-list --count "HEAD..$REMOTE/$BRANCH")"
  if [[ "$n" -eq 0 ]]; then
    say "Up to date with $REMOTE/$BRANCH — nothing incoming."
    return 0
  fi
  say "$n incoming commit(s) on $REMOTE/$BRANCH:"
  incoming | sed 's/^/  /'
  warn_suspects
  say "Nothing was changed. Run ./deploy.sh deploy to take them."
}

recipe_deploy() {
  if [[ -n "$(git -C "$HERE" status --porcelain)" ]]; then
    die "Refusing to deploy: working tree has local changes."
  fi
  fetch || die "Could not reach $REMOTE"
  warn_suspects
  if dry_run; then
    say "DRY_RUN is on — would run:"
    echo "  git -C $HERE merge --ff-only $REMOTE/$BRANCH"
    echo "  $HERE/install.sh"
    echo "  echo '<sha> <date>' > $STATE_FILE"
    echo "Run it for real:  DRY_RUN=false ./deploy.sh deploy"
    return 0
  fi
  git -C "$HERE" merge --ff-only "$REMOTE/$BRANCH" ||
    die "Not a fast-forward — the branch has diverged; merge by hand."
  "$HERE/install.sh"
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(head_sha)" "$(date -Iseconds)" >"$STATE_FILE"
  say "Deployed $(head_sha)."
}

recipe_logs() {
  journalctl --user --no-pager -n 60 -t quickshell -t gpu-screen-recorder 2>/dev/null |
    tail -60 || warn "No user journal available."
}

case "${1:-status}" in
  status) recipe_status ;;
  pull)   recipe_pull ;;
  deploy) recipe_deploy ;;
  logs)   recipe_logs ;;
  *) die "Unknown recipe: $1 (recipes: status pull deploy logs)" ;;
esac
