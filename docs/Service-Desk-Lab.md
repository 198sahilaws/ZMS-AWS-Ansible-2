# Service Desk Lab

A small internal IT service desk, split across **three tiers on three hosts**:
Flask + gunicorn rendering HTML on the Ubuntu **web** host, Flask + gunicorn
holding the business logic on the Ubuntu **middleware** host, and Oracle MySQL
on the Ubuntu **db** host. A traffic generator on the Ubuntu **client** host
drives the whole thing. Built for `deployments/web-app`.

It exists to put realistic, continuously changing data in front of MySQL and to
make the tiers talk to each other over the network, so the estate produces
enterprise-shaped east-west traffic instead of an idle port. The three-tier
split is what makes that traffic interesting: a request now crosses two host
boundaries on two different protocols before it reaches storage.

> **Version 2.x is the three-tier app.** 1.x was a single Flask process on the
> web host that did everything. If you are reading a runbook that says the web
> host holds the database password, it predates the split — see
> "What changed in 2.0" at the end.

## Topology

| Host | Group intersection | What runs there |
|---|---|---|
| web | `role_web & distro_ubuntu` | gunicorn on **:8090** — HTML only, no DB driver, no credentials |
| middleware | `role_middleware & distro_ubuntu` | gunicorn on **:8091** — all SQL, all business rules, creates + seeds the schema |
| db | `role_db & distro_ubuntu` | MySQL 8, schema `servicedesk` |
| client | `role_client & distro_ubuntu` | `sd-traffic.timer`, real HTTP every 2 min |

Declared in `vars/servicedesk.yml`, resolved from inventory groups at run time —
never hardcoded IPs. Re-run Terraform, get new addresses, converge again, and the
map still holds.

Every request crosses **two** host boundaries:

```
client --HTTP :8090--> web --HTTP :8091--> middleware --MySQL :3306--> db
```

on a fresh TCP connection each time. Three hops, three hosts, three sets of
flows — and a database credential that exists on exactly one of them.

**Port 8090 did not move.** It is still the front door and still on the
`Role=web` host, so bookmarks, the traffic generator and every existing check
are unchanged. 8091 is deliberately a different number even though it is a
different host: in a flow log the port alone then tells you which tier answered.

### The client host is not a tier

It is a load generator that happens to live on its own instance. `Role=client`
exists so the traffic originates off-box, from a process a microsegmentation
agent can attribute — not because the application has a fourth layer.

## Why a middleware tier

Not to proxy the database. The middleware owns rules that have no home in either
of the other two tiers:

- **SLA evaluation.** Hours-to-breach by priority (`P1` 4h, `P2` 8h, `P3` 24h,
  `P4` 72h), each open ticket classified `on_track` / `at_risk` / `breached`,
  surfaced per-row and aggregated in `/stats.open_by_sla`. Pure policy, kept out
  of the schema on purpose: it is exactly the kind of rule that changes without
  a migration.
- **Assignment.** A new ticket is auto-assigned to the least-loaded agent,
  computed from the current open queue at the moment of creation.
- **Input coercion.** An unknown priority is coerced to `P3` and the response
  says so in `priority_coerced`, rather than 400-ing or silently storing junk.

None of that is derivable from a row, and none of it belongs in a template.
That is the test for which side of the line new code goes on: if it needs
`render_template` it belongs in `web.py`, if it needs `pymysql` it belongs in
`api.py`, and nothing needs both.

## One payload, two tiers

`roles/servicedesk_app` installs the **same** code on the web and middleware
hosts. `sdapp/wsgi.py` reads `SD_TIER` from the environment file and imports
either `sdapp.web` or `sdapp.api`. The role is applied twice with different
`sd_tier` values — the same pattern as `roles/zms_microservice` being deployed
four times with different `ZMS_SERVICE` values.

| File | Tier | Imports |
|---|---|---|
| `sdapp/api.py` | middleware | `pymysql`, never `render_template` |
| `sdapp/web.py` | web | `render_template`, never `pymysql` |
| `sdapp/client.py` | web | stdlib `urllib` only — the web tier's HTTP client |
| `sdapp/db.py` | middleware | only ever imported from `api.py` |

The shared payload means one deploy path, one version number and one place to
fix a bug. The dispatch means the web host physically cannot run a query: it has
no password to run it with.

### The JSON contract between the tiers

`api.py` emits datetimes as **ISO-8601 strings**, not Flask's default RFC 1123,
and `client.revive()` turns `created_at`, `updated_at`, `closed_at` and `due_at`
back into `datetime` objects before the templates see them. That is why
`index.html` and `ticket.html` still call `.strftime()` unchanged.

## Credential containment

The web host has **no** database password. Not an empty one — absent.

- `playbooks/servicedesk-web.yml` performs no `aws_secret` lookup at all, so the
  password is never in that play's variable scope and a `-vvv` run cannot leak
  it.
- `/etc/servicedesk/servicedesk.env` on the web host has no `SD_DB_PASSWORD`
  line.
- The MySQL grant is scoped to the **middleware** host's /24, not the web
  host's. The web host could not connect even if it somehow learned the
  password. In a ring-fenced estate the grant is derived per ring, so `dev`'s
  middleware is not authorised against `prod`'s database either — the security
  groups already drop that packet, but a grant looser than the fence is a trap
  for whoever loosens the fence next.

If you are debugging the web tier and feel the urge to paste a secret lookup
back into `servicedesk-web.yml`, the header comment in that file is there to
argue with you.

## Schema

Three tables. `users` (requesters and agents), `tickets` (ref, subject, status,
priority, category, requester, assignee, timestamps), `comments` (body, author,
internal flag). Indexed for the queue view's actual access pattern:
`(status, priority, created_at)`.

Unchanged by the three-tier split — SLA and assignment are **derived**, not
stored, so 2.0 needed no migration.

Kept to syntax both MySQL 8 and MariaDB 10.11 accept, so the app can be tested
locally and repointed at a MariaDB host without a code change.

## Seed data

`sdapp/seed.py` — **deterministic** and **idempotent**. Runs on the middleware
host, because that is where the credentials are.

- 40 users, 500 tickets over 90 days, ~1,300 comments (tunable in `vars/`)
- Weighted so it looks like a real queue rather than uniform noise: ~49% closed,
  P3 dominant with a handful of P1s, a long tail of comment counts (many tickets
  with 1–3, a few with 17), ~95% weekday with a mid-morning peak
- Same `sd_seed_random` produces byte-identical content, so "did the data
  change?" is answerable with a checksum
- Runs on every converge and exits without writing once tickets exist; only a
  first run prints `inserted`, which is what the role's `changed_when` keys on

```bash
# force a reseed -- ON THE MIDDLEWARE HOST
/opt/servicedesk/venv/bin/python -m sdapp.seed --force
```

## Endpoints

Served on **:8090** by the web tier:

| Path | Purpose |
|---|---|
| `/` | queue view, filterable by status and priority, with SLA colouring |
| `/ticket/<ref>` | detail with comments — one round trip to the middleware |
| `/health` | 200 healthy, **503 degraded**, with both a `middleware` and a `database` object |
| `/api/*`, `/stats` | **forwarded verbatim** to the middleware |

Served on **:8091** by the middleware tier:

| Path | Purpose |
|---|---|
| `GET /api/tickets` | queue as JSON, each row carrying an `sla` object |
| `GET /api/tickets/<ref>` | ticket plus its comments in one response |
| `POST /api/tickets` | raise a ticket; auto-assigns, reports `priority_coerced` |
| `POST /api/tickets/<ref>/comments` | comment; a comment on a `new` ticket moves it to `open` |
| `/stats` | counts by status and priority, plus `open_by_sla` |
| `/health` | 200 healthy, **503 degraded** with a `database` object |

The web tier's `/api/*` and `/stats` responses are the middleware's **bytes**,
passed through without re-serialising: same status, same content type, same
payload. That is why `sd-traffic.py` and `servicedesk-verify.yml` needed no
changes, and it is a deliberate constraint — if the web tier ever starts
reshaping those responses, the front door stops being a faithful view of the
API.

Likewise `/health` on :8090 nests the middleware's `database` object verbatim,
so monitors written against the 1.x app that key off `database.reachable` and
`database.tickets` keep working. The added `middleware` object is what tells you
which leg broke.

## Traffic generator

`sd-traffic.py` on the client host: **stdlib `urllib` only**, so the client host
needs no venv, no pip and no packages. Driven by a systemd timer with
`RandomizedDelaySec` — without jitter every host fires on the same second and the
flow log shows a synchronised pulse no real estate produces, which is exactly the
artefact that misleads a clustering algorithm.

Each burst: check health, browse the queue, open a few tickets, sometimes raise
one (~35%), sometimes comment (~50%), read stats. Reads dominate writes, as a
real service desk does.

Unchanged by the split, and that is the point — it still speaks only to
:8090. Each burst now generates traffic on **three** legs instead of two,
because every call it makes fans out through the middleware to MySQL.

It is a **real HTTP client on purpose**. A microsegmentation agent attributes a
flow to the process that opened it, so traffic from `hping3` or `tcpreplay` would
be attributed to the generator binary and the flow records would be useless.

## Running it

```bash
ansible-playbook playbooks/servicedesk-db.yml          # database, account, drop-in
ansible-playbook playbooks/servicedesk-middleware.yml  # logic tier, schema, seed
ansible-playbook playbooks/servicedesk-web.yml         # frontend tier
ansible-playbook playbooks/servicedesk-client.yml      # traffic timer
ansible-playbook playbooks/servicedesk-verify.yml      # end-to-end asserts (by hand)
```

**Order matters and each step depends on the one before it.** `db` creates the
schema and the grant for the middleware host; `middleware` creates the tables
and seeds them; `web` renders from the middleware; `client` drives the web tier.
Run `web` before `middleware` and its health check correctly reports a 503
naming an unreachable middleware — harmless, but a wasted converge.

`playbooks/servicedesk-app.yml` still exists as a **compatibility alias** that
imports the middleware and web plays in order, because runbooks and muscle
memory still reach for it. Do not add it to a play list that already contains
the two real plays — that deploys both tiers twice per converge.

The four deploy playbooks are in **both** `orchestrate.yml` and
`scripts/converge.sh`'s `LINUX_PLAYS`, so the app self-heals on the hourly timer.
Those two lists are maintained by hand and the timer runs `converge.sh`, not
`orchestrate.yml` — a play added to only one of them behaves differently by hand
than on a schedule. `servicedesk-verify.yml` is deliberately in neither: it ends
in asserts and would mark the unit failed during a deliberate failure demo.

## The degradation demos

There are now **two** ways to break it, and the app tells you which one happened.

Database down:

```bash
sudo systemctl stop mysql             # on the db host
curl -s http://<web>:8090/health      # 503, middleware.reachable true, database.reachable false
curl -s http://<middleware>:8091/health   # 503 — confirms it is really the db leg
curl -s http://<web>:8090/            # "Service degraded", not a stack trace
```

Middleware down:

```bash
sudo systemctl stop servicedesk       # on the MIDDLEWARE host
curl -s http://<web>:8090/health      # 503, middleware.reachable false
curl -s http://<web>:8090/            # "Middleware unreachable"
```

The web tier stays up in both cases and names the failed tier in `failed_tier`,
so "app down", "middleware down" and "database down" are three distinguishable
states rather than one blank page. `Restart=always` on both units means the
estate heals itself once the underlying cause is fixed; `converge.sh` re-running
hourly means it heals even if the unit file or payload was the problem.

`servicedesk-verify.yml` asserts the legs **outside-in and in order** — the
middleware leg before the database leg — because a middleware outage also makes
`database.reachable` false, and asserting the database first would send you to
the wrong host.

## Notes

- **`mysql_native_password` on purpose.** MySQL 8 defaults new accounts to
  `caching_sha2_password`, which PyMySQL can only complete over a plaintext
  connection if `cryptography` is installed — an extra, sometimes compiled,
  dependency for zero benefit inside a VPC.
- **A connection per request on purpose** (`sdapp/db.py`, no pool). That is what
  makes each request a distinct flow rather than one long-lived socket an agent
  sees once and never again. The same reasoning applies to the web tier's HTTP
  calls: `sdapp/client.py` opens a connection per call and does not keep-alive.
- **`sd_http_timeout` (8s) must stay above `SD_DB_CONNECT_TIMEOUT` (5s).**
  Otherwise, when MySQL is down, the web tier times out before the middleware
  can answer and blames the middleware for the database's failure.
- **The app password** comes from `servicedesk_db_password` in the consolidated
  secret, written by Terraform from `var.servicedesk_db_password`. That variable
  defaults to `""`, and an empty value falls back to `mysql_root_password` —
  which both plays now warn about loudly, because it means
  `/etc/servicedesk/servicedesk.env` on the middleware host holds a credential
  that also authenticates as root on the db host. Set it. Even in the fallback
  case the *account* is not root: its grant is `servicedesk.*` only, and only
  from the middleware host's /24 — which in a multi-ring estate is one ring's
  middleware subnet rather than the whole VPC.
- **The db host runs Oracle MySQL**, not MariaDB, because `ubuntu-mysql.yml`
  installs `mysql-server`. The role probes for `mysql.service` then
  `mariadb.service` rather than mapping from the distro.
- **`Role=middleware` is case-sensitive.** The inventory derives `role_middleware`
  verbatim from the EC2 tag, so `Role=Middleware` yields `role_Middleware` and
  matches nothing — the play fails with "no hosts matched" rather than an error
  that mentions casing.
- **`ubuntu_server_roles` is append-only.** `middleware` is the 4th entry, not
  the 3rd, even though it sits between web and db logically: the `for_each` key
  is the list index and the subnet is `subnet_ids[idx % az_count]`, so inserting
  an entry renames and re-subnets — and therefore **replaces** — every instance
  after it.

## What changed in 2.0

| | 1.x | 2.x |
|---|---|---|
| Hosts running app code | 1 (web) | 2 (web, middleware) |
| Ports | 8090 | 8090, 8091 |
| Hosts with the DB password | web | middleware only |
| Deploy plays | `servicedesk-app.yml` | `servicedesk-middleware.yml` + `servicedesk-web.yml` |
| Ways to degrade | 1 (db) | 2 (db, middleware) |
| Schema | 3 tables | 3 tables, unchanged |
| Front door | `:8090` | `:8090`, unchanged |

Terraform side: `middleware` added to the Linux role allow-lists in
`modules/estate/variables.tf`, `deployments/custom/variables.tf` **and each
`modules/compute-<distro>/variables.tf`** — the child-module validation is the
real gate, and missing it fails the plan with a confusing message. The security
groups needed no change: they already allow all inbound from within the VPC, so
8091 was open the moment something listened on it.
