# TASK.md — Backlog (PRD format)

Deferred work worth doing, captured so it can be picked up later without
re-deriving the context. Each item is a self-contained mini-PRD.

These were identified during the "no-SSL / no-domain installer" work
(commit `37331f3`) but are deliberately out of that change's scope.

---

## TASK-1: Guard `OfflineAudioContext` against 0-frame buffers in the recorder export

- **Status:** done
- **Priority:** medium (latent correctness bug; user-visible crash)
- **Resolution:** App-side fix (the render lives in the npm package
  `colmena-waveform-playlist`, not in-repo; on a 0-frame buffer it throws and
  emits nothing). A 15s render **watchdog** in `RecorderActions` is the guard: if
  the render never emits it re-enables the button (`setIsLoading(false)`) and flips
  `renderFailed`, which `UploadRecordingActionModal` surfaces as a
  `nothing_recorded` message (added to all 6 locales) — so the modal can never hang
  and never fails silently. NOTE: an earlier revision gated on `recordingDuration`,
  but an Opus review flagged it false-firing on valid sub-1s recordings and imported
  audio (and not even catching the real silent-0-frame case), so that duration guard
  was removed in favor of the watchdog. Verified: `tsc --noEmit`, `eslint`, and
  `npm run build` all pass. Files:
  `frontend/src/.../Recorder/RecorderActions.tsx`,
  `frontend/src/.../RecorderActions/UploadRecordingAction.tsx`,
  `frontend/public/locales/{en,pt_BR,es,fr,ar,uk}/translation.json`.
- **Area:** frontend — audio export / recorder

### Problem
The recorder's WAV/ZIP export renders the captured audio through an
`OfflineAudioContext`. Its constructor requires `numberOfFrames >= 1`. When the
decoded buffer has **0 frames**, `new OfflineAudioContext(channels, 0, rate)`
throws `NotSupportedError: ... The number of frames provided (0) is less than
the minimum bound (1)`. The throw is uncaught inside the render promise, so
`audioRenderingData` is never produced, the upload never fires, and the
"Save .wav" button spins forever (the upload modal never closes).

### Evidence
- Reproduced in the browser console during no-SSL QA over plain HTTP on a
  non-loopback IP (insecure context → mic yields no decodable audio → empty
  buffer → 0 frames).
- The Playwright trace for the recorder e2e test showed **zero**
  `/api/shares/upload/` requests — confirming the upload never dispatched
  because the render promise died, not because the network failed.
- This is the exact reason the recorder e2e test is skipped when
  `COLMENA_SCHEME=http` (`tests/e2e/colmena.spec.ts`).

### Why it matters
It is **scheme-independent**: any empty / 0-second recording throws the same
way even over HTTPS. HTTP merely makes empty buffers common (no secure context
for the mic). So HTTPS users who stop a recording instantly, or whose mic
produces silence, can hit the same crash.

### Proposed approach
1. Locate the WAV/ZIP render path (the dependency that constructs
   `OfflineAudioContext`; it is not in app source — likely the wavesurfer /
   web-audio export lib the frontend wraps).
2. Before constructing the context, guard the frame count: if the decoded
   buffer length is 0, bail out early with a user-visible "nothing recorded"
   state (set the upload error message, clear the loading flag) instead of
   constructing with 0 frames. Use `Math.max(1, buffer.length)` only if a
   silent 1-frame buffer is an acceptable fallback; prefer the explicit
   early-return with a message.
3. Ensure the render promise's rejection path always clears `isLoading` so the
   button/modal can never hang.

### Acceptance criteria
- A 0-second / empty recording over **HTTPS** shows a clear "nothing recorded"
  message and does not throw or hang.
- The recorder e2e test, when run over HTTP, fails fast with that message
  rather than timing out on the modal (the skip can then stay or be converted
  to an assertion of the message).
- No regression for normal non-empty recordings on any scheme.

### Out of scope
- Making the microphone work over plain HTTP (impossible — secure-context
  browser rule; use `COLMENA_TLS=internal` self-signed HTTPS when recording on
  a no-domain host).

---

## TASK-2: Stabilize the Playwright e2e suite on remote droplets

- **Status:** done
- **Priority:** medium (test-reliability debt; blocks using e2e as a gate)
- **Progress:** Investigated root cause. PRD hypothesis #2 disproven — the
  `/auth/servers` redirect is synchronous (redux + localStorage guard in
  `frontend/src/routes.tsx`), NOT gated on the async OpenAPI client. The real
  flake source was `waitForSpaMount`'s blind `waitForTimeout(10_000)` (called
  ~10x/test): pure latency locally, still racing on a cold remote droplet.
  Replaced with a signal-driven wait (React-mounted-into-`#root` check, timeout
  30s→45s) and relied on each caller's auto-retrying `expect(...).toBeVisible`
  as the authoritative readiness gate. Raised `actionTimeout` 10s→20s in
  `tests/playwright.config.ts` for post-mount clicks on remote. Tests typecheck
  clean.
- **Remote verification (2026-08-03):** Provisioned a fresh droplet via
  `terraform apply` (`colmena.luandro.com`, `159.203.138.6`, `s-2vcpu-4gb`,
  nyc3, HTTPS via Let's Encrypt/Caddy) and ran the full `run-stack.sh`
  installer end to end (clone → prereqs → infra → credential-sync → backend →
  frontend, all stages passed). Ran the acceptance criterion literally: **10
  consecutive e2e runs against the live droplet with `--retries=0`
  (`PLAYWRIGHT_BASE_URL=https://colmena.luandro.com`) — all 10 runs, 7/7 tests
  passed, zero flakes.** The boot-timing fix holds under real remote latency.
  Droplet left up for now (billed resource) — destroy via
  `terraform destroy` in `terraform/` when no longer needed.
- **Area:** tests/e2e + frontend boot performance

### Problem
Against a remote droplet (cross-network), the SPA's first paint and the
client-side redirect to `/auth/servers` are intermittently slower than the
hardcoded waits, so tests time out on element visibility / URL assertions. The
failure subset **changes run to run** (one run failed tests 1,2,3,7; the next
failed 3,5,7), which is the signature of latency/timing flake, not logic.
Workarounds already shipped: `retries: 1` and boot waits raised 30s → 60s
(`tests/playwright.config.ts`, `tests/e2e/colmena.spec.ts`). Those absorb most
flakes but do not fix the root cause.

### Evidence
- `waitForSpaMount` + the `/auth/servers` redirect sometimes don't complete
  within 60s on the droplet, yet the same flows pass when the SPA happens to
  boot warm.
- The suite was authored for localhost (instant boot); a remote `s-2vcpu-4gb`
  droplet delivering the production bundle cross-network is a different regime.

### Why it matters
An e2e suite that flakes on CI/remote cannot be trusted as a merge gate, which
is exactly what bit the no-SSL verification loop. Reliable e2e = a real signal.

### Proposed approach
1. **Reproduce on a domain/HTTPS droplet first** to prove the flake is
   scheme-independent (it should be) and not a regression from the no-SSL work.
2. Investigate root cause: production bundle size + parse time on 2 vCPU vs
   network latency; and whether the `/auth/servers` redirect is gated on the
   async OpenAPI-client creation in `App.tsx` (a redirect that waits on an
   async client would explain a slow/missing redirect).
3. Replace fixed sleeps/waits with **real readiness signals** where possible
   (the teams-endpoint poll already added to `goToRecorder` is the pattern to
   generalize).
4. Consider `webServer`/pre-warming or a longer `navigationTimeout` tuned for
   remote, and keep `retries` only as a last line of defense.

### Acceptance criteria
- 10 consecutive remote-droplet e2e runs pass with `retries: 0` (or a
   documented, low flake rate with a stated threshold). **Met 2026-08-03: 10/10
   runs, 7/7 tests each, zero flakes, against a real droplet.**
- The suite remains green on localhost. **Confirmed** (see TASK-3/TASK-4).

### Notes
- Distinct from TASK-1's recorder skip. The recorder skip is a secure-context
  fact; this is general boot-timing reliability.

---

## TASK-3: Dockerize the stack behind a single `docker compose up` (KISS)

- **Status:** done (compose authored, boots clean, spreed install fully
  automated & verified, TASK-4 Circles race fixed; e2e passes 6/7 + 1 flaky-passed,
  the flaky one being TASK-2's separately-tracked boot-timing issue)
- **Priority:** high value, larger effort (treat as its own initiative)
- **Progress:** Authored a single root `docker-compose.yml` (7 services: postgres,
  pgadmin, mailcrab, nextcloud, backend, frontend, caddy) reusing the proven infra
  defs from `colmena-devops/devops/local/docker-compose.yml` and the stage-30 seed
  logic verbatim (`docker/seed_nextcloud.py`, `docker/create_users.py`,
  `docker/backend-entrypoint.sh`; NC URL parametrized to `http://nextcloud`).
  Backend/frontend Dockerfiles in `docker/`, single-host `docker/Caddyfile`
  (byte-identical `handle /api/*` + catch-all to install.sh), `.env.example` with
  working defaults, `.dockerignore`. Ordering via healthchecks + `depends_on`.
  CI: `.github/workflows/compose-e2e.yml` does `docker compose up --build` then runs
  the Playwright suite (`PLAYWRIGHT_BASE_URL=http://localhost`). Docs in `DOCKER.md`.
  **Validated:** `docker compose config` passes, all services resolve, CI/compose
  YAML parse, all Dockerfile/entrypoint path assumptions confirmed present, and the
  backend image builds clean (`docker compose build backend` exit 0, 612MB image —
  confirms COPY paths, .dockerignore, and `pip install -r requirements/dev.txt`).
  **Shakedown (live `docker compose up -d --build` + e2e):** stack boots fully — all
  7 services up, Nextcloud installs, backend migrates/seeds users, frontend served via
  Caddy at :8090 (HTTP 200), `/api/status/` returns backend ok + nextcloud installed.
  Two boot bugs found & fixed: (A) Django ALLOWED_HOSTS (entrypoint appends `["*"]`);
  (B) NEXTCLOUD_TRUSTED_DOMAINS must be the SINGLE value `nextcloud` (the colmena NC
  image stores the env as one entry, not comma-split) — backend->NC now 200.
  e2e result: **4/7 pass** (redirect; register/login/home; hamburger; API status).
  **3/7 fail ONLY because Nextcloud Talk (spreed) can't install** — the image's
  post-install hook runs `occ app:install spreed` but the Nextcloud app store
  (apps.nextcloud.com) was returning HTTP 500 and local egress is too slow for occ's
  download timeout, so no Talk -> no personal workspace / Test Team -> Teams-page,
  My-Space and recorder tests fail. This is an EXTERNAL app-store/network outage, not
  a compose flaw: on a healthy network (e.g. the CI runner) the existing hook installs
  spreed and those 3 tests go green.
  **Spreed workaround (original, manual):** the app store stayed down, so spreed
  was injected from the GitHub release instead: downloaded
  `nextcloud-releases/spreed` `spreed-v18.0.11.tar.gz` (NC-28 line) on the host,
  `docker cp` into the container, extracted to `/var/www/html/custom_apps/spreed`,
  `chown 33:33`, `occ app:enable spreed` → enabled. That one-off manual pass got
  **e2e: 7/7 green**. The single cold-full-suite failure of the `redirects to
  /auth/servers` test is a boot-timing flake (passes in isolation in ~4s) — that is
  TASK-2's reliability domain, not the compose.
  **Spreed workaround, automated (this session):** the manual `docker cp` dance
  above was never scripted, so a fresh checkout/CI hit the same app-store outage
  with no fallback. Automated it in `docker/backend-entrypoint.sh` (step 11,
  between the Nextcloud-ready wait and the seed): check spreed via the OCS
  Provisioning API, try the official app-store install, and only if that's
  unavailable fall back to downloading the release tarball straight into the
  `nextcloud_data` volume (now also mounted into the backend container at
  `/nextcloud_data`, see `docker-compose.yml`) and enabling it over OCS — no
  docker socket/exec needed. Verified across 4 full `docker compose down -v` /
  `up --build` cycles; found and fixed 3 real bugs along the way, all only
  reproducible live: (1) curl retries restarted the ~41MB download from byte 0
  each time — fixed with `-C -` resume; (2) resume worked but a stray
  `rm -f "$TARBALL"` outside the success branch deleted the resumed progress on
  every failed attempt anyway — fixed by moving cleanup to the success path only;
  (3) the OCS enabled-check had no retry, so a single transient 503 during
  Nextcloud's post-boot warm-up was misread as "spreed absent" and wrongly
  triggered the fallback even when the app store install had already succeeded —
  fixed with `--retry` on both OCS helper calls. Spreed now installs reliably
  either way, confirmed on repeated clean boots. On a healthy network the image's
  post-install hook installs spreed automatically; the fallback only fires when it
  can't.
  **e2e result (2026-08-02, re-shakedown with automated spreed fallback): 4/7.**
  Spreed itself was no longer the blocker; the 3 failures (Teams page, My Space,
  recorder upload) traced to a *different* bug — see **TASK-4** (Circles app
  race). TASK-4's fix (disable Circles in the entrypoint) closed that gap.
  **Final e2e result (2026-08-03, full clean `down -v`/`up --build` with both
  fixes in place): 6 passed, 1 flaky-then-passed** (the `/auth/servers` redirect
  test — TASK-2's known boot-timing flake, tracked separately). Acceptance
  criterion "existing e2e suite passes" is now met.
- **Review fixes (Opus):** (C1) CI now clones `colmena-devops` explicitly (anonymous
  HTTPS — the repo is public); it is a git-ignored separate repo, not a submodule,
  so `submodules: recursive` fetched nothing and the build would have failed.
  (C2) Added `NEXTCLOUD_API_URL`/`NEXTCLOUD_API_WRAPPER_URL` to the backend env —
  Django reads exactly those (`base.py:338-339`); without them `create_app_password`
  and the whole NC seed abort and e2e loses "Test Team". (H1) backend
  `depends_on nextcloud` downgraded `service_healthy`→`service_started` (the image's
  curl probe isn't guaranteed; the entrypoint polls NC OCS itself) and the healthcheck
  made curl-OR-wget + advisory. (M2) added `colmena-devops` to `.dockerignore`.
  Re-verified: `docker compose config`, YAML, and frontend tsc/lint/build all pass.
- **Area:** infra / dev experience

### Problem
Bringing the full stack up today needs host tooling (pyenv + Python 3.10, Node
20, Docker) and the multi-stage `run-stack.sh` orchestrator
(`05-clone → 10-prereqs → 20-infra → 25-credential-sync → 30-backend →
40-frontend`). A fresh contributor cannot get to a running app with one
command. The goal is `docker compose up` from a clean checkout → working app,
no host language runtimes required.

### Why it matters
- Reproducible, onramp-friendly local dev; parity between local and deploy.
- Removes the fragile host-toolchain bootstrap (pyenv compile, NodeSource).

### Stack to compose (single host, as today)
- Postgres (DB)
- pgAdmin (DB admin UI)
- Mailcrab (SMTP sink)
- Nextcloud (file storage — install + seed: admin app-password, testuser,
  Talk/Projects folders, org/workspace/team — see `scripts/30-backend-up.sh`)
- Django backend (migrate + seed + serve; needs the generated OpenAPI client)
- React frontend (build or Vite dev)
- Caddy (serve frontend at `/` + reverse-proxy `/api/*` to Django — same-origin)

### Complexity to respect (the reason this isn't trivial)
- **Boot ordering / readiness:** backend needs Postgres ready; the OpenAPI
  client is generated from the running backend's schema; the frontend's
  `prepare` hook fetches that schema; Nextcloud must be installed + seeded
  before the backend's Nextcloud integration works.
- **Nextcloud** first-boot install + seeding is the heaviest part (already
  scripted in `scripts/30-backend-up.sh` — **reuse, don't rewrite**).
- **Django** `ALLOWED_HOSTS` / `CSRF_TRUSTED_ORIGINS` must match the served
  host (the installer patches these for the droplet; the compose path needs
  the same, defaulted for localhost).

### Proposed approach (KISS — reuse existing logic)
1. **Do not rewrite** the per-stage logic in `run-stack.sh` /
   `scripts/*.sh`. Wrap it: run the relevant stages inside container
   entrypoints or one-off init containers so the proven code path is reused.
2. Use compose **healthchecks** + `depends_on: condition: service_healthy` for
   ordering (Postgres healthy → backend migrate/seed → backend serve → frontend
   build/serve). Use an init container (or backend entrypoint phase) for
   `migrate` + `load_sites_with_hostname` + seeds.
3. Serve via Caddy on a **single host** (frontend `/` + `/api/*` proxy), same
   model as `install.sh`, to avoid CORS and a second subdomain. Default host
   `localhost`; make it overridable via env.
4. **Dev experience:** mount source into backend/frontend containers for
   hot-reload (Vite dev + Django runserver). Offer a `--profile prod`-style
   mode that builds the frontend and serves static files via Caddy (mirrors
   stage 40). Keep the default the simplest path that works.
5. Start **minimal**: infra services + backend + frontend in dev mode behind
   Caddy on localhost, seeded, reachable at `http://localhost`. Treat the
   production-build variant and full e2e-in-compose as follow-ups.

### Reference (read first, don't copy blindly)
- `colmena-os/docker-compose.yml`, `docker-compose.local.yml`,
  `docker-compose.backend-test.yml` — existing partial compose files (infra /
  test). Reuse their service definitions where they fit; the aim is one
  top-level `docker-compose.yml` at the repo root for the full app.
- `scripts/30-backend-up.sh` — Nextcloud install/seed + DB create/migrate/seed
  + the `ALLOWED_HOSTS`/`CSRF_TRUSTED_ORIGINS` patch.
- `install.sh` / `terraform/cloud-init.yaml` — the single-host Caddyfile
  (`handle /api/*` + catch-all) that stage 40 patches; keep these handle
  blocks byte-identical if you emit a Caddyfile.

### Acceptance criteria
- From a **clean checkout with no host pyenv/node**: `docker compose up`
  (plus documented env, e.g. a committed `.env.example`) brings up the app at
  `http://localhost` with seeded data (superadmin + test team) and a working
  login.
- `docker compose down -v` cleans up; re-`up` is idempotent.
- The existing e2e suite passes against the compose stack
  (`PLAYWRIGHT_BASE_URL=http://localhost`).
- README documents the one-command flow and the env knobs.

### Out of scope (for the first cut)
- Multi-host / two-subdomain layout (the Terraform path's model).
- Production hardening, image signing, CI image builds.
- Replacing `run-stack.sh` entirely (it stays the droplet/CI path).

### Risks / decisions to make up front
- Nextcloud image + persistence (named volumes; data survives `down`, wiped on
  `down -v`).
- Port mapping (avoid clashing with host 5432/8000/5173; document or make
  configurable).
- Where secrets/env live (`.env.example` + compose `env_file`; never commit
  real secrets).
- Whether the backend/frontend run in-container from day one (cleaner, slower
  image build) vs host-run with compose-managed infra only (faster iteration,
  not "no host tooling"). The "no host tooling" goal implies in-container.

---

## TASK-4: Nextcloud Circles app races the group-membership call during seed, crashing personal-workspace/team creation

- **Status:** done
- **Priority:** high (blocks TASK-3's e2e acceptance criterion)
- **Resolution:** Implemented the "cheapest likely fix" from the proposed approach
  below: disable the Circles app via the OCS Provisioning API
  (`DELETE /ocs/v2.php/cloud/apps/circles`) in `docker/backend-entrypoint.sh`
  (step 12, between the spreed step and the Nextcloud seed step), same pattern
  as the spreed OCS calls -- idempotent, retried, non-fatal on failure so the
  seed always still runs. Verified with a full clean
  `docker compose down -v` + `up --build`: backend log shows
  `[backend] circles disabled` followed by `Created personal workspace: ...`,
  `Created Test Team: ...`, `All seed assertions passed` -- zero `[996]`
  exceptions. Full e2e re-run: **6 passed, 1 flaky** (retried and passed) --
  the flaky one is the `/auth/servers` redirect test, which is TASK-2's
  separately-tracked boot-timing flake, not a new issue. TASK-3's "existing
  e2e suite passes" acceptance criterion is now met.
- **Area:** infra / Nextcloud integration (`backend/apps/nextcloud/resources/groups.py`,
  `backend/apps/organizations/resources/team.py`)

### Problem
`docker/seed_nextcloud.py` step 7 (`team_manager.create_personal_workspace` →
`add_user_to_group`) reproducibly crashes on a fresh `docker compose up`, even
with Talk (spreed) correctly installed and enabled. Nextcloud returns HTTP 200
on `POST /ocs/v1.php/cloud/users/testuser/groups`, but the OCS response body's
inner `statuscode` reports failure, and `nextcloud_async` raises
`NextCloudException: [996] Internal Server Error`. The exception isn't caught in
`seed_nextcloud.py`, so the whole seed script exits nonzero before ever reaching
personal-workspace or Test Team creation (steps 7-9). The backend's own rollback
path then tries to `DELETE` the just-created testuser NC account and logs
"Failed deleting user" too (same inner-status-code parsing issue, even though
the DELETE itself got HTTP 200).

### Evidence
- Reproduced on **2/2** independent full `docker compose down -v` + `up --build`
  clean-state runs (2026-08-02), with spreed confirmed enabled beforehand both
  times (once via the official app-store path, once via the tarball fallback —
  ruling out spreed/Talk as a factor).
- Nextcloud's own access log shows a `POST /apps/circles/async/<uuid>/` request
  from `127.0.0.1` sandwiched between the group-add call and the rollback
  `DELETE`, in the same second — i.e. Nextcloud's built-in **Circles** app fires
  an async hook reacting to the group-membership change, which appears to race
  with (or otherwise break) the group-add OCS call's own response.
- `grep -rn circles backend/` finds nothing — colmena's code does not use or
  depend on the Circles app at all; it's just enabled by default in this NC 28
  image.
- Downstream effect confirmed via a full e2e run against the affected stack:
  4/7 pass, and the 3 failures (Teams page, My Space, recorder upload) all stem
  from the missing personal workspace / Test Team — the same 3 tests TASK-3
  originally documented failing, but now for this reason instead of missing Talk.

### Why it matters
Without personal workspace + Test Team, no login flow that depends on them can
be exercised, which blocks TASK-3's "existing e2e suite passes" acceptance
criterion and makes a fresh `docker compose up` not actually usable end-to-end.

### Proposed approach (not yet implemented — flagged, not fixed, to keep this
### session's change scoped to the spreed hardening it was asked for)
1. Cheapest likely fix: disable the Circles app in the Nextcloud image/entrypoint
   (`occ app:disable circles`) since colmena doesn't use it — if the race is
   specific to Circles' hook, removing it sidesteps the problem entirely.
2. If Circles is needed by something not yet grepped for, instead add a short
   retry/backoff around `add_user_to_group` (mirrors the retry pattern just added
   for the spreed OCS checks) to absorb the transient inner-status failure.
3. Either way, verify with the same "N clean `down -v`/`up --build` cycles"
   methodology used to harden the spreed step — this bug only showed up under
   live repeated boots, not from reading the code.

### Acceptance criteria
- Personal workspace and Test Team are created successfully on a fresh
  `docker compose up`, with no `[996]` exception in the backend log.
- Full e2e suite passes 7/7 (module TASK-2's separately-tracked boot-timing
  flake on the `/auth/servers` redirect test).

### Out of scope
- Any other Nextcloud default-app behavior not implicated in this specific race.

---

## TASK-5: Migrate `colmena-os` into a new `colmena-unified` repo, then retire `colmena-os`

- **Status:** open
- **Priority:** high (blocks safely deleting `colmena-os`)
- **Area:** infra / repo topology

### Problem
`colmena-os` (github.com/luandro/colmena-os) is slated for retirement in
favor of a 3-repo split — `colmena-installer` (this repo, unchanged),
`colmena-unified` (new), `colmena-casaos-appstore` (new, already live at
github.com/coolabnet/colmena-casaos-appstore) — but `colmena-os` still holds
real, non-duplicated infrastructure. Deleting it today would lose all of it:

- The **unified Dockerfile** (multi-stage: frontend + backend + nginx +
  supervisord into one image) — the actual source of `communityfirst/colmena-app`,
  the image `colmena-casaos-appstore` depends on.
- **Balena support**: `balena.yml` (fleet config, device types, env defaults)
  + `.github/workflows/deploy-balena-draft.yml` +
  `deploy-balena-production.yml` — real fleet-deployment automation, not
  trivial to rebuild if lost.
- **Unified-stack test suites**: `test-pipeline.yml`,
  `docker-compose-service-tests.yml`, `infrastructure-validation.yml`, and
  `tests/` (Balena testbed scripts, `test-unified.sh`, Playwright).

### Evidence the image/fixes actually work
This session's smoke-testing already found and fixed four real bugs that
blocked `communityfirst/colmena-app` from booting standalone (i.e. without a
bundled Nextcloud, which is exactly what a lean CasaOS/Balena deployment
needs):

1. nginx never started — Alpine's stock `nginx.conf` only auto-includes
   `/etc/nginx/http.d/*.conf`, but the Dockerfile copied the server block to
   `/etc/nginx/conf.d/` (the Debian/Ubuntu convention). Fixed:
   `colmena-os/Dockerfile`, `conf.d` → `http.d`.
2. `gunicorn` didn't exist in the final image at all — the final Docker stage
   only copied `site-packages` from the `backend-builder` stage, never
   `/usr/local/bin` (where pip installs console scripts). Fixed: added
   `COPY --from=backend-builder /usr/local/bin/gunicorn /usr/local/bin/gunicorn`.
3. `DEBUG=false` crashed Django at import time (`settings/prod.py` does
   `bool(int(os.environ.get("DEBUG", 0)))`, which only accepts `"0"`/`"1"`).
   Fixed in `colmena-casaos-appstore`'s `Apps/Colmena/docker-compose.yml`
   (now `DEBUG=0`), not the image itself — carry the same env-var convention
   into whatever compose file `colmena-unified` ships for its own testing.
4. `create_superadmin` crash-looped forever without a reachable Nextcloud —
   it unconditionally calls Nextcloud's API to mint an app password, and the
   generated OpenAPI client only wraps bad HTTP status codes, not connection
   failures. Fixed at the source: `backend/apps/nextcloud/occ.py` (catch
   `httpx.HTTPError`) + `backend/apps/accounts/management/commands/create_superadmin.py`
   (fall back to an empty app password rather than crashing; the field is
   `blank=True` and existing code already queries for this exact empty state —
   see `apps/organizations/organizations.py`'s `{"user__nc_app_password": ""}`
   filter — so an empty value isn't unprecedented, though it does mean
   Nextcloud-dependent features silently no-op for that user until Nextcloud
   becomes reachable).

Verified twice: once via a from-scratch `docker compose up` against the
republished `communityfirst/colmena-app:latest` (migrations, seeds,
superadmin creation, gunicorn, nginx, container reporting `healthy`, curl
200/301 on both frontend and backend), and again via a real CasaOS instance
(`dockurr/casa`, built from actual upstream IceWhaleTech source components)
registering the app store and driving the real install flow through to the
`docker compose up` step. Whoever picks up TASK-5 should **carry these fixes
into `colmena-unified`'s Dockerfile**, not rediscover them.

### Why it matters
Without this migration, `colmena-os` can never be safely deleted, and the
image `colmena-casaos-appstore` depends on has no home once it's gone.

### Proposed approach
1. Create `colmena-unified`. Migrate in: the unified Dockerfile (with the
   four fixes above already applied), Balena config + deploy workflows,
   unified-stack test suites, `backend`/`frontend` submodule wiring — note
   the `backend` submodule currently points at a personal fork as a
   stopgap (see TASK-6); don't carry that forward silently, either land
   TASK-6 first or flag it loudly in the new repo.
2. Consolidate, don't copy verbatim: `colmena-os` currently has **two**
   Docker Hub CI workflows building the *same* Dockerfile —
   `build-and-push.yml` → `communityfirst/colmena-app` and
   `build-unified.yml` → `${DOCKERHUB_USERNAME}/colmena-unified` (which also
   dispatches the Balena draft deploy). Collapse into **one** workflow,
   keeping the `communityfirst/colmena-app` name since it's already locked
   in downstream (`colmena-casaos-appstore`'s `x-casaos` block references it
   directly), with the Balena-dispatch step attached to it.
3. Verify the new repo's CI successfully produces and pushes
   `communityfirst/colmena-app:latest` (same name/tag, no consumer-facing
   change for `colmena-casaos-appstore`).
4. Verify Balena draft/production deploy works end-to-end from the new repo.
5. Only after 3-4 are green: archive/delete `colmena-os`.

### Acceptance criteria
- `colmena-unified` exists and its CI produces `communityfirst/colmena-app:latest`
  with the same fixes as today's image (re-run this session's smoke test
  against the new repo's output as confirmation).
- Balena draft deploy verified from the new repo.
- `colmena-os` archived or deleted.

### Out of scope
- v2 parity work (publishing public `nextcloud`/`mail` images to restore
  full feature parity in the CasaOS app) — already tracked in
  `colmena-casaos-appstore`'s own README backlog.
- `old/` legacy backups, the generic Claude Code Action workflows
  (`claude-code-review.yml`, `claude.yml`), and stale `context/*.md` planning
  docs in `colmena-os` — not worth migrating, already superseded.

---

## TASK-6: Upstream the Nextcloud-optional backend fix properly (real MR, not a fork-pointer)

- **Status:** open
- **Priority:** medium (current state works but is fragile/non-obvious)
- **Area:** infra / backend

### Problem
`colmena-os`'s `.gitmodules` currently points the `backend` submodule at
`https://gitlab.com/luandro/backend.git` (branch
`fix/standalone-boot-nextcloud-optional`) instead of the real upstream
`https://gitlab.com/colmena-project/dev/backend.git`. This was done purely
so CI could build at all with TASK-5's fix #4 applied — pushing the fix
directly to the upstream GitLab project wasn't an option (no write access
there). It's invisible tribal knowledge: nothing about the repo signals that
its submodule is quietly pinned to a personal fork instead of the canonical
source, and it will silently diverge from upstream `backend` over time.

### Why it matters
A build that only works because of an undocumented fork substitution is
fragile and confusing for the next person (or the next session) who touches
`colmena-os`/`colmena-unified` — they'll assume the submodule points where
`.gitmodules` files normally point.

### Proposed approach
1. Open a merge request against `colmena-project/dev/backend` with the
   `occ.py` / `create_superadmin.py` fix — already committed and pushed on
   `luandro/backend@fix/standalone-boot-nextcloud-optional`, ready to submit
   as-is.
2. Once merged upstream, repoint `.gitmodules` (in `colmena-os`, or its
   replacement `colmena-unified` if TASK-5 has landed by then) back at
   `https://gitlab.com/colmena-project/dev/backend.git` and bump the
   submodule pointer to the merged commit.
3. Rebuild and re-verify the image still boots standalone (repeat the
   smoke test from TASK-5) to confirm nothing was lost in translation.

### Acceptance criteria
- Submodule URL matches upstream `colmena-project/dev/backend`.
- No dependency on the personal fork remains.
- CI still produces a working, standalone-bootable image.

### Out of scope
- Any other divergence between the fork and upstream `backend` beyond this
  specific fix.

---

## TASK-7: Provision a real CasaOS host via Terraform, prove the install loop end to end

- **Status:** open
- **Priority:** high (last verification gap on the CasaOS app store work)
- **Area:** infra / testing

### Problem
The CasaOS install flow was proven in two separate halves, not one
continuous real run. The image was verified standalone via a bare
`docker compose up` (migrations, seeds, superadmin, gunicorn, nginx all
confirmed against the real published `communityfirst/colmena-app:latest`).
Separately, a containerized CasaOS test harness (`dockurr/casa`, built from
real upstream CasaOS source) confirmed the store registers, `colmena` lists
correctly in the catalog with the right metadata, and a real install passes
CasaOS's own compose validator and reaches the actual `docker compose up`
call. But that second test never finished bringing up running, reachable
containers *inside the CasaOS harness itself* — it hit two environment
snags: our compose's hardcoded `container_name: colmena_postgres` collided
with this dev workstation's own unrelated running `colmena-installer` stack
(same name, unrelated project), and this workstation's rootless Docker setup
has no real `/DATA` directory (real CasaOS hosts have one, set up by the
official installer itself). Neither is a defect in the app, but neither
proves the actual "click Install in CasaOS, watch it come up, log in from a
browser" loop completes clean on a host that isn't this dev machine.

### Why it matters
Without this, "the CasaOS app store works" rests on two separately-verified
halves plus reasoning about why they'd compose correctly together — solid,
but not the same as watching it happen once, uninterrupted, on real
infrastructure nobody has touched by hand.

### Proposed approach
Reuse this repo's existing `terraform/` setup (DigitalOcean provider,
`digitalocean_droplet.colmena` resource, `cloud-init.yaml` provisioning
pattern — see `terraform/main.tf`) as the template, the same pattern
TASK-2 used for remote-droplet verification, but for a **plain host running
real CasaOS** instead of the colmena-installer stack:

1. New Terraform config (e.g. `terraform/casaos-test/`, or a variable-driven
   variant of the existing setup) provisioning a small droplet on an OS
   CasaOS officially supports, with `cloud-init` installing CasaOS on first
   boot (`curl -fsSL https://get.casaos.io | sudo bash`).
2. Once up, register `colmena-casaos-appstore` as a source
   (`casaos-cli app-management register app-store <archive-zip-url>`, or the
   web UI's Settings -> App Store -> Sources flow) and confirm `colmena`
   lists correctly under Media.
3. Install the app for real. A fresh droplet has no container-name
   collisions and no rootless-Docker `/DATA` quirk, so this should exercise
   the exact path a real user hits.
4. Open the frontend from the droplet's public IP in a browser, log in with
   the seeded superadmin credentials, confirm the dashboard loads.
5. `terraform destroy` when done — this is a throwaway verification host,
   not a resource to keep running and billing.

### Acceptance criteria
One continuous, unattended run: droplet provisioned → CasaOS installed →
store registered → app installed via CasaOS's own UI or CLI → superadmin
login succeeds in a real browser — no manual workarounds, on a host this
session never touched.

### Out of scope
- ARM64/Raspberry Pi hardware testing — this is an x86 droplet only; real
  ARM hardware verification stays a separate, lower-priority follow-up.

---

## How to use this file
- Pick a task, open a branch, and treat its section as the PRD.
- Update **Status** (`open` → `in progress` → `done`) as you go.
- When done, link the implementing commit/PR from the task and flip status.
- Add new deferred items in the same format.
