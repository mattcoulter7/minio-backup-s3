#!/usr/bin/env sh
set -e

# If SCHEDULE is set, run periodically; else run once now.
if [ -n "$SCHEDULE" ]; then
  echo "Starting cron with schedule: $SCHEDULE (TZ=$TZ)"
  exec /usr/local/bin/go-cron "$SCHEDULE" /bin/bash /backup.sh
else
  echo "Running single sync (no SCHEDULE set)"
  exec /bin/bash /backup.sh
fi
