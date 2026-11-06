# GitHub Actions Workflows (fork)

### `images.yml` — audit, test, build, publish

Runs on pushes and pull requests to `main`.

| Job | What it does | Blocks the deploy? |
|---|---|---|
| **audit** | `pip-audit` on `requirements.txt`, `npm audit` (production deps, high+) | yes |
| **test** | unit tests + `scripts/ci/smoke.sh` against Postgres 16 and Redis | yes |
| **images** | builds backend + frontend with SBOM and provenance; on `main` pushes to `ghcr.io/<owner>/openthreat-{backend,frontend}:sha-<commit>` and `:main` | — |

Pull requests (including Dependabot's) run everything but never push images.
The VPS pulls the images itself (`deploy/deploy.sh`, see `deploy/README.md`);
nothing in GitHub has access to the server.

All actions are pinned to commit SHAs; Dependabot keeps them updated.

Upstream's `ci.yml`, `quick-check.yml` and `deploy.yml` were removed in this
fork: `images.yml` covers them, `ci.yml` could no longer install its test
dependencies, and `deploy.yml` pushed via SSH to the upstream author's server.
