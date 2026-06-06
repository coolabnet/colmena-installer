#!/usr/bin/env bash
# Stage 05 -- clone: ensure all required repos are present and on the right branch
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

# HTTPS support for droplets / CI without SSH keys.
# Set COLMENA_CLONE_PROTO=https to clone via https:// URLs instead of git@.
# Override individual repo URLs via COLMENA_*_URL env vars (see above).
COLMENA_CLONE_PROTO="${COLMENA_CLONE_PROTO:-ssh}"

# Convert ssh URL -> https URL when requested. Idempotent on already-https URLs.
_ssh_to_https() {
  local url="$1"
  # git@host:owner/repo.git  ->  https://host/owner/repo.git
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    echo "https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "$url"
  fi
}

if [[ "$COLMENA_CLONE_PROTO" == "https" ]]; then
  BACKEND_URL="$(_ssh_to_https "$BACKEND_URL")"
  FRONTEND_URL="$(_ssh_to_https "$FRONTEND_URL")"
  DEVOPS_URL="$(_ssh_to_https "$DEVOPS_URL")"
  OS_URL="$(_ssh_to_https "$OS_URL")"
fi

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
if [[ -n "$SSH_BIN" ]]; then
  ok "ssh at $SSH_BIN"
else
  if [[ "$COLMENA_CLONE_PROTO" == "ssh" ]]; then
    fail "ssh not found in PATH (needed for git@ URLs); set COLMENA_CLONE_PROTO=https"
    exit 1
  else
    warn "ssh missing; COLMENA_CLONE_PROTO=https so it's not required"
  fi
fi

# ── Helper: clone or verify a repo ───────────────────────────────────────────
ensure_repo() {
  local name="$1"
  local dir="$2"
  local url="$3"
  local branch="$4"

  if [[ -d "$dir/.git" ]]; then
    # Repo exists -- fetch and checkout the target branch
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
        # Branch might not exist on origin -- try fetching all and checking out
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
    # Repo missing -- clone it. Try the configured protocol first, then fall back.
    step "Clone $name from $url ($branch)"
    if _clone_with_fallback "$name" "$url" "$dir" "$branch"; then
      ok "$name cloned via $url"
    else
      fail "$name: clone failed from $url (and fallback URL)"
      return 1
    fi
  fi
}

# Clone a repo, trying the configured protocol first and the other protocol as a
# last-ditch fallback. Honors COLMENA_CLONE_PROTO for the "primary" choice.
# Args: <name> <primary_url> <dir> <branch>
_clone_with_fallback() {
  local name="$1"
  local primary_url="$2"
  local dir="$3"
  local branch="$4"

  # Build the ordered list of URLs to try
  local -a urls
  urls=("$primary_url")
  local alt
  if [[ "$COLMENA_CLONE_PROTO" == "https" ]]; then
    alt="$(_https_to_ssh "$primary_url")"
  else
    alt="$(_ssh_to_https "$primary_url")"
  fi
  [[ -n "$alt" && "$alt" != "$primary_url" ]] && urls+=("$alt")

  for u in "${urls[@]}"; do
    if git clone --branch "$branch" "$u" "$dir" 2>/dev/null; then
      info "(cloned from $u)"
      return 0
    fi
    # Branch missing on the primary ref -- clone default then try to checkout
    if git clone "$u" "$dir" 2>/dev/null; then
      if git -C "$dir" checkout "$branch" 2>/dev/null; then
        info "(cloned from $u, then checked out $branch)"
        return 0
      fi
      warn "$name cloned from $u but $branch not found (on $(git -C "$dir" rev-parse --abbrev-ref HEAD))"
      quirk "branch-missing" "$name: $branch not found after clone from $u"
      return 0
    fi
    warn "clone attempt failed: $u"
  done
  return 1
}

# Convert https URL -> ssh URL. Returns empty on non-convertible URLs.
_https_to_ssh() {
  local url="$1"
  # https://host/owner/repo.git  ->  git@host:owner/repo.git
  if [[ "$url" =~ ^https?://([^/]+)/(.+)$ ]]; then
    echo "git@${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  else
    echo ""
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
