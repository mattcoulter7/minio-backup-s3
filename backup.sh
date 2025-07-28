#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# ---- Required source (MinIO) ----
: "${MINIO_URL:?Set MINIO_URL (e.g. http://minio:9000)}"
: "${MINIO_ACCESS_KEY:?Set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?Set MINIO_SECRET_KEY}"

# ---- Required destination (AWS) ----
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${AWS_REGION:?Set AWS_REGION (e.g. ap-southeast-2)}"

# ---- Modes / options ----
DEST_MODE="${DEST_MODE:-prefix}"              # "prefix" (single S3 bucket + per-bucket prefixes) or "per-bucket"
DEST_BUCKET="${DEST_BUCKET:-}"                # required when DEST_MODE=prefix
DEST_PREFIX="${DEST_PREFIX:-}"                # optional extra prefix under the bucket
DEST_BUCKET_TEMPLATE="${DEST_BUCKET_TEMPLATE:-}"  # required when DEST_MODE=per-bucket; must include {bucket}

REMOVE="${REMOVE:-yes}"                       # yes|true|1 to mirror deletions
DRY_RUN="${DRY_RUN:-no}"                      # yes|true|1 for preview
ALLOW_INSECURE="${ALLOW_INSECURE:-no}"        # yes|true|1 if MinIO is HTTP/self-signed
BUCKETS_IN="${BUCKETS:-}"                     # optional allow-list (space/newline separated)

# Export defaults for aws-cli
export AWS_DEFAULT_REGION="${AWS_REGION}"

MC="mc"
SRC_INSECURE_FLAG=""
case "${ALLOW_INSECURE,,}" in yes|true|1) SRC_INSECURE_FLAG="--insecure" ;; esac

# ---- MinIO alias (source) ----
$MC $SRC_INSECURE_FLAG alias set src "$MINIO_URL" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null

# ---- Helpers ----
is_true(){ case "${1,,}" in yes|true|1) return 0 ;; *) return 1 ;; esac; }

# get_region <bucket> -> prints region or empty if bucket doesn't exist
get_region() {
  local b="$1"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    local loc
    loc="$(aws s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text 2>/dev/null || echo 'None')"
    case "$loc" in None|null|""|AWS_GLOBAL) echo "us-east-1" ;; *) echo "$loc" ;; esac
  else
    echo ""
  fi
}

# ensure_bucket <bucket> <region>
ensure_bucket() {
  local b="$1" r="$2"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$r" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$b" >/dev/null
  else
    aws s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$r" >/dev/null
  fi
}

# alias name for a region (dst-ap-southeast-2, dst-us-east-1, ...)
alias_for_region(){ printf 'dst-%s' "$1"; }

# ensure_dst_alias <region> -> prints alias name bound to the correct endpoint
ensure_dst_alias() {
  local r="$1" a ep
  a="$(alias_for_region "$r")"
  if [ "$r" = "us-east-1" ]; then
    ep="https://s3.amazonaws.com"
  else
    ep="https://s3.${r}.amazonaws.com"
  fi
  $MC alias set "$a" "$ep" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null
  echo "$a"
}

# ---- Gather MinIO buckets ----
if [ -n "$BUCKETS_IN" ]; then
  mapfile -t buckets < <(printf '%s\n' "$BUCKETS_IN" | tr ' ' '\n' | sed '/^$/d')
else
  mapfile -t buckets < <($MC $SRC_INSECURE_FLAG ls src | awk '{print $NF}' | sed 's:/$::' | grep -v '^\.minio\.sys$' || true)
fi

if [ "${#buckets[@]}" -eq 0 ]; then
  log "No buckets found on source; nothing to do."
  exit 0
fi

# ---- Validate mode inputs ----
case "$DEST_MODE" in
  prefix)
    [ -n "$DEST_BUCKET" ] || die "DEST_BUCKET is required when DEST_MODE=prefix"
    ;;
  per-bucket)
    [[ "$DEST_BUCKET_TEMPLATE" == *"{bucket}"* ]] || die "DEST_BUCKET_TEMPLATE must include {bucket}"
    ;;
  *) die "DEST_MODE must be 'prefix' or 'per-bucket'";;
esac

# ---- Mirror flags ----
MIRROR_FLAGS=(--overwrite)
is_true "$REMOVE"  && MIRROR_FLAGS+=("--remove")
is_true "$DRY_RUN" && MIRROR_FLAGS+=("--dry-run")

rc=0

if [ "$DEST_MODE" = "prefix" ]; then
  # Determine/create the single destination bucket and bind alias to its actual region
  dest_region="$(get_region "$DEST_BUCKET")"
  if [ -z "$dest_region" ]; then
    dest_region="$AWS_REGION"
    log "Creating destination bucket s3://${DEST_BUCKET} in region ${dest_region}"
    ensure_bucket "$DEST_BUCKET" "$dest_region"
  else
    log "Destination bucket s3://${DEST_BUCKET} already exists in region ${dest_region}"
  fi
  dst_alias="$(ensure_dst_alias "$dest_region")"
  log "Using alias ${dst_alias} -> $( $MC alias list | awk -v a="$dst_alias" '$1==a{print $3}' )"

  # Preflight with the regional alias
  if ! $MC ls "${dst_alias}/${DEST_BUCKET}" >/dev/null 2>&1; then
    err="$($MC ls "${dst_alias}/${DEST_BUCKET}" 2>&1 || true)"
    echo "$err" >&2; die "Cannot access s3://${DEST_BUCKET} via alias ${dst_alias}"
  fi

  for b in "${buckets[@]}"; do
    dest="${dst_alias}/${DEST_BUCKET}"
    [ -n "$DEST_PREFIX" ] && dest="${dest}/${DEST_PREFIX%/}"
    dest="${dest}/${b}"
    log "Mirroring: src/${b}  -->  ${dest}"
    if ! $MC $SRC_INSECURE_FLAG mirror "${MIRROR_FLAGS[@]}" "src/${b}" "${dest}"; then
      log "Mirror FAILED for bucket: ${b}"; rc=1
    fi
  done

else  # per-bucket
  for b in "${buckets[@]}"; do
    dest_bucket="${DEST_BUCKET_TEMPLATE//\{bucket\}/$b}"

    b_region="$(get_region "$dest_bucket")"
    if [ -z "$b_region" ]; then
      b_region="$AWS_REGION"
      log "Creating destination bucket s3://${dest_bucket} in region ${b_region}"
      ensure_bucket "$dest_bucket" "$b_region"
    else
      log "Destination bucket s3://${dest_bucket} already exists in region ${b_region}"
    fi
    dst_alias="$(ensure_dst_alias "$b_region")"
    log "Using alias ${dst_alias} -> $( $MC alias list | awk -v a="$dst_alias" '$1==a{print $3}' )"

    if ! $MC ls "${dst_alias}/${dest_bucket}" >/dev/null 2>&1; then
      err="$($MC ls "${dst_alias}/${dest_bucket}" 2>&1 || true)"
      echo "$err" >&2
      log "Skipping ${b}: cannot access destination bucket s3://${dest_bucket}"
      rc=1
      continue
    fi

    dest="${dst_alias}/${dest_bucket}"
    [ -n "$DEST_PREFIX" ] && dest="${dest}/${DEST_PREFIX%/}"
    dest="${dest}/${b}"
    log "Mirroring: src/${b}  -->  ${dest}"
    if ! $MC $SRC_INSECURE_FLAG mirror "${MIRROR_FLAGS[@]}" "src/${b}" "${dest}"; then
      log "Mirror FAILED for bucket: ${b}"; rc=1
    fi
  done
fi

exit $rc
