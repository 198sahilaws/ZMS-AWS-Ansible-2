# ZMS Microservices Lab

A small e-commerce application, deliberately spread across the estate: three
Python microservices on three different Linux distributions, each talking to its
own MariaDB server on a *fourth* distribution, tied together by a web front end
that owns no database at all.

It exists to make distributed-system behaviour visible on hardware you control —
cross-host TCP, per-service schemas, fan-out with timeouts, partial failure, and
a write that spans three databases with no distributed transaction to lean on.

**No Terraform was changed to build this.** The workload security groups already
allow all traffic inside the VPC (`10.188.0.0/16`), so ports 8001–8003, 8080 and
3306 need no new rules. Everything here is Python plus Ansible.

---

## Topology

| Service | App host | Port | Database host | Schema |
|---|---|---|---|---|
| `catalog-svc` | Ubuntu web (`role_web` ∩ `distro_ubuntu`) | 8001 | Amazon Linux db | `zms_catalog` |
| `inventory-svc` | Amazon Linux web (`distro_amazon`) | 8002 | SLES 15 db | `zms_inventory` |
| `orders-svc` | RHEL 9 web (`distro_rhel`) | 8003 | RHEL 9 db | `zms_orders` |
| `storefront` | SLES 15 web (`distro_sles`) | 8080 | *(none)* | — |

At the time of writing that resolves to:

```
catalog     10.188.11.94  : 8001  ->  10.188.10.113 : 3306   (zms_catalog)
inventory   10.188.11.128 : 8002  ->  10.188.10.114 : 3306   (zms_inventory)
orders      10.188.11.116 : 8003  ->  10.188.10.118 : 3306   (zms_orders)
storefront  10.188.11.107 : 8080  ->  the three above
```

Those addresses are **not** written down anywhere in the code. `vars/zms-app.yml`
names inventory *groups*, and each play resolves them at run time:

```jinja
groups['role_web'] | intersect(groups['distro_ubuntu']) | first
```

Replace an instance, get a new private IP, converge again — the environment
files are rewritten and nothing else has to change.

### Two deliberate choices

**Every service crosses a distro boundary to reach its database**, except orders,
which stays on RHEL for both. That makes orders the control case: when a
cross-distro path misbehaves, orders is the one that still works, which narrows
the cause fast.

**The Ubuntu database host is not used.** `playbooks/ubuntu-mysql.yml` installs
Oracle MySQL there, not MariaDB, and this application is MariaDB-only. No schema
is mapped to `distro_ubuntu`, so `zms-app-db.yml` ends the play on that host and
leaves it alone. To bring it in, install MariaDB there and point a service at it
in `vars/zms-app.yml`.

---

## What was added

```
control-repo/
├── vars/zms-app.yml                     # topology map — the only file to edit
├── playbooks/
│   ├── zms-app-db.yml                   # step 1: schemas, accounts, bind-address
│   ├── zms-app-services.yml             # step 2: the three microservices
│   ├── zms-app-frontend.yml             # step 3: the storefront
│   └── zms-app-verify.yml               # read-only end-to-end check
├── roles/
│   ├── zms_app_db/                      # MariaDB preparation
│   └── zms_microservice/                # deploy one service to one host
│       └── files/app/                   # the Python payload (identical on all 4 hosts)
│           ├── requirements.txt
│           └── zmsapp/
│               ├── config.py  db.py  clients.py  base.py
│               ├── schema.py  seed.py  generator.py  wsgi.py
│               ├── catalog.py  inventory.py  orders.py  storefront.py
│               └── templates/           # storefront UI
├── orchestrate.yml                      # three imports added, section 2b
└── scripts/converge.sh                  # three entries added to LINUX_PLAYS
```

Nothing outside `control-repo/` was touched.

---

## Deploy

From the Ansible control node (`10.188.30.226`), in `/srv/repos/...`:

```bash
ansible-playbook playbooks/zms-app-db.yml
ansible-playbook playbooks/zms-app-services.yml
ansible-playbook playbooks/zms-app-frontend.yml
ansible-playbook playbooks/zms-app-verify.yml     # proves the whole path
```

Or in one go, since all three are wired into section 2b of the orchestrator:

```bash
ansible-playbook orchestrate.yml --tags zms-app
```

### How it runs unattended

The hourly `ansible-estate` timer does **not** run `orchestrate.yml`. It runs
`scripts/converge.sh`, which iterates its own `LINUX_PLAYS` / `WINDOWS_PLAYS`
arrays so that one failing playbook cannot abort the whole chain the way
`import_playbook` does. The three application playbooks are listed in **both**
files, and they have to be — a playbook in `orchestrate.yml` alone runs only
when someone invokes it by hand.

So once this is merged the application deploys, and self-heals, on the hour with
nobody running anything: a stopped service is restarted, a deleted virtualenv is
rebuilt, a hand-edited environment file is put back.

`zms-app-verify.yml` is deliberately **not** in either list. It ends in an
assert, so scheduling it would mark the timer unit failed during a deliberate
failure demo. Run it by hand.

> If you add another application playbook later, add it to `converge.sh` too, or
> it will look scheduled and never run.

**First run takes a few minutes** (four virtualenvs, pip fetching wheels through
the NAT gateway, plus seeding). Subsequent runs are seconds: the seeder no-ops
once rows exist and pip no-ops once the venv is built.

### Reaching the UI

The web hosts are in private subnets. RDP to the Windows bastion
(`15.224.45.16`), then browse to:

```
http://10.188.11.107:8080/
```

From the control node, without a browser:

```bash
curl -s http://10.188.11.107:8080/api/topology | python3 -m json.tool
```

---

## What each page demonstrates

| Page | What is actually happening |
|---|---|
| **Dashboard** (`/`) | Six concurrent HTTP calls (health + stats × 3). Renders whatever came back within 2.5 s and marks the rest unreachable. |
| **Products** (`/products`) | One call to catalog for a page of rows, then **one bulk call** to inventory for all their stock — not one call per row. Joined in Python. Two schemas, two servers, two distros, one table. |
| **Orders** (`/orders`) | Single service, single schema. The boring baseline. |
| **Order detail** | Two hops: storefront → orders → (catalog ∥ inventory). The second hop is made from the RHEL host, not the SLES one, so it tests a different network path. |
| **Place order** (`/new`) | The saga: price via catalog → reserve via inventory (per line) → write locally. Any failure releases what was already reserved. |

### The bulk-endpoint rule

`/products/bulk?ids=1,2,3` and `/stock/bulk?ids=1,2,3` exist because rendering 40
rows must not cost 40 HTTP round trips. In a fan-out architecture every service
needs an endpoint shaped like this, or page latency becomes row count × RTT. It
is the single most common performance mistake in a first microservices build.

---

## Failure demos

Each of these is one command and takes under a minute.

**1 — Partial estate.** On the Ubuntu web host:

```bash
sudo systemctl stop zms-catalog
```

Reload the dashboard: the catalog card is red, the other two keep their numbers.
Products still lists nothing (catalog owns the list) but returns a clear banner
rather than a 500. Order detail still renders — names are blank, the order is
intact. Start it again, or wait for the next converge, which starts it for you.

**2 — Database down, service up.** On the SLES database host:

```bash
sudo systemctl stop mariadb
```

inventory-svc stays running and answers `/health` with **503** and the exact
connection error. The dashboard shows "db down" rather than "unreachable" — a
different badge because it is a different failure, and a load balancer should
treat them differently too.

**3 — Refused write.** Find a product the Products page shows as out of stock,
order it at `/new`. inventory returns 409, orders refuses, no order row is
written. Now stop inventory-svc entirely and try again: orders gets a timeout
instead and returns 503. Same refusal, different reason, and the page says which.

**4 — Compensation.** Order a multi-line basket where the second line is out of
stock. The first line's reservation is released before the error returns. Check
it on the inventory host:

```sql
SELECT * FROM zms_inventory.stock_moves WHERE reason IN ('reserve','release')
ORDER BY id DESC LIMIT 10;
```

You will see the reserve and its matching release. That is a saga standing in
for the `ROLLBACK` you cannot have across three servers.

**5 — The timeout itself.** On the RHEL web host, `sudo tc qdisc add dev eth0
root netem delay 4000ms` (needs `iproute-tc`). Orders now exceeds the 2.5 s
budget and the dashboard degrades instead of hanging. Remove with `tc qdisc del
dev eth0 root`.

---

## Troubleshooting

In rough order of how often each one actually happens.

| Symptom | Cause | Fix |
|---|---|---|
| `/health` returns 503, `Can't connect to MySQL server` | MariaDB bound to `127.0.0.1` | `zms-app-db.yml` writes `/etc/my.cnf.d/99-zms-app.cnf` with `bind-address = 0.0.0.0`. Confirm with `ss -ltn \| grep 3306` — it must not say `127.0.0.1:3306`. |
| 503, `Access denied for user 'zmsapp'@'10.188.x.y'` | Grant is for the wrong host pattern | The account is `'zmsapp'@'10.188.%'`. If your app host is outside `10.188.0.0/16`, widen `zms_app_db_client_pattern`. |
| Connections take ~5 s then fail | Reverse DNS lookups on connect | `skip-name-resolve = 1` in the same drop-in. Re-run `zms-app-db.yml`. |
| Service reachable locally, not from other hosts | `firewalld` (RHEL, SLES) | The role opens the port when firewalld is active. `firewall-cmd --list-ports` to confirm. Amazon Linux has no firewalld; Ubuntu's ufw is inactive. |
| `No Python >= 3.8` on SLES | SLES 15 ships Python 3.6 as `python3` | The role installs `python311`. If the repo lacks it: `zypper install python311 python311-pip`, then converge. |
| pip fails fetching wheels | NAT egress | Every dependency is a pure-Python wheel; nothing compiles. Check the NAT gateway and retry — the task already retries three times. |
| Storefront renders but every card is unreachable | Endpoint map unresolved | `grep ZMS_.*_URL /etc/zms-app/storefront.env`. Empty means a `role_web` ∩ `distro_*` intersection was empty — check the instance tags with `ansible-inventory --graph`. |
| Templates not found under gunicorn | Flask root path | Fixed in `base.py`: the Flask import name is the *package* (`zmsapp`), not the service name. Do not change it back. |

Logs are in journald, one identifier per service:

```bash
journalctl -u zms-catalog -f
journalctl -t zms-order-generator --since -1h
```

---

## Changing the topology

Everything lives in `vars/zms-app.yml`.

**Move a service to a different host** — change its `app_distro_group`. The next
converge deploys it there; remove the old unit by hand (the role does not track
past placements).

**Point a service at a different database** — change its `db_distro_group`, then
run `zms-app-db.yml` (creates the schema on the new host) and
`zms-app-services.yml` (rewrites the environment file). Data does not migrate.

**Change the data volume** — `zms_app_seed_products` / `zms_app_seed_orders`,
then reseed:

```bash
/opt/zms-app/venv/bin/python -m zmsapp.seed --force
```

Catalog and inventory must use the same `zms_app_seed_products` and
`zms_app_seed_random_seed`, or product ids stop lining up between the two.

**Turn off the fake traffic** — `zms_app_generator_enabled: false`, then
converge. It places one order a minute through the public API on the orders host.

---

## What this is not

Left out on purpose, because it is a lab:

- **TLS.** Everything is plaintext HTTP inside the VPC.
- **Authentication.** No login, no API keys, no service identity. Any host in
  the VPC can call any endpoint.
- **Connection pooling.** Connect-per-request, so a broken network path shows up
  on the next page load rather than minutes later. Correct for teaching, wrong
  for production.
- **Schema migrations.** Tables are created by `CREATE TABLE IF NOT EXISTS`.
  There is no versioning and no downgrade path.
- **Metrics and tracing.** `/health` and `/stats` per service, and that is all.
  Prometheus, Grafana and a correlation-ID header would be the natural next step.
- **Replication or failover.** One MariaDB instance per schema. Stop it and that
  service is degraded until you start it again — which is the point of demo 2.
- **Secrets hygiene.** The application account reuses the MariaDB root password
  from the consolidated secret, because adding a field to that secret would mean
  a Terraform change. Override with `-e zms_app_db_password_override='...'` on
  both `zms-app-db.yml` and `zms-app-services.yml` if you want them separate.
