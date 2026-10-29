"""Does the cloud DB already hold our site? Exit codes:
0 = yes, Frappe is fully installed
3 = DB reachable and has no tables at all (empty): safe to build the site in it
4 = DB has tables but Frappe's install never finished (half-built): needs a human to decide
A connection error raises and exits 1, so it's never mistaken for "empty"."""

import json
import os
import sys

import MySQLdb

conf = json.load(open(f"sites/{os.environ['SITE_NAME']}/site_config.json"))
connect = {
	"host": conf["db_host"],
	"port": int(conf["db_port"]),
	"user": conf["db_user"],
	"password": conf["db_password"],
	"database": conf["db_name"],
}
if conf.get("db_ssl_ca"):
	connect["ssl"] = {"ca": conf["db_ssl_ca"]}

cursor = MySQLdb.connect(**connect).cursor()
cursor.execute("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")
if cursor.fetchone()[0] == 0:
	sys.exit(3)

# Frappe records itself in installed_apps as the very last step of its install
try:
	cursor.execute(
		"SELECT defvalue FROM `tabDefaultValue` WHERE parent = '__global' AND defkey = 'installed_apps'"
	)
	row = cursor.fetchone()
except MySQLdb.ProgrammingError:  # tabDefaultValue itself doesn't exist yet
	row = None
sys.exit(0 if row and "frappe" in json.loads(row[0]) else 4)
