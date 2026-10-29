# frappe_setup

Production image for our Frappe apps. The `Dockerfile` builds **one image**, and **one pod** runs
the whole app (web, realtime, background jobs, scheduler). MariaDB and Redis are **not** in the
image: point it at existing ones with env vars.

The image holds no code from this repo. It fetches each app from GitHub at a release tag:

| App | Repo | Pinned in |
|---|---|---|
| frappe | `akshansh-modi/frappe` (v16 + our patches, see its `PATCHES.md`) | `FRAPPE_TAG` in `Dockerfile` |
| telephony | `akshansh-modi/telephony` (fork of `frappe/telephony`, which has no tags) | `apps.json` |
| helpdesk | `akshansh-modi/support-helpdesk` | `apps.json` |
| crm | `akshansh-modi/crm` | `apps.json` |
| insurance | `akshansh-modi/insurance` | `apps.json` |

Each built image lists what it contains in `apps/versions.txt` (app, tag, commit).

## Releasing

1. In each app repo that changed: tag the commit to ship and push the tag.
   ```bash
   git tag -a release-<YYYY.MM.DD> -m "Release release-<YYYY.MM.DD>" && git push origin release-<YYYY.MM.DD>
   ```
   Tags are never moved or reused. A fix after release gets a new tag (e.g. `release-<date>.1`).
2. In this repo: set the new tags in `apps.json` / `FRAPPE_TAG`, commit.
3. Build and push, tagged with this repo's commit, never only `latest`:
   ```bash
   docker build -t <registry>/frappe-app:$(git rev-parse --short HEAD) .
   docker push <registry>/frappe-app:$(git rev-parse --short HEAD)
   ```
4. Deploy that image. Rolling back = deploying the previous image tag.

Never point `apps.json` at a branch: a rebuild would pick up whatever was pushed since.

## Build

- **BuildKit is required** (Docker's default builder since version 23): the Dockerfile uses bind and cache mounts.
- **Build for the nodes' CPU type.** Graviton nodes are `linux/arm64`, the others `linux/amd64`. Pass `--platform` to match.
- **Network during the build:** GitHub (the app repos, and a few Python packages), PyPI, the npm registry. The repos are public, so no token is needed.
- **Build time:** about 25 minutes from scratch. Every step from `bench init` on reruns when `apps.json` or `FRAPPE_TAG` changes; the cache mounts keep package downloads fast. CI agents that start empty lose the cache; use `--cache-from`/`--cache-to type=registry` there.

## Try it locally

```bash
docker build -t frappe-app:local .
docker network create frappe-local
docker run -d --name mariadb --network frappe-local -e MARIADB_ROOT_PASSWORD=123 mariadb:11.8 \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --skip-character-set-client-handshake
docker run -d --name redis --network frappe-local redis:8-alpine
docker exec mariadb mariadb -uroot -p123 -e "CREATE DATABASE app; CREATE USER app@'%' IDENTIFIED BY 'app'; GRANT ALL ON app.* TO app@'%';"
# .env: SITE_NAME=localhost DB_HOST=mariadb DB_NAME=app DB_USER=app DB_PASSWORD=app
#       REDIS_URL=redis://redis:6379 ENCRYPTION_KEY=<generated> ADMIN_PASSWORD=admin HOST_NAME=http://localhost:8000
docker run --name app --network frappe-local -p 8000:8000 -p 9000:9000 --env-file .env frappe-app:local
```

Open http://localhost:8000 (Administrator / `ADMIN_PASSWORD`). Without an ingress routing `/socket.io`
to 9000, Desk gets no live updates; Helpdesk and CRM still do.

`DEVELOPER_MODE=1` works for trying things out, but doctype changes made in the UI are written
inside the container and lost with it. Real doctype work happens in the app's own repo.

## Kubernetes settings

- **`replicas: 1` and `strategy: Recreate`, always.** The default RollingUpdate briefly runs two pods: two schedulers (duplicate emails and tickets), two first-start installs racing on an empty database, and an EBS volume that can't attach to the second pod.
- **Probes.** The first start (creating the site, installing apps, migrating) takes several minutes before anything listens:
  - `startupProbe`: TCP 8000, allowing up to 30 minutes (e.g. `periodSeconds: 10`, `failureThreshold: 180`). A probe that kills the pod mid-install leaves a half-built database that has to be emptied by hand.
  - `livenessProbe`: TCP 8000. Not the HTTP ping: it needs the database, so a database blip would restart the pod.
  - `readinessProbe`: HTTP `GET /api/method/ping` on 8000, which returns `{"message":"pong"}`.
- **Security context:** `runAsNonRoot: true` works (the image runs as uid 1000). Set `allowPrivilegeEscalation: false` and `fsGroup: 1000`. `readOnlyRootFilesystem` is **not** supported: the start script writes config into `sites/`.
- **Shutdown:** on a deploy, the process manager gives running requests and background jobs 5 seconds, then stops them.
- **Network:** only the ingress should reach ports 8000 and 9000 (a NetworkPolicy, if the cluster enforces them). The image trusts `X-Forwarded-*` headers from any address that reaches it.
- **The pod must be able to reach `https://<SITE_NAME>`** (through the ingress). When a browser opens a realtime connection, the realtime server checks the login by calling back the address the page was opened on. If the pod can't reach it, realtime is refused with `Unauthorized: fetch failed`; the rest of the app still works.
- **Logs:** everything goes to the container's stdout: gunicorn's access log, process output and Frappe's own logs (`FRAPPE_STREAM_LOGGING=1`). Nothing is written to log files.

## Ingress

- **Host rule:** match only `SITE_NAME`. No catch-all rule pointing at this service.
- **Routing:** everything to port `8000`, **except the path `/socket.io`, which goes to port `9000`**, with WebSocket upgrade allowed.
- **Headers to the pod:** keep the `Host` header (it must equal `SITE_NAME`) and send `X-Forwarded-Proto: https` (Frappe then puts `Secure` on the login cookie). `X-Forwarded-For` must be overwritten, not appended, or clients can fake their IP and dodge the login lockout: on an ALB set `routing.http.xff_header_processing.mode=replace`; on ingress-nginx keep `use-forwarded-headers` off (the default).
- **Upload size:** about 50 MB (ingress-nginx defaults to 1 MB). **Timeouts:** 120 s.
- **Security headers:** nothing in the image adds them, so add them here: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`.
- **ALB health check** for the 9000 target: path `/socket.io/?EIO=4&transport=polling`.

## Env vars (a Kubernetes Secret)

See `.env.example`.

| Variable | Value |
|---|---|
| `SITE_NAME` | **The host name people open in the browser**, e.g. `app.example.com` |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | MariaDB, e.g. RDS (tested with MariaDB 11.8). The database and user must exist; the database must be empty on the first start. |
| `DB_SSL_CA` | Path of the CA file for SSL to the database, e.g. RDS's `global-bundle.pem` mounted from a ConfigMap. The certificate's host name is checked. Empty means no SSL. |
| `REDIS_URL` | `redis://default:<password>@<host>:<port>`, or `rediss://…` for TLS. Use a non-serverless, cluster-mode-disabled ElastiCache. |
| `ENCRYPTION_KEY` | Generate once and never change it (command in `.env.example`) |
| `ADMIN_PASSWORD` | Administrator password. Only used on the first start |
| `AUTO_MIGRATE` | `1` runs `migrate` on every start, so new doctypes and fields in a new image get their tables. For an environment with a database of its own. Default `0`. |
| `HOST_NAME` | Optional. Base URL for links in emails. Default `https://<SITE_NAME>` |
| `INSTALL_APPS` | Optional. Default `telephony helpdesk crm insurance` |
| `GUNICORN_WORKERS` | Optional. Default `2` |
| `DEVELOPER_MODE`, `SERVER_SCRIPT_ENABLED` | `0` in the image. `1` only for local trying out, never in prod. |

## Storage

Uploaded files (ticket attachments, policy documents) are written to
`/home/frappe/frappe-bench/sites/<SITE_NAME>/`. Every deploy replaces the pod, so without a volume
they're lost on each deploy. To keep them: one EBS volume (ReadWriteOnce) mounted at exactly that
path. Never mount over `sites/`: that hides the built frontend.

## What happens on each start

1. `docker/write_config.py` writes the config from the env vars.
2. Empty database: `docker/image_start.sh` creates the site. Existing site: skipped.
3. `AUTO_MIGRATE=1`: `migrate` updates the tables for the new code.
4. Apps in `INSTALL_APPS` that aren't installed yet get installed.
5. Web, realtime, worker and scheduler start (`bench start --no-dev`).
