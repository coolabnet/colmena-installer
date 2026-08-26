# TODO

Open work only. Closed items live in git history (this file supersedes
TASK.md + HANDOFF.md, merged 2026-08-25). Upstream MR statuses re-verified
2026-08-25.

## 1. Nudge 5 unmerged upstream MRs · actionable now
All authored from `luandro/*` forks; we have no write access upstream, so
merging is on the maintainers.

| MR | Contents | Open since |
|---|---|---|
| [!301](https://gitlab.com/colmena-project/dev/backend/-/merge_requests/301) | backend: Nextcloud graceful degradation (502s + logging, Superadmin-group login, folder auto-create) | Jun 04 |
| [!302](https://gitlab.com/colmena-project/dev/backend/-/merge_requests/302) | backend: boot standalone without Nextcloud (`occ.py`/`create_superadmin.py`) | Aug 07 |
| [!358](https://gitlab.com/colmena-project/dev/frontend/-/merge_requests/358) | frontend: chat skeleton loading, My Space nav guard, React key warning (recreates closed !357; branch renamed `NNN-*` to pass CI filters) | Aug 25 |
| [!360](https://gitlab.com/colmena-project/dev/frontend/-/merge_requests/360) | frontend: recorder export hang on empty recordings (render watchdog + nothing_recorded i18n) | Aug 25 |

## 2. colmena-unified cutover · blocked on !301 + !302

- [ ] repoint `.gitmodules` `backend` → `https://gitlab.com/colmena-project/dev/backend.git`, bump to the merged commit
- [ ] delete the "personal fork" warning section from colmena-unified's README
- [ ] rebuild image; rerun standalone smoke test (no Nextcloud container: migrations, seeds, superadmin creation, login)

## 3. Fix schema skew in the published image · PR open

ROOT CAUSE (found 2026-08-25, deeper than "stale schema"): frontend
OpenAPI artifacts are gitignored, and colmena-unified's Dockerfile filled
the gap by copying the NEXTCLOUD wrapper schema over the frontend's and
regenerating from it (`|| true` hiding failures) — so the published image
ships a client for the wrong API entirely.

FIX IMPLEMENTED → [colmena-unified PR #1](https://github.com/coolabnet/colmena-unified/pull/1):
tracked `schemas/colmena-openapi.json` generated offline from the pinned
backend commit (+PROVENANCE), Dockerfile uses it with fail-fast typegen
and a status_retrieve CI guard, plus workflow fixes (invalid sha-tag on
PR builds, single-platform PR validation). Opus approved plan rev 6;
GPT review loop converged to DONE; Build-and-Push CI green on branch.

- [ ] merge PR #1 (maintainer/self per org perms) → CI republishes `latest`
- [ ] acceptance: pull digest → bare stack → Add server → Connect succeeds (exact TASK-7 failure step) → login smoke
- [ ] update this file + colmena-unified README known-gaps note
