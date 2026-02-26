#!/usr/bin/env bash
set -euo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*"; }
fail() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

# Standard 5-field cron: "min hour day-of-month month day-of-week"
# Example hourly: "0 * * * *"
SCHEDULE="${SCHEDULE:-0 * * * *}"

# If user runs `docker run ... backup` then do a one-shot run and exit.
if [ "${1:-}" = "backup" ]; then
  exec /app/backup.sh
fi

# Write supercronic schedule file
mkdir -p /config
CRONFILE=/config/crontab
cat >"${CRONFILE}" <<EOF
${SCHEDULE} /app/backup.sh
EOF

log "Starting scheduler with: ${SCHEDULE}"
exec /usr/local/bin/supercronic "${CRONFILE}"
