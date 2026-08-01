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
- Ports **80** and **443** open (Caddy uses both for TLS), or only port **80** (or the custom port) for `none` mode.
- **Either** a domain with a DNS **A record** already pointing at the server's IP (required for a browser-trusted Let's Encrypt cert), **or** nothing at all — you can install against the server's raw IP for a quick trial.

### What it asks

The installer detects the server's public IP, then asks only the prompts relevant to the selected host:

1. **Domain name** (e.g. `colmena.example.com`) — or leave blank to use the server's detected IP.
2. **Plain HTTP or self-signed TLS?** — asked for bare IP addresses; loopback hosts default to plain HTTP.
3. **Let's Encrypt staging certs?** (untrusted, for testing only) — asked **only when a domain is given**; defaults to **No** (= trusted production certs).
4. **Email** for Let's Encrypt / TLS expiry notices — required for production certs, optional for staging.

### After it finishes (~10 min)

1. Open `<scheme>://<your-host>` (accept the certificate warning if you used an IP or staging certs).
2. On the Colmena login screen, **add your server** using the URL `<scheme>://<your-host>`. The app stores the server URL locally — there is no pre-seeded server.

> **Note:** with an IP address or staging certs the browser shows a certificate warning you must accept before the page loads; `none` mode has no certificate warning.

### Non-interactive / automation

All prompts can be skipped with environment variables:

| Variable | Purpose |
|----------|---------|
| `COLMENA_HOST` | Domain or IP (optionally `:port`) to serve on |
| `COLMENA_EMAIL` | Email for Let's Encrypt / TLS notices (required for production) |
| `COLMENA_TLS` | `production` \| `staging` \| `internal` \| `none` |

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

The installer picks one of four TLS modes based on your answers:

- **production** (default for a domain): trusted Let's Encrypt certs. Rate-limited to **5 certs per domain per 168 hours**, so use **staging** while iterating.
- **staging**: untrusted certs (browser warning), no rate-limit risk — for testing.
- **internal**: Caddy self-signed cert; browser warning. Use this when HTTPS is required without a trusted certificate.
- **none**: plain HTTP, no certificate, for local/LAN deployments; automatic for loopback hosts. Pair it with an IP or local domain.

### Choosing a mode (feature limits)

The audio **recorder needs a browser *secure context***, not strictly HTTPS. HTTPS always provides one; **`localhost` / `127.0.0.1` provide one even over plain HTTP**; a non-loopback host (a LAN/public IP, or a domain) over plain HTTP does **not**. This is the main practical difference between the modes:

| Host | `COLMENA_TLS` | Certificate warning? | Recorder | Notes |
|------|---------------|----------------------|----------|-------|
| `localhost` / `127.0.0.1` | `none` (HTTP) | none | works | Loopback is a secure context; best for local dev. |
| LAN / public IP | `none` (HTTP) | none (address bar shows "Not secure") | **broken** | Mic yields no audio → empty buffer; see note below. |
| any IP / domain | `internal` (self-signed HTTPS) | one-time click-through | works | Pick this when you have **no domain but need recording**. |
| real domain | `staging` / `production` | staging warns; production clean | works | Production needs DNS pointing here. |

So: **no domain + need the recorder → use `internal`** (accept the self-signed warning once), not `none`. Use `none` for localhost or for non-recording LAN trials.

Over plain HTTP on a non-loopback host, other secure-context browser APIs also degrade: the async clipboard (`navigator.clipboard`, e.g. copy-link buttons), service workers / PWA install, and camera/screen-share (`getUserMedia`/`getDisplayMedia`) may be unavailable. Authentication itself is unaffected — the app signs in with a JWT in `localStorage` (not `Secure`-flagged cookies), and the installer writes Django's `CSRF_TRUSTED_ORIGINS` with the matching `http://` scheme, so login and form POSTs work over HTTP. Plain HTTP also sends all traffic in cleartext: fine on a trusted LAN, unacceptable on the public internet (use HTTPS there).

> **Note on the recorder error `Failed to construct 'OfflineAudioContext': The number of frames provided (0) is less than the minimum bound (1)`:** this is what you see in the browser console when the recorder runs without a secure context (the captured audio decodes to zero frames). It is also a latent frontend bug — any *empty* recording throws it regardless of scheme — but normal, non-empty recordings over HTTPS are unaffected. The end-to-end suite skips the recorder test when `COLMENA_SCHEME=http` for this reason.

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

If you'd rather have infrastructure provisioned for you, the Terraform path spins up a DigitalOcean droplet. Set `domain_name` to a DigitalOcean-managed base domain to configure DNS and serve across **two subdomains** (`colmena.<domain>` + `colmena-api.<domain>`), or leave `domain_name = ""` for an IP-only deployment with no DNS records or Let's Encrypt:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coolabnet/colmena-installer/main/terraform/deploy.sh)
```

See `terraform/terraform.tfvars.example` and the `terraform/` directory for the full variable list. Key options:

| Variable | Default | Purpose |
|----------|---------|---------|
| `do_token` | (required) | DigitalOcean API token |
| `domain_name` | `""` | Base domain in DO (e.g. `luandro.com`), or blank for IP-only |
| `frontend_subdomain` | `colmena` | Frontend subdomain (`colmena.<domain>`) |
| `api_subdomain` | `colmena-api` | API subdomain (`colmena-api.<domain>`) |
| `letsencrypt_staging` | `true` | Use Let's Encrypt staging CA (untrusted). Set `false` for browser-trusted certs. |
| `tls_mode` | `""` | `production`, `staging`, `internal`, or `none`; blank derives from `letsencrypt_staging`. |

IP-only plain HTTP example:

```bash
terraform apply -var 'domain_name=' -var 'tls_mode=none'
```

> **Note:** an IP-only deployment (`domain_name = ""`) serves the frontend and the API on the **same** host (the droplet IP), exactly like `install.sh` — the two-subdomain layout only exists when a domain is set. The droplet detects its own public IP at boot (via `api.ipify.org`/`ifconfig.me`, with a local-IP fallback), so the host needs either outbound internet or a routable local address when it first boots.

Teardown: `terraform destroy`.
