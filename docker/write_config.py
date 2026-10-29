"""Merge settings from .env into common_site_config.json (and, in cloud mode, the
site's site_config.json). Merging instead of overwriting keeps keys Frappe or we
added by hand (mute_emails etc.)."""

import json
import os
from pathlib import Path

env = os.environ
sites = Path("sites")


def merge(path: Path, values: dict):
	path.parent.mkdir(parents=True, exist_ok=True)
	current = json.loads(path.read_text()) if path.exists() else {}
	current.update(values)
	path.write_text(json.dumps(current, indent=1))


def required(key: str) -> str:
	if not env.get(key):
		raise SystemExit(f"{key} is empty in .env (needed for MODE={env['MODE']})")
	return env[key]


merge(
	sites / "common_site_config.json",
	{
		"redis_cache": env["REDIS_URL"],
		"redis_queue": env["REDIS_URL"],
		"redis_socketio": env["REDIS_URL"],
		"default_site": env["SITE_NAME"],
		"serve_default_site": True,
		"developer_mode": int(env.get("DEVELOPER_MODE", 1)),  # the prod image sets 0
		"server_script_enabled": int(env.get("SERVER_SCRIPT_ENABLED", 1)),  # Frappe default is off; dev turns it on, the image off
		"webserver_port": 8000,
		"socketio_port": 9000,
	},
)

# Background-job queue names are "<bench_id>:<queue>"; workers with the same bench_id share
# a queue. Same code -> same id (prod pods: leave empty or set one shared value).
# Different code -> different id (two devs on the shared cloud Redis: each sets their own).
if env.get("BENCH_ID"):
	merge(sites / "common_site_config.json", {"bench_id": env["BENCH_ID"]})

if env["MODE"] == "cloud":
	# The folders `bench new-site` would have made (frappe/installer.py make_site_dirs);
	# cloud mode never runs new-site, and Frappe crashes without logs/ etc.
	for folder in ("public/files", "private/backups", "private/files", "locks", "logs"):
		(sites / env["SITE_NAME"] / folder).mkdir(parents=True, exist_ok=True)

	site_config = sites / env["SITE_NAME"] / "site_config.json"
	merge(
		site_config,
		{
			"db_type": "mariadb",
			"db_host": required("DB_HOST"),
			"db_port": int(required("DB_PORT")),
			"db_name": required("DB_NAME"),
			"db_user": required("DB_USER"),
			"db_password": required("DB_PASSWORD"),
			# Must be identical for everyone on the shared site, or saved passwords
			# (email accounts etc.) encrypted by one dev can't be decrypted by the other.
			"encryption_key": required("ENCRYPTION_KEY"),
		},
	)

	# SSL: DB_SSL_CA = CA file to verify the server with (e.g. the system bundle for SkySQL);
	# empty = no SSL (fine over Tailscale, which already encrypts). Removed explicitly when
	# empty, since merge() never deletes and an old value would otherwise stick around.
	conf = json.loads(site_config.read_text())
	if env.get("DB_SSL_CA"):
		conf["db_ssl_ca"] = env["DB_SSL_CA"]
		# Also check the certificate is for DB_HOST. On in the image; off by default so dev is unchanged.
		conf["db_ssl_check_hostname"] = int(env.get("DB_SSL_CHECK_HOSTNAME", 0))
	else:
		conf.pop("db_ssl_ca", None)
		conf.pop("db_ssl_check_hostname", None)
	# Public base URL for links Frappe builds outside a request (password-reset and notification
	# emails from background jobs). Only set, never removed, like every other merged key.
	if env.get("HOST_NAME"):
		conf["host_name"] = env["HOST_NAME"]
	site_config.write_text(json.dumps(conf, indent=1))
