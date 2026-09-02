"""WSGI entrypoint. gunicorn loads sdapp.wsgi:app (see the systemd unit)."""
from .web import app

__all__ = ["app"]
