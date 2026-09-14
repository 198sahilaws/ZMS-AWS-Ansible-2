#!/usr/bin/env bash
# reconverge.sh — cloud-init hook / systemd-timer entry point for the control
# node (Document 1 scaffolding). Pulls the control repo, refreshes collections,
# then re-applies bootstrap to itself. bootstrap.yml resolves the single
# consolidated credentials secret and writes the SSH key from it.
set -euo pipefail

# Load the Terraform-injected environment (AWS_REGION, ANSIBLE_SECRET_NAME,
# CONTROL_REPO_DIR) for MANUAL runs. Under systemd the unit already injects these
# via EnvironmentFile (read as root), and estate.env is root-owned 0640 — so the
# 'ansible' service user CANNOT read it. Test readability (-r), not existence
# (-f): if unreadable we simply rely on the already-injected environment instead
# of aborting under 'set -e'.
ENV_FILE="${ANSIBLE_ESTATE_ENV:-/etc/ansible/estate.env}"
if [ -r "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"

cd "${REPO_DIR}"

# The control node's bootstrap runs `chmod +x /opt/control-repo/scripts/*.sh`
# after cloning. Those files are 100644 in the repo, so the chmod flips them to
# 100755 and git reports them as modified forever — every debug bundle shows
#   M scripts/collect-debug.sh
#   M scripts/reconverge.sh
# which looks like someone edited the node by hand. It is only the exec bit.
#
# It is not cosmetic. This script runs under `set -e`, and `git pull --ff-only`
# refuses to overwrite locally-modified files — so the first time a pushed
# commit touches either of those two scripts, the pull aborts and takes the
# whole converge with it, reporting a git error that has nothing to do with the
# real change. Telling git to stop tracking the exec bit makes the chmod a
# no-op as far as the working tree is concerned.
git config core.fileMode false

# Keep the control repo current (single source of truth for push config).
git pull --ff-only

# Refresh collections. --upgrade so changed version pins actually replace an
# already-installed version (otherwise galaxy leaves the old one in place).
ansible-galaxy collection install --upgrade -r requirements.yml

# AWS_REGION and ANSIBLE_SECRET_NAME are injected into the environment by the
# control node's cloud-init (Terraform module.secrets / ansible-control). The
# IAM GetSecretValue policy is scoped to that one secret ARN.
ansible-playbook bootstrap.yml

# To converge the estate on a schedule, a second timer can run:
#   ansible-playbook site.yml --check --diff   # alert on drift, then enforce
#   ansible-playbook site.yml
