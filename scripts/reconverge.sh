#!/usr/bin/env bash
# reconverge.sh — cloud-init hook / systemd-timer entry point for the control
# node (Document 1 scaffolding). Pulls the control repo, refreshes collections,
# then re-applies bootstrap to itself. bootstrap.yml resolves the single
# consolidated credentials secret and writes the SSH key from it.
set -euo pipefail

# Load the Terraform-injected environment (AWS_REGION, ANSIBLE_SECRET_NAME,
# CONTROL_REPO_DIR). The systemd unit provides these via EnvironmentFile, but a
# manual run does not — so source the file here to make both paths work.
ENV_FILE="${ANSIBLE_ESTATE_ENV:-/etc/ansible/estate.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"

cd "${REPO_DIR}"

# Keep the control repo current (single source of truth for push config).
git pull --ff-only

# Refresh collections.
ansible-galaxy collection install -r requirements.yml

# AWS_REGION and ANSIBLE_SECRET_NAME are injected into the environment by the
# control node's cloud-init (Terraform module.secrets / ansible-control). The
# IAM GetSecretValue policy is scoped to that one secret ARN.
ansible-playbook bootstrap.yml

# To converge the estate on a schedule, a second timer can run:
#   ansible-playbook site.yml --check --diff   # alert on drift, then enforce
#   ansible-playbook site.yml
