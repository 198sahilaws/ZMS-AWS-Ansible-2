#!/usr/bin/env bash
# systemd ExecStopPost hook. Records each converge's result to a persistent log,
# and on failure to a dedicated failures log (so a CloudWatch alarm / cron can
# watch a single file) and optionally publishes to SNS. Called with one arg: the
# label ("bootstrap" or "estate"). Always exits 0 so it never alters the unit's
# own result.
set -u

LABEL="${1:-ansible}"
LOG_DIR="${ANSIBLE_LOG_DIR:-/var/log/ansible}"
RESULT="${SERVICE_RESULT:-unknown}"   # systemd: 'success' or e.g. 'exit-code'
STATUS="${EXIT_STATUS:-?}"            # systemd: numeric exit status
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"

mkdir -p "$LOG_DIR" 2>/dev/null || true
echo "$TS ${LABEL} result=${RESULT} exit=${STATUS} host=${HOST}" >> "$LOG_DIR/converge-status.log" 2>/dev/null || true

if [ "$RESULT" != "success" ]; then
  echo "$TS ${LABEL} FAILED (exit=${STATUS}) — inspect: journalctl -u ansible-${LABEL}.service" \
    >> "$LOG_DIR/converge-failures.log" 2>/dev/null || true

  # Optional alert: set ANSIBLE_ALERT_SNS_TOPIC_ARN in /etc/ansible/estate.env.
  # Region comes from AWS_REGION (Terraform injects it into estate.env). Do NOT
  # hardcode a region fallback — a wrong region silently publishes nowhere. If
  # AWS_REGION is unset, extract it from the topic ARN (arn:aws:sns:<region>:...).
  if [ -n "${ANSIBLE_ALERT_SNS_TOPIC_ARN:-}" ] && command -v aws >/dev/null 2>&1; then
    SNS_REGION="${AWS_REGION:-$(echo "$ANSIBLE_ALERT_SNS_TOPIC_ARN" | cut -d: -f4)}"
    if [ -n "$SNS_REGION" ]; then
      aws sns publish \
        --region "$SNS_REGION" \
        --topic-arn "$ANSIBLE_ALERT_SNS_TOPIC_ARN" \
        --subject "Ansible ${LABEL} converge FAILED on ${HOST}" \
        --message "$(tail -n 40 "$LOG_DIR/converge-failures.log" 2>/dev/null)" \
        >/dev/null 2>&1 || true
    else
      echo "$TS ${LABEL} SNS alert skipped: no AWS_REGION and none in topic ARN" \
        >> "$LOG_DIR/converge-failures.log" 2>/dev/null || true
    fi
  fi
fi
exit 0
