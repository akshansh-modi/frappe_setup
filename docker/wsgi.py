"""WSGI app for the production image (gunicorn, run from sites/).

Frappe normally picks the site from the request's Host header. This image serves exactly one site,
so pin it: requests to any host (a pod IP from a health probe, an internal service name) still reach
SITE_NAME. Static /assets and /files are served by the app itself, so no nginx is needed in front.
"""

import os

import frappe.app

frappe.app._site = os.environ["SITE_NAME"]
# ponytail: werkzeug serves /assets and /files; put nginx or a CDN in front if static traffic gets heavy
application = frappe.app.application_with_statics()
