# TASK.md — Backlog (PRD format)

Deferred work worth doing, captured so it can be picked up later without
re-deriving the context. Each item is a self-contained mini-PRD.

## Done (trimmed — see git history for full PRD/resolution detail)

- **TASK-1** — Recorder 0-frame `OfflineAudioContext` crash: 15s render
  watchdog in `RecorderActions.tsx` + `nothing_recorded` i18n message.
- **TASK-2** — Playwright e2e flake on remote droplets: replaced blind
  `waitForTimeout` with a signal-driven SPA-mount check in
  `tests/e2e/colmena.spec.ts`. Verified 10/10 clean runs on a live droplet.
- **TASK-3** — Single `docker compose up` for the full stack: root
  `docker-compose.yml` + `docker/backend-entrypoint.sh`, automated spreed
  fallback, `DOCKER.md`. e2e 6/7 + 1 flaky (TASK-2's flake).
- **TASK-4** — Nextcloud Circles app race crashing seed: disabled Circles
  via OCS Provisioning API in `docker/backend-entrypoint.sh` (step 12).
- **TASK-5** — Migrated `colmena-os` → `github.com/coolabnet/colmena-unified`.
  CI publishes `communityfirst/colmena-app:latest`; Balena draft deploy
  verified live (6 balena-cli/compose-schema bugs found + fixed along the
  way). `colmena-os` archived.
- **TASK-7** — Real CasaOS host via Terraform (`terraform/casaos-test/`):
  full install loop verified end to end (droplet → CasaOS → app-store →
  install → login), 5 deployment bugs found + fixed, 1 frontend/backend
  schema-skew bug root-caused and flagged. Droplet destroyed after.

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

## How to use this file
- Pick a task, open a branch, and treat its section as the PRD.
- Update **Status** (`open` → `in progress` → `done`) as you go.
- When done, link the implementing commit/PR from the task and flip status.
- Add new deferred items in the same format.
- Once a task lands `done`, trim its full PRD here to a one-line pointer
  under "Done" (like the others above) — full detail lives in git history.
