#!/usr/bin/env bash
# Stage 05 — clone: ensure all required repos are present and on the right branch
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="clone"

stage 05 "Ensure repos are present"

# ── Repo definitions ─────────────────────────────────────────────────────────
# Each repo: FOLDER | GIT_URL | BRANCH
# Defaults point to the fork (luandro/*) where the fix branches live.
# Override to upstream origin if your branches are merged:
#   COLMENA_BACKEND_URL=git@gitlab.com:colmena-project/dev/backend.git
#   COLMENA_FRONTEND_URL=git@gitlab.com:colmena-project/dev/frontend.git
#   COLMENA_DEVOPS_URL=git@gitlab.com:colmena-project/dev/colmena-devops.git
#   COLMENA_OS_URL=git@github.com:luandro/colmena-os.git
# Override branch names:
#   COLMENA_BACKEND_BRANCH, COLMENA_FRONTEND_BRANCH, COLMENA_DEVOPS_BRANCH, COLMENA_OS_BRANCH

BACKEND_URL="${COLMENA_BACKEND_URL:-git@gitlab.com:luandro/backend.git}"
BACKEND_BRANCH="${COLMENA_BACKEND_BRANCH:-fix/nextcloud-graceful-degradation}"

FRONTEND_URL="${COLMENA_FRONTEND_URL:-git@gitlab.com:luandro/frontend.git}"
FRONTEND_BRANCH="${COLMENA_FRONTEND_BRANCH:-fix/ui-chat-nav-hardening}"

DEVOPS_URL="${COLMENA_DEVOPS_URL:-git@gitlab.com:luandro/colmena-devops.git}"
DEVOPS_BRANCH="${COLMENA_DEVOPS_BRANCH:-fix/nextcloud-docker-volume-build}"

OS_URL="${COLMENA_OS_URL:-git@github.com:luandro/colmena-os.git}"
OS_BRANCH="${COLMENA_OS_BRANCH:-main}"

declare -A REPOS=(
  [backend]="$BACKEND_DIR|$BACKEND_URL|$BACKEND_BRANCH"
  [frontend]="$FRONTEND_DIR|$FRONTEND_URL|$FRONTEND_BRANCH"
  [colmena-devops]="$DEVOPS_DIR|$DEVOPS_URL|$DEVOPS_BRANCH"
  [colmena-os]="$COLMENA_OS_DIR|$OS_URL|$OS_BRANCH"
)

step "Check git"
GIT_BIN=$(command -v git || true)
[[ -n "$GIT_BIN" ]] || { fail "git not found in PATH"; exit 1; }
ok "git at $GIT_BIN ($(git --version 2>&1))"

step "Check ssh"
SSH_BIN=$(command -v ssh || true)
[[ -n "$SSH_BIN" ]] || { fail "ssh not found in PATH (needed for git@gitlab.com URLs)"; exit 1; }
ok "ssh at $SSH_BIN"

# ── Helper: clone or verify a repo ───────────────────────────────────────────
ensure_repo() {
  local name="$1"
  local dir="$2"
  local url="$3"
  local branch="$4"

  if [[ -d "$dir/.git" ]]; then
    # Repo exists — fetch and checkout the target branch
    local current_branch
    current_branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

    if [[ "$current_branch" == "$branch" ]]; then
      ok "$name already on $branch"
    else
      step "Switch $name to $branch"
      if git -C "$dir" fetch origin "$branch" 2>/dev/null && \
         git -C "$dir" checkout "$branch" 2>/dev/null; then
        ok "$name switched to $branch"
      else
        # Branch might not exist on origin — try fetching all and checking out
        if git -C "$dir" fetch --all 2>/dev/null && \
           git -C "$dir" checkout "$branch" 2>/dev/null; then
          ok "$name switched to $branch (from remote)"
        else
          warn "$name: could not switch to $branch (staying on $current_branch)"
          quirk "branch-mismatch" "$name: wanted $branch, staying on $current_branch"
        fi
      fi
    fi
  else
    # Repo missing — clone it
    step "Clone $name from $url ($branch)"
    if git clone --branch "$branch" "$url" "$dir" 2>/dev/null; then
      ok "$name cloned ($branch)"
    else
      # Target branch might not exist on origin — clone default then checkout
      if git clone "$url" "$dir" 2>/dev/null; then
        if git -C "$dir" checkout "$branch" 2>/dev/null; then
          ok "$name cloned and switched to $branch"
        else
          warn "$name cloned but $branch not found (on $(git -C "$dir" rev-parse --abbrev-ref HEAD))"
          quirk "branch-missing" "$name: $branch not found after clone"
        fi
      else
        fail "$name: clone failed from $url"
        return 1
      fi
    fi
  fi
}

# ── Ensure each repo ─────────────────────────────────────────────────────────
CLONE_FAIL=0
for name in backend frontend colmena-devops colmena-os; do
  IFS='|' read -r dir url branch <<< "${REPOS[$name]}"
  if ! ensure_repo "$name" "$dir" "$url" "$branch"; then
    CLONE_FAIL=$((CLONE_FAIL + 1))
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
if [[ $CLONE_FAIL -gt 0 ]]; then
  fail "$CLONE_FAIL repo(s) could not be prepared"
  finish_stage
  exit 1
fi

step "Verify folder structure"
for name in backend frontend colmena-devops colmena-os; do
  IFS='|' read -r dir _ _ <<< "${REPOS[$name]}"
  if [[ -d "$dir" ]]; then
    ok "$name/ present"
  else
    fail "$name/ missing"
    CLONE_FAIL=$((CLONE_FAIL + 1))
  fi
done

[[ $CLONE_FAIL -eq 0 ]]
finish_stage
