# Single-container production image: web, socketio, worker and scheduler all run in this one
# container; MariaDB and Redis are external. The code comes from GitHub at the release tags in
# apps.json (and FRAPPE_TAG below), so the same commit of this repo always builds the same image.
# Pinned by digest so every build starts from the same base.
FROM frappe/bench@sha256:2f726e0386810dc21190d6d402c01bead40b721b1faf57b8b1c574af279fdca3

ARG FRAPPE_REPO=https://github.com/akshansh-modi/frappe
ARG FRAPPE_TAG=release-2026.10.29

# DB connection comes from env (write_config.py's "cloud" path). Developer mode and Server Scripts
# are off (Server Scripts let an admin account run Python on the server); a dev running the image
# locally can turn them on with DEVELOPER_MODE=1 / SERVER_SCRIPT_ENABLED=1.
ENV MODE=cloud DEVELOPER_MODE=0 SERVER_SCRIPT_ENABLED=0 DB_SSL_CHECK_HOSTNAME=1 UV_LINK_MODE=copy

# One RUN on purpose: files deleted in a later layer still ship in the earlier one, so fetching,
# building and cleaning up happen together (otherwise ~1 GB of node_modules and .git stays in the image).
#
# 1. The code: frappe from FRAPPE_REPO, then every app in apps.json (helpdesk requires telephony).
#    The cache mounts keep downloaded packages on the build machine; they never enter the image.
# 2. sites/apps.txt in apps.json order (bench writes it in its own order), matched by git remote URL.
# 3. Frontend build. The Helpdesk build reads socketio_port from common_site_config.json, so it must
#    exist first; write_config.py fills in the rest when the container starts.
#    --frozen-lockfile: fail instead of resolving different package versions than the lockfile.
#    FRAPPE_DOCKER_BUILD=1: skip telling Redis about the new assets (there's no Redis while building;
#    without it the build retries forever). --force: always build here, instead of Frappe first
#    trying to download prebuilt assets from the internet.
# 4. Record what was built (apps/versions.txt), then drop what isn't needed at runtime:
#    node_modules (socketio.js needs frappe's, so keep that one) and git history.
WORKDIR /home/frappe
RUN --mount=type=bind,source=apps.json,target=/tmp/apps.json \
    --mount=type=cache,target=/home/frappe/.cache/pip,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/frappe/.cache/uv,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/frappe/.cache/yarn,uid=1000,gid=1000 \
    bench init frappe-bench \
      --frappe-path "$FRAPPE_REPO" --frappe-branch "$FRAPPE_TAG" \
      --apps_path /tmp/apps.json \
      --python "$(which python3.14)" \
      --skip-redis-config-generation --skip-assets --no-procfile \
 && cd frappe-bench \
 && env/bin/python -c 'import json, subprocess; \
      urls = [a["url"] for a in json.load(open("/tmp/apps.json"))]; \
      url = lambda app: subprocess.check_output(["git", "-C", f"apps/{app}", "ls-remote", "--get-url"], text=True).strip(); \
      apps = open("sites/apps.txt").read().split(); \
      apps.sort(key=lambda a: -1 if a == "frappe" else urls.index(url(a))); \
      open("sites/apps.txt", "w").write("\n".join(apps) + "\n")' \
 && echo '{"socketio_port": 9000}' > sites/common_site_config.json \
 && for app in apps/*/; do \
      if [ -f "$app/package.json" ]; then (cd "$app" && yarn install --frozen-lockfile) || exit 1; fi; \
    done \
 && FRAPPE_DOCKER_BUILD=1 bench build --force \
 && find apps -name node_modules -prune -not -path apps/frappe/node_modules -exec rm -rf {} + \
 && for app in apps/*/; do \
      printf '%s %s %s\n' "$(basename "$app")" \
        "$(git -C "$app" describe --tags --exact-match 2>/dev/null || echo untagged)" \
        "$(git -C "$app" rev-parse HEAD)"; \
    done > apps/versions.txt \
 && rm -rf apps/*/.git

WORKDIR /home/frappe/frappe-bench

# Copied after the build so editing these scripts doesn't redo the slow steps above.
COPY --chown=frappe:frappe docker docker

# The processes `bench start` runs. gunicorn, not `bench serve`: the dev server has an interactive
# debugger. socketio.js needs apps/frappe/node_modules, which is why the prune above keeps it.
RUN { echo 'web: cd sites && ../env/bin/gunicorn --pythonpath ../docker --bind 0.0.0.0:8000 --workers ${GUNICORN_WORKERS:-2} --timeout 120 --access-logfile - --preload wsgi:application'; \
      echo 'socketio: node apps/frappe/socketio.js'; \
      echo 'worker: bench worker'; \
      echo 'schedule: bench schedule'; } > Procfile

# Trust X-Forwarded-Proto from the ingress, which handles HTTPS: without it gunicorn treats every
# request as plain http and Frappe leaves the Secure flag off the login cookie. Only the ingress can
# reach the container, so "*" is fine; DevOps can narrow it to the ingress's address range.
ENV FORWARDED_ALLOW_IPS=*

# Frappe's own logs (frappe.logger) go to stderr instead of files under logs/ and sites/*/logs/.
# `bench start` merges every process's stderr into the container's stdout, for the log collector.
ENV FRAPPE_STREAM_LOGGING=1

# The base image lets the frappe user run anything as root without a password (sudoers +
# sudo group). Nothing here needs it, so take it away: the app user stays an ordinary user.
USER root
RUN sed -i '/^frappe ALL=(ALL) NOPASSWD: ALL$/d' /etc/sudoers && gpasswd -d frappe sudo
# Numeric, so Kubernetes' runAsNonRoot can verify the image doesn't run as root.
USER 1000:1000

EXPOSE 8000 9000
CMD ["bash", "/home/frappe/frappe-bench/docker/image_start.sh"]
