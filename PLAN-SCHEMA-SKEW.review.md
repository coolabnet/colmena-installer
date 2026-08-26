# PLAN (rev 6): Fix Add-server flow in the published communityfirst/colmena-app image

## Root cause (verified 2026-08-25, evidence chain)

1. TASK-7 live repro: SPA Add-server probe throws
   `TypeError: ...status_retrieve is not a function` against the published
   image ⇒ the served bundle's runtime client lacks `/api/status/`.
2. In the frontend repo the OpenAPI artifacts are **gitignored**
   (`frontend/.gitignore:20` glob `schema.*`, plus `:19`
   `src/api/utilities/*`): a clean checkout contains only `Client.ts`
   and `utilities/.gitkeep`. GitLab CI generates them by downloading from
   `OPENAPI_SCHEMA_LOCATION` (repo CI variable) before building.
3. colmena-unified's `Dockerfile` never had that download step. Its
   frontend stage instead does:
   ```dockerfile
   COPY backend/apps/nextcloud/openapi/schema.json ./src/api/schema.json
   RUN npm run openapi-optimize && npm run openapi-typegen || true
   ```
   i.e. it substitutes the **Nextcloud wrapper's** schema (different API,
   no `status_retrieve`) and regenerates the runtime client from it,
   swallowing failures with `|| true`. The Add-server probe then calls an
   operation that does not exist in the bundled definition.
   Why the hack exists: the frontend normally generates its client at
   CONTAINER START (docker/frontend-entrypoint.sh waits for
   OPENAPI_SCHEMA_LOCATION and runs openapi-tasks via the npm prepare
   hook). An image-build stage has no reachable backend and
   scripts/openapi.js throws without that variable, so a file was copied
   in as a "fallback" — the wrong one. This plan keeps generation OFFLINE
   at build time (tracked schema file); it never reintroduces network
   fetches inside docker build.
4. CasaOS appstore pins floating `communityfirst/colmena-app:latest`;
   every fresh install ships the broken client.

## Change (all in `coolabnet/colmena-unified`, one PR)

1. **Add a tracked Colmena API schema**: `schemas/colmena-openapi.json`,
   generated from the exact backend commit the repo's `backend` submodule
   pins (see Generation below). Provenance recorded in
   `schemas/PROVENANCE.md`: pin SHA, date, generator command, route used.
2. **Dockerfile frontend stage**:
   - replace the COPY source:
     `COPY schemas/colmena-openapi.json ./src/api/schema.json`
     (comment updated: "Tracked Colmena API schema — see
     schemas/PROVENANCE.md")
   - make generation strict: `RUN npm run openapi-optimize && npm run openapi-typegen`
     (drop `|| true`; a failed regeneration must fail the build)
   - add a CI-side guard right after typegen:
     `RUN grep -q status_retrieve src/api/utilities/schema-runtime.json`
     (moves the dev-machine sanity gate into every future build at zero cost)
3. Nothing else changes: backend stage keeps generating its Nextcloud
   python client from its own path (verified separate and correct).

## Generation procedure (offline-first, deterministic; cwd stated per step)

1. cwd: anywhere. Fresh unified clone, then
   `git submodule update --init --checkout backend` — submodules check
   out the EXACT gitlink SHA by construction.
2. cwd: unified root. Equality gate against the recorded pin:
   `test "$(git -C backend rev-parse HEAD)" = "$(git ls-tree HEAD backend | awk '{print $3}')"`
   or abort.
3. Pre-flight: unified `.gitignore` does not exclude `schemas/*.json`
   (verified 2026-08-25: env/logs/OS patterns only).
4. cwd: `backend/`. PRIMARY — offline generator, no docker. A fresh
   checkout has NO venv (`backend/.gitignore` ignores it; Makefile uses
   `venv/bin`), so bootstrap first: `make venv && make install.dev`
   (host network OK — outside docker build; `make venv` calls plain
   `python`, host needs python-is-python3 or equivalent).
   DJANGO_SETTINGS_MODULE defaults to `colmena.settings.dev` whose DB
   settings carry defaults ⇒ no live postgres needed.
   TRAP: the Makefile includes `.env` when present, leaving `$(PYTHON)`
   EMPTY in fresh checkouts — `install.dev` hardcodes `venv/bin/pip3`
   so bootstrap succeeds, then generation would silently run SYSTEM
   python (wrong package versions or ModuleNotFoundError). Pin it:
   `make gen.openapi.schema FORMAT=openapi-json PYTHON=venv/bin/python3`
   → emits `backend/schema.yaml` containing JSON →
   `mv schema.yaml ../schemas/colmena-openapi.json`.
   FALLBACK (only if this fails on settings/import; cwd: unified root):
   bring up postgres+backend via unified compose, then
   `curl -fsS -H 'Accept: application/vnd.oai.openapi+json' \
      http://localhost:8000/api/schema/ -o schemas/colmena-openapi.json`.
   (Historical note: the frontend download script always saved YAML into
   schema.json and openapicmd sniffs format — committing true JSON is
   still the right call.)
5. cwd: unified root. Sanity-gate before committing:
   `jq -e . schemas/colmena-openapi.json >/dev/null` AND
   `grep -q status_retrieve schemas/colmena-openapi.json`.
6. Write `schemas/PROVENANCE.md`: pin SHA, date, generator command,
   route used.

## Workflow

1. Branch `fix/frontend-schema-overwrite` off `main`.
2. Commit schema + PROVENANCE + Dockerfile edits. Message: "Fix published
   image losing the Colmena OpenAPI schema" + root-cause body.
3. PRE-MERGE GATE: local `docker build --target <frontend-builder-stage> .`
   on the branch — resolve the real stage name from the Dockerfile when
   writing this step. Dropping `|| true` plus regenerated
   Definitions.d.ts can surface masked tsc failures (`npm run build` is
   `tsc && vite build`); main must not go red.
4. Push, open PR to `main`, merge.
5. Push-to-main triggers `build-and-push.yml` (pushes+PRs to main are
   triggers); successful main build publishes `latest` +
   `main-<run-sha>` tags.

## Acceptance verification

1. Record the new image digest from CI / Docker Hub tag.
2. `docker pull communityfirst/colmena-app@<digest>`; bare stack up (no
   Nextcloud), fresh `.env`; wait for readiness.
3. Static check (assets live under `/usr/share/nginx/html`):
   `docker exec <ctr> sh -c 'grep -qF /api/status/ /usr/share/nginx/html/assets/*.js'`
4. Live probe, bounded: `curl -fsS --max-time 30
   http://localhost:8080/api/status/` returns JSON with backend ok.
5. Decisive end-to-end (browser-harness): app → Add server → server URL →
   Connect succeeds (exact TASK-7 failure step).
6. Login smoke with SUPERADMIN_EMAIL/PASSWORD.
7. Post-acceptance docs (separate change — needs PR/digest/CI values that
   exist only after execution): TODO.md item 3 → done.

## Rollout & docs

- Verify Balena dispatch independently before claiming it: the
  deploy-to-balena-draft listener/repository config is separate from
  build-and-push.yml (its dispatch supplies no repository); production
  stays manual.
- Existing CasaOS installs do NOT auto-update: document pull+recreate in
  the PR description; record the digest to verify.
- Known workflow nits, out of scope: PR builds combine multi-platform
  with `load: true`; former `*/colmena-unified` image name unpublished.
- Follow-up candidates: dev-entrypoint swallow patterns; CI job diffing
  tracked schema vs backend pin.

## Risks / notes

- Schema drift vs backend pin remains possible; PROVENANCE states the
  refresh command (controlled residual risk).
- Nothing in this plan commits inside the frontend repo.
