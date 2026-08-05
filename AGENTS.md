# Colmena Installer — Agent Guide

This directory **is** the git repo (`coolabnet/colmena-installer`, branch
`main`). It is the installer/orchestrator: it clones the four component repos
as sub-repos, wires them together, and brings up the full stack via three
independent paths. It does not contain application source itself.

## Sub-repos (not part of this repo)

`backend/`, `frontend/`, `colmena-devops/`, and `colmena-os/` are **separate
git repos**, git-ignored here (see `.gitignore`), not submodules. They don't
exist until cloned:

```bash
COLMENA_CLONE_PROTO=https bash scripts/05-clone.sh
```

(drop `COLMENA_CLONE_PROTO=https` if you have an SSH key for the `luandro/*`
forks these clone from by default — see `scripts/05-clone.sh` for URLs/branch
overrides).

| Directory         | Purpose                                                              |
|--------------------|-----------------------------------------------------------------------|
| `backend/`         | Django REST API (Python 3.10). Owns the public API and OpenAPI schema. |
| `frontend/`        | React 18 PWA (Vite, TypeScript). Consumes the backend OpenAPI client.  |
| `colmena-devops/`  | Docker build contexts for Postgres/Nextcloud/Mailcrab infra images.   |
| `colmena-os/`      | Unrelated integration repo, cloned by `05-clone.sh` but not used by any of the three run paths below. |

All real editing happens in the sibling repo itself, not here. This repo only
orchestrates.

## Three ways to run the stack

1. **`run-stack.sh`** (host toolchain: pyenv/Python 3.10, Node 20, Docker for
   infra) — the droplet/CI path. Staged pipeline, see `scripts/*.sh`:

   ```bash
   bash run-stack.sh          # full run: clone through teardown
   bash run-stack.sh up       # stages 05-40 only (stack stays up)
   bash run-stack.sh test     # stage 50 only (assumes stack is running)
   bash run-stack.sh down     # teardown only
   ```

   Stages: `05 clone` → `10 prereqs` → `20 infra` (Postgres/pgAdmin/Mailcrab/
   Nextcloud via Docker) → `30 backend` (venv, migrate, seed) → `40 frontend`
   (npm, Vite build) → `50 tests` (backend tests, tsc, Playwright) →
   `90 teardown`. Env knobs documented in `README.md`.

2. **`docker compose`** (only Docker + git needed, no host Python/Node) — the
   local-dev onramp. Clone sub-repos first (see above), then:

   ```bash
   docker compose up -d --build
   ```

   App at `http://localhost:8090` (Caddy), backend API also on `:8000`. See
   **`DOCKER.md`** for the full service list, boot ordering, and env knobs.
   `docker/backend-entrypoint.sh` is the interesting file — idempotent boot
   sequence including a Nextcloud Talk (spreed) install fallback and a
   Circles-app workaround.

3. **Terraform droplet deploy** (`terraform/`) — provisions a DigitalOcean
   droplet whose `cloud-init` runs the same `run-stack.sh` flow remotely.
   `terraform apply` / `terraform destroy` in that directory; see
   `terraform/main.tf` and `terraform/terraform.tfvars.example`.

There's also **`install.sh`** — a standalone bring-your-own-server installer
(curl-pipeable, no Terraform/DigitalOcean needed) documented as the primary
path in `README.md`.

## Tests

`tests/` is a standalone Playwright e2e suite (own `package.json`), pointed at
whichever of the three stacks above is currently running via
`PLAYWRIGHT_BASE_URL`. CI runs it against the docker-compose stack:
`.github/workflows/compose-e2e.yml`.

## Key docs

- `README.md` — install.sh usage, `run-stack.sh` usage, docker-compose
  quickstart, Terraform deploy.
- `DOCKER.md` — docker-compose stack detail.
- `TASK.md` — backlog/PRD-format tracking of deferred work; update status as
  items are picked up or closed.
