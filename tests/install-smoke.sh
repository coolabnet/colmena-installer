#!/usr/bin/env bash
# tests/install-smoke.sh -- sandboxed smoke test for install.sh.
#
# Verifies install.sh's LOGIC end-to-end WITHOUT performing any real install.
# All mutating work happens inside disposable `docker run --rm` containers whose
# apt/system/curl/node tooling is SHIMMED, so the script runs deterministically.
# The real run-stack.sh is replaced by a stub that just prints its handoff env.
#
# What it checks:
#   * Host static: `bash -n install.sh`, `shellcheck -S error install.sh`.
#   * Docker gate: `docker run --rm hello-world`; SKIP (exit 0) if unavailable.
#   * Functional matrix x {ubuntu:22.04, debian:12}: 6 cases (production domain,
#     staging domain, IP, IP:port, bogus-TLS rejected, prod-without-email rejected).
#   * Stage-40 coupling: the catch-all handle block install.sh emits MUST match
#     scripts/40-frontend-up.sh's regex, or the prod frontend is never served.
#
# Re-runnable: --rm containers, no leftover host state. Exits non-zero on any FAIL.
#
# NOTE on stdin: install.sh's interactive `read`s differ per case, so each case
# gets targeted stdin instead of a blanket `yes |` -- `yes` would feed "y" into
# the staging email prompt (rejecting the blank it expects) and loop forever on
# the prod-without-email prompt. Per-case stdin:
#   case 1 (prod+email):    "y\n"        -> DNS "Continue anyway?" only
#   case 2 (staging):       "\ny\n"      -> blank email, then DNS "y"
#   case 3..6:              empty/EOF    -> IP has no reads; 5/6 die early

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO/install.sh"

IMAGES=(ubuntu:22.04 debian:12)

log() { printf '%s\n' "$*"; }
line() { printf '%s\n' "------------------------------------------------------------"; }

OVERALL=0

# ──────────────────────────────────────────────────────────────────────────────
# Host static checks
# ──────────────────────────────────────────────────────────────────────────────
log "HOST static checks"

if bash -n "$INSTALL_SH" >/tmp/smoke_bashn 2>&1; then
  log "HOST   bash -n            : PASS"
else
  log "HOST   bash -n            : FAIL"
  cat /tmp/smoke_bashn
  OVERALL=1
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$INSTALL_SH" >/tmp/smoke_sc 2>&1; then
    log "HOST   shellcheck -S error: PASS"
  else
    log "HOST   shellcheck -S error: FAIL"
    cat /tmp/smoke_sc
    OVERALL=1
  fi
else
  log "HOST   shellcheck -S error: SKIP (shellcheck not installed)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Docker gate -- if docker is unavailable, SKIP (exit 0), never install on host.
# ──────────────────────────────────────────────────────────────────────────────
log ""
log "Docker gate"
if ! docker run --rm hello-world >/tmp/smoke_hw 2>&1; then
  log "SKIP: docker unavailable (docker run --rm hello-world failed):"
  tail -5 /tmp/smoke_hw
  log "(No host install attempted. Exiting 0 per spec.)"
  exit 0
fi
log "docker OK"

# ──────────────────────────────────────────────────────────────────────────────
# Functional matrix: one disposable container per base image; inside it we run
# all 6 cases + the stage-40 regex check. The in-container script is delivered
# via stdin (`bash -s`); single-quoted heredoc delimiter => no host expansion,
# so every $ below is expanded by the container shell (not the host).
# ──────────────────────────────────────────────────────────────────────────────
for IMG in "${IMAGES[@]}"; do
  log ""
  line
  log "Running matrix in $IMG"
  line

  docker run --rm -i \
    -v "$REPO":/src:ro \
    -e IMG="$IMG" \
    "$IMG" bash -s >/tmp/smoke_img 2>&1 <<'CONTAINER'
set -u
IMG="${IMG:-unknown}"
WORK=/work
SRC=/src
FAKE="$WORK/fakebin"
CAD=/etc/caddy/Caddyfile
OUT=/tmp/install.out

echo "===== image: $IMG ====="

# ---- writable copy of install.sh + stubbed run-stack.sh as its sibling ----
mkdir -p "$WORK" /etc/caddy /usr/share/keyrings
cp "$SRC/install.sh" "$WORK/install.sh"
chmod +x "$WORK/install.sh"

cat > "$WORK/run-stack.sh" <<'STUB'
#!/usr/bin/env bash
echo "RUNSTACK_STUB_INVOKED arg=$1"
echo "ENV BACKEND_HOSTNAME=$BACKEND_HOSTNAME"
echo "ENV FRONTEND_HOSTNAME=$FRONTEND_HOSTNAME"
echo "ENV STACK_MODE=$STACK_MODE INSTALL_MISSING=$INSTALL_MISSING SKIP_DEV_TOOLS=$SKIP_DEV_TOOLS COLMENA_CLONE_PROTO=$COLMENA_CLONE_PROTO"
exit 0
STUB
chmod +x "$WORK/run-stack.sh"

# ---- fakebin shims: every binary install.sh invokes that could mutate system ----
mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/apt-get"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/gpg"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/git"
cat > "$FAKE/lsb_release" <<'LSB'
#!/usr/bin/env bash
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
  debian) echo bookworm ;;
  *) echo jammy ;;
esac
LSB
cat > "$FAKE/curl" <<'CURL'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *ipify*|*ifconfig.me*) echo "203.0.113.10"; exit 0 ;;
  esac
done
exit 0
CURL
cat > "$FAKE/node" <<'NODE'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then echo "v20.0.0"; fi
exit 0
NODE
chmod +x "$FAKE"/*

# Pre-create keyrings so install.sh's key-setup branches are skipped.
touch /usr/share/keyrings/docker-archive-keyring.gpg /usr/share/keyrings/caddy-stable-archive-keyring.gpg

# Per-case stdin (see file-header note).
printf 'y\n'   > /tmp/in1
printf '\ny\n' > /tmp/in2
: > /tmp/in_empty

EPATH="$FAKE:$PATH"

run_install() {  # $1=stdinfile  $2..=COLMENA VAR=VAL ; sets RC, writes $CAD/$OUT
  stdinfile="$1"; shift
  rm -f "$CAD"
  unset COLMENA_HOST COLMENA_EMAIL COLMENA_TLS
  for a in "$@"; do export "$a"; done
  PATH="$EPATH" /usr/bin/timeout 90 /bin/bash "$WORK/install.sh" <"$stdinfile" >"$OUT" 2>&1
  RC=$?
}

FAIL=0; REASON=""
reset() { FAIL=0; REASON=""; }
fail() { FAIL=1; REASON="${REASON}${1} | "; }
has() { grep -Fq -- "$2" "$1"; }   # has <file> <needle>

emit() {  # <testname>
  if [ "$FAIL" -eq 0 ]; then
    echo "$1 $IMG : PASS"
  else
    echo "$1 $IMG : FAIL [${REASON% | }]"
    if [ -f "$CAD" ]; then echo "----- Caddyfile ($1 $IMG) -----"; cat "$CAD"; echo "----- end Caddyfile -----"; fi
    if [ -f "$OUT" ]; then echo "----- install.sh tail ($1 $IMG) -----"; tail -25 "$OUT"; echo "----- end tail -----"; fi
  fi
}

# ---- CASE 1: production domain + email ----
reset
run_install /tmp/in1 COLMENA_HOST=colmena.example.com COLMENA_TLS=production COLMENA_EMAIL=ops@example.com
cp "$CAD" /tmp/cad1 2>/dev/null || cp /dev/null /tmp/cad1
{ [ "$RC" -eq 0 ] || fail "exit=$RC want0"; }
{ head -1 "$CAD" 2>/dev/null | grep -Fxq '{' || fail "no-global-block"; }
{ has "$CAD" "email ops@example.com" || fail "no-global-email"; }
{ has "$CAD" "colmena.example.com {" || fail "no-site-line"; }
{ has "$CAD" "handle /api/* {" || fail "no-api-handle"; }
{ has "$CAD" "reverse_proxy localhost:8000" || fail "no-api-proxy"; }
{ has "$CAD" "handle {" || fail "no-catchall-handle"; }
{ has "$CAD" "reverse_proxy localhost:5173" || fail "no-frontend-proxy"; }
{ has "$OUT" "RUNSTACK_STUB_INVOKED arg=droplet" || fail "stub-not-invoked"; }
{ has "$OUT" "BACKEND_HOSTNAME=colmena.example.com" || fail "no-BACKEND_HOSTNAME"; }
{ has "$OUT" "FRONTEND_HOSTNAME=colmena.example.com" || fail "no-FRONTEND_HOSTNAME"; }
{ has "$OUT" "STACK_MODE=droplet" || fail "no-STACK_MODE"; }
emit "CASE 1"

# ---- CASE 2: staging domain, no email ----
reset
run_install /tmp/in2 COLMENA_HOST=colmena.example.com COLMENA_TLS=staging
{ [ "$RC" -eq 0 ] || fail "exit=$RC want0"; }
{ head -1 "$CAD" 2>/dev/null | grep -Fxq '{' && fail "unexpected-global-block"; }
{ has "$CAD" "email " && fail "has-email-line"; }
{ has "$CAD" "colmena.example.com {" || fail "no-site-line"; }
{ has "$CAD" "acme-staging-v02.api.letsencrypt.org" || fail "no-staging-acme"; }
{ has "$CAD" "handle /api/* {" || fail "no-api-handle"; }
{ has "$CAD" "handle {" || fail "no-catchall-handle"; }
emit "CASE 2"

# ---- CASE 3: bare IP (internal TLS) ----
reset
run_install /tmp/in_empty COLMENA_HOST=203.0.113.10
cp "$CAD" /tmp/cad3 2>/dev/null || cp /dev/null /tmp/cad3
{ [ "$RC" -eq 0 ] || fail "exit=$RC want0"; }
{ has "$CAD" "https://203.0.113.10 {" || fail "no-ip-site-line"; }
{ has "$CAD" "tls internal" || fail "no-tls-internal"; }
{ has "$CAD" "handle /api/* {" || fail "no-api-handle"; }
{ has "$CAD" "handle {" || fail "no-catchall-handle"; }
{ has "$OUT" "BACKEND_HOSTNAME=203.0.113.10" || fail "no-BACKEND_HOSTNAME"; }
emit "CASE 3"

# ---- CASE 4: IP:port (internal TLS) ----
reset
run_install /tmp/in_empty COLMENA_HOST=203.0.113.10:8443
{ [ "$RC" -eq 0 ] || fail "exit=$RC want0"; }
{ has "$CAD" "https://203.0.113.10:8443 {" || fail "no-ipport-site-line"; }
{ has "$CAD" "tls internal" || fail "no-tls-internal"; }
{ has "$OUT" "BACKEND_HOSTNAME=203.0.113.10:8443" || fail "no-BACKEND_HOSTNAME"; }
emit "CASE 4"

# ---- CASE 5: invalid TLS rejected ----
reset
run_install /tmp/in_empty COLMENA_HOST=colmena.example.com COLMENA_TLS=bogus
{ [ "$RC" -ne 0 ] || fail "exit=0 want-nonzero"; }
emit "CASE 5"

# ---- CASE 6: production without email rejected ----
reset
run_install /tmp/in_empty COLMENA_HOST=colmena.example.com COLMENA_TLS=production
{ [ "$RC" -ne 0 ] || fail "exit=0 want-nonzero"; }
emit "CASE 6"

# ---- STAGE-40 regex coupling (scripts/40-frontend-up.sh rewrites the catch-all) ----
reset
{ grep -Pzq 'handle\s*\{[\s\S]*?reverse_proxy\s+localhost:5173[\s\S]*?\}' /tmp/cad1 || fail "regex-no-match-case1"; }
emit "STAGE40 case1"
reset
{ grep -Pzq 'handle\s*\{[\s\S]*?reverse_proxy\s+localhost:5173[\s\S]*?\}' /tmp/cad3 || fail "regex-no-match-case3"; }
emit "STAGE40 case3"

echo "===== end $IMG ====="
CONTAINER
  drc=$?

  cat /tmp/smoke_img

  if [ "$drc" -ne 0 ] && ! grep -q 'CASE 1 '"$IMG"' :' /tmp/smoke_img; then
    log "IMAGE $IMG : FAIL (docker run exited $drc before completing the matrix)"
    OVERALL=1
  fi
  if grep -q ' : FAIL' /tmp/smoke_img; then
    OVERALL=1
  fi
  if ! grep -q 'CASE 1 '"$IMG"' :' /tmp/smoke_img; then
    log "IMAGE $IMG : FAIL (matrix did not complete)"
    OVERALL=1
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
log ""
line
if [ "$OVERALL" -eq 0 ]; then
  log "OVERALL: PASS -- all cases passed on both images."
else
  log "OVERALL: FAIL -- one or more cases failed (see FAIL lines above)."
fi
line
exit "$OVERALL"
