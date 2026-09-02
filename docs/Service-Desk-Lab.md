# Service Desk Lab

A small internal IT service desk — Flask + gunicorn on the Ubuntu **web** host,
Oracle MySQL on the Ubuntu **db** host, and a traffic generator on the Ubuntu
**client** host. Built for `deployments/web-app`.

It exists to put realistic, continuously changing data in front of MySQL and to
make the web host talk to the database host over the network, so the estate
produces enterprise-shaped east-west traffic instead of an idle port.

## Topology

| Host | Group intersection | What runs there |
|---|---|---|
| web | `role_web & distro_ubuntu` | gunicorn on **:8090**, creates + seeds the schema |
| db | `role_db & distro_ubuntu` | MySQL 8, schema `servicedesk` |
| client | `role_client & distro_ubuntu` | `sd-traffic.timer`, real HTTP every 2 min |

Declared in `vars/servicedesk.yml`, resolved from inventory groups at run time —
never hardcoded IPs. Re-run Terraform, get new addresses, converge again, and the
map still holds.

Every request crosses a host boundary: **client → web** over HTTP, **web → db**
over MySQL, on a fresh TCP connection each time.

## Schema

Three tables. `users` (requesters and agents), `tickets` (ref, subject, status,
priority, category, requester, assignee, timestamps), `comments` (body, author,
internal flag). Indexed for the queue view's actual access pattern:
`(status, priority, created_at)`.

Kept to syntax both MySQL 8 and MariaDB 10.11 accept, so the app can be tested
locally and repointed at a MariaDB host without a code change.

## Seed data

`sdapp/seed.py` — **deterministic** and **idempotent**.

- 40 users, 500 tickets over 90 days, ~1,300 comments (tunable in `vars/`)
- Weighted so it looks like a real queue rather than uniform noise: ~49% closed,
  P3 dominant with a handful of P1s, a long tail of comment counts (many tickets
  with 1–3, a few with 17), ~95% weekday with a mid-morning peak
- Same `sd_seed_random` produces byte-identical content, so "did the data
  change?" is answerable with a checksum
- Runs on every converge and exits without writing once tickets exist; only a
  first run prints `inserted`, which is what the role's `changed_when` keys on

```bash
# force a reseed
/opt/servicedesk/venv/bin/python -m sdapp.seed --force
```

## Endpoints

| Path | Purpose |
|---|---|
| `/` | queue view, filterable by status and priority |
| `/ticket/<ref>` | detail with comments (join across all three tables) |
| `GET /api/tickets` | queue as JSON — what the generator polls |
| `POST /api/tickets` | raise a ticket |
| `POST /api/tickets/<ref>/comments` | comment; a comment on a `new` ticket moves it to `open` |
| `/stats` | counts by status and priority |
| `/health` | 200 healthy, **503 degraded** with a `database` object |

## Traffic generator

`sd-traffic.py` on the client host: **stdlib `urllib` only**, so the client host
needs no venv, no pip and no packages. Driven by a systemd timer with
`RandomizedDelaySec` — without jitter every host fires on the same second and the
flow log shows a synchronised pulse no real estate produces, which is exactly the
artefact that misleads a clustering algorithm.

Each burst: check health, browse the queue, open a few tickets, sometimes raise
one (~35%), sometimes comment (~50%), read stats. Reads dominate writes, as a
real service desk does.

It is a **real HTTP client on purpose**. A microsegmentation agent attributes a
flow to the process that opened it, so traffic from `hping3` or `tcpreplay` would
be attributed to the generator binary and the flow records would be useless.

## Running it

```bash
ansible-playbook playbooks/servicedesk-db.yml       # database, account, drop-in
ansible-playbook playbooks/servicedesk-app.yml      # app, schema, seed
ansible-playbook playbooks/servicedesk-client.yml   # traffic timer
ansible-playbook playbooks/servicedesk-verify.yml   # end-to-end asserts (by hand)
```

All three deploy playbooks are in **both** `orchestrate.yml` and
`scripts/converge.sh`'s `LINUX_PLAYS`, so the app self-heals on the hourly timer.
`servicedesk-verify.yml` is deliberately in neither — it ends in asserts and
would mark the unit failed during a deliberate failure demo.

## The degradation demo

```bash
sudo systemctl stop mysql          # on the db host
curl -s http://<web>:8090/health   # 503, with the reason in the body
curl -s http://<web>:8090/         # renders "Service degraded", not a stack trace
```

Every route degrades the same way — HTML and JSON alike — via one Flask
`errorhandler` for `pymysql.MySQLError`. The app stays up and says what is wrong,
which is what makes "app down" distinguishable from "database down".

## Notes

- **`mysql_native_password` on purpose.** MySQL 8 defaults new accounts to
  `caching_sha2_password`, which PyMySQL can only complete over a plaintext
  connection if `cryptography` is installed — an extra, sometimes compiled,
  dependency for zero benefit inside a VPC.
- **A connection per request on purpose** (`sdapp/db.py`, no pool). That is what
  makes each request a distinct flow rather than one long-lived socket an agent
  sees once and never again.
- **The app password** comes from `servicedesk_db_password` in the consolidated
  secret if present, otherwise falls back to `mysql_root_password`. The account
  is still not root: its grant is `servicedesk.*` only.
- **The db host runs Oracle MySQL**, not MariaDB, because `ubuntu-mysql.yml`
  installs `mysql-server`. The role probes for `mysql.service` then
  `mariadb.service` rather than mapping from the distro.
