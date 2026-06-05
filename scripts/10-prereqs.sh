#!/usr/bin/env bash
# Stage 10 — prereqs: Python 3.10 via pyenv, Node via nvm
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
STAGE_NAME="prereqs"

stage 10 "Verify prereqs"

step "Check pyenv"
if [[ -x /home/luandro/.pyenv/bin/pyenv ]]; then
  ok "pyenv at /home/luandro/.pyenv/bin/pyenv"
else
  fail "pyenv missing at /home/luandro/.pyenv/bin/pyenv"
  exit 1
fi

step "Check Python 3.10.0"
if /home/luandro/.pyenv/bin/pyenv versions --bare 2>/dev/null | grep -q '^3\.10\.0$'; then
  ok "pyenv 3.10.0 installed"
else
  fail "pyenv 3.10.0 not installed"
  exit 1
fi
PY310=/home/luandro/.pyenv/shims/python3.10
[[ -x "$PY310" ]] || { fail "no shim for python3.10"; exit 1; }
ok "python3.10 -> $($PY310 -V 2>&1)"

step "Check node"
NODE_BIN=$(command -v node || true)
if [[ -n "$NODE_BIN" ]]; then
  ok "node at $NODE_BIN ($($NODE_BIN -v))"
else
  fail "node missing"
  exit 1
fi

step "Check npm"
NPM_BIN=$(command -v npm || true)
[[ -n "$NPM_BIN" ]] || { fail "npm missing"; exit 1; }
ok "npm at $NPM_BIN ($($NPM_BIN -v))"

step "Check docker"
DOCKER_BIN=$(command -v docker || true)
[[ -n "$DOCKER_BIN" ]] || { fail "docker missing"; exit 1; }
ok "docker at $DOCKER_BIN ($($DOCKER_BIN -v 2>&1 | head -1))"
if $DOCKER_BIN info 2>/dev/null | grep -q 'rootless: true'; then
  warn "rootless Docker detected — Nextcloud will be blocked by UID mapping"
  quirk "rootless-docker" "Nextcloud data dir will fail with permission denied; see REPORT.md"
fi

step "Check docker compose"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose available ($(docker compose version --short 2>/dev/null))"
else
  fail "docker compose missing (modern 'docker compose' v2 plugin required)"
  exit 1
fi

step "Check browser-harness"
BH=$(command -v browser-harness || true)
[[ -n "$BH" ]] || { fail "browser-harness missing"; exit 1; }
ok "browser-harness at $BH"

step "Check playwright"
PW=$(command -v playwright || true)
[[ -n "$PW" ]] || { fail "playwright missing"; exit 1; }
ok "playwright at $PW (version: $($PW --version 2>&1))"

finish_stage
