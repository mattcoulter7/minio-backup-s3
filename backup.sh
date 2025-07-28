#!/usr/bin/env bash
set -euo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*"; }
fail() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

# -------- REQUIRED ENV --------
: "${MINIO_URL:?Set MINIO_URL (e.g. http://minio:9000)}"
: "${MINIO_ACCESS_KEY:?Set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?Set MINIO_SECRET_KEY}"

: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${AWS_REGION:?Set AWS_REGION (e.g. ap-southeast-2)}"

: "${DEST_BUCKET:?Set DEST_BUCKET (S3 bucket you OWN or a unique name to create)}"

# -------- OPTIONAL ENV --------
DEST_PREFIX="${DEST_PREFIX:-}"     # extra prefix inside DEST_BUCKET
REMOVE="${REMOVE:-yes}"            # yes|true|1 to delete dest objects not in source
DRY_RUN="${DRY_RUN:-no}"           # yes|true|1 to preview only
ALLOW_INSECURE="${ALLOW_INSECURE:-no}"  # yes|true|1 if MinIO is HTTP/self-signed
BUCKETS="${BUCKETS:-}"             # optional space/newline list to restrict which MinIO buckets

export AWS_DEFAULT_REGION="${AWS_REGION}"

# -------- mc aliases --------
INSECURE_FLAG=""
case "$(echo "${ALLOW_INSECURE}" | tr '[:upper:]' '[:lower:]')" in
  yes|true|1) INSECURE_FLAG="--insecure" ;;
esac

mc ${INSECURE_FLAG} alias set src "${MINIO_URL}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null

# -------- helpers --------
bucket_region() {
  # prints region if you OWN/access the bucket, empty otherwise
  if aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; then
    loc="$(aws s3api get-bucket-location --bucket "$1" --query 'LocationConstraint' --output text 2>/dev/null || echo 'None')"
    case "$loc" in None|null|""|AWS_GLOBAL) echo "us-east-1" ;; *) echo "$loc" ;; esac
  else
    echo ""
  fi
}

create_bucket_if_missing() {
  local b="$1" r="$2"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    return 0
  fi
  log "Creating bucket s3://${b} in region ${r} (if available)…"
  if [ "$r" = "us-east-1" ]; then
    out="$(aws s3api create-bucket --bucket "$b" 2>&1)" || true
  else
    out="$(aws s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$r" 2>&1)" || true
  fi
  if echo "$out" | grep -q "BucketAlreadyOwnedByYou"; then
    return 0
  fi
  if echo "$out" | grep -q "BucketAlreadyExists"; then
    # Somebody else owns this name; you can't use it.
    fail "S3 bucket name 's3://${b}' is NOT available (owned by another account). Choose a bucket you own or a unique name."
  fi
  # If create failed with anything else, check again; otherwise surface message.
  if ! aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    fail "Failed to create bucket s3://${b}: ${out}"
  fi
}

regional_endpoint() {
  [ "$1" = "us-east-1" ] && echo "https://s3.amazonaws.com" || echo "https://s3.$1.amazonaws.com"
}

# -------- ensure destination bucket & endpoint --------
dest_region="$(bucket_region "${DEST_BUCKET}")"
if [ -z "$dest_region" ]; then
  dest_region="$AWS_REGION"
  create_bucket_if_missing "${DEST_BUCKET}" "${dest_region}"
  # after creation, trust configured region
  log "Using bucket s3://${DEST_BUCKET} (region ${dest_region})"
else
  log "Using existing bucket s3://${DEST_BUCKET} (region ${dest_region})"
fi

dst_ep="$(regional_endpoint "${dest_region}")"
mc alias set dst "${dst_ep}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null
log "S3 alias 'dst' -> ${dst_ep}"

# Preflight with mc against the correct regional endpoint
if ! mc ls "dst/${DEST_BUCKET}" >/dev/null 2>&1; then
  err="$(mc ls "dst/${DEST_BUCKET}" 2>&1 || true)"
  fail "Cannot access s3://${DEST_BUCKET} via ${dst_ep}. Details: ${err}"
fi

# -------- list source buckets --------
if [ -n "$BUCKETS" ]; then
  # allow space/newline separated list
  mapfile -t src_buckets < <(printf '%s\n' "$BUCKETS" | tr ' ' '\n' | sed '/^$/d')
else
  mapfile -t src_buckets < <(mc ${INSECURE_FLAG} ls src | awk '{print $NF}' | sed 's:/$::' | grep -v '^\.minio\.sys$' || true)
fi

if [ "${#src_buckets[@]}" -eq 0 ]; then
  log "No MinIO buckets found. Nothing to do."
  exit 0
fi

log "Source buckets: ${src_buckets[*]}"

# -------- mirror --------
MIRROR_FLAGS=(--overwrite)
case "$(echo "$REMOVE" | tr '[:upper:]' '[:lower:]')" in yes|true|1) MIRROR_FLAGS+=("--remove") ;; esac
case "$(echo "$DRY_RUN" | tr '[:upper:]' '[:lower:]')" in yes|true|1) MIRROR_FLAGS+=("--dry-run") ;; esac

rc=0
for b in "${src_buckets[@]}"; do
  dest="dst/${DEST_BUCKET}"
  [ -n "$DEST_PREFIX" ] && dest="${dest}/${DEST_PREFIX%/}"
  dest="${dest}/${b}"
  log "Mirroring: src/${b}  -->  ${dest}"
  if ! mc ${INSECURE_FLAG} mirror "${MIRROR_FLAGS[@]}" "src/${b}" "${dest}"; then
    log "Mirror FAILED for bucket: ${b}"
    rc=1
  fi
done

[ $rc -eq 0 ] && log "Sync completed OK." || fail "One or more bucket syncs failed (rc=${rc})."
