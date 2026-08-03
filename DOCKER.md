# Docker Compose — one-command local stack

Brings up the **full** Colmena stack with no host language runtimes (no
pyenv/Python, no Node on the host — only Docker and git). `backend/`,
`frontend/`, and `colmena-devops/` are separate repos (git-ignored here, not
submodules) that the Dockerfiles build from, so clone them first:

```bash
COLMENA_CLONE_PROTO=https bash scripts/05-clone.sh   # clones backend/, frontend/,
                                                       # colmena-devops/, colmena-os/
cp .env.example .env        # optional: every var has a working default
docker compose up -d --build
```

> `COLMENA_CLONE_PROTO=https` avoids needing an SSH key set up for the
> `luandro/*` GitLab/GitHub forks; drop it if you already have one.

Then open **http://localhost:8090** (the SPA via Caddy). The backend API is also
reachable directly at **http://localhost:8000**, pgAdmin at :5050, Mailcrab at
:1080, Nextcloud at :8003.

> Caddy listens on host port **8090** (not 80) so the stack works under rootless
> Docker, which can't bind privileged ports. Set `HTTP_PORT=80` in `.env` if your
> Docker runs as root and you want port 80.

Seeded login (matches the e2e suite): `testuser@domain.org` / `testpassword123`.

Tear down (keeps data): `docker compose down`. Wipe data: `docker compose down -v`.
Re-`up` is idempotent — the backend entrypoint re-runs each seed step safely.

## What runs

| service    | image / build                         | notes |
|------------|---------------------------------------|-------|
| postgres   | postgres:13                           | healthchecked; backend waits on it |
| pgadmin    | dpage/pgadmin4                        | DB admin UI, :5050 |
| mail       | Mailcrab (colmena-devops build)       | SMTP sink, :1080/:1025 |
| nextcloud  | colmena-devops build                  | OCS :8003, wrapper :8004; healthchecked |
| backend    | `docker/backend.Dockerfile`           | Django; runs the stage-30 seed, then runserver :8000 |
| frontend   | `docker/frontend.Dockerfile`          | Vite dev; generates the OpenAPI client at boot, :5173 |
| caddy      | caddy:2                               | single host: `/` → frontend, `/api/*` → backend |

## Boot ordering (compose healthchecks + depends_on)

`postgres` healthy + `nextcloud` healthy → `backend` (generate OpenAPI client →
create DB → migrate → relax `django_site` uniqueness for single-domain →
`load_sites_with_hostname` → seed fixtures + groups → superadmin + testuser →
Nextcloud testuser/teams seed → runserver) → `frontend` (waits for the backend
schema, `npm install` whose `prepare` generates the client, then Vite) → `caddy`.

The backend seed logic is reused verbatim from `scripts/30-backend-up.sh`
(`docker/seed_nextcloud.py`, `docker/create_users.py`) — only the Nextcloud URL is
parametrized to `http://nextcloud`. The Caddy `handle` blocks mirror `install.sh`.

## Environment

See `.env.example` — every knob (ports, Postgres/Nextcloud creds, hostnames) has a
default that works for localhost. Override by copying to `.env`.

## CI

`.github/workflows/compose-e2e.yml` does exactly the above on a clean runner, then
runs the Playwright e2e suite from `tests/` with `PLAYWRIGHT_BASE_URL=http://localhost:8090`
and `COLMENA_SERVER_URL=http://localhost:8000`, uploading the report on failure.

## Relation to run-stack.sh

This is the onramp / local-dev path. `run-stack.sh` remains the droplet/CI
orchestrator (host-toolchain based). They reuse the same per-stage logic.
