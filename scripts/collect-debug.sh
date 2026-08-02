#!/usr/bin/env bash
#
# collect-debug.sh - Gather Ansible failure diagnostics from the ZMS AWS control node.
#
# Produces a timestamped tarball under /tmp containing cloud-init logs, the
# Ansible/collection state, config, dynamic-inventory + connectivity checks,
# IAM-role (IMDSv2)/DNS/egress probes, SSH-key metadata, the estate logs, and the
# systemd unit status/journals.
#
# Usage:
#   ./collect-debug.sh              # collect what the current user can read
#   sudo ./collect-debug.sh         # also capture root-owned logs/keys/journals
#
# SECURITY: the bundle may contain identifiers (account id, region, secret name,
# host names, IPs) but deliberately avoids secrets - it never prints the SSH
# private key or the consolidated Secrets Manager secret value, only captures the
# IMDSv2 IAM role name + creds-endpoint HTTP status (not the credentials), never
# runs a playbook or `ansible-inventory --list` (which would resolve aws_secret
# lookups), and runs a final redaction pass. Still, review the tarball before
# sharing it externally.

set -o pipefail

# ---------------------------------------------------------------- config -----
REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
ENV_FILE="/etc/ansible/estate.env"
LOG_DIR="/var/log/ansible"
KEY_FILE="/etc/ansible/keys/ansible_rsa"
IMDS="http://169.254.169.254"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUT_DIR="/tmp/ansible-debug-${HOST}-${TS}"
REPORT="${OUT_DIR}/report.txt"
mkdir -p "$OUT_DIR"

# System Ansible (installed via apt); include /usr/local/bin just in case.
# Disable the shared log so collection stays read-only and avoids the
# not-writeable warning.
export PATH="/usr/local/bin:/usr/bin:${PATH}"
export ANSIBLE_LOG_PATH="${OUT_DIR}/ansible-collect.log"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE" 2>/dev/null || true; set +a; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# --------------------------------------------------------------- helpers -----
section() { printf '\n\n========== %s ==========\n' "$*" >>"$REPORT"; }
run() {   # run <label> <cmd...>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 60 "$@" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
runsh() { # runsh <label> <shell string>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 120 bash -lc "$*" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
copy() {  # copy <src> [destname]
  local src="$1"; local dst="${2:-$(basename "$1")}"
  if [ -r "$src" ]; then
    cp -a "$src" "${OUT_DIR}/${dst}" 2>/dev/null \
      && printf '  collected: %s\n' "$src" >>"$REPORT" \
      || printf '  could not copy: %s\n' "$src" >>"$REPORT"
  else
    printf '  not readable (try sudo): %s\n' "$src" >>"$REPORT"
  fi
}

{
  echo "ZMS AWS control-node Ansible debug bundle"
  echo "generated : $(date -u) (UTC)"
  echo "user      : $(id -un) (uid $(id -u))"
  echo "host      : $(hostname -f 2>/dev/null || hostname)"
  echo "repo_dir  : ${REPO_DIR}"
  echo "region    : ${REGION:-<unset>}"
} >"$REPORT"

# 1) host / OS
section "HOST / OS"
run "uname -a" uname -a
copy /etc/os-release os-release
run "uptime" uptime
runsh "disk usage" "df -h / /var /opt 2>/dev/null"
runsh "memory" "free -h 2>/dev/null"

# 2) cloud-init (first-boot control-node bootstrap)
section "CLOUD-INIT"
run "cloud-init status --long" cloud-init status --long
copy /var/log/cloud-init-output.log cloud-init-output.log
copy /var/log/cloud-init.log cloud-init.log

# 3) Ansible + Python environment
section "ANSIBLE / PYTHON ENVIRONMENT"
runsh "which ansible*" "command -v ansible ansible-playbook ansible-galaxy ansible-inventory 2>&1"
run "ansible --version" ansible --version
runsh "pip (ansible/boto/winrm pkgs)" "python3 -m pip list 2>/dev/null | grep -Ei 'ansible|boto3|botocore|pywinrm|requests|resolvelib|cryptography' || echo 'pip list not available'"
runsh "installed collections" "ansible-galaxy collection list 2>&1"
# Directly diagnose the two common import root causes: amazon.aws needs boto3/
# botocore; the Windows (WinRM) path needs pywinrm.
printf '\n$ python import check (boto3 / winrm)\n' >>"$REPORT"
timeout 30 python3 - >>"$REPORT" 2>&1 <<'PY' || printf '[python not available]\n' >>"$REPORT"
mods = ['boto3', 'botocore', 'winrm']
for m in mods:
    try:
        __import__(m)
        print('ok  ', m)
    except Exception as e:
        print('FAIL', m, '->', repr(e))
PY

# 4) configuration
section "CONFIGURATION"
copy "${REPO_DIR}/ansible.cfg" ansible.cfg
copy "${REPO_DIR}/inventory/aws_ec2.yml" aws_ec2.yml
runsh "effective config (changed only)" "cd '${REPO_DIR}' && ansible-config dump --only-changed 2>&1 | head -n 80"
if [ -r "$ENV_FILE" ]; then
  printf '\n--- %s (names only; no secrets by design) ---\n' "$ENV_FILE" >>"$REPORT"
  cat "$ENV_FILE" >>"$REPORT" 2>/dev/null
  cp -a "$ENV_FILE" "${OUT_DIR}/estate.env" 2>/dev/null
else
  printf '\n%s not readable (try sudo)\n' "$ENV_FILE" >>"$REPORT"
fi

# 5) dynamic inventory (structure only - never --list/--vars, they resolve creds)
section "INVENTORY (structure only)"
runsh "ansible-inventory --graph" "cd '${REPO_DIR}' && ansible-inventory --graph 2>&1"

# 6) AWS IAM role via IMDSv2 (role name + HTTP status only, never the credentials)
section "AWS IAM ROLE (IMDSv2)"
runsh "IMDSv2 token (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X PUT '${IMDS}/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 10 || echo 'IMDS unreachable'"
runsh "attached IAM role name" "T=\$(curl -s -X PUT '${IMDS}/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 10); curl -s -H \"X-aws-ec2-metadata-token: \$T\" --max-time 10 '${IMDS}/latest/meta-data/iam/security-credentials/' 2>&1 || echo 'no instance role / IMDS unreachable'"
runsh "role creds endpoint (status only, NOT the creds)" "T=\$(curl -s -X PUT '${IMDS}/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 10); R=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" --max-time 10 '${IMDS}/latest/meta-data/iam/security-credentials/'); [ -n \"\$R\" ] && curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H \"X-aws-ec2-metadata-token: \$T\" --max-time 10 \"${IMDS}/latest/meta-data/iam/security-credentials/\$R\" || echo 'no role'"
runsh "sts get-caller-identity (identifiers only)" "command -v aws >/dev/null 2>&1 && aws sts get-caller-identity ${REGION:+--region $REGION} 2>&1 || echo 'aws CLI not installed'"

# 7) Secrets Manager reachability (describe metadata only - never the value)
section "SECRETS MANAGER (metadata only)"
runsh "ANSIBLE_SECRET_NAME set?" "[ -n \"\${ANSIBLE_SECRET_NAME:-}\" ] && echo \"ANSIBLE_SECRET_NAME=\${ANSIBLE_SECRET_NAME}\" || echo 'ANSIBLE_SECRET_NAME NOT set'"
runsh "describe-secret (no value)" "command -v aws >/dev/null 2>&1 && [ -n \"\${ANSIBLE_SECRET_NAME:-}\" ] && aws secretsmanager describe-secret --secret-id \"\$ANSIBLE_SECRET_NAME\" ${REGION:+--region $REGION} 2>&1 | head -n 40 || echo 'aws CLI missing or ANSIBLE_SECRET_NAME unset'"

# 8) DNS + egress
section "DNS / NETWORK EGRESS"
copy /etc/resolv.conf resolv.conf
runsh "resolve pypi + secretsmanager endpoint" "getent hosts pypi.org; [ -n \"\${REGION:-}\" ] && getent hosts \"secretsmanager.\${REGION}.amazonaws.com\""
runsh "egress -> pypi (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 12 https://pypi.org/simple/ || echo 'no egress'"
runsh "egress -> secretsmanager (status)" "[ -n \"\${REGION:-}\" ] && curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 12 \"https://secretsmanager.\${REGION}.amazonaws.com\" || echo 'REGION unset'"

# 9) SSH key (metadata only, never the contents)
section "SSH KEY (metadata only)"
runsh "key file perms/owner" "ls -l '${KEY_FILE}' 2>&1 || echo 'key file missing (bootstrap.yml not run?)'"
runsh "key fingerprint" "ssh-keygen -lf '${KEY_FILE}' 2>&1 || echo 'cannot read fingerprint'"

# 10) estate logs
section "ANSIBLE LOGS"
copy "${LOG_DIR}/ansible.log" ansible.log
copy "${LOG_DIR}/converge-status.log" converge-status.log
copy "${LOG_DIR}/converge-failures.log" converge-failures.log
runsh "recent failures in ansible.log" "tail -n 600 '${LOG_DIR}/ansible.log' 2>/dev/null | grep -iE 'fatal|failed=|unreachable|error|traceback' | tail -n 120 || echo 'no ansible.log (try sudo)'"

# 11) systemd units + journals
section "SYSTEMD (timers + services)"
run "list-timers" systemctl list-timers "ansible-*" --all --no-pager
for u in ansible-bootstrap ansible-estate; do
  run "status ${u}.service" systemctl status "${u}.service" --no-pager -l
  runsh "journal ${u} (last 200)" "journalctl -u ${u}.service -n 200 --no-pager 2>&1 || echo 'no journal access (try sudo)'"
done

# 12) control repo state + syntax check
section "CONTROL REPO"
runsh "git log/status" "cd '${REPO_DIR}' && git -c safe.directory='${REPO_DIR}' log --oneline -n 5 2>&1; echo '---'; git -c safe.directory='${REPO_DIR}' status -s 2>&1"
runsh "site.yml --syntax-check" "cd '${REPO_DIR}' && ansible-playbook site.yml --syntax-check 2>&1 | tail -n 40"
runsh "orchestrate.yml --syntax-check" "cd '${REPO_DIR}' && ansible-playbook orchestrate.yml --syntax-check 2>&1 | tail -n 40"

# 13) live reachability (default verbosity; credentials are NOT printed)
section "CONNECTIVITY PROBE (best-effort)"
runsh "ping Linux (SSH)" "cd '${REPO_DIR}' && timeout 90 ansible os_linux -m ansible.builtin.ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"
runsh "ping Windows (WinRM)" "cd '${REPO_DIR}' && timeout 120 ansible os_windows -m ansible.windows.win_ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"

# ----------------------------------------------- redact + package (safety) ---
# Defense in depth: scrub anything that looks like a token/secret value.
find "$OUT_DIR" -type f -print0 2>/dev/null | xargs -0 -r sed -i -E \
  -e 's/(access_token"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
  -e 's/(Bearer )[A-Za-z0-9._+/=-]+/\1<REDACTED>/g' \
  -e 's/([Pp]assword"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1<REDACTED>/g' \
  -e 's/("?SecretAccessKey"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9/+=]+/\1<REDACTED>/g' \
  -e 's/("?SessionToken"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9/+=._-]+/\1<REDACTED>/g' \
  -e 's/(aws_secret_access_key[[:space:]]*=[[:space:]]*)[A-Za-z0-9/+=]+/\1<REDACTED>/g' \
  2>/dev/null || true

TARBALL="/tmp/ansible-debug-${HOST}-${TS}.tar.gz"
tar -czf "$TARBALL" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" 2>/dev/null

echo
echo "Ansible debug bundle written:"
echo "  folder : $OUT_DIR"
echo "  tarball: $TARBALL"
echo
echo "Copy it off the node, e.g. from your workstation:"
echo "  scp -i <key>.pem -o ProxyJump=ubuntu@<bastion-ip> ubuntu@$(hostname -s):$TARBALL ."
echo "  # or via SSM:  aws ssm start-session --target <control-instance-id>"
echo
echo "Review before sharing (contains account id / region / secret-name identifiers)."
echo "Re-run with sudo to include root-owned logs, keys, and journals."
