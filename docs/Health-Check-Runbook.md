# ZMS AWS Lab — Health Check and Triage Runbook

Operational reference for checking whether the estate is deployed and working.
Every command here was taken from the code in this repo, not from documentation,
so unit names, paths, ports and users are the real ones.

Scope is the live estate: the Ansible control node, the bastion, and the four
Ubuntu managed hosts (web, middleware, db, client). The repo also contains
Windows AD/IIS and RHEL/SLES/Amazon Linux playbooks; they are out of scope here
because no host in this deployment carries those tags.

---

## Estate shape

| Role | Tag intersection | What runs on it |
|---|---|---|
| Control node | management subnet, not in `os_linux` | `/opt/control-repo`, two systemd timers, Ansible |
| Bastion | `role_bastion` | SSH jump host / SSM target |
| Web | `role_web` ∩ `distro_ubuntu` | `apache2` on 80, `servicedesk` (gunicorn) on **8090** — HTML only |
| Middleware | `role_middleware` ∩ `distro_ubuntu` | `servicedesk` (gunicorn) on **8091** — all SQL, holds the DB password |
| DB | `role_db` ∩ `distro_ubuntu` | Oracle MySQL 8 (`mysql.service`) on 3306, schema `servicedesk` |
| Client | `role_client` ∩ `distro_ubuntu` | `sd-traffic.timer` generating load at the web host |

The service desk is **three tiers on three hosts** (app version 2.x):

```
CLIENT --HTTP :8090--> WEB --HTTP :8091--> MIDDLEWARE --MySQL :3306--> DB
```

Two things follow from that and they drive most of the triage below. First, the
**unit name is `servicedesk` on both the web and middleware hosts** — the same
role installs the same payload twice and `SD_TIER` in the env file decides which
Flask app runs, so "is `servicedesk` active?" is a question you must ask of a
specific host. Second, **only the middleware host can reach MySQL**: it has the
password and the grant is scoped to its /16. A DB-connectivity test run from the
web host is expected to fail and proves nothing.

> If you are on a host running app version 1.x (single tier, web host holds the
> password), this runbook is ahead of it. Check
> `grep SD_TIER /etc/servicedesk/servicedesk.env` — absent means 1.x.

Resolve the actual addresses rather than hardcoding them — instances get
replaced and the IP changes:

```bash
# On the control node, as ubuntu, from /opt/control-repo
ansible-inventory --graph
ansible role_web:\&distro_ubuntu        --list-hosts
ansible role_middleware:\&distro_ubuntu --list-hosts
ansible role_db:\&distro_ubuntu         --list-hosts
ansible role_client:\&distro_ubuntu     --list-hosts
```

Throughout this document `WEB`, `MW`, `DB` and `CLIENT` mean the private IPs
those commands return.

If `role_middleware` is empty, the estate predates the three-tier split or the
EC2 tag is wrong. The group name is derived verbatim from the tag, so
`Role=Middleware` produces `role_Middleware` and matches nothing; check
`ubuntu_server_roles` in `deployments/web-app/main.tf` and the actual tag with
`ansible-inventory --graph`.

### Getting a shell

The managed hosts are private. Use SSM from your workstation, or hop through the
bastion. From the control node itself you do not normally need a shell on the
managed hosts at all — that is what the Ansible ad-hoc commands in each section
are for.

---

## 0. The sixty-second sweep

Run this block on the control node as `ubuntu`. It answers "is anything wrong"
before you start digging.

```bash
cd /opt/control-repo

# --- is the control node itself converging? ---
systemctl list-timers 'ansible-*' --no-pager
systemctl is-active ansible-bootstrap.service ansible-estate.service
tail -n 5 /var/log/ansible/converge-status.log
tail -n 20 /var/log/ansible/converge-failures.log

# --- does the control node have what it needs to talk to the estate? ---
sudo test -s /etc/ansible/keys/ansible_rsa && echo "SSH key present" || echo "NO SSH KEY - bootstrap.yml has not run"
ansible-inventory --graph
ansible all -m ping

# --- are the four application tiers up? ---
ansible role_web:\&distro_ubuntu        -m command -a 'systemctl is-active servicedesk apache2'
ansible role_middleware:\&distro_ubuntu -m command -a 'systemctl is-active servicedesk'
ansible role_db:\&distro_ubuntu         -m command -a 'systemctl is-active mysql'
ansible role_client:\&distro_ubuntu     -m command -a 'systemctl is-active sd-traffic.timer'

# --- is the application actually serving? both legs, each from its own host ---
ansible role_web:\&distro_ubuntu        -m uri -a "url=http://localhost:8090/health status_code=200,503 return_content=yes"
ansible role_middleware:\&distro_ubuntu -m uri -a "url=http://localhost:8091/health status_code=200,503 return_content=yes"
```

Then the single authoritative end-to-end test:

```bash
ansible-playbook playbooks/servicedesk-verify.yml
```

Read the sweep like this. No SSH key means nothing downstream can possibly be
healthy — fix the control node first (section 1) and ignore everything else.
`ping` failures on all Linux hosts point at the key or the security group, not at
the applications.

The two `/health` results together localise the fault in one step, which is the
main reason to run both rather than just the front door:

| `:8090` | `:8091` | Meaning | Go to |
|---|---|---|---|
| 200 | 200 | Healthy | — |
| 503, `middleware.reachable` **false** | refused or 503 | Middleware tier down | §4 |
| 503, `middleware.reachable` true | 503 | Database leg down | §5 |
| refused | 200 | Web tier down; the rest is fine | §3 |
| refused | refused | Both app hosts down — suspect converge, not the app | §1 |

`failed_tier` in the web tier's 503 body names the broken leg directly, so
`curl -s http://WEB:8090/health | python3 -m json.tool` is usually faster than
reasoning through the table.

**Do not diagnose the middleware from the database leg.** A middleware outage
also reports `database.reachable: false` at :8090 — from the web tier's vantage
point the database genuinely is unreachable — so always read
`middleware.reachable` first. `servicedesk-verify.yml` asserts in that order for
the same reason.

---

## 1. Ansible control node

This tier is first because every other check runs through it, and because a
silent failure here looks exactly like an application outage.

### Is the node built at all?

```bash
cloud-init status --long
sudo tail -n 50 /var/log/zms-control-bootstrap.log
sudo tail -n 100 /var/log/cloud-init-output.log
systemctl status zms-control-bootstrap.timer --no-pager
ls -la /opt/control-repo
```

`zms-control-bootstrap.timer` retries every 5 minutes and disables itself once
the bootstrap succeeds, so a timer still listed as active means the bootstrap has
never completed. Read the tail of its log for the reason. An empty or missing
`/opt/control-repo` means the clone failed — almost always DNS or NAT egress at
first boot.

To re-drive it by hand at any time (it is idempotent):

```bash
sudo /usr/local/sbin/zms-control-bootstrap.sh
```

### Environment and identity

```bash
sudo cat /etc/ansible/estate.env
sudo ls -l /etc/ansible/keys/
ansible --version
ansible-galaxy collection list 2>/dev/null | head -n 30
ls /opt/control-repo/collections/ansible_collections/
```

`estate.env` must contain `AWS_REGION`, `ANSIBLE_SECRET_NAME`,
`ANSIBLE_SECRET_ARN`, `ANSIBLE_ESTATE` and `CONTROL_REPO_DIR`.

**The manual-run trap.** `estate.env` is `0640 root:root`, so `ubuntu` cannot
read it. The systemd units get it via `EnvironmentFile`, but your interactive
shell does not — and with `ANSIBLE_ESTATE` unset the inventory filter falls back
to the wildcard `Environment: "*"`, which discovers *every* Terraform-managed
instance in the account and region, including other deployments. Always load the
environment before running anything by hand:

```bash
set -a; . <(sudo cat /etc/ansible/estate.env); set +a
echo "region=$AWS_REGION estate=$ANSIBLE_ESTATE"
```

If `ansible-inventory --graph` shows more hosts than you expect, this is why.

### AWS and secret access

```bash
set -a; . <(sudo cat /etc/ansible/estate.env); set +a
aws sts get-caller-identity
aws ec2 describe-instances --filters Name=tag:ManagedBy,Values=Terraform \
  --query 'Reservations[].Instances[].[PrivateIpAddress,Tags[?Key==`Role`].Value|[0],State.Name]' --output table
aws secretsmanager describe-secret --secret-id "$ANSIBLE_SECRET_NAME" --query 'Name'
# Key names only, never values:
aws secretsmanager get-secret-value --secret-id "$ANSIBLE_SECRET_NAME" \
  --query SecretString --output text | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)))'
```

The last command is deliberately written to print the *keys* of the consolidated
secret and nothing else. Never paste a `get-secret-value` output into a ticket or
a chat window.

### Convergence state

```bash
systemctl list-timers 'ansible-*' --no-pager
systemctl status ansible-bootstrap.service --no-pager
systemctl status ansible-estate.service --no-pager
journalctl -u ansible-estate.service -n 200 --no-pager
tail -n 100 /var/log/ansible/ansible.log
cat /var/log/ansible/converge-status.log
cat /var/log/ansible/converge-failures.log
```

Two timers, doing different jobs. `ansible-bootstrap.timer` (2 min after boot,
then every 30 min) runs `scripts/reconverge.sh`, which self-converges the control
node only — it pulls the repo, refreshes collections and writes the SSH key. It
never touches the estate. `ansible-estate.timer` (10 min after boot, then hourly)
runs `scripts/converge.sh`, which is what actually pushes to the managed hosts.

Force either one immediately:

```bash
sudo systemctl start ansible-bootstrap.service   # self-converge
sudo systemctl start ansible-estate.service      # push to the estate, takes minutes
```

Or run them in the foreground where you can watch:

```bash
cd /opt/control-repo
./scripts/reconverge.sh
./scripts/converge.sh --linux
```

`converge.sh` runs each playbook as its own `ansible-playbook` process and prints
a `CONVERGE SUMMARY` block at the end listing passed and failed playbooks. That
summary is the fastest way to see which tier is broken. Note that
`servicedesk-verify.yml` and `zms-app-verify.yml` are deliberately excluded from
it — they end in asserts and would mark the unit failed during a deliberate
failure demo. Run those by hand.

### Repo and collection hygiene

```bash
cd /opt/control-repo
git status --short
git log --oneline -5
git rev-parse --abbrev-ref HEAD
```

A dirty tree here used to be fatal. `reconverge.sh` now sets
`core.fileMode false` and uses `git fetch` + `git reset --hard origin/<branch>`
rather than `git pull --ff-only`, precisely because a pull refuses to run on a
dirty tree and that aborted the whole script under `set -e` before the SSH key
was ever written. If you see modified files, expect them to be discarded at the
next timer tick — commit and push instead of editing on the node.

### Inventory and connectivity

```bash
ansible-inventory --graph
ansible-inventory --host <IP>
ansible all -m ping
ansible os_linux -m ping
ansible all -m setup -a 'filter=ansible_distribution*'
ansible all -m command -a 'uptime'
```

`ansible all -m ping` failing everywhere with UNREACHABLE is a control-node
problem (missing key, wrong key, security group), not five simultaneous host
failures. Check `/etc/ansible/keys/ansible_rsa` exists and is `0600` first.

One known and expected oddity: the bastion and the control node do not appear in
`os_linux` or `distro_ubuntu`, so `roles/baseline` never runs on them. This is
stable across rebuilds, so it is either intentional or a long-standing tag
omission — not a regression to chase.

### Debug bundle

When you want everything at once, or need to hand the state to someone else:

```bash
sudo /opt/control-repo/scripts/collect-debug.sh
```

It is read-only, redacts secrets on the way out, and writes a tarball to `/tmp`.
It sets `ANSIBLE_CACHE_PLUGIN=memory` so that running it under `sudo` does not
take ownership of `/var/tmp/ansible_facts` and silently disable fact caching for
the `ubuntu` service user afterwards.

---

## 2. Bastion

Little runs here; it exists to be jumped through.

```bash
systemctl is-active sshd amazon-ssm-agent
ss -lntp | grep :22
journalctl -u ssh -n 50 --no-pager
# from the bastion, prove the path onward -- one probe per hop:
nc -vz WEB 8090
nc -vz MW  8091
nc -vz DB  3306
```

If `nc` from the bastion succeeds but the same probe from the web host fails, the
problem is a security group rule between those two specific tiers, not a host
firewall.

All three should succeed from here. The security groups allow all inbound from
within the VPC, so the bastion can reach every hop directly even though the real
request path never does — which makes this the cleanest place to prove a
listener exists before blaming the tier in front of it.

---

## 3. Web tier

Two services live here and they are independent: `apache2` on port 80 (installed
by `playbooks/ubuntu-apache2.yml`, essentially a placeholder) and `servicedesk`
on port 8090 (the Flask application behind gunicorn). A failure of one says
nothing about the other.

**This host renders HTML and nothing else.** It has no database driver in scope,
no database password, and no route to MySQL that would work if it had one. Every
piece of data it displays came from the middleware over HTTP. If you find
yourself reaching for a MySQL command here, you are on the wrong host — go to
§4 or §5.

### Service state

```bash
systemctl status servicedesk --no-pager
systemctl status apache2 --no-pager
systemctl is-enabled servicedesk apache2
ss -lntp | grep -E ':(80|8090)'
journalctl -u servicedesk -n 100 --no-pager
journalctl -t servicedesk --since '15 min ago' --no-pager
```

The unit runs as `sdapp:sdapp` with `Restart=always` and `RestartSec=5`, and
gunicorn logs access and errors to the journal under the identifier
`servicedesk`. A flapping service shows up as repeated "Started"/"Main process
exited" pairs in `journalctl -u servicedesk`.

The unit is named `servicedesk` on the middleware host too. Confirm which tier
you are looking at before drawing a conclusion:

```bash
sudo grep -E '^SD_(TIER|MIDDLEWARE_URL)=' /etc/servicedesk/servicedesk.env
# web host: SD_TIER=web plus SD_MIDDLEWARE_URL=http://MW:8091
```

### Is it installed?

```bash
ls -l /opt/servicedesk/venv/bin/gunicorn
ls -l /opt/servicedesk/src/sdapp/
sudo ls -l /etc/servicedesk/servicedesk.env
systemctl cat servicedesk --no-pager
/opt/servicedesk/venv/bin/pip list 2>/dev/null | grep -Ei 'flask|gunicorn|pymysql'
```

The same payload is installed on both app hosts — `api.py`, `web.py`, `db.py`
and `client.py` are all present here, and `pymysql` is in the venv. That is
expected and is not a credential leak: `wsgi.py` imports only `sdapp.web` when
`SD_TIER=web`, and `web.py` never imports `db`.

`/etc/servicedesk` is `0750 root:sdapp` and the env file inside it is
`0640 root:sdapp`. On the **web** host it deliberately carries **no**
`SD_DB_PASSWORD` line at all — absent, not empty. If you find one there,
something has re-added a secret lookup to `playbooks/servicedesk-web.yml` and
that is a regression worth reverting.

### HTTP endpoints

```bash
curl -s -o /dev/null -w 'health: %{http_code}\n' http://localhost:8090/health
curl -s http://localhost:8090/health | python3 -m json.tool
curl -s http://localhost:8090/stats  | python3 -m json.tool
curl -s 'http://localhost:8090/api/tickets?status=open&limit=3' | python3 -m json.tool
curl -s -o /dev/null -w 'index: %{http_code}\n' http://localhost:8090/
curl -s -o /dev/null -w 'apache: %{http_code}\n' http://localhost:80/
```

This tier serves `/`, `/ticket/<ref>` and `/health` itself, and **forwards
`/api/*` and `/stats` to the middleware byte for byte** — same status, same
content type, same payload. So a difference between `curl WEB:8090/api/tickets`
and `curl MW:8091/api/tickets` is a real fault, not a rendering difference.

**Read `/health` carefully — this is the hinge of the whole lab.** It returns
`200` only when this tier, the middleware **and** the database are all good, and
the body carries both a `middleware` object and a `database` object:

```json
{"service": "servicedesk", "tier": "web", "status": "degraded",
 "failed_tier": "middleware",
 "middleware": {"url": "http://MW:8091", "reachable": false},
 "database": {"reachable": false, "error": "middleware unreachable at ..."}}
```

`failed_tier` is the field to read first. The `database` object is nested from
the middleware verbatim when the middleware answers, so monitors written against
the 1.x single-tier app keep working — but note that when the **middleware** is
down this tier still reports `database.reachable: false`, because from here it
genuinely is. Reading `database` alone will send you to the wrong host.

So: connection refused means this tier is down. `503` with
`middleware.reachable: false` means hop two is broken — §4. `503` with
`middleware.reachable: true` means the database leg is broken — §5, and do not
waste time on gunicorn here. `200` with zero tickets in `/stats` means every tier
is fine but the seed never ran.

Write a ticket to prove the POST path works end to end, through both hops.
Priority is an enum — `P1` to `P4` — and anything else is coerced to `P3`, which
the response now tells you about in `priority_coerced`. New tickets are created
with status `new`, not `open`, and are auto-assigned to the least-loaded agent:

```bash
REF=$(curl -s -X POST http://localhost:8090/api/tickets \
  -H 'Content-Type: application/json' \
  -d '{"subject":"runbook smoke test","body":"created by hand","priority":"P3"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["ref"])')
echo "created $REF"
curl -s "http://localhost:8090/api/tickets?status=new&limit=5" | python3 -m json.tool
curl -s -o /dev/null -w 'ticket page: %{http_code}\n' "http://localhost:8090/ticket/$REF"
```

A `409` with `no users exist; run the seeder first` means the schema is present
but unseeded — §8.

### Middleware connectivity from the web host

This is the equivalent of the old "can the web host reach MySQL?" check, moved
up a hop. It is the first thing to run when `/health` reports
`middleware.reachable: false`:

```bash
sudo grep '^SD_MIDDLEWARE_URL=' /etc/servicedesk/servicedesk.env
nc -vz MW 8091
curl -s -o /dev/null -w 'mw health: %{http_code}\n' http://MW:8091/health
curl -s http://MW:8091/health | python3 -m json.tool
```

`nc` succeeding while `curl` hangs points at `SD_HTTP_TIMEOUT` (8s) versus a
middleware that is up but blocked on MySQL — which is a §5 problem wearing a §4
costume. The timeout is deliberately longer than the middleware's own 5s
database connect timeout so the middleware gets to return its considered 503
first; if someone has lowered it below 5s, the web tier will time out and blame
the middleware for the database's failure.

An empty or missing `SD_MIDDLEWARE_URL` means `servicedesk-web.yml` could not
resolve a host in `role_middleware ∩ distro_ubuntu` — check the tag, not the
network.

### Re-deploy this tier

```bash
# on the control node
ansible-playbook playbooks/servicedesk-web.yml
ansible-playbook playbooks/ubuntu-apache2.yml
```

---

## 4. Middleware tier

`servicedesk` (gunicorn) on port **8091**, on the `role_middleware ∩
distro_ubuntu` host. Same unit name, same paths and same payload as the web
tier — `SD_TIER=middleware` is the only difference, and it is what makes
`wsgi.py` import `sdapp.api` instead of `sdapp.web`.

This is the only host that talks to MySQL, so every database symptom is
diagnosed from here.

### Service state and identity

```bash
systemctl status servicedesk --no-pager
ss -lntp | grep 8091
journalctl -u servicedesk -n 100 --no-pager
sudo grep -E '^SD_(TIER|DB_HOST|DB_NAME|DB_USER)=' /etc/servicedesk/servicedesk.env
```

`SD_TIER` must read `middleware`. If it reads `web`, this host is running the
frontend against itself and `/health` will report an unreachable middleware in a
confusing loop — re-run `playbooks/servicedesk-middleware.yml`.

Unlike the web host, the env file here **does** carry `SD_DB_PASSWORD`. It is
`0640 root:sdapp`; do not `cat` it into a terminal you are sharing.

### HTTP endpoints

```bash
curl -s -o /dev/null -w 'health: %{http_code}\n' http://localhost:8091/health
curl -s http://localhost:8091/health | python3 -m json.tool
curl -s http://localhost:8091/stats  | python3 -m json.tool
curl -s 'http://localhost:8091/api/tickets?status=open&limit=3' | python3 -m json.tool
```

Every route here returns JSON — there are no templates on this tier, so a
request for `/` returns 404 and that is correct. `/health` is the 1.x contract
unchanged: `200` when the database answers, `503` with a `database` object when
it does not, plus `"tier": "middleware"` so you can tell which process answered.

Two things to look at in `/stats` that only exist on this tier's logic:

```bash
curl -s http://localhost:8091/stats | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["open_by_sla"])'
curl -s 'http://localhost:8091/api/tickets?status=open&limit=3' | python3 -c \
  'import json,sys; [print(t["ref"], t["priority"], t["sla"]) for t in json.load(sys.stdin)]'
```

`open_by_sla` counts `on_track` / `at_risk` / `breached` against the per-priority
budgets (P1 4h, P2 8h, P3 24h, P4 72h). These are **derived at read time**, not
stored, so they change as the clock moves and a rising `breached` count on a
static dataset is expected rather than a fault.

Datetimes are emitted as ISO-8601 strings here, not Flask's default RFC 1123.
That is the contract `sdapp/client.py` revives on the web side; if a template
starts showing raw strings where it used to show formatted dates, look at
`DATETIME_FIELDS` in `client.py` before suspecting the template.

### Database connectivity from the middleware host

This is the check that distinguishes "MySQL is down" from "MySQL is up but this
host cannot reach it", and it is the one worth running first whenever
`:8091/health` returns 503:

```bash
nc -vz DB 3306
sudo bash -c 'set -a; . /etc/servicedesk/servicedesk.env; set +a;
  cd /opt/servicedesk/src && /opt/servicedesk/venv/bin/python -c "from sdapp import db; print(db.health())"'
```

The `cd` matters: the app's `PYTHONPATH` is `/opt/servicedesk/src`, set in the
env file, and the import fails without it.

Run this on the **middleware** host. The same command on the web host fails for
two reasons at once — no password in the environment and no grant for that
address — and neither failure tells you anything about MySQL.

### Re-deploy this tier

```bash
# on the control node
ansible-playbook playbooks/servicedesk-middleware.yml
```

---

## 5. Database tier

Oracle MySQL 8, unit name `mysql` (not `mariadb` — every other distro in the repo
uses MariaDB, this one does not). The role probes for the unit rather than
mapping it from the distro.

### Service and listener

```bash
systemctl status mysql --no-pager
ss -lntp | grep 3306
sudo mysqladmin status
sudo tail -n 100 /var/log/mysql/error.log
```

The listener line must read `0.0.0.0:3306`. `127.0.0.1:3306` means the
middleware host cannot connect and every downstream symptom will look like a
security group problem. The `33060` socket on loopback is the X Protocol port
and is irrelevant here.

### Authentication — read this before running any `mysql` command

There are two accounts and neither of them is your login user.

`mysql -e "..."` as `ubuntu` gives
`ERROR 1045 (28000): Access denied for user 'ubuntu'@'localhost'`. That is not a
fault; there simply is no `ubuntu` MySQL account. Use the socket-authenticated
root account instead:

```bash
sudo mysql -e "SHOW DATABASES;"
sudo mysql -e "SELECT COUNT(*) FROM servicedesk.tickets;"
```

The application account `sdapp` is granted **only from the MIDDLEWARE host's
/16** (`sdapp`@`10.%`, derived at converge time from that host's own address),
with `servicedesk.*:ALL` and nothing else. It therefore cannot connect over the
local socket or as `localhost`. To test it the way the app does, connect over
TCP to the host's own routable address:

```bash
mysql -h DB -u sdapp -p -e "SELECT COUNT(*) FROM servicedesk.tickets;"
```

The grant moved from the web host to the middleware host when the tiers were
split. It is still a /16 rather than a /32 because a replaced instance keeps its
subnet but not its address — and in this estate both app hosts sit in the same
/16 anyway, so the /16 is what makes the split a *credential* boundary rather
than a network one. The web host cannot connect because it has no password, not
because MySQL would refuse it.

The password is in the consolidated secret (`servicedesk_db_password`, falling
back to `mysql_root_password`), and is present in
`/etc/servicedesk/servicedesk.env` on the **middleware** host only.

### Data checks

```bash
sudo mysql -e "SHOW DATABASES;"
sudo mysql -e "SHOW TABLES IN servicedesk;"
sudo mysql -e "SELECT COUNT(*) AS users FROM servicedesk.users;
               SELECT COUNT(*) AS tickets FROM servicedesk.tickets;
               SELECT COUNT(*) AS comments FROM servicedesk.comments;"
sudo mysql -e "SELECT status, COUNT(*) FROM servicedesk.tickets GROUP BY status;"
sudo mysql -e "SELECT ref, subject, status, created_at FROM servicedesk.tickets ORDER BY created_at DESC LIMIT 5;"
```

The seed is deterministic (40 users, 500 tickets, 90 days, seed `20260901`), so
counts should be stable across rebuilds. A count that drifts is itself a signal.

### Grants and accounts

```bash
sudo mysql -e "SELECT user, host, plugin FROM mysql.user;"
sudo mysql -e "SHOW GRANTS FOR 'sdapp'@'10.%';"
```

`sdapp` should use `mysql_native_password`, deliberately — MySQL 8 defaults to
`caching_sha2_password`, which PyMySQL can only complete with the `cryptography`
package installed.

### Configuration drop-in

```bash
ls -l /etc/mysql/mysql.conf.d/
grep -rn bind-address /etc/mysql/
sudo mysql -e "SELECT @@bind_address, @@skip_name_resolve, @@port;"
```

The drop-in is `/etc/mysql/mysql.conf.d/zz-servicedesk.cnf` and the `zz-` prefix
is load-bearing. `!includedir` reads `*.cnf` in ASCII order and the last
assignment wins; Ubuntu's own unnumbered `mysqld.cnf` in that same directory sets
`bind-address = 127.0.0.1`, so anything numbered (`99-`, `50-`) sorts *before* it
and gets silently overridden. If you find a `99-servicedesk.cnf` there, it is a
leftover and the role should have removed it.

### Re-deploy this tier

```bash
# on the control node
ansible-playbook playbooks/ubuntu-mysql.yml      # installs the server
ansible-playbook playbooks/servicedesk-db.yml    # database, account, drop-in
```

`servicedesk-db.yml` derives the grant from `role_middleware ∩ distro_ubuntu`.
If that group is empty it falls back to `10.0.0.0`, producing a `10.%` grant
that happens to work in this estate by accident — so a missing middleware tag
will not necessarily show up here. Check the group, not the grant.

---

## 6. Client tier

A systemd timer that fires a small burst of HTTP traffic at the web host so the
lab has something to look at. It speaks only to `WEB:8090` and knows nothing
about the middleware — deliberately, since it stands in for a user's browser.
Each burst now generates traffic on all three legs, because every call it makes
fans out through the middleware to MySQL.

```bash
systemctl list-timers sd-traffic.timer --no-pager
systemctl status sd-traffic.timer --no-pager
systemctl status sd-traffic.service --no-pager
journalctl -u sd-traffic.service -n 50 --no-pager
journalctl -t sd-traffic --since '30 min ago' --no-pager
ls -l /opt/servicedesk-traffic/sd-traffic.py
systemctl cat sd-traffic.service --no-pager | grep SD_BASE_URL
```

The timer fires 3 minutes after boot and then every 2 minutes with 45 seconds of
jitter, so `list-timers` showing a next elapse inside about 3 minutes is the
healthy state. The service is `Type=oneshot` running as `nobody:nogroup`, so a
"dead" state between firings is normal — look at the last exit code, not at
whether it is currently running.

Fire one burst by hand:

```bash
sudo systemctl start sd-traffic.service; journalctl -u sd-traffic.service -n 20 --no-pager
# or directly, bypassing systemd:
SD_BASE_URL=http://WEB:8090 /usr/bin/python3 /opt/servicedesk-traffic/sd-traffic.py --once
```

Prove the client can reach the app at all — this is the same path the verify
playbook uses, and a failure here with a healthy web host means a security group:

```bash
nc -vz WEB 8090
curl -s -o /dev/null -w '%{http_code}\n' http://WEB:8090/health
```

Also check the SMB client tooling the client playbook installs:

```bash
dpkg -l cifs-utils curl | tail -n 3
```

### Re-deploy this tier

```bash
# on the control node
ansible-playbook playbooks/servicedesk-client.yml
ansible-playbook playbooks/linux-client.yml
```

---

## 7. Symptom to cause

| Symptom | Most likely cause | Where to look |
|---|---|---|
| `ansible all -m ping` UNREACHABLE on every Linux host | `bootstrap.yml` never ran, so `/etc/ansible/keys/ansible_rsa` does not exist | §1, `journalctl -u ansible-bootstrap.service` |
| `/opt/control-repo` empty or missing | First-boot clone failed; retry timer still active | §1, `/var/log/zms-control-bootstrap.log` |
| `cloud-init status` reports `error` | Historic `packages:` module failure on a transient NAT race; harmless if the bootstrap log is clean | §1 |
| `ansible-inventory --graph` shows unexpected hosts | `ANSIBLE_ESTATE` not loaded in your shell, so the tag filter fell back to `*` | §1, load `estate.env` |
| `git status` shows modified `scripts/*.sh` | Exec bit only. Cosmetic now, but it once deadlocked `git pull` and took the estate down | §1 |
| `:8090/health` connection refused | Web tier `servicedesk` unit down or crash-looping | §3, `journalctl -u servicedesk` |
| `:8090/health` 503, `middleware.reachable` false | Middleware down, or `SD_MIDDLEWARE_URL` wrong/empty | §4, then §3 "Middleware connectivity" |
| `:8090/health` 503, `middleware.reachable` true | Both app tiers up, database leg is down | §5 — check the listener and the `10.%` grant |
| `:8090` says degraded but `:8091` returns 200 | The two tiers disagree — usually `SD_TIER` wrong in one env file | §3 and §4 identity checks |
| Web tier shows "Middleware unreachable" page | Hop two, not the database, whatever the `database` object says | §4 |
| `/health` 200 but `/stats` all zeros | Schema exists, seed never ran | §5 data checks, then reseed on the MW host |
| `role_middleware` empty in `ansible-inventory --graph` | Tag missing or miscased (`Role=Middleware` → `role_Middleware`) | Estate shape, `deployments/web-app/main.tf` |
| MySQL running but the middleware cannot connect | Bound to `127.0.0.1` — a later-sorting `.cnf` overrode the drop-in | §5, `grep -rn bind-address /etc/mysql/` |
| `ERROR 1045 ... 'ubuntu'@'localhost'` | No such MySQL account; you need `sudo mysql` | §5 authentication |
| `ERROR 1045 ... 'sdapp'@'localhost'` | The grant is `sdapp`@`10.%` — connect over TCP to the host's own IP, not the socket | §5 authentication |
| No `SD_DB_PASSWORD` in the web host's env file | Correct and deliberate — the web tier holds no credentials | §3 |
| The service desk deploys twice per converge | `servicedesk-app.yml` listed alongside the two real plays; it is an alias that imports both | `scripts/converge.sh` |
| Ansible warns the jsonfile cache is not writable | `/var/tmp/ansible_facts` owned by root after a `sudo` run; units run as `ubuntu` | `sudo chown -R ubuntu:ubuntu /var/tmp/ansible_facts` |
| `converge-status.log` does not exist | `/var/log/ansible` missing; `notify-result.sh` runs as `ubuntu` and cannot create it | `sudo install -d -o ubuntu -g ubuntu -m 0755 /var/log/ansible` |
| Timer fires but nothing changes on the estate | You are looking at `ansible-bootstrap` (self-converge only), not `ansible-estate` | §1 |
| A playbook never runs on schedule | It is in `orchestrate.yml` but not in the `LINUX_PLAYS` array in `converge.sh` — the two lists are maintained by hand | `scripts/converge.sh` |

---

## 8. Reseeding and repair

Both of these run **on the middleware host**. The web host has no credentials,
so the same commands there fail with an authentication error that looks like a
database fault and is not one.

```bash
# Force a reseed (the seeder no-ops once rows exist)
sudo -u sdapp bash -c 'set -a; . /etc/servicedesk/servicedesk.env; set +a;
  cd /opt/servicedesk/src && /opt/servicedesk/venv/bin/python -m sdapp.seed --force'

# Recreate the schema
sudo -u sdapp bash -c 'set -a; . /etc/servicedesk/servicedesk.env; set +a;
  cd /opt/servicedesk/src && /opt/servicedesk/venv/bin/python -m sdapp.bootstrap'
```

Full estate reconverge, in dependency order, from the control node:

```bash
cd /opt/control-repo
ansible-playbook playbooks/ubuntu-mysql.yml
ansible-playbook playbooks/servicedesk-db.yml
ansible-playbook playbooks/servicedesk-middleware.yml
ansible-playbook playbooks/servicedesk-web.yml
ansible-playbook playbooks/servicedesk-client.yml
ansible-playbook playbooks/servicedesk-verify.yml
```

The order is not optional: the db play creates the database and the grant, the
middleware play creates the tables inside it and seeds them, the web play points
the frontend at the middleware, and the client play points traffic at the
frontend. Running the web play early is harmless — it will deploy and report an
unreachable middleware — but you will have to run it again.

`playbooks/servicedesk-app.yml` still works and does the middleware and web
plays in order, if that is the name in your muscle memory.

If the schema or seed task fails and Ansible reports `the output has been hidden
due to the fact that no_log was specified`, re-run with the debug flag. It
unmasks stdout and stderr for that run only, and the database password is
exposed in it — so do not use it casually and do not paste the output anywhere:

```bash
ansible-playbook playbooks/servicedesk-middleware.yml -e sd_debug_schema=true
```

---

## 9. The deliberate failure demos

The lab is built so that an outage degrades visibly rather than disappearing.
With three tiers there are now two demos, and the point of running both is that
the app distinguishes them.

### Database down

```bash
# on the db host
sudo systemctl stop mysql

# on the middleware host — up, and honest about why it cannot serve
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/health   # 503
curl -s http://localhost:8091/health | python3 -m json.tool             # database.reachable false

# on the web host — also up, and it names the right leg
curl -s http://localhost:8090/health | python3 -m json.tool
#   middleware.reachable true, database.reachable false, failed_tier "database"
systemctl is-active servicedesk                                          # still active

# restore
sudo systemctl start mysql
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8090/health   # 200
```

### Middleware down

```bash
# on the MIDDLEWARE host
sudo systemctl stop servicedesk

# on the web host
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8090/health   # 503
curl -s http://localhost:8090/health | python3 -m json.tool
#   middleware.reachable FALSE, failed_tier "middleware"
curl -s http://localhost:8090/ | grep -i 'middleware unreachable'
systemctl is-active servicedesk                                          # web tier still active

# restore
sudo systemctl start servicedesk
```

Note the asymmetry worth pointing out when demonstrating this: the middleware
outage also reports `database.reachable: false`, because from the web tier's
vantage point the database genuinely is unreachable. `failed_tier` and
`middleware.reachable` are what separate the two cases. A monitor that only
watches `database.reachable` will page the DBA for a middleware crash — which is
exactly the failure mode the extra field exists to prevent.

`Restart=always` means stopping a unit this way only holds while you hold it; a
`systemctl stop` stays stopped, but a `kill` heals in five seconds. If you want
the outage to survive an hourly converge, mask the unit rather than stopping it.

This is why `servicedesk-verify.yml` is excluded from `converge.sh`: during
either demo its asserts would fail and mark the `ansible-estate` unit failed,
which is noise rather than signal.

---

## Appendix — paths, units and ports

**Control node.** Repo `/opt/control-repo`; collections
`/opt/control-repo/collections`; environment `/etc/ansible/estate.env`
(`0640 root:root`); SSH key `/etc/ansible/keys/ansible_rsa`; logs
`/var/log/ansible/{ansible.log,converge-status.log,converge-failures.log}`,
`/var/log/zms-control-bootstrap.log`; fact cache `/var/tmp/ansible_facts`; units
`ansible-bootstrap.timer` (2 min / 30 min), `ansible-estate.timer` (10 min / 60
min), `zms-control-bootstrap.timer` (2 min / 5 min, self-disabling).

**Web.** Units `servicedesk`, `apache2`; ports **8090**, 80; app root
`/opt/servicedesk` with `src/`, `venv/`; config `/etc/servicedesk/servicedesk.env`
(`0640 root:sdapp`, `SD_TIER=web`, `SD_MIDDLEWARE_URL=http://MW:8091`, **no**
`SD_DB_PASSWORD`); log dir `/var/log/servicedesk` (gunicorn actually logs to the
journal as `servicedesk`); runs as `sdapp:sdapp`; serves `/`, `/ticket/<ref>`,
`/health`, and forwards `/api/*` and `/stats` verbatim.

**Middleware.** Unit `servicedesk`; port **8091**; identical paths, user and
payload to the web host; config `/etc/servicedesk/servicedesk.env`
(`SD_TIER=middleware`, **with** `SD_DB_PASSWORD`); serves JSON only — `/api/*`,
`/stats`, `/health`; the only host with a MySQL credential.

**DB.** Unit `mysql`; port 3306; schema `servicedesk` with tables `users`,
`tickets`, `comments`; account `sdapp`@`<middleware /24>.%` — the first three
octets of the **middleware** host's address, and in a ring-fenced estate the
middleware host in the *same ring*. Run
`SELECT user, host FROM mysql.user WHERE user='sdapp';` to see the live value;
a bare `10.%` means the derivation fell back and the middleware was not in the
inventory when `servicedesk-db.yml` ran. Privileges `servicedesk.*:ALL`,
plugin `mysql_native_password`; drop-in
`/etc/mysql/mysql.conf.d/zz-servicedesk.cnf`; socket
`/var/run/mysqld/mysqld.sock`.

**Client.** Units `sd-traffic.timer`, `sd-traffic.service` (`Type=oneshot`, runs
as `nobody:nogroup`); script `/opt/servicedesk-traffic/sd-traffic.py`; target from
`SD_BASE_URL` in the unit.
