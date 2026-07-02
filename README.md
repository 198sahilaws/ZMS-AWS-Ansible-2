# Ansible Control Repo — Push Configuration (AWS)

Single source of truth for pushing configuration to AWS instances discovered
dynamically. The control node (inside the VPC) pulls this repo, refreshes
collections, fetches credentials from Secrets Manager, and runs the playbooks.
Assumes the AWS infrastructure from Document 1 is in place: EC2-describe IAM,
the `managed` SG path, consistent `Role` / `OS` / `Environment` tags, and
populated secrets.

## Layout

```
.
├── ansible.cfg
├── requirements.yml          # collections
├── inventory/
│   └── aws_ec2.yml           # dynamic inventory plugin config
├── group_vars/
│   ├── all.yml
│   ├── os_linux.yml          # SSH connection settings
│   └── os_windows.yml        # WinRM connection settings
├── host_vars/                # rare; per-host overrides
├── roles/
│   └── baseline/             # example cross-platform role
├── scripts/
│   └── reconverge.sh         # cloud-init / timer hook
├── bootstrap.yml             # the node configuring itself (localhost)
└── site.yml                  # the push playbook(s) for the estate
```

> Inventory groups are keyed off tags: the `OS` tag produces `os_linux` /
> `os_windows`, which `group_vars` of the same name target for connection
> settings. `Role` → `role_*`, `Environment` → `env_*`.

## Setup

```bash
# Install collections on the control node
ansible-galaxy collection install -r requirements.yml

# (Optional) set the region — defaults to eu-west-3 if unset
export AWS_REGION=eu-west-3

# Confirm discovery — you should see os_linux / os_windows populated
ansible-inventory -i inventory/aws_ec2.yml --graph
```

### AWS region

The region is configured in one place: the `AWS_REGION` environment variable
(default `eu-west-3`). It is read by the dynamic inventory (`regions`), the
`aws_region` var in `group_vars/all.yml` used by `aws_secret` lookups, and
`scripts/reconverge.sh`. To target a different region, just `export AWS_REGION=...`
before running — no file edits needed. Per-environment overrides can also be set
in an `env_*.yml` group_vars file.

## Credentials

No static secrets in Git.

- **SSH key** is fetched from Secrets Manager at converge time and written to
  `/etc/ansible/keys/ansible_ed25519` (see `scripts/reconverge.sh` and
  `bootstrap.yml`).
- **WinRM credential** is resolved in-play via the `amazon.aws.aws_secret`
  lookup (see `group_vars/os_windows.yml`).
- For any remaining static secrets, use `ansible-vault` with
  `--vault-password-file` sourced from the secret store.

## Running pushes

```bash
# Dry run (report drift, change nothing)
ansible-playbook site.yml --check --diff

# Full converge
ansible-playbook site.yml

# Scope by tag-derived group or environment
ansible-playbook site.yml --limit 'os_linux:&env_prod'

# Run only tagged tasks, in rolling batches to limit blast radius
ansible-playbook site.yml --tags packages --forks 20 --limit os_windows
```

**Drift cadence:** the control node's systemd timer re-applies `bootstrap.yml`
to itself. To converge the estate on a schedule, add a second timer running
`ansible-playbook site.yml` (optionally `--check` first with alerting on
changes, then enforce). At a few dozen hosts a 30–60 min cadence is comfortable.

## Windows / hardened-host notes

- Have plays call signed installers (`win_package` / signed `win_chocolatey`)
  rather than large custom PowerShell on hardened hosts.
- Under WDAC/AppLocker enforce — especially Constrained Language Mode — staged
  PowerShell can fail. Test against a representative hardened host early; route
  CLM-locked hosts to the golden-image path instead of runtime push.
- Keep `ansible_winrm_server_cert_validation: validate` in production; only use
  `ignore` against self-signed listeners in a lab.

## Pre-flight checklist

- [ ] `ansible-galaxy collection install -r requirements.yml` succeeds.
- [ ] `ansible-inventory --graph` shows `os_linux` / `os_windows` populated.
- [ ] `ansible os_linux -m ping` returns `pong`.
- [ ] `ansible os_windows -m ansible.windows.win_ping` returns `pong`.
- [ ] Secrets resolve (no plaintext credentials in Git).
- [ ] `site.yml --check` is clean before the first enforce run.

## Tunables

| Variable | Where | Default | Purpose |
|---|---|---|---|
| `AWS_REGION` (env) | inventory, `all.yml`, reconverge | `eu-west-3` | Target region (single knob) |
| `linux_login_user` | `group_vars/os_linux.yml` | `ubuntu` | SSH user; override per group/host for `ec2-user`/`rocky` AMIs |
| `rolling_batch` | `-e` at run time | `100%` | `serial:` batch size for blast-radius control |
| `max_fail_pct` | `-e` at run time | `0` | `max_fail_percentage:` per play |
| `linux_baseline_package` / `windows_baseline_package` | `-e` / group_vars | `htop` / `7zip` | Example package installed by `site.yml` |

Rolling, fail-fast converge:

```bash
ansible-playbook site.yml -e rolling_batch=25% -e max_fail_pct=10
```

> The internal apt/yum repos are GPG-verified: place the signing keys at
> `{{ repo_base_url }}/keys/internal-archive-keyring.gpg` (Debian) and
> `{{ repo_base_url }}/keys/RPM-GPG-KEY-internal` (RHEL). Avoid `[trusted=yes]`.

## Development / linting

```bash
pip install ansible-lint yamllint pre-commit
pre-commit install        # run hooks on every commit
ansible-lint              # lint the whole repo (profile: production)
yamllint .
```

CI runs the same checks on push / PR via `.github/workflows/lint.yml`.

## Windows task playbooks

Standalone playbooks under `playbooks/`. They default to tag-derived role groups
(`role_dc`, `role_web`, `role_fileserver`) and can be scoped with `--limit` or
`-e target=...`. Run from the repo root so `ansible.cfg` and the dynamic
inventory are picked up.

| Playbook | Default target | What it does |
|---|---|---|
| `playbooks/windows-adds.yml` | `role_dc` | Installs AD DS and builds a **new forest** `alcor.co.in` (NetBIOS `ALCOR`). DSRM password from Secrets Manager (`ansible-control/adds-dsrm-password`). |
| `playbooks/windows-iis.yml` | `role_web` | Enables IIS (`Web-Server` + mgmt console) and starts `W3SVC`. Override `iis_features` for extras. |
| `playbooks/windows-share.yml` | `role_fileserver` | Creates an SMB share, **Everyone read-only** (share + NTFS). Override `share_name` / `share_path`. |
| `playbooks/windows-python.yml` | `os_windows` | Installs `python3` from the internal Chocolatey source. Pin with `-e python_version=3.12.4`. |
| `playbooks/windows-domain-join.yml` | `os_windows` | Joins hosts to **alcor.co.in** via `microsoft.ad.membership` (skips `role_dc`). Join creds from Secrets Manager (`ansible-control/domain-join-credential`, JSON username/password). Set `domain_dns_server` if VPC DNS isn't the DC. |
| `playbooks/windows-zms-enforcer.yml` | `os_windows` | Installs the **Zscaler Microsegmentation Enforcer** (conversion of `windows/install.ps1`). Nonce from Secrets Manager (`ansible-control/zms-provision-nonce`); prod→beta endpoint fallback, retried download, `PROVISIONKEY_FILE` install. |

```bash
# Examples
ansible-playbook playbooks/windows-adds.yml --limit win-dc01
ansible-playbook playbooks/windows-iis.yml -e target=role_web --check
ansible-playbook playbooks/windows-share.yml -e share_name=software -e 'share_path=D:\Shares\software'
ansible-playbook playbooks/windows-python.yml --limit win-app01
ansible-playbook playbooks/windows-domain-join.yml --limit win-app01 -e domain_dns_server=10.0.0.10
ansible-playbook playbooks/windows-zms-enforcer.yml --limit win-app01 -e zms_auto_reboot=true
```

> The forest build requires `ansible-control/adds-dsrm-password` to exist in
> Secrets Manager (a strong DSRM password as a plain string) before running.

## Ubuntu task playbooks

Linux playbooks under `playbooks/`. They default to `os_linux` and safely skip
non-Debian hosts. Scope "selected" runs with `--limit` or `-e target=...`.

| Playbook | Default target | What it does |
|---|---|---|
| `playbooks/ubuntu-setup.yml` | `os_linux` | Full `apt` upgrade (reboot if required) **and** installs common packages (`netcat-openbsd`, `curl`, `wget`). Tags: `update`, `packages`. Override `ubuntu_packages`. |
| `playbooks/ubuntu-apache2.yml` | `os_linux` (use `--limit`) | Installs Apache2 and enables/starts the `apache2` service. |
| `playbooks/ubuntu-mysql.yml` | `os_linux` (use `--limit`) | Installs MySQL server, enables/starts the `mysql` service; optional root password via `mysql_root_password` (Secrets Manager). |

```bash
# Examples
ansible-playbook playbooks/ubuntu-setup.yml -e rolling_batch=25% --check
ansible-playbook playbooks/ubuntu-setup.yml --tags update
ansible-playbook playbooks/ubuntu-setup.yml --tags packages
ansible-playbook playbooks/ubuntu-apache2.yml --limit web01,web02
ansible-playbook playbooks/ubuntu-mysql.yml -e target=role_db
```

## Amazon Linux task playbooks

Linux playbooks under `playbooks/`, equivalent to the Ubuntu set but for the
RedHat family (Amazon Linux). They default to `os_linux` and safely skip
non-RedHat hosts. Scope "selected" runs with `--limit` or `-e target=...`.

| Playbook | Default target | What it does |
|---|---|---|
| `playbooks/amazonlinux-setup.yml` | `os_linux` | Full `dnf` upgrade (reboot if `needs-restarting -r` says so) **and** installs common packages (`nmap-ncat`, `curl`, `wget`). Tags: `update`, `packages`. Override `amazonlinux_packages`. |
| `playbooks/amazonlinux-httpd.yml` | `os_linux` (use `--limit`) | Installs Apache **httpd** (the Amazon Linux name for apache2) and enables/starts the service. |
| `playbooks/amazonlinux-mysql.yml` | `os_linux` (use `--limit`) | Adds the MySQL Community repo and installs `mysql-community-server` (service `mysqld`). MariaDB alternative noted in-file. |

```bash
# Examples
ansible-playbook playbooks/amazonlinux-setup.yml -e rolling_batch=25% --check
ansible-playbook playbooks/amazonlinux-setup.yml --tags update
ansible-playbook playbooks/amazonlinux-setup.yml --tags packages
ansible-playbook playbooks/amazonlinux-httpd.yml --limit web01,web02
ansible-playbook playbooks/amazonlinux-mysql.yml -e target=role_db
```

> Both the Ubuntu and Amazon Linux sets default to `os_linux` and self-select by
> OS family, so they are safe to run estate-wide; the non-matching distro is
> skipped per host.


## Automated execution (systemd timers)

The control node runs the playbooks on a schedule via systemd. Unit files are in
`systemd/`. Because systemd (and `sudo`) do not inherit your shell environment,
`AWS_REGION` / `ANSIBLE_SECRET_NAME` are supplied through an `EnvironmentFile`.

```bash
# 1. Environment file (names the secret; holds no secret material)
sudo install -m 600 systemd/estate.env.example /etc/ansible/estate.env
sudo vi /etc/ansible/estate.env          # set AWS_REGION + ANSIBLE_SECRET_NAME

# 2. Install units
sudo cp systemd/ansible-*.service systemd/ansible-*.timer /etc/systemd/system/
sudo systemctl daemon-reload

# 3. Enable the timers
sudo systemctl enable --now ansible-bootstrap.timer   # control-node self-converge (30 min)
sudo systemctl enable --now ansible-estate.timer      # estate converge via site.yml (60 min)

# Run once now / inspect
sudo systemctl start ansible-estate.service
systemctl list-timers 'ansible-*'
journalctl -u ansible-estate.service -n 50 --no-pager
```

Requirements: `ansible-core` (and `git`, AWS CLI/`boto3`) installed **system-wide**
so the unit's `PATH` finds them (or set `PATH=` in `estate.env`); the `ubuntu`
user has passwordless `sudo` (default on Ubuntu AMIs, needed for `become`); and
`/opt/control-repo` is owned by `ubuntu`.

- `ansible-bootstrap.*` runs `scripts/reconverge.sh` — git pull, refresh
  collections, re-apply `bootstrap.yml` (self-heals the control node).
- `ansible-estate.*` runs `site.yml` in rolling batches. To alert-only on drift,
  change its `ExecStart` to `... site.yml --check --diff` first, then a second
  enforce timer.

### Alternatives

- **cron** — simplest, but no logging/dependency ordering; systemd is preferred.
- **EventBridge Scheduler + SSM Run Command** — trigger the converge from AWS on
  a schedule without a persistent timer; good if the control node is ephemeral.
- **AWX / Ansible Automation Platform** — web UI, RBAC, scheduling, surveys, and
  run history if you outgrow a single control node.
- **CI/CD (GitHub Actions, GitLab CI, Jenkins)** — run `ansible-playbook` from a
  pipeline on merge to `main`; pairs well with the linting workflow already here.

## Run logs & failure alerting

Every `ansible-playbook` run appends to **`/var/log/ansible/ansible.log`**
(`log_path` in `ansible.cfg`) in addition to journald. The systemd units also run
`scripts/notify-result.sh` as an `ExecStopPost` hook, which records each converge:

- `/var/log/ansible/converge-status.log` — one line per run (`result=success/…`).
- `/var/log/ansible/converge-failures.log` — failures only; point a CloudWatch
  Logs agent or a cron alarm at this single file.

For push alerts, set `ANSIBLE_ALERT_SNS_TOPIC_ARN` in `/etc/ansible/estate.env`
(the node's IAM role needs `sns:Publish` on that topic); the hook then publishes
a message on any failed converge.

```bash
# quick health check on the control node
tail -n 5 /var/log/ansible/converge-status.log
tail -n 20 /var/log/ansible/converge-failures.log   # empty = no failures
grep -c 'failed=[1-9]' /var/log/ansible/ansible.log  # any run with a failed host
```

The cloud-init in `deploy/` creates `/var/log/ansible` (ubuntu-owned) at build time.
