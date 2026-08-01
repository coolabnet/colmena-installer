#!/usr/bin/env bash
# install.sh -- Colmena bring-your-own-server installer.
#
# Installs the full Colmena stack on a fresh Ubuntu/Debian server with one command:
#   bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/install.sh)
#
# The stack is served from a SINGLE host: the frontend at <scheme>://<host>/ and the
# API at <scheme>://<host>/api/* (Caddy proxies /api/* to Django on :8000, everything
# else to the frontend on :5173, which stage 40 later swaps to static files).
# Use COLMENA_TLS=none for plain HTTP when no SSL certificate or domain is available.
# There is NO second "api" subdomain here -- that is the Terraform path only.
#
# What this script does:
#   1. Checks preconditions (root, apt, git, curl).
#   2. Gathers config (domain/IP, TLS mode, email) with env-var overrides.
#   3. Verifies DNS points here (warn + confirm, never hard-fail).
#   4. Installs system packages + Docker + Node 20 + Caddy (mirrors
#      terraform/cloud-init.yaml, idempotent / safe to re-run).
#   5. Writes a single-site /etc/caddy/Caddyfile.
#   6. Clones colmena-installer (if needed) and runs run-stack.sh droplet.
#
# Env-var overrides (skip the matching interactive prompt):
#   COLMENA_HOST   -- domain or IP[:port] to serve on
#   COLMENA_EMAIL  -- email for Let's Encrypt / TLS notices
#   COLMENA_TLS    -- one of: production | staging | internal | none
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[colmena]${NC} $*"; }
warn() { echo -e "${YELLOW}[colmena]${NC} $*"; }
die()  { echo -e "${RED}[colmena]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# 1. Preconditions
# ──────────────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This installer must run as root (it installs system packages, Docker, Caddy). Re-run with: sudo bash install.sh"
command -v apt-get >/dev/null 2>&1 || die "Only Ubuntu/Debian (apt-based) systems are supported."

export DEBIAN_FRONTEND=noninteractive

# git + curl are needed for the rest of this script (fetching keys, cloning).
# Install them up front if missing.
base_need=()
command -v git >/dev/null 2>&1 || base_need+=(git)
command -v curl >/dev/null 2>&1 || base_need+=(curl)
if [[ ${#base_need[@]} -gt 0 ]]; then
  apt-get update
  apt-get install -y "${base_need[@]}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Gather config (interactive prompts, env-var overrides)
# ──────────────────────────────────────────────────────────────────────────────

# Detect this server's public IP first (used as a default and for DNS checks).
SERVER_IP="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
fi
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$SERVER_IP" ]] || die "Could not determine this server's public IP address."

# --- Host (domain or IP) ---
if [[ -v COLMENA_HOST ]]; then
  HOST="$COLMENA_HOST"
else
  read -rp "Domain name (e.g. colmena.example.com), or leave blank to use this server's IP [$SERVER_IP]: " HOST
  HOST="${HOST:-$SERVER_IP}"
fi

# An IP literal (optionally with a port) => no real TLS cert is possible.
HOST_IS_IP=0
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
  HOST_IS_IP=1
fi

# Loopback hosts (localhost / 127.x / ::1) are for local deployments: plain HTTP.
HOST_BARE="${HOST%%:*}"
HOST_IS_LOOPBACK=0
case "$HOST_BARE" in
  localhost|127.*) HOST_IS_LOOPBACK=1 ;;
esac
[[ "$HOST" == "::1" ]] && HOST_IS_LOOPBACK=1

# Caddy site-address / URL form of the host. A bare IPv6 literal (e.g. ::1) must
# be wrapped in [] or Caddy's address parser and the printed URL are both invalid.
# IPv4, hostnames, and already-bracketed IPv6 ([::1], [::1]:port) pass through.
CADDY_ADDR="$HOST"
if [[ "$HOST" == *:* && "$HOST" != *.* && "$HOST" != "["* ]]; then
  CADDY_ADDR="[$HOST]"
fi

# --- TLS mode ---
if [[ -v COLMENA_TLS ]]; then
  case "$COLMENA_TLS" in
    production|staging|internal|none) TLS="$COLMENA_TLS" ;;
    http) TLS="none" ;;   # friendly alias
    *) die "COLMENA_TLS must be one of: production, staging, internal, none (got: $COLMENA_TLS)" ;;
  esac
  if [[ ( "$HOST_IS_IP" -eq 1 || "$HOST_IS_LOOPBACK" -eq 1 ) && ( "$TLS" == "production" || "$TLS" == "staging" ) ]]; then
    die "Let's Encrypt cannot issue certificates for a bare IP or loopback host. Use COLMENA_TLS=internal or COLMENA_TLS=none."
  fi
elif [[ "$HOST_IS_LOOPBACK" -eq 1 ]]; then
  TLS="none"
  info "Loopback host detected -- serving plain HTTP (no TLS)."
elif [[ "$HOST_IS_IP" -eq 1 ]]; then
  # Let's Encrypt cannot issue certificates for bare IP addresses.
  read -rp "Serve over plain HTTP (no TLS, no certificate warning)? [y/N]: " http_ans || http_ans=""
  if [[ "${http_ans:0:1}" =~ [yY] ]]; then
    TLS="none"
    info "Serving plain HTTP. Browsers will NOT show a certificate warning."
  else
    TLS="internal"
    info "IP address detected -- using Caddy internal (self-signed) TLS. Browsers will show a certificate warning."
  fi
else
  read -rp "Use Let's Encrypt STAGING certs (untrusted, for testing only)? [y/N]: " le_ans
  if [[ "${le_ans:0:1}" =~ [yY] ]]; then
    TLS="staging"
  else
    TLS="production"
  fi
fi

# --- Email (only meaningful for real Let's Encrypt issuance) ---
EMAIL=""
if [[ "$TLS" == "production" || "$TLS" == "staging" ]]; then
  if [[ -v COLMENA_EMAIL ]]; then
    EMAIL="$COLMENA_EMAIL"
    [[ -z "$EMAIL" || "$EMAIL" == *@* ]] || die "COLMENA_EMAIL must contain '@' (or be empty)."
    [[ "$TLS" == "production" && -z "$EMAIL" ]] && die "Production Let's Encrypt TLS requires an email. Set COLMENA_EMAIL or run interactively."
  else
    if [[ "$TLS" == "production" ]]; then
      while true; do
        read -rp "Email for Let's Encrypt / TLS expiry notices: " EMAIL
        if [[ "$EMAIL" == *@* ]]; then break; fi
        warn "A valid email is required for production TLS; please retry."
      done
    else
      read -rp "Email for Let's Encrypt / TLS expiry notices (may be blank): " EMAIL
      [[ -z "$EMAIL" || "$EMAIL" == *@* ]] || die "Email must contain '@' or be blank."
    fi
  fi
fi

info "Host: $HOST   TLS: $TLS${EMAIL:+   Email: $EMAIL}"
SCHEME=https
[[ "$TLS" == "none" ]] && SCHEME=http

# ──────────────────────────────────────────────────────────────────────────────
# 3. Verification (warn + confirm; never hard-fail)
# ──────────────────────────────────────────────────────────────────────────────

# Confirm the chosen host actually reaches this server.
# Plain HTTP does not need DNS or Let's Encrypt reachability checks.
if [[ "$HOST_IS_IP" -eq 0 && "$TLS" != "none" ]]; then
  RESOLVED="$(getent hosts "$HOST_BARE" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ -z "$RESOLVED" ]] && command -v dig >/dev/null 2>&1; then
    RESOLVED="$(dig +short "$HOST_BARE" A 2>/dev/null | tail -1 || true)"
  fi
  if [[ -n "$RESOLVED" && "$RESOLVED" != "$SERVER_IP" ]]; then
    warn "DNS for '$HOST_BARE' resolves to $RESOLVED, not this server ($SERVER_IP)."
    warn "Let's Encrypt validation will fail until DNS points here."
    read -rp "Continue anyway? [y/N]: " ans
    [[ "${ans:0:1}" =~ [yY] ]] || die "Aborted. Point DNS for $HOST_BARE to $SERVER_IP and re-run."
  elif [[ -z "$RESOLVED" ]]; then
    warn "Could not resolve '$HOST_BARE'. Let's Encrypt validation will likely fail."
    read -rp "Continue anyway? [y/N]: " ans
    [[ "${ans:0:1}" =~ [yY] ]] || die "Aborted."
  fi
else
  if [[ "$TLS" != "none" && "$HOST_BARE" != "$SERVER_IP" ]]; then
    warn "The IP you entered ($HOST_BARE) differs from this server's detected public IP ($SERVER_IP)."
    read -rp "Continue anyway? [y/N]: " ans
    [[ "${ans:0:1}" =~ [yY] ]] || die "Aborted."
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. System setup (mirrors terraform/cloud-init.yaml packages: + runcmd:)
# ──────────────────────────────────────────────────────────────────────────────
info "Installing system packages..."

# Full package set from cloud-init (build deps are needed by pyenv/Python build in run-stack.sh).
BASE_PKGS=(
  git curl wget build-essential libssl-dev zlib1g-dev libbz2-dev
  libreadline-dev libsqlite3-dev libffi-dev liblzma-dev ca-certificates
  gnupg lsb-release apt-transport-https uidmap
)
apt-get update
apt-get install -y "${BASE_PKGS[@]}"

# Detect distro for the Docker repo path (cloud-init hardcodes ubuntu; we support debian too).
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  DISTRO="${ID:-ubuntu}"
else
  DISTRO="ubuntu"
fi
ARCH="$(dpkg --print-architecture)"
CODENAME="$(lsb_release -cs)"

# --- Docker (official repo, not Ubuntu's older docker.io) ---
if [[ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg
fi
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
info "Docker ready."

# --- Node 20.x via NodeSource (skip setup if v20 already present) ---
if ! command -v node >/dev/null 2>&1 || ! node -v 2>/dev/null | grep -q '^v20\.'; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi
info "Node $(node -v) ready."

# --- Caddy (Cloudsmith repo) ---
if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
fi
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt-get update
# --force-confdef --force-confold keeps our Caddyfile when the caddy package ships a default one.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  caddy
info "Caddy ready."

# ──────────────────────────────────────────────────────────────────────────────
# 5. Write /etc/caddy/Caddyfile (single site block)
# ──────────────────────────────────────────────────────────────────────────────
#
# WHY the two handle blocks are written verbatim with these exact ports:
#   - scripts/40-frontend-up.sh regex-replaces the catch-all block
#       /handle\s*\{[\s\S]*?reverse_proxy\s+localhost:5173[\s\S]*?\}/
#     with static file serving once the production frontend is built. That regex
#     only matches a `handle {` block containing `reverse_proxy localhost:5173`
#     (port 5173, FRONTEND_PORT default). Do NOT rename the port or restructure
#     this block or stage 40 will silently fail to patch it.
#   - The /api/* handle is kept and never touched by stage 40.
info "Writing Caddyfile..."

CADDY_TMP="$(mktemp)"
{
  # Global options block: only the production path registers an LE account email.
  # (Staging certs are throwaway; internal certs are self-signed -- neither needs it.)
  if [[ "$TLS" == "production" && -n "$EMAIL" ]]; then
    printf '{\n    email %s\n}\n\n' "$EMAIL"
  fi

  # Site address line.
  if [[ "$TLS" == "none" ]]; then
    # Explicit http:// scheme disables Caddy's automatic HTTPS entirely.
    printf 'http://%s {\n' "$CADDY_ADDR"
  elif [[ "$TLS" == "internal" ]]; then
    printf 'https://%s {\n' "$HOST"
    printf '    tls internal\n'
  else
    printf '%s {\n' "$HOST"
    if [[ "$TLS" == "staging" ]]; then
      printf '    tls {\n        ca https://acme-staging-v02.api.letsencrypt.org/directory\n    }\n'
    fi
  fi

  # /api/* -> Django (same-origin avoids CORS). ALWAYS present.
  printf '    handle /api/* {\n        reverse_proxy localhost:8000\n    }\n'
  # catch-all -> frontend dev server (stage 40 swaps this to static files). See note above.
  printf '    handle {\n        reverse_proxy localhost:5173\n    }\n'

  printf '}\n'
} > "$CADDY_TMP"

install -m 0644 -o root -g root "$CADDY_TMP" /etc/caddy/Caddyfile
rm -f "$CADDY_TMP"

systemctl enable --now caddy
systemctl restart caddy
info "Caddyfile written and Caddy restarted."

# ──────────────────────────────────────────────────────────────────────────────
# 6. Clone the installer (if not already inside a clone) and run the stack
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd 2>/dev/null || echo .)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/run-stack.sh" ]]; then
  INSTALLER_DIR="$SCRIPT_DIR"
else
  INSTALLER_DIR="/root/colmena-installer"
  if [[ -d "$INSTALLER_DIR/.git" ]]; then
    info "Updating existing installer clone at $INSTALLER_DIR..."
    git -C "$INSTALLER_DIR" pull --ff-only
  else
    info "Cloning colmena-installer into $INSTALLER_DIR..."
    git clone https://github.com/coolabnet/colmena-installer.git "$INSTALLER_DIR"
  fi
fi

cd "$INSTALLER_DIR"

# These mirror /opt/colmena/start-stack.sh from cloud-init. The host vars make
# stage 30 set Django ALLOWED_HOSTS/CSRF_TRUSTED_ORIGINS; the single-domain
# install passes the same host for both backend and frontend.
export COLMENA_CLONE_PROTO=https
export INSTALL_MISSING=1
export SKIP_DEV_TOOLS=1
export STACK_MODE=droplet
export COLMENA_TLS="$TLS"
export BACKEND_HOSTNAME="$HOST"
export FRONTEND_HOSTNAME="$HOST"

info "Running the Colmena stack (this builds the backend + frontend, ~10 min)..."
if bash run-stack.sh droplet; then
  echo
  info "Colmena is up."
  info "Open: $SCHEME://$CADDY_ADDR"
  info "Then, in the Colmena login screen, add your server with URL: $SCHEME://$CADDY_ADDR"
else
  die "run-stack.sh failed. Review the output above, fix the issue, and re-run this installer (it is safe to re-run)."
fi
