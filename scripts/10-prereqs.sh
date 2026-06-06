#!/usr/bin/env bash
# Stage 10 — prereqs: verify (or install) pyenv/Python 3.10, Node 20.x, Docker, Playwright
#
# Flags (env):
#   INSTALL_MISSING=1 — when set, installs missing pyenv/Python and Node from package managers
#                       (idempotent; safe to re-run). Used by cloud-init's background stack job.
#   SKIP_DEV_TOOLS=1  — skip browser-harness + global playwright checks (droplet has no browser)
#   STACK_MODE=droplet — informational; affects logging only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="prereqs"

INSTALL_MISSING="${INSTALL_MISSING:-0}"
SKIP_DEV_TOOLS="${SKIP_DEV_TOOLS:-0}"
STACK_MODE="${STACK_MODE:-local}"

stage 10 "Verify (or install) prereqs (mode=$STACK_MODE, install=$INSTALL_MISSING, skip_dev_tools=$SKIP_DEV_TOOLS)"

# Helper: detect the OS package manager once
_detect_pkg() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  else echo none
  fi
}
PKG_MGR=$(_detect_pkg)

# ── pyenv ────────────────────────────────────────────────────────────────────
step "Check pyenv"
PYENV_BIN="$HOME/.pyenv/bin/pyenv"
if [[ -x "$PYENV_BIN" ]]; then
  ok "pyenv at $PYENV_BIN"
else
  if [[ "$INSTALL_MISSING" == "1" && "$PKG_MGR" == "apt" ]]; then
    step "Install pyenv (cloning from GitHub)"
    if [[ ! -d "$HOME/.pyenv" ]]; then
      git clone --depth=1 https://github.com/pyenv/pyenv.git "$HOME/.pyenv" >>"$PREREQ_LOG" 2>&1
    fi
    # Persist pyenv on PATH for this process and any child stages.
    export PATH="$HOME/.pyenv/bin:$HOME/.pyenv/shims:$PATH"
    PYENV_BIN="$HOME/.pyenv/bin/pyenv"
    if [[ -x "$PYENV_BIN" ]]; then
      ok "pyenv installed at $PYENV_BIN"
    else
      fail "pyenv install failed; see $PREREQ_LOG"
      exit 1
    fi
  else
    fail "pyenv missing at $PYENV_BIN (re-run with INSTALL_MISSING=1)"
    exit 1
  fi
fi

# ── Python 3.10.0 (built by pyenv) ───────────────────────────────────────────
step "Check Python 3.10.0"
PY310_SHIM="$HOME/.pyenv/shims/python3.10"
if [[ -x "$PY310_SHIM" ]] || $PYENV_BIN versions --bare 2>/dev/null | grep -q '^3\.10\.0$'; then
  ok "pyenv 3.10.0 installed"
else
  if [[ "$INSTALL_MISSING" == "1" && "$PKG_MGR" == "apt" ]]; then
    step "Install Python 3.10.0 via pyenv (compiles ~3 min)"
    if [[ "$PKG_MGR" == "apt" ]]; then
      # Build dependencies for cpython on Ubuntu/Debian. Idempotent.
      sudo -n apt-get update -y >>"$PREREQ_LOG" 2>&1 || true
      sudo -n apt-get install -y --no-install-recommends \
        build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
        libsqlite3-dev libffi-dev liblzma-dev ca-certificates \
        >>"$PREREQ_LOG" 2>&1 || true
    fi
    $PYENV_BIN install 3.10.0 >>"$PREREQ_LOG" 2>&1
    if $PYENV_BIN versions --bare 2>/dev/null | grep -q '^3\.10\.0$'; then
      ok "pyenv 3.10.0 built"
    else
      fail "pyenv 3.10.0 build failed; see $PREREQ_LOG"
      exit 1
    fi
  else
    fail "Python 3.10.0 not installed (re-run with INSTALL_MISSING=1)"
    exit 1
  fi
fi
[[ -x "$PY310_SHIM" ]] || { fail "no shim for python3.10"; exit 1; }
ok "python3.10 -> $($PY310_SHIM -V 2>&1)"

# ── Node 20.x ────────────────────────────────────────────────────────────────
step "Check node"
NODE_BIN=$(command -v node || true)
if [[ -n "$NODE_BIN" ]]; then
  ok "node at $NODE_BIN ($($NODE_BIN -v))"
else
  if [[ "$INSTALL_MISSING" == "1" && "$PKG_MGR" == "apt" ]]; then
    step "Install Node 20.x via NodeSource (idempotent)"
    if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -n bash - >>"$PREREQ_LOG" 2>&1
    fi
    sudo -n apt-get install -y --no-install-recommends nodejs >>"$PREREQ_LOG" 2>&1
    NODE_BIN=$(command -v node || true)
    [[ -n "$NODE_BIN" ]] || { fail "node install failed; see $PREREQ_LOG"; exit 1; }
    ok "node installed at $NODE_BIN ($($NODE_BIN -v))"
  else
    fail "node missing (re-run with INSTALL_MISSING=1)"
    exit 1
  fi
fi

step "Check npm"
NPM_BIN=$(command -v npm || true)
[[ -n "$NPM_BIN" ]] || { fail "npm missing"; exit 1; }
ok "npm at $NPM_BIN ($($NPM_BIN -v))"

# ── Docker (must be pre-installed by cloud-init; we only verify) ──────────────
step "Check docker"
DOCKER_BIN=$(command -v docker || true)
if [[ -n "$DOCKER_BIN" ]]; then
  ok "docker at $DOCKER_BIN ($($DOCKER_BIN -v 2>&1 | head -1))"
  if $DOCKER_BIN info 2>/dev/null | grep -q 'rootless: true'; then
    warn "rootless Docker detected — Nextcloud will be blocked by UID mapping"
    quirk "rootless-docker" "Nextcloud data dir will fail with permission denied; see REPORT.md"
  fi
else
  fail "docker missing (must be pre-installed by cloud-init or host package manager)"
  exit 1
fi

step "Check docker compose"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose available ($(docker compose version --short 2>/dev/null))"
else
  fail "docker compose missing (modern 'docker compose' v2 plugin required)"
  exit 1
fi

# ── Dev tools (skip on droplet) ──────────────────────────────────────────────
if [[ "$SKIP_DEV_TOOLS" == "1" ]]; then
  skip "browser-harness (SKIP_DEV_TOOLS=1)"
  skip "playwright CLI (SKIP_DEV_TOOLS=1)"
else
  step "Check browser-harness"
  BH=$(command -v browser-harness || true)
  [[ -n "$BH" ]] || { fail "browser-harness missing"; exit 1; }
  ok "browser-harness at $BH"

  step "Check playwright"
  PW=$(command -v playwright || true)
  [[ -n "$PW" ]] || { fail "playwright missing"; exit 1; }
  ok "playwright at $PW (version: $($PW --version 2>&1))"
fi

finish_stage
