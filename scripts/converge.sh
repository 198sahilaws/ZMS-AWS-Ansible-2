#!/usr/bin/env bash
# converge.sh — the estate convergence runner (what ansible-estate.service runs).
#
# WHY THIS EXISTS (instead of pointing systemd straight at orchestrate.yml):
# orchestrate.yml chains playbooks with import_playbook, so they share ONE
# ansible-playbook process. If any play ends with all its hosts failed, Ansible
# prints "NO MORE HOSTS LEFT" and aborts the whole run — every later playbook is
# skipped. In practice one broken role (or unreachable Windows) stopped the
# entire estate from converging.
#
# This runner executes each playbook as its OWN ansible-playbook invocation, so a
# failure is contained: it is recorded, and the remaining playbooks still run.
# The script exits non-zero at the end if anything failed, so systemd still
# reports the unit as failed and notify-result.sh logs/alerts — but only AFTER
# giving every role a chance to converge.
#
# Usage:
#   ./converge.sh                 # full estate
#   ./converge.sh --linux         # Linux chain only
#   ./converge.sh --windows       # Windows chain only
set -o pipefail

# Load the Terraform-injected env for manual runs. Under systemd the unit already
# provides these via EnvironmentFile, and estate.env is root-owned 0640 (the
# service user cannot read it) — so test readability, never abort on it.
ENV_FILE="${ANSIBLE_ESTATE_ENV:-/etc/ansible/estate.env}"
if [ -r "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
cd "$REPO_DIR" || { echo "FATAL: cannot cd to $REPO_DIR"; exit 1; }

# Blast-radius controls, overridable from the unit or the environment.
ROLLING_BATCH="${ROLLING_BATCH:-25%}"
MAX_FAIL_PCT="${MAX_FAIL_PCT:-20}"

# Baseline first, then the Linux role services (independent of AD), then the
# Windows AD chain. Same order and intent as orchestrate.yml — see the design
# rules documented there. Full OS upgrades (ubuntu-setup / amazonlinux-setup) are
# deliberately NOT here: they reboot hosts and belong in a maintenance window.
LINUX_PLAYS=(
  # MUST be first: RHEL 8 ships Python 3.6, which ansible-core cannot use on a
  # managed node. This raw-based playbook installs python3.11 before any
  # Python-dependent task (including fact gathering) is attempted.
  playbooks/rhel8-python-bootstrap.yml
  site.yml
  playbooks/ubuntu-apache2.yml
  playbooks/amazonlinux-httpd.yml
  playbooks/sles-apache2.yml
  playbooks/rhel-httpd.yml
  playbooks/ubuntu-mysql.yml
  playbooks/amazonlinux-mysql.yml
  playbooks/sles-mariadb.yml
  playbooks/rhel-mariadb.yml
  playbooks/linux-fileshare.yml
  playbooks/linux-client.yml
  # --- ZMS microservices demo application ----------------------------------
  # Must follow the *-mariadb plays above: zms-app-db.yml expects
  # mariadb.service to already exist on the hosts it prepares.
  #
  # These three are the reason the app self-heals unattended. THIS array -- not
  # orchestrate.yml -- is what the hourly ansible-estate timer actually runs, so
  # a playbook missing here never runs on a schedule no matter what
  # orchestrate.yml imports. Keep the two lists in step when adding a playbook.
  #
  # All three are idempotent and fast on a converged estate: the seeder no-ops
  # once rows exist and pip no-ops once the venv is built. To stop deploying the
  # demo app on a schedule, delete these three lines; nothing else depends on
  # them.
  playbooks/zms-app-db.yml
  playbooks/zms-app-services.yml
  playbooks/zms-app-frontend.yml
  # NOT playbooks/zms-app-verify.yml -- it ends in an assert, so it would mark
  # the unit failed during a deliberate failure demo. Run it by hand.
)
WINDOWS_PLAYS=(
  playbooks/windows-adds.yml
  playbooks/windows-domain-join.yml
  playbooks/windows-rodc.yml
  playbooks/windows-iis.yml
  playbooks/windows-share.yml
  playbooks/windows-python.yml
  playbooks/windows-zms-enforcer.yml
  playbooks/windows-client.yml
)

case "${1:-}" in
  --linux)   PLAYS=("${LINUX_PLAYS[@]}") ;;
  --windows) PLAYS=("${WINDOWS_PLAYS[@]}") ;;
  *)         PLAYS=("${LINUX_PLAYS[@]}" "${WINDOWS_PLAYS[@]}") ;;
esac

FAILED=()
PASSED=()

for play in "${PLAYS[@]}"; do
  [ -f "$play" ] || { echo "SKIP (missing): $play"; continue; }
  echo "=============================================================="
  echo ">>> $play"
  echo "=============================================================="
  if ansible-playbook "$play" \
        -e "rolling_batch=${ROLLING_BATCH}" \
        -e "max_fail_pct=${MAX_FAIL_PCT}"; then
    PASSED+=("$play")
  else
    rc=$?
    echo "!!! FAILED (exit ${rc}): $play — continuing with the remaining playbooks"
    FAILED+=("$play")
  fi
done

echo
echo "================= CONVERGE SUMMARY ================="
printf 'passed : %s\n' "${#PASSED[@]}"
for p in "${PASSED[@]}"; do printf '   ok   %s\n' "$p"; done
printf 'failed : %s\n' "${#FAILED[@]}"
for p in "${FAILED[@]}"; do printf '   FAIL %s\n' "$p"; done
echo "==================================================="

# Non-zero if anything failed, so systemd + notify-result.sh still flag it.
[ "${#FAILED[@]}" -eq 0 ] || exit 1
exit 0
