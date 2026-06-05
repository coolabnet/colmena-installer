# Colmena Installer

One command to pull, build, and test the full Colmena stack.

```bash
git clone https://github.com/coolabnet/colmena-installer.git && cd colmena-installer && bash run-stack.sh
```

## Prerequisites

- **Docker** with compose v2 plugin
- **Python 3.10** via pyenv
- **Node.js** with npm
- **Playwright** + browser-harness (for E2E tests)
- **git** and **ssh** (with keys for GitLab/GitHub)

## What it does

| Stage | Description |
|-------|-------------|
| 05 clone | Clones all sub-repos on their correct branches |
| 10 prereqs | Verifies toolchain (pyenv, node, docker, playwright) |
| 20 infra | Starts Postgres, pgAdmin, Mailcrab, Nextcloud via Docker |
| 30 backend | Sets up venv, installs deps, runs migrations and seeds |
| 40 frontend | Installs npm deps, starts Vite dev server |
| 50 tests | Runs backend tests, TypeScript check, Playwright E2E |
| 90 teardown | Stops all services and cleans up |

## Usage

```bash
bash run-stack.sh          # full run (clone through teardown)
bash run-stack.sh up       # stages 05–40 only (stack stays up)
bash run-stack.sh test     # stage 50 only (assumes stack is running)
bash run-stack.sh down     # teardown only
bash run-stack.sh 05       # clone sub-repos only
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SKIP_PLAYWRIGHT` | `0` | Set to `1` to skip browser tests |
| `SKIP_NEXTCLOUD` | `0` | Set to `1` to skip Nextcloud container |
| `SKIP_BUILD` | `0` | Set to `1` to skip Vite production build |
| `KEEP_DATA` | `0` | Set to `1` to keep Docker volumes on teardown |
