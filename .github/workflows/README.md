# GitHub Actions Workflows (fork)

### `images.yml` — audit, test, build, publish

Runs on pushes and pull requests to `main`.

| Job | What it does | Blocks the deploy? |
|---|---|---|
| **audit** | `pip-audit` on `requirements.txt`, `npm audit` (production deps, high+) | yes |
| **test** | unit tests + `scripts/ci/smoke.sh` against Postgres 16 and Redis | yes |
| **stack** | builds both images and runs the real `docker-compose.yml` (nginx, frontend, backend, worker, beat, Postgres, Redis); `scripts/ci/stack-test.sh` checks pages, API, redirect, lock-downs, bundle URLs and Celery through nginx | yes |
| **images** | builds backend + frontend with SBOM and provenance; on `main` pushes to `ghcr.io/<owner>/openthreat-{backend,frontend}:sha-<commit>` and `:main` | — |

Pull requests (including Dependabot's) run everything but never push images.
The VPS pulls the images itself (`deploy/deploy.sh`, see `deploy/README.md`);
nothing in GitHub has access to the server.

All actions are pinned to commit SHAs; Dependabot keeps them updated.

### `dependabot-automerge.yml` — merge Dependabot PRs that pass

Runs after **Images** succeeded on a Dependabot PR (GitHub's recommended
two-workflow pattern: the PR run is untrusted and read-only, this one runs
from `main` and never checks out PR code).

- **patch / minor** (from the versions in the PR, incl. grouped and security
  PRs; see `scripts/ci/dependabot_update_type.py`) → squash-merge, then start
  **Images** on `main` (GITHUB_TOKEN merges don't trigger push workflows).
  `main` runs the full pipeline again before any image is published, and the
  VPS deploy health-checks and rolls back on its own.
- **major / unknown** → label `dependabot:manual-review` and a comment.
- Skipped if the PR got new commits since the run, contains commits not made
  by Dependabot, or has the label `no-automerge`.

Upstream's `ci.yml`, `quick-check.yml` and `deploy.yml` were removed in this
fork: `images.yml` covers them, `ci.yml` could no longer install its test
dependencies, and `deploy.yml` pushed via SSH to the upstream author's server.
