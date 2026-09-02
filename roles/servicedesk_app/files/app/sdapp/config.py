"""Configuration, read entirely from the environment.

Ansible writes /etc/servicedesk/servicedesk.env and systemd passes it in via
EnvironmentFile, so nothing here is hardcoded and nothing is read from a file
this process would have to find. Same contract as the ZMS microservices app.
"""
import os


def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


DB_HOST = os.environ.get("SD_DB_HOST", "127.0.0.1")
DB_PORT = _int("SD_DB_PORT", 3306)
DB_NAME = os.environ.get("SD_DB_NAME", "servicedesk")
DB_USER = os.environ.get("SD_DB_USER", "sdapp")
DB_PASSWORD = os.environ.get("SD_DB_PASSWORD", "")

# Connect timeout kept short: a hung database should surface on /health in
# seconds, not hold a gunicorn worker for the default 10s+ per request.
DB_CONNECT_TIMEOUT = _int("SD_DB_CONNECT_TIMEOUT", 5)

APP_NAME = os.environ.get("SD_APP_NAME", "ZMS Lab Service Desk")
APP_PORT = _int("SD_APP_PORT", 8090)

# Seeder controls. Deterministic by default so two runs against two databases
# produce identical data and a diff is meaningful.
SEED_USERS = _int("SD_SEED_USERS", 40)
SEED_TICKETS = _int("SD_SEED_TICKETS", 500)
SEED_DAYS = _int("SD_SEED_DAYS", 90)
SEED_RANDOM = _int("SD_SEED_RANDOM", 20260901)
