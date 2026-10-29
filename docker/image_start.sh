#!/bin/bash
# Start script of the single-container image (Dockerfile). See docker/IMAGE.md.
set -e
cd /home/frappe/frappe-bench

: "${SITE_NAME:?set SITE_NAME (the host name people open in the browser)}"
: "${REDIS_URL:?set REDIS_URL}"
# Links in emails etc.: the ingress serves the site over https
export HOST_NAME="${HOST_NAME:-https://$SITE_NAME}"

# common_site_config.json + sites/<site>/site_config.json from env, on every start
env/bin/python docker/write_config.py

# Empty database: build the site in it (same checks as docker/entrypoint.sh in cloud mode)
rc=0; env/bin/python docker/site_in_db.py || rc=$?
if [ "$rc" = 3 ]; then
	echo "Database '$DB_NAME' is empty, creating site $SITE_NAME in it..."
	bench new-site "$SITE_NAME" --force --no-setup-db \
		--db-name "$DB_NAME" \
		--admin-password "${ADMIN_PASSWORD:?set ADMIN_PASSWORD for the first start}"
	bench --site "$SITE_NAME" scheduler enable
elif [ "$rc" = 4 ]; then
	echo "Database '$DB_NAME' is half-built (has tables, but Frappe never finished installing). Empty it by hand, then start again."
	exit 1
elif [ "$rc" != 0 ]; then
	echo "Can't reach the database (see error above)"; exit 1
fi

# AUTO_MIGRATE=1: apply the new code's table changes (new doctypes, new fields) on every start.
# For an environment with a database of its own, like SIT. Off by default: on a database other
# setups share, migrate is a manual, agreed step. Runs before install-app, so a newly added app
# installs onto an up-to-date schema.
if [ "${AUTO_MIGRATE:-0}" = 1 ]; then
	bench --site "$SITE_NAME" migrate
fi

# Already-installed apps are skipped.
bench --site "$SITE_NAME" install-app ${INSTALL_APPS:-telephony helpdesk crm insurance}

# --no-dev: plain `bench start` sets DEV_SERVER=true, which shows full Python error tracebacks to
# every visitor, including logged-out ones. Fine on a dev laptop, an information leak anywhere else.
exec bench start --no-dev
