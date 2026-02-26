#!/usr/bin/env bash
set -euo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*"; }
fail() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
is_truthy() { case "$(echo "${1:-}" | lower)" in yes|true|1) return 0 ;; *) return 1 ;; esac; }

# ---------- REQUIRED ENV ----------
: "${SRC_ENDPOINT:?Set SRC_ENDPOINT (e.g. http://minio:9000)}"
: "${SRC_ACCESS_KEY:?Set SRC_ACCESS_KEY}"
: "${SRC_SECRET_KEY:?Set SRC_SECRET_KEY}"
: "${SRC_PROVIDER:?Set SRC_PROVIDER (Minio|AWS|Other|Cloudflare)}"

: "${DEST_ENDPOINT:?Set DEST_ENDPOINT (e.g. https://<accountid>.r2.cloudflarestorage.com)}"
: "${DEST_ACCESS_KEY:?Set DEST_ACCESS_KEY}"
: "${DEST_SECRET_KEY:?Set DEST_SECRET_KEY}"
: "${DEST_PROVIDER:?Set DEST_PROVIDER (AWS|Other|Cloudflare|Minio)}"

: "${DEST_BUCKET:?Set DEST_BUCKET}"

# ---------- OPTIONAL ENV ----------
SRC_REGION="${SRC_REGION:-us-east-1}"
DEST_REGION="${DEST_REGION:-us-east-1}"

SRC_FORCE_PATH_STYLE="${SRC_FORCE_PATH_STYLE:-true}"
DEST_FORCE_PATH_STYLE="${DEST_FORCE_PATH_STYLE:-true}"

SRC_INSECURE_TLS="${SRC_INSECURE_TLS:-false}"
DEST_INSECURE_TLS="${DEST_INSECURE_TLS:-false}"

SRC_BUCKETS="${SRC_BUCKETS:-}"   # space/newline separated list; if empty => discover
DEST_PREFIX="${DEST_PREFIX:-}"   # prefix inside DEST_BUCKET

REMOVE="${REMOVE:-yes}"          # yes => sync (delete extras), no => copy
DRY_RUN="${DRY_RUN:-no}"         # yes => --dry-run

TRANSFERS="${TRANSFERS:-16}"
CHECKERS="${CHECKERS:-16}"

# ---------- rclone config ----------
mkdir -p /config
export RCLONE_CONFIG=/config/rclone.conf

cat >"$RCLONE_CONFIG" <<EOF
[src]
type = s3
provider = ${SRC_PROVIDER}
access_key_id = ${SRC_ACCESS_KEY}
secret_access_key = ${SRC_SECRET_KEY}
endpoint = ${SRC_ENDPOINT}
region = ${SRC_REGION}
force_path_style = ${SRC_FORCE_PATH_STYLE}

[dst]
type = s3
provider = ${DEST_PROVIDER}
access_key_id = ${DEST_ACCESS_KEY}
secret_access_key = ${DEST_SECRET_KEY}
endpoint = ${DEST_ENDPOINT}
region = ${DEST_REGION}
force_path_style = ${DEST_FORCE_PATH_STYLE}
EOF

# TLS flags (simple + global)
RCLONE_TLS_FLAGS=()
is_truthy "${SRC_INSECURE_TLS}" && RCLONE_TLS_FLAGS+=(--no-check-certificate)
is_truthy "${DEST_INSECURE_TLS}" && RCLONE_TLS_FLAGS+=(--no-check-certificate)

# Determine which buckets to sync
get_src_buckets() {
  if [ -n "${SRC_BUCKETS}" ]; then
    printf '%s\n' "${SRC_BUCKETS}" | tr ' ' '\n' | sed '/^$/d'
    return 0
  fi

  # list buckets visible on src
  rclone lsd src: "${RCLONE_TLS_FLAGS[@]}" 2>/dev/null \
    | awk '{print $NF}' \
    | sed 's:/*$::' \
    | grep -v '^\.minio\.sys$' \
    || true
}

mapfile -t buckets < <(get_src_buckets)

if [ "${#buckets[@]}" -eq 0 ]; then
  log "No source buckets found (or no access). Nothing to do."
  exit 0
fi

# Select mode
mode="copy"
verb="Copying"
extra_flags=()
if is_truthy "${REMOVE}"; then
  mode="sync"
  verb="Syncing (with deletes)"
fi
is_truthy "${DRY_RUN}" && extra_flags+=(--dry-run)

log "Starting: ${verb} ${#buckets[@]} bucket(s)"
log "src endpoint: ${SRC_ENDPOINT}"
log "dst endpoint: ${DEST_ENDPOINT}"
log "dest bucket:  ${DEST_BUCKET}${DEST_PREFIX:+/${DEST_PREFIX%/}}"
log "mode: ${mode}  dry_run: ${DRY_RUN}  transfers: ${TRANSFERS}  checkers: ${CHECKERS}"

# Ensure dest bucket exists (best-effort)
rclone mkdir "dst:${DEST_BUCKET}" "${RCLONE_TLS_FLAGS[@]}" >/dev/null 2>&1 || true

rc=0
for b in "${buckets[@]}"; do
  src_path="src:${b}"
  dst_path="dst:${DEST_BUCKET}"
  [ -n "${DEST_PREFIX}" ] && dst_path="${dst_path}/${DEST_PREFIX%/}"
  dst_path="${dst_path}/${b}"

  log "${verb}: ${src_path} -> ${dst_path}"

  if ! rclone "${mode}" \
      "${src_path}" "${dst_path}" \
      --fast-list \
      --transfers "${TRANSFERS}" \
      --checkers "${CHECKERS}" \
      --stats 30s \
      --stats-one-line \
      "${RCLONE_TLS_FLAGS[@]}" \
      "${extra_flags[@]}"; then
    log "FAILED: bucket ${b}"
    rc=1
  fi
done

[ $rc -eq 0 ] && log "Backup completed OK." || fail "One or more bucket syncs failed."
