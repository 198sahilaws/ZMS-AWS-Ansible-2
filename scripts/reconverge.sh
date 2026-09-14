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
# It is not cosmetic, and it has already cost a full estate outage. On
# ip-10-188-30-54 (2026-09-14) origin moved 068e812..87cebeb, that commit touched
# scripts/collect-debug.sh, and the pull refused:
#   error: Your local changes to the following files would be overwritten by merge:
#           scripts/collect-debug.sh
#   Aborting
# Under `set -e` this script then exited 1 before ansible-playbook bootstrap.yml
# ever ran, so /etc/ansible/keys/ansible_rsa was never written and every
# subsequent estate converge failed with UNREACHABLE on all three Linux hosts.
# The reported error named a debug script nobody had edited.
git config core.fileMode false

# Bring the working tree to exactly origin/<branch>, rather than merging into it.
#
# `git pull --ff-only` is the wrong verb for this machine. The control node is a
# pure CONSUMER of the repo — nothing here is ever authored locally, and anything
# that differs is drift to be discarded, not work to be preserved. A pull refuses
# to proceed whenever the tree is dirty for any reason (the exec bit above, a
# half-finished hand edit during debugging, a partially-applied file), which
# converts a cosmetic difference into a total converge failure. reset --hard
# cannot get stuck in that state, and it is what the Terraform cloud-init
# bootstrap script already does for the same repo, so the two entry points now
# behave identically.
#
# If you need to test a local change on the node, expect it to be erased at the
# next timer tick. Commit and push instead.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch --prune origin
git reset --hard "origin/${BRANCH}"

# reset --hard rewrites these at their recorded mode, and with core.fileMode
# false that means 644 — so the exec bit the bootstrap applied is stripped on
# every converge. The systemd units are immune (they invoke `/bin/bash <script>`
# deliberately), but a human typing ./scripts/collect-debug.sh is not. Re-apply.
# The permanent fix is to record the bit in git itself, once, from a workstation:
#   git update-index --chmod=+x scripts/*.sh && git commit -m 'mark scripts executable'
# after which this line becomes a no-op.
chmod +x scripts/*.sh 2>/dev/null || true

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
