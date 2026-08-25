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

## 3. Fix schema skew in the published image · actionable now

The frontend OpenAPI client baked into `communityfirst/colmena-app` predates
the `/api/status/` endpoint, so the SPA's Add-server reachability probe calls
`status_retrieve()` → `TypeError ... not a function` → always reports
offline. Flow is dead in every published image; not fixable via env/runtime
config. Root-caused during CasaOS e2e verification, previously unrecorded.

- [ ] regenerate the frontend client against the current backend schema (or fetch the schema at image-build time)
- [ ] land as an upstream frontend MR; rebuild via colmena-unified CI
- [ ] accept: fresh image where Add server → Connect succeeds against a running stack
