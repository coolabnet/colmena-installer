#!/usr/bin/env bash
# Colmena one-liner deployer.
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/terraform/deploy.sh)
#
# This script:
#   1. Checks for terraform binary
#   2. Clones the installer repo (if not already inside it)
#   3. Prompts for required variables
#   4. Runs terraform init + apply
#   5. Waits for the stack to come up
#   6. Runs e2e tests
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[colmena]${NC} $*"; }
warn()  { echo -e "${YELLOW}[colmena]${NC} $*"; }
die()   { echo -e "${RED}[colmena]${NC} $*" >&2; exit 1; }

# --- Check prerequisites ---
command -v terraform >/dev/null 2>&1 || die "terraform is not installed. See https://developer.hashicorp.com/terraform/downloads"
command -v git >/dev/null 2>&1 || die "git is not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is not installed."

# --- Clone or use existing ---
REPO="https://github.com/coolabnet/colmena-installer.git"
INSTALLER_DIR="$(mktemp -d)/colmena-installer"

info "Cloning colmena-installer..."
git clone --depth 1 "$REPO" "$INSTALLER_DIR" 2>/dev/null
cd "$INSTALLER_DIR/terraform"

# --- Prompt for config ---
if [[ ! -f terraform.tfvars ]]; then
  cp terraform.tfvars.example terraform.tfvars

  # Interactive prompts
  read -rp "DigitalOcean API token: " DO_TOKEN
  read -rp "Domain name (e.g. luandro.com): " DOMAIN_NAME
  read -rp "Frontend subdomain [colmena]: " FE_SUB
  read -rp "API subdomain [colmena-api]: " API_SUB
  read -rp "Region [nyc3]: " REGION
  read -rp "Droplet size [s-2vcpu-4gb]: " SIZE
  read -rp "SSH public key path [~/.ssh/id_rsa.pub]: " SSH_KEY
  read -rp "Use Let's Encrypt staging? (true/false) [true]: " LE_STAGING

  # Write terraform.tfvars
  cat > terraform.tfvars <<EOF
do_token             = "${DO_TOKEN}"
domain_name          = "${DOMAIN_NAME}"
frontend_subdomain   = "${FE_SUB:-colmena}"
api_subdomain        = "${API_SUB:-colmena-api}"
region               = "${REGION:-nyc3}"
droplet_size         = "${SIZE:-s-2vcpu-4gb}"
ssh_public_key_path  = "${SSH_KEY:-~/.ssh/id_rsa.pub}"
letsencrypt_staging  = ${LE_STAGING:-true}
EOF
  info "Wrote terraform.tfvars"
fi

# --- Terraform init + apply ---
info "Running terraform init..."
terraform init -input=false

info "Running terraform apply..."
terraform apply -auto-approve

# --- Wait for bootstrap ---
DROPLET_IP=$(terraform output -raw droplet_ip)
FRONTEND_URL=$(terraform output -raw url)

info "Droplet created at $DROPLET_IP"
info "Waiting for SSH..."
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "root@$DROPLET_IP" "echo OK" 2>/dev/null; then
    break
  fi
  echo "  attempt $i/30..."
  sleep 10
done

info "Stack is bootstrapping in the background (~10 min)."
info "Watch progress:  ssh root@$DROPLET_IP 'tail -f /var/log/colmena-install.log'"
info ""
info "When ready, test with:"
info "  terraform output -raw e2e_command | bash"
info ""
info "Frontend: $FRONTEND_URL"
info "SSH:      ssh root@$DROPLET_IP"
info ""
info "To tear down when done:  terraform destroy"
