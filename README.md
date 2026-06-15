# Colmena Installer

Deploy the full Colmena stack to your own Ubuntu/Debian server in one command — no Terraform, no DigitalOcean account, just a fresh box with root access.

## Install on your own server

This is the primary path. Run the installer as **root** on a fresh server (the process-substitution form keeps the interactive prompts working — don't pipe to `bash`):

```bash
sudo bash -c "bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/install.sh)"
```

If you're already root, drop the wrapper:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/install.sh)
```

### Requirements

- A fresh **Ubuntu 22.04+** or **Debian 12+** server with root or `sudo` access.
- Ports **80** and **443** open (Caddy uses both for TLS).
- **Either** a domain with a DNS **A record** already pointing at the server's IP (required for a browser-trusted Let's Encrypt cert), **or** nothing at all — you can install against the server's raw IP for a quick trial.

### What it asks

The installer detects the server's public IP, then runs three prompts:

1. **Domain name** (e.g. `colmena.example.com`) — or leave blank to use the server's detected IP.
2. **Let's Encrypt staging certs?** (untrusted, for testing only) — asked **only when a domain is given**; defaults to **No** (= trusted production certs).
3. **Email** for Let's Encrypt / TLS expiry notices — required for production certs, optional for staging.

### After it finishes (~10 min)

1. Open `https://<your-host>` (accept the certificate warning if you used an IP or staging certs).
2. On the Colmena login screen, **add your server** using the URL `https://<your-host>`. The app stores the server URL locally — there is no pre-seeded server.

> **Note:** with an IP address or staging certs the browser shows a certificate warning you must accept before the page loads.

### Non-interactive / automation

All three prompts can be skipped with environment variables:

| Variable | Purpose |
|----------|---------|
| `COLMENA_HOST` | Domain or IP (optionally `:port`) to serve on |
| `COLMENA_EMAIL` | Email for Let's Encrypt / TLS notices (required for production) |
| `COLMENA_TLS` | `production` \| `staging` \| `internal` |

```bash
COLMENA_HOST=colmena.example.com COLMENA_EMAIL=you@example.com COLMENA_TLS=production \
  sudo -E bash -c "bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/install.sh)"
```

## What gets deployed

Everything is served from a **single host** — the frontend at the root and the API under `/api/*`, so there are no CORS issues and no second subdomain.

| Service | URL / Port | Description |
|---------|------------|-------------|
| Frontend (SPA) | `https://<host>/` | Production React build served by Caddy |
| API (Django) | `https://<host>/api/*` | Reverse-proxied by Caddy to gunicorn/runserver on :8000 |
| Nextcloud | 8003/8004 | File storage, installed and seeded |
| Postgres | 5432 | Database (Docker) |
| pgAdmin | 5050 | Database admin UI (Docker) |
| Mailcrab | 1080/1025 | SMTP sink for dev emails (Docker) |

## TLS certificates

The installer picks one of three TLS modes based on your answers:

- **production** (default for a domain): trusted Let's Encrypt certs. Rate-limited to **5 certs per domain per 168 hours**, so use **staging** while iterating.
- **staging**: untrusted certs (browser warning), no rate-limit risk — for testing.
- **internal** (automatic when you give an IP): Caddy self-signed cert; browser warning. Let's Encrypt cannot issue certificates for bare IP addresses, so this is the only option for an IP host.

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

## Advanced: managed DigitalOcean deploy (Terraform)

If you'd rather have infrastructure provisioned for you, the Terraform path spins up a DigitalOcean droplet and configures DNS automatically, serving the app across **two subdomains** (`colmena.<domain>` + `colmena-api.<domain>`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/terraform/deploy.sh)
```

See `terraform/terraform.tfvars.example` and the `terraform/` directory for the full variable list. Key options:

| Variable | Default | Purpose |
|----------|---------|---------|
| `do_token` | (required) | DigitalOcean API token |
| `domain_name` | (required) | Base domain in DO (e.g. `luandro.com`) |
| `frontend_subdomain` | `colmena` | Frontend subdomain (`colmena.<domain>`) |
| `api_subdomain` | `colmena-api` | API subdomain (`colmena-api.<domain>`) |
| `letsencrypt_staging` | `true` | Use Let's Encrypt staging CA (untrusted). Set `false` for browser-trusted certs. |

Teardown: `terraform destroy`.
