#!/usr/bin/env bash
set -euo pipefail

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

: "${MINIO_URL:?Set MINIO_URL (e.g. http://minio:9000)}"
: "${MINIO_ACCESS_KEY:?Set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?Set MINIO_SECRET_KEY}"

: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${AWS_REGION:?Set AWS_REGION (e.g. ap-southeast-2)}"
: "${DEST_BUCKET:?Set DEST_BUCKET}"

AWS_ENDPOINT="${AWS_S3_ENDPOINT:-https://s3.${AWS_REGION}.amazonaws.com}"
DEST_PREFIX="${DEST_PREFIX:-}"
REMOVE="${REMOVE:-yes}"
DRY_RUN="${DRY_RUN:-no}"
MC_INSECURE="${MC_INSECURE:-no}"
BUCKETS_IN="${BUCKETS:-}"

MC="mc"
INSECURE_FLAG=""
case "${MC_INSECURE,,}" in yes|true|1) INSECURE_FLAG="--insecure" ;; esac

$MC $INSECURE_FLAG alias set src "$MINIO_URL" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null
$MC $INSECURE_FLAG alias set dst "$AWS_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null
$MC $INSECURE_FLAG mb --ignore-existing "dst/${DEST_BUCKET}" || true

MIRROR_FLAGS=(--overwrite)
case "${REMOVE,,}" in yes|true|1) MIRROR_FLAGS+=("--remove") ;; esac
case "${DRY_RUN,,}" in yes|true|1) MIRROR_FLAGS+=("--dry-run") ;; esac

if [ -n "$BUCKETS_IN" ]; then
  mapfile -t buckets < <(printf '%s\n' "$BUCKETS_IN" | tr ' ' '\n' | sed '/^$/d')
else
  mapfile -t buckets < <($MC $INSECURE_FLAG ls src | awk '{print $NF}' | sed 's:/$::' | grep -v '^\.minio\.sys$' || true)
fi

if [ "${#buckets[@]}" -eq 0 ]; then
  log "No buckets found on source; nothing to do."
  exit 0
fi

rc=0
for b in "${buckets[@]}"; do
  dest="dst/${DEST_BUCKET}"
  [ -n "$DEST_PREFIX" ] && dest="${dest}/${DEST_PREFIX%/}"
  dest="${dest}/${b}"
  log "Mirroring: src/${b}  -->  ${dest}"
  if ! $MC $INSECURE_FLAG mirror "${MIRROR_FLAGS[@]}" "src/${b}" "${dest}"; then
    log "Mirror FAILED for bucket: ${b}"
    rc=1
  fi
done

exit $rc
