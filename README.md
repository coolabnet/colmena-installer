# Colmena Installer

Deploy a full Colmena stack to a DigitalOcean droplet in one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/terraform/deploy.sh)
```

Or clone and run locally:

```bash
git clone https://github.com/coolabnet/colmena-installer.git && cd colmena-installer && bash run-stack.sh
```

## What gets deployed

| Service | Port | Description |
|---------|------|-------------|
| Frontend (SPA) | 443 | Production React build served by Caddy |
| API (Django) | 443 `/api/*` | Reverse-proxied by Caddy to gunicorn on :8000 |
| Nextcloud | 8003/8004 | File storage, installed and seeded |
| Postgres | 5432 | Database (Docker) |
| pgAdmin | 5050 | Database admin UI (Docker) |
| Mailcrab | 1080/1025 | SMTP sink for dev emails (Docker) |

## Cloud deployment (DigitalOcean)

### Prerequisites

- A [DigitalOcean](https://digitalocean.com) account with an API token (Settings > API > Tokens/Write)
- A domain registered in DO with nameservers delegated to DigitalOcean
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- SSH key pair (default: `~/.ssh/id_rsa`)

### Quick start

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars -- fill in do_token and domain_name at minimum
terraform init
terraform apply
```

Terraform will:
1. Create a droplet (2 vCPU / 4 GB RAM recommended)
2. Configure DNS A records for `colmena.<domain>` and `colmena-api.<domain>`
3. Provision with cloud-init (Docker, Node, Caddy, pyenv)
4. Bootstrap the full stack in the background (~10 min)

### Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `do_token` | (required) | DigitalOcean API token |
| `domain_name` | (required) | Base domain in DO (e.g. `luandro.com`) |
| `frontend_subdomain` | `colmena` | Frontend subdomain (`colmena.<domain>`) |
| `api_subdomain` | `colmena-api` | API subdomain (`colmena-api.<domain>`) |
| `region` | `nyc3` | DO region slug |
| `droplet_size` | `s-2vcpu-4gb` | Droplet size (4 GB RAM minimum) |
| `letsencrypt_staging` | `true` | Use Let's Encrypt staging CA (untrusted certs). Set `false` for browser-trusted certs. Rate-limited to 5 certs/domain/week — use staging while iterating. |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | SSH public key for droplet access |

### After deploy

```bash
terraform output          # shows IPs, URLs, SSH command
ssh root@<droplet_ip>     # check bootstrap progress
```

Wait for the bootstrap to complete (~10 min):

```bash
ssh root@<droplet_ip> "tail -f /var/log/colmena-install.log"
```

Then run e2e tests from your local machine:

```bash
terraform output -raw e2e_command | bash
```

### TLS certificates

The default uses the **Let's Encrypt staging CA**, which issues untrusted certificates (you'll see a browser warning). This avoids hitting the production rate limit (5 certs per domain per 168 hours) while iterating.

To switch to **trusted certificates**, set `letsencrypt_staging = false` in `terraform.tfvars` and re-apply. Caddy will obtain production certs on the next restart.

### Teardown

```bash
terraform destroy
```

Removes the droplet, firewall, and DNS A records. The DO domain itself is preserved.

## Local development

```bash
bash run-stack.sh          # full run (clone through teardown)
bash run-stack.sh up       # stages 05-40 only (stack stays up)
bash run-stack.sh test     # stage 50 only (assumes stack is running)
bash run-stack.sh down     # teardown only
```

### Stages

| Stage | Description |
|-------|-------------|
| 05 clone | Clones all sub-repos on their correct branches |
| 10 prereqs | Verifies toolchain (pyenv, node, docker, playwright) |
| 20 infra | Starts Postgres, pgAdmin, Mailcrab, Nextcloud via Docker |
| 30 backend | Sets up venv, installs deps, runs migrations and seeds |
| 40 frontend | Installs npm deps, builds production bundle |
| 50 tests | Runs backend tests, TypeScript check, Playwright E2E |
| 90 teardown | Stops all services and cleans up |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SKIP_PLAYWRIGHT` | `0` | Set to `1` to skip browser tests |
| `SKIP_NEXTCLOUD` | `0` | Set to `1` to skip Nextcloud container |
| `SKIP_BUILD` | `0` | Set to `1` to skip Vite production build |
| `KEEP_DATA` | `0` | Set to `1` to keep Docker volumes on teardown |
