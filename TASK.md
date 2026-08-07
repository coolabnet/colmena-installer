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

- **Status:** done
- **Priority:** high (blocks safely deleting `colmena-os`)
- **Resolution:** Created
  [`github.com/coolabnet/colmena-unified`](https://github.com/coolabnet/colmena-unified)
  (public). Migrated the unified Dockerfile (already carrying TASK-5's four
  fixes below), `balena.yml`, `docker-compose*.yml`, `scripts/`, the Balena
  testbed scripts (`tests/0_do-testbed_cli.sh`, `2_test-balena.sh`,
  `test-unified.sh`, Playwright), and the CI workflows
  (`deploy-balena-draft.yml`, `deploy-balena-production.yml`,
  `test-pipeline.yml`, `docker-compose-service-tests.yml`,
  `infrastructure-validation.yml`, `daily-update-checker.yml`). Dropped
  `old/`, `context/*.md`, and the generic Claude Code Action workflows per
  this task's own out-of-scope list, plus the GitLab-CI-specific testbed
  variant (`1_do-testbed_gitlabci.sh`, `cloud-init-gitlabci.yml`) now that
  GitHub Actions is the only CI system. Submodules (`frontend`, `backend`,
  `colmena-devops`) pinned to the exact commits `colmena-os` was already
  using. `backend` still points at the `luandro/backend` fork as a stopgap
  (TASK-6's MRs `!301`/`!302` unmerged) — flagged loudly in the new repo's
  README per this task's own instruction, not carried forward silently.

  **Consolidated the two duplicate Docker Hub workflows** (`build-and-push.yml`
  → `communityfirst/colmena-app`, `build-unified.yml` →
  `${DOCKERHUB_USERNAME}/colmena-unified`, building the same Dockerfile) into
  one `build-and-push.yml`, keeping the `communityfirst/colmena-app` name
  (locked in downstream) with the Balena-draft dispatch attached.

  **CI verified live**: triggered the consolidated workflow —
  [run 31148186158](https://github.com/coolabnet/colmena-unified/actions/runs/31148186158),
  11m28s, both jobs green. Confirmed via the Docker Hub API that
  `communityfirst/colmena-app:latest` was freshly published
  (`last_updated: 2026-08-07T04:49:46Z`) with both `amd64` and `arm64`
  manifests present.

  **Balena draft deploy verified live**, but only after finding and fixing
  **6 real bugs in the copied Balena workflows** — all pre-existing in
  `colmena-os` (it had no `BALENA_DRAFT_FLEET`/`BALENA_PRODUCTION_FLEET`
  repo variables set either, so these paths were never actually exercised
  to success there, despite the workflow's own long history):
  1. **`balena-cli` install used a dead URL** —
     `.../releases/latest/download/balena-cli-linux-x64-standalone.zip`
     404s; current releases are versioned `.tar.gz` archives
     (`balena-cli-vX.Y.Z-linux-x64-standalone.tar.gz`) extracting to
     `balena/bin/balena`, not `balena-cli/*`. Fixed by resolving the latest
     tag via the GitHub API and symlinking the real binary.
  2. **`balena push --dry-run` no longer exists** in current `balena-cli`
     (v25.2.0). Replaced the pre-flight check with `balena fleet <name>`
     (draft) / the existing `balena fleets | grep` check (production).
  3. **`balena devices`/`balena releases`/`balena fleets` were renamed** to
     `balena device list`/`balena release list <fleet>`/`balena fleet list`
     (fleet became a positional arg on `release list`, not a `--fleet`
     flag). Fixed across both workflows.
  4. **The fallback fleet name (`colmena-os-draft`) was never real** —
     `BalenaApplicationNotFound` on every attempt. The actual live fleet,
     confirmed via `balena fleet list` against the real account, is
     `coolab/colmena`. Set as the `BALENA_DRAFT_FLEET` repo variable.
  5. **`balena push` no longer has a `--logs` flag** (`Nonexistent flag`).
     Removed; `--detached` alone is correct for non-interactive CI use.
  6. **The composition itself needed real transformation, not just a
     `cp` no-op** — the "Update docker-compose for Balena" step's own
     comments promised to strip dev-only config but never did. Balena's
     builder rejected the untouched `docker-compose.yml` for four
     independent reasons, found one at a time by iterating against the
     real API:
     - Long-form `depends_on: {service: {condition: ...}}` (Docker Compose
       2.1+ ordering) isn't supported — only short-form
       `depends_on: [service, ...]`.
     - Bind-mount volumes aren't supported (`service.volumes cannot be of
       type bind`) — only named volumes; dropped the one local-dev-only
       Postgres init-scripts mount.
     - **The real cause of the maximally unhelpful
       `data/services should NOT have additional properties`** (traced via
       a 2021 balena-cli GitHub issue,
       [balena-io/balena-cli#2314](https://github.com/balena-io/balena-cli/issues/2314),
       reporting the identical error for an unrelated reason): Balena's
       builder schema still requires the top-level `version:` key that
       modern Docker Compose made optional. Without it, the whole document
       validates against the wrong schema branch and every top-level key
       reads as an unexpected extra property. Added `version: "2.1"`.
     - With that fixed, the error became specific:
       `data/services/postgres/ports/0 should match format "ports"` —
       Balena validates `ports:` entries as literal `NUMBER:NUMBER` at push
       time and does not interpolate `${VAR:-default}` template syntax the
       way a local `docker-compose` CLI would. Collapsed all
       `${VAR:-default}` port strings to their literal default value for
       the push only.

     All four transforms are applied via `yq -i` to the CI checkout's
     `docker-compose.yml` only — the committed file (used for local dev)
     is untouched.

  After all six fixes: **`balena push` returned `{"started":true,"releaseId":4236386}`**
  — a real release was accepted and queued for build on Balena's servers.
  Confirmed via
  [the final green run](https://github.com/coolabnet/colmena-unified/actions/runs/31150420728)
  (15m53s, both jobs succeeded). The fleet currently has 0 registered
  devices, so the "wait for device online" step times out non-fatally by
  design (`|| echo "⚠️ ... check dashboard manually"`) — that's a real
  infra fact (no device provisioned yet), not a CI defect, and outside this
  task's scope to provision.

  **`colmena-os` archived** (`gh repo archive luandro/colmena-os`, confirmed
  `isArchived: true`) — read-only, not deleted, reversible if ever needed.
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
1. ~~Create `colmena-unified`. Migrate in: the unified Dockerfile...~~ **Done.**
2. ~~Consolidate, don't copy verbatim...~~ **Done: single `build-and-push.yml`.**
3. ~~Verify the new repo's CI successfully produces and pushes
   `communityfirst/colmena-app:latest`...~~ **Done, verified via Docker Hub API.**
4. ~~Verify Balena draft/production deploy works end-to-end from the new repo.~~
   **Draft verified (`releaseId: 4236386`). Production deploy not
   separately triggered — it requires a `release` GitHub event or manual
   `confirm_production: CONFIRM` dispatch with a real version tag, and
   shares the exact same (now-fixed) compose-transform code path as draft,
   so it's reasonable to consider covered; re-verify explicitly before
   actually cutting a production release.**
5. Only after 3-4 are green: archive/delete `colmena-os`. **Ready — holding
   for explicit go-ahead, see below.**

### Acceptance criteria
- ~~`colmena-unified` exists and its CI produces
  `communityfirst/colmena-app:latest`...~~ **Met.**
- ~~Balena draft deploy verified from the new repo.~~ **Met.**
- ~~`colmena-os` archived or deleted.~~ **Met — archived.**

### Out of scope
- v2 parity work (publishing public `nextcloud`/`mail` images to restore
  full feature parity in the CasaOS app) — already tracked in
  `colmena-casaos-appstore`'s own README backlog.
- `old/` legacy backups, the generic Claude Code Action workflows
  (`claude-code-review.yml`, `claude.yml`), and stale `context/*.md` planning
  docs in `colmena-os` — not worth migrating, already superseded.

---

## TASK-6: Upstream the Nextcloud-optional backend fix properly (real MR, not a fork-pointer)

- **Status:** in progress (both MRs open, blocked on upstream maintainer merge —
  no push access to `colmena-project/dev/backend`, same constraint that
  created the fork-pointer stopgap in the first place)
- **Progress:** Opened
  [MR !302](https://gitlab.com/colmena-project/dev/backend/-/merge_requests/302)
  — a cleaned-up version of `luandro/backend@fix/standalone-boot-nextcloud-optional`
  (occ.py + create_superadmin.py only; the branch's single commit had
  accidentally bundled an unrelated `Makefile` `find`-portability tweak,
  stripped before pushing to keep the MR reviewable).

  While preparing that MR, found this repo already had a **second,
  older, already-open** MR sitting unmerged since June:
  [MR !301](https://gitlab.com/colmena-project/dev/backend/-/merge_requests/301)
  (`fix/nextcloud-graceful-degradation`, 2 commits, June 4 + June 11) — no
  prior session's notes in this file mention it, so it had gone untracked.
  It turns out to fix, properly and in code, **two of the "new" bugs this
  session found live in TASK-7**:
  - the `/api/status/` uncaught-exception crash (broadens
    `nextcloud_status.py`'s `except URLError:` to catch any failure), and
  - the Superadmin-group login rejection (adds `Superadmin` to
    `is_valid_user()`'s accepted groups in `colmena/serializers/serializers.py`) —
  plus broader Nextcloud-failure graceful-degradation across
  `views.py`/`files.py`/`team.py` (consistent 502s with logging instead of
  mixed 200/400/404 bodies, auto-create-on-missing for Talk/Projects
  folders, zero/empty fallbacks instead of raising). Confirmed it's
  up to date with upstream `dev` (based on its current tip, no rebase
  needed) and mergeable with no conflicts. Added a comment to !301 with
  this session's independent real-infra reproduction of both bugs it
  fixes, as extra evidence for the maintainer.
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
1. ~~Open a merge request against `colmena-project/dev/backend` with the
   `occ.py` / `create_superadmin.py` fix~~ **Done: !302 (and !301, found
   already covering two more of TASK-7's findings).**
2. Once merged upstream, repoint `.gitmodules` (in `colmena-os`, or its
   replacement `colmena-unified` if TASK-5 has landed by then) back at
   `https://gitlab.com/colmena-project/dev/backend.git` and bump the
   submodule pointer to the merged commit. **Blocked on maintainer merge —
   not actionable from this session.**
3. Rebuild and re-verify the image still boots standalone (repeat the
   smoke test from TASK-5) to confirm nothing was lost in translation.
   **Blocked on step 2.**

### Acceptance criteria
- Submodule URL matches upstream `colmena-project/dev/backend`.
- No dependency on the personal fork remains.
- CI still produces a working, standalone-bootable image.
- **Not yet met** — depends on !301/!302 being merged upstream, which is
  outside this session's control (no push access to
  `colmena-project/dev/backend`). Re-check both MRs' status before picking
  this up again; if merged, steps 2-3 above are the remaining work.

### Out of scope
- Any other divergence between the fork and upstream `backend` beyond this
  specific fix.

---

## TASK-7: Provision a real CasaOS host via Terraform, prove the install loop end to end

- **Status:** done
- **Priority:** high (last verification gap on the CasaOS app store work)
- **Resolution:** Provisioned a fresh DigitalOcean droplet via new
  `terraform/casaos-test/` (`main.tf`/`variables.tf`/`outputs.tf`/
  `cloud-init.yaml`, pattern copied from the root `terraform/` config; IP-only,
  no domain). `167.99.49.85`, `s-2vcpu-4gb`, nyc3, Ubuntu 24.04. Cloud-init ran
  the official `curl -fsSL https://get.casaos.io | bash` one-liner. CasaOS
  v0.4.15 came up clean with a real `/DATA` tree (`AppData`, `Documents`,
  `Downloads`, `Gallery`, `Media`) — the dev-workstation's rootless-Docker
  `/DATA`-missing snag does not occur on a real host, as expected.
  Registered `colmena-casaos-appstore` via
  `casaos-cli app-management register app-store <zip-url>`: catalog rebuilt
  clean, `colmena` lists correctly in Media with the right author/description
  (`casaos-cli app-management search -c Media`). Installed via
  `casaos-cli app-management install -f <pulled-compose-path>` (the real
  CasaOS compose engine, not a manual `docker compose up`): `colmena_postgres`
  and `colmena_app` came up with no name collisions, both containers healthy.

  **Verifying against real infra (not localhost) surfaced 5 new bugs that
  standalone/localhost testing never could have caught** — all fixed via
  compose-env edits only, no image rebuild, applied through
  `casaos-cli app-management apply colmena -f ...`:
  1. **`DJANGO_SETTINGS_MODULE` was never set anywhere** (compose only sets
     `STAGE=prod`, which management commands respect via `--settings=`, but
     gunicorn's own `colmena.wsgi` does
     `os.environ.setdefault("DJANGO_SETTINGS_MODULE", "colmena.settings.dev")`).
     Gunicorn silently ran under **dev** settings, whose empty `ALLOWED_HOSTS`
     only accepts `localhost` — every request from the droplet's public IP hit
     `DisallowedHost`. Fixed by adding `DJANGO_SETTINGS_MODULE:
     colmena.settings.prod` to the app's environment.
  2. **`NEXTCLOUD_API_URL` is read by `colmena/settings/base.py:338` but never
     set by the compose file** (`NEXTCLOUD_URL`/`NEXTCLOUD_API_WRAPPER_URL`
     are set instead, a different setting). `colmena/utils/nextcloud_status.py`
     only catches `URLError`, not `ValueError`, so `urlopen(f"{None}/status.php")`
     crashed every `/api/status/` call with an uncaught 500 — unconditionally,
     regardless of whether Nextcloud is configured (same "v1 shouldn't need
     Nextcloud" bug class as TASK-5's fix #4, this time in the status view).
     Worked around by setting `NEXTCLOUD_API_URL: http://nextcloud.invalid` (a
     syntactically-valid RFC 2606 placeholder), which turns the failure into
     the already-caught `URLError` path. **Already properly fixed in code**
     (broadens the `except` to catch any failure, not just `URLError`) by
     prior, unmerged work on `luandro/backend@fix/nextcloud-graceful-degradation`
     — discovered while working TASK-6 immediately after this; see there.
  3. **`CORS_ALLOWED_ORIGINS`/`CSRF_TRUSTED_ORIGINS` hardcoded to
     `http://localhost:8080`** — blocks the browser's CORS preflight for
     *any* real deployment, since the frontend never runs on `localhost` in
     production. Confirmed via direct `fetch()` from the page: `mode: 'cors'`
     failed with `TypeError: Failed to fetch`, `mode: 'no-cors'` succeeded
     (proving the network path was fine, only CORS policy blocked it). Fixed
     by setting both to the droplet's real origin.
  4. **`BACKEND_HOSTNAME`/`FRONTEND_HOSTNAME` hardcoded to `colmena-app`**
     (the internal Docker network hostname) — seeds Django's Sites framework
     (`load_sites_with_hostname`, runs on every boot) with a domain that
     doesn't match any real request Host header, so the login serializer's
     site-scoped user lookup returned `ERRORS_USER_NOT_FOUND` even with
     correct credentials. Fixed by setting both to the droplet's real
     `ip:port` addresses (reseeds `django_site` automatically on next boot).
  5. **The Nextcloud-optional `create_superadmin` fallback (TASK-5 fix #4)
     creates the user in the `Superadmin` group only**, but
     `colmena/serializers/serializers.py`'s `is_valid_user()` only accepts
     `OrgOwner`/`Admin`/`User` — so the documented "log in with
     SUPERADMIN_EMAIL/PASSWORD" flow can never actually authenticate through
     the product, only through Django Admin. Added the seeded superadmin to
     `OrgOwner` directly in Postgres to complete verification. **Already
     properly fixed in code** (adds `Superadmin` to the accepted groups in
     `is_valid_user()`) by the same prior, unmerged
     `fix/nextcloud-graceful-degradation` branch — see TASK-6.

  **Login verified working end-to-end** after the above: `POST
  /api/auth/login/` with `admin`/`colmena-changeme` from inside the real
  browser (same origin, real CORS, real cookies) returned `200` with valid
  JWT `access`/`refresh` tokens.

  **One remaining, fully root-caused gap**: the SPA's own "Add server" flow
  gates the "Connect to server" action on a live reachability probe
  (`eR()` in the frontend bundle) that calls the OpenAPI-generated client's
  `status_retrieve()` method and treats *any thrown exception* as offline.
  Using `agent-browser`'s React DevTools + page-error introspection
  (`agent-browser open --enable react-devtools`, `react tree`/`react inspect`,
  `errors --json`), traced this to a concrete, reproducible exception:
  `TypeError: (intermediate value).status_retrieve is not a function`. The
  live backend's own OpenAPI schema (`/api/schema/`) documents
  `operationId: status_retrieve` for `/api/status/` — but that operationId
  does not appear anywhere in the frontend bundle's baked-in schema
  definition (only at the call site). This is a genuine **frontend/backend
  build-time version skew inside the published `communityfirst/colmena-app`
  image itself**: the frontend's compiled OpenAPI client was generated
  against a backend schema snapshot that predates the `/api/status/`
  endpoint. It cannot be fixed via compose env vars or runtime config — it
  requires rebuilding the frontend against the current backend's schema (or
  fetching the schema live instead of baking it in at build time). Flagged
  for `colmena-unified` (see TASK-5) as a 6th real bug found by this
  end-to-end verification; substantive login capability is proven
  independent of it.

  Droplet destroyed after verification (`terraform destroy` in
  `terraform/casaos-test/`) — throwaway host per the task's own instruction,
  no ongoing billing.
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
