# Deploying OpenThreat (fork `deploy` branch)

```
 GitHub                                       VPS (rootless Podman)
 ──────                                       ─────────────────────
 push / merged PR on `deploy`                  openthreat-deploy.timer (every 10 min)
   └─ Actions: images.yml                        └─ deploy/deploy.sh
        audit ─ pip-audit, npm audit                  git fetch origin deploy
        test  ─ unit + smoke vs Postgres/Redis        new commit? pull ghcr …:sha-<commit>
        images─ build, SBOM, provenance               (not there yet → retry next run)
                push ghcr.io/<owner>/…:sha-<commit>   pg_dump backup
                                                      checkout + pin OT_IMAGE_TAG
                                                      migrations (alembic + SQL)
                                                      restart, health check
                                                      failed → roll back code + images
```

Nothing in GitHub can reach the VPS: no SSH keys or server credentials in
GitHub secrets. The VPS only pulls (git over the deploy key, images from
GHCR). Every running image corresponds to exactly one commit.

## One-time setup

1. **GitHub**
   - Actions → enable workflows for the fork. Then disable the inherited
     `Deploy to Production` workflow (it still exists on `main`, and syncing
     the fork pushes to `main`): Actions → *Deploy to Production* → ⋯ →
     *Disable workflow*.
   - After the first successful `Images` run: your profile → Packages →
     `openthreat-backend` / `openthreat-frontend` → Package settings →
     *Change visibility* → Public. (Or keep them private and run
     `podman login ghcr.io` on the VPS with a PAT that only has
     `read:packages`.)
   - The VPS deploy key only needs **read** access now.

2. **VPS** (as the stack user, in the repo checkout)
   ```bash
   cp .env.vps.example .env.new   # merge your existing values into it
   # required: POSTGRES_*, SECRET_KEY (>= 32 chars), CSRF_SECRET_KEY,
   #           OT_REGISTRY, NGINX_HTTP(S)_PORT
   deploy/install.sh
   deploy/deploy.sh --force       # first deploy
   ```

## Day to day

| What | How |
|---|---|
| Ship a change | merge/push to `deploy` → CI → live within ~10 min after CI is green |
| Dependabot update | review + merge the PR (CI must be green) |
| What's running | `deploy/deploy.sh --status` |
| Deploy now | `systemctl --user start openthreat-deploy.service` |
| Logs | `journalctl --user -u openthreat-deploy.service -f` |
| Roll back | `deploy/deploy.sh --rollback` (previous commit + its images) |
| Pause auto-deploy | `systemctl --user stop openthreat-deploy.timer` |

A commit whose deploy failed is rolled back automatically and skipped
until a newer commit arrives (or `--force`).

### Database restore

Migrations are **not** reverted on rollback. Every deploy writes a dump
first (`DEPLOY_BACKUP_DIR`, default `~/backups/openthreat`, newest
`DEPLOY_BACKUP_KEEP` kept):

```bash
systemctl --user stop openthreat-deploy.timer
podman-compose stop backend celery-worker celery-beat
pg=$(podman ps -q --filter label=com.docker.compose.service=postgres)
podman exec -i "$pg" sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' \
  < ~/backups/openthreat/openthreat-YYYYMMDD-HHMMSS-<commit>.dump
podman-compose start backend celery-worker celery-beat
systemctl --user start openthreat-deploy.timer
```

## Rules for the VPS checkout

- Don't edit tracked files on the VPS; the deploy refuses to run on a
  dirty tree. Change them on `deploy` and push.
- Local-only files stay untracked: `.env`, `nginx/ssl/`, `.deploy/`.
- Rebasing `deploy` onto upstream and force-pushing is fine; the VPS
  follows the rewritten history.

## Metrics

`/metrics` is blocked in nginx. Scrape it from inside the Podman network
(`http://backend:8001/metrics`), e.g. with `docker-compose.monitoring.yml`.
