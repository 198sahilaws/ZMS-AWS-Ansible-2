"""The service desk web application.

Routes are split between a small HTML UI (what a person opens) and a JSON API
(what the traffic generator on the client host drives). Both hit the same
queries, so generated traffic exercises the same code path a human would.
"""
import datetime as dt

import pymysql
from flask import Flask, abort, jsonify, render_template, request, url_for

from . import config, db

app = Flask(__name__)

STATUSES = ["new", "open", "pending", "resolved", "closed"]
PRIORITIES = ["P1", "P2", "P3", "P4"]
OPEN_STATUSES = ("new", "open", "pending")


# --- helpers -----------------------------------------------------------------

def _next_ref():
    """Next SD-nnnnnn. MAX+1 rather than an auto-increment mirror so a
    force-reseed cannot produce a duplicate ref against a stale sequence."""
    row = db.query_one("SELECT MAX(CAST(SUBSTRING(ref, 4) AS UNSIGNED)) AS n FROM tickets")
    return "SD-%06d" % ((row["n"] or 0) + 1)


def _queue(status=None, priority=None, assignee=None, limit=50):
    where, args = [], []
    if status == "open":
        where.append("t.status IN %s")
        args.append(OPEN_STATUSES)
    elif status in STATUSES:
        where.append("t.status = %s")
        args.append(status)
    if priority in PRIORITIES:
        where.append("t.priority = %s")
        args.append(priority)
    if assignee:
        where.append("a.username = %s")
        args.append(assignee)
    clause = ("WHERE " + " AND ".join(where)) if where else ""
    args.append(limit)
    return db.query(
        "SELECT t.ref, t.subject, t.status, t.priority, t.category, "
        "       t.created_at, t.updated_at, "
        "       r.full_name AS requester, a.full_name AS assignee, "
        "       (SELECT COUNT(*) FROM comments c WHERE c.ticket_id = t.id) AS comment_count "
        "FROM tickets t "
        "JOIN users r ON r.id = t.requester_id "
        "LEFT JOIN users a ON a.id = t.assignee_id "
        + clause +
        " ORDER BY FIELD(t.priority, 'P1','P2','P3','P4'), t.created_at DESC "
        "LIMIT %s", args)


def _stats():
    by_status = db.query("SELECT status, COUNT(*) AS n FROM tickets GROUP BY status")
    by_priority = db.query(
        "SELECT priority, COUNT(*) AS n FROM tickets "
        "WHERE status IN %s GROUP BY priority", (OPEN_STATUSES,))
    totals = db.query_one(
        "SELECT (SELECT COUNT(*) FROM tickets) AS tickets, "
        "       (SELECT COUNT(*) FROM comments) AS comments, "
        "       (SELECT COUNT(*) FROM users) AS users")
    return {
        "totals": totals,
        "by_status": {r["status"]: r["n"] for r in by_status},
        "open_by_priority": {r["priority"]: r["n"] for r in by_priority},
    }


# --- HTML --------------------------------------------------------------------

@app.errorhandler(pymysql.MySQLError)
def database_down(exc):
    """A database outage is a 503, never a 500 with a stack trace.

    Registered globally so the JSON API and the HTML pages degrade the SAME way
    — an earlier version only handled it on the index route, so stopping MySQL
    gave a friendly page but a bare 500 on /api/tickets, which made the
    "watch it degrade" demo inconsistent depending on what you happened to hit.
    """
    detail = "%s: %s" % (type(exc).__name__, exc)
    wants_json = request.path.startswith("/api/") or request.path == "/stats"
    if wants_json:
        return jsonify({"service": "servicedesk", "status": "degraded",
                        "database": {"reachable": False, "host": config.DB_HOST,
                                     "database": config.DB_NAME, "error": detail}}), 503
    return render_template("error.html", app_name=config.APP_NAME, detail=detail), 503


@app.route("/")
def index():
    status = request.args.get("status", "open")
    priority = request.args.get("priority") or None
    rows = _queue(status=status, priority=priority)
    stats = _stats()
    return render_template("index.html", app_name=config.APP_NAME, tickets=rows,
                           stats=stats, status=status, priority=priority,
                           statuses=STATUSES, priorities=PRIORITIES)


@app.route("/ticket/<ref>")
def ticket_detail(ref):
    ticket = db.query_one(
        "SELECT t.*, r.full_name AS requester, r.email AS requester_email, "
        "       a.full_name AS assignee "
        "FROM tickets t JOIN users r ON r.id = t.requester_id "
        "LEFT JOIN users a ON a.id = t.assignee_id WHERE t.ref = %s", (ref,))
    if not ticket:
        abort(404)
    comments = db.query(
        "SELECT c.body, c.is_internal, c.created_at, u.full_name AS author, u.role "
        "FROM comments c JOIN users u ON u.id = c.author_id "
        "WHERE c.ticket_id = %s ORDER BY c.created_at", (ticket["id"],))
    return render_template("ticket.html", app_name=config.APP_NAME,
                           ticket=ticket, comments=comments)


# --- JSON API ----------------------------------------------------------------

@app.route("/api/tickets", methods=["GET"])
def api_list():
    return jsonify(_queue(status=request.args.get("status", "open"),
                          priority=request.args.get("priority") or None,
                          limit=min(int(request.args.get("limit", 25)), 200)))


@app.route("/api/tickets", methods=["POST"])
def api_create():
    payload = request.get_json(silent=True) or {}
    subject = (payload.get("subject") or "").strip()
    if not subject:
        return jsonify({"error": "subject is required"}), 400

    requester = db.query_one(
        "SELECT id FROM users WHERE username = %s", (payload.get("requester"),))
    if not requester:
        requester = db.query_one(
            "SELECT id FROM users WHERE role = 'requester' ORDER BY RAND() LIMIT 1")
    if not requester:
        return jsonify({"error": "no users exist; run the seeder first"}), 409

    ref = _next_ref()
    db.execute(
        "INSERT INTO tickets (ref, subject, body, category, status, priority, "
        "requester_id, created_at, updated_at) "
        "VALUES (%s, %s, %s, %s, 'new', %s, %s, %s, %s)",
        (ref, subject[:200], (payload.get("body") or "")[:4000],
         (payload.get("category") or "general")[:32],
         payload.get("priority") if payload.get("priority") in PRIORITIES else "P3",
         requester["id"], dt.datetime.now(), dt.datetime.now()))
    return jsonify({"ref": ref, "status": "new"}), 201


@app.route("/api/tickets/<ref>/comments", methods=["POST"])
def api_comment(ref):
    payload = request.get_json(silent=True) or {}
    body = (payload.get("body") or "").strip()
    if not body:
        return jsonify({"error": "body is required"}), 400

    ticket = db.query_one("SELECT id, status FROM tickets WHERE ref = %s", (ref,))
    if not ticket:
        return jsonify({"error": "no such ticket"}), 404
    author = db.query_one(
        "SELECT id FROM users WHERE username = %s", (payload.get("author"),)) \
        or db.query_one("SELECT id FROM users ORDER BY RAND() LIMIT 1")

    db.execute("INSERT INTO comments (ticket_id, author_id, body, is_internal) "
               "VALUES (%s, %s, %s, %s)",
               (ticket["id"], author["id"], body[:4000],
                1 if payload.get("internal") else 0))
    # A comment on an untriaged ticket moves it into the queue, which is what
    # gives the generator a way to change state without a separate endpoint.
    if ticket["status"] == "new":
        db.execute("UPDATE tickets SET status = 'open' WHERE id = %s", (ticket["id"],))
    return jsonify({"ref": ref, "commented": True}), 201


@app.route("/stats")
def stats():
    return jsonify(_stats())


@app.route("/health")
def health():
    """200 when the database answers, 503 when it does not.

    Same contract as the ZMS microservices app: the body always carries a
    'database' object so a monitor can tell "app down" from "database down".
    """
    ok, detail = db.health()
    return jsonify({"service": "servicedesk", "status": "ok" if ok else "degraded",
                    "database": detail}), (200 if ok else 503)
