# MinIO → S3-Compatible Backup (rclone + supercronic)

This project backs up **all buckets** (or a selected subset) from a **source S3-compatible store** (e.g. MinIO) into a **destination S3-compatible store** (AWS S3, Cloudflare R2, Wasabi, Backblaze B2 S3, DigitalOcean Spaces, IDrive e2, another MinIO, etc.).

It uses:
- **rclone** for S3-to-S3 copy/sync
- **supercronic** for scheduling (standard cron syntax)

You get two scripts:
- `backup.sh` — runs **one backup execution** and exits
- `run.sh` — runs `backup.sh` on a **cron schedule** (default container entrypoint)

---

## How it works

For each source bucket:

- Source: `src:<bucket>`
- Destination: `dst:<DEST_BUCKET>/<DEST_PREFIX>/<bucket>`

Example:
- `src:bucket-1` → `dst:my-backups/minio/bucket-1`

### Copy vs Sync (deletes)
- `REMOVE=no` → `rclone copy` (does **not** delete anything on destination)
- `REMOVE=yes` → `rclone sync` (destination becomes a mirror; **deletes extra** objects)

---

## Quick Start (Docker / Compose)

1) Create `.env` from the template:

```bash
cp template.env .env
````

2. Fill in `.env` values for source + destination.

3. Run scheduled backups (default):

```bash
docker compose up -d --build
```

4. Run a one-shot backup:

```bash
docker compose run --rm minio-backup-s3 backup
```

---

## Cloudflare R2 notes (common 403 cause)

R2’s S3 API uses **Access Key ID** + **Secret Access Key** and the **account endpoint**:

* `DEST_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com`
* `DEST_PROVIDER=Cloudflare`
* `DEST_REGION=auto`
* `DEST_FORCE_PATH_STYLE=true`

Do **not** use your Cloudflare API token as the S3 secret.

---

## Environment Variables

> All variables are read from the container environment (recommended via `.env` / Kubernetes Secret).

| Variable                | Required | Default             | Description                                                                                                           |
| ----------------------- | -------: | ------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `SRC_ENDPOINT`          |        ✅ | –                   | Source S3 endpoint URL (e.g. `http://minio:9000`, `https://s3.ap-southeast-2.amazonaws.com`)                          |
| `SRC_ACCESS_KEY`        |        ✅ | –                   | Source S3 Access Key ID                                                                                               |
| `SRC_SECRET_KEY`        |        ✅ | –                   | Source S3 Secret Access Key                                                                                           |
| `SRC_PROVIDER`          |        ✅ | –                   | rclone S3 provider string (e.g. `Minio`, `AWS`, `Cloudflare`, `Other`)                                                |
| `SRC_REGION`            |          | `us-east-1`         | Source region (MinIO often uses `us-east-1`)                                                                          |
| `SRC_FORCE_PATH_STYLE`  |          | `true`              | Force path-style addressing for source (`true/false`). Often needed for non-AWS S3 endpoints.                         |
| `SRC_INSECURE_TLS`      |          | `false`             | Skip TLS certificate verification for source (`true/false`). Use only for self-signed HTTPS.                          |
| `SRC_BUCKETS`           |          | empty               | Optional space/newline list of source buckets to sync. If empty, buckets are auto-discovered using `rclone lsd src:`. |
| `DEST_ENDPOINT`         |        ✅ | –                   | Destination S3 endpoint URL (e.g. AWS regional endpoint, R2 account endpoint, Wasabi endpoint)                        |
| `DEST_ACCESS_KEY`       |        ✅ | –                   | Destination S3 Access Key ID                                                                                          |
| `DEST_SECRET_KEY`       |        ✅ | –                   | Destination S3 Secret Access Key                                                                                      |
| `DEST_PROVIDER`         |        ✅ | –                   | rclone S3 provider string (e.g. `AWS`, `Cloudflare`, `Other`, `Minio`)                                                |
| `DEST_REGION`           |          | `us-east-1`         | Destination region (R2 commonly `auto`)                                                                               |
| `DEST_FORCE_PATH_STYLE` |          | `true`              | Force path-style addressing for destination (`true/false`). Often required for non-AWS.                               |
| `DEST_INSECURE_TLS`     |          | `false`             | Skip TLS certificate verification for destination (`true/false`).                                                     |
| `DEST_BUCKET`           |        ✅ | –                   | Destination bucket name (this is the “root” bucket you back up into)                                                  |
| `DEST_PREFIX`           |          | empty               | Optional prefix under `DEST_BUCKET` (e.g. `minio`)                                                                    |
| `REMOVE`                |          | `yes`               | `yes` → `rclone sync` (delete extras). `no` → `rclone copy` (no deletes).                                             |
| `DRY_RUN`               |          | `no`                | `yes` to run with `--dry-run` (no changes made)                                                                       |
| `TRANSFERS`             |          | `16`                | rclone parallel transfers                                                                                             |
| `CHECKERS`              |          | `16`                | rclone parallel checkers (listing/checking)                                                                           |
| `SCHEDULE`              |          | `0 * * * *`         | Cron schedule (5-field standard cron). Example hourly: `0 * * * *`                                                    |
| `TZ`                    |          | (container default) | Timezone for logs + cron interpretation (e.g. `Australia/Melbourne`)                                                  |

---

## Provider Configuration Examples

### AWS S3 (destination)

```env
DEST_PROVIDER=AWS
DEST_ENDPOINT=https://s3.ap-southeast-2.amazonaws.com
DEST_REGION=ap-southeast-2
DEST_FORCE_PATH_STYLE=false
```

### Cloudflare R2 (destination)

```env
DEST_PROVIDER=Cloudflare
DEST_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
DEST_REGION=auto
DEST_FORCE_PATH_STYLE=true
```

### DigitalOcean Spaces (destination)

```env
DEST_PROVIDER=Other
DEST_ENDPOINT=https://sfo3.digitaloceanspaces.com
DEST_REGION=sfo3
DEST_FORCE_PATH_STYLE=true
```

---

## Kubernetes Example

This example runs as a **CronJob** once per hour and stores configuration in a Secret.

> Note: Replace image name/tag with your built image. If you push to a registry, update `image:` accordingly.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
type: Opaque
stringData:
  SRC_ACCESS_KEY: "minio"
  SRC_SECRET_KEY: "miniosecret"
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-r2-credentials
type: Opaque
stringData:
  DEST_ACCESS_KEY: "<dest-access-key-id>"
  DEST_SECRET_KEY: "<dest-secret-access-key>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-backup-s3
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio-backup-s3
  template:
    metadata:
      labels:
        app: minio-backup-s3
    spec:
      containers:
        - name: minio-backup-s3
          image: mattcoulter7/minio-backup-s3:latest
          imagePullPolicy: IfNotPresent
          env:
            # --- General ---
            - name: TZ
              value: "Australia/Melbourne"

            # Standard cron (5-field). Hourly:
            - name: SCHEDULE
              value: "0 * * * *"

            # --- Source (MinIO example) ---
            - name: SRC_PROVIDER
              value: "Minio"
            - name: SRC_ENDPOINT
              value: "http://minio-service.default.svc.cluster.local:9000"
            - name: SRC_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: SRC_ACCESS_KEY
            - name: SRC_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: SRC_SECRET_KEY
            - name: SRC_REGION
              value: "us-east-1"
            - name: SRC_FORCE_PATH_STYLE
              value: "true"
            - name: SRC_INSECURE_TLS
              value: "false"
            # Optional: restrict buckets
            # - name: SRC_BUCKETS
            #   value: "bucket-1 bucket-2"

            # --- Destination (Cloudflare R2 example) ---
            - name: DEST_PROVIDER
              value: "Cloudflare"
            - name: DEST_ENDPOINT
              value: "https://<accountid>.r2.cloudflarestorage.com"
            - name: DEST_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: cloudflare-r2-credentials
                  key: DEST_ACCESS_KEY
            - name: DEST_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: cloudflare-r2-credentials
                  key: DEST_SECRET_KEY
            - name: DEST_REGION
              value: "auto"
            - name: DEST_FORCE_PATH_STYLE
              value: "true"
            - name: DEST_INSECURE_TLS
              value: "false"

            # --- Destination path ---
            - name: DEST_BUCKET
              value: "your-bucket"
            - name: DEST_PREFIX
              value: "minio"

            # --- Behaviour ---
            - name: REMOVE
              value: "yes"
            - name: DRY_RUN
              value: "no"
            - name: TRANSFERS
              value: "16"
            - name: CHECKERS
              value: "16"
```

---

## Troubleshooting

### Supercronic “bad crontab line”

Use standard cron format (5 fields), e.g.:

* Hourly: `0 * * * *`
* Every 15 minutes: `*/15 * * * *`

### 403 Forbidden (R2 and other providers)

Most common causes:

* Wrong endpoint (must be the provider’s S3 endpoint, not a console URL)
* Wrong credentials (R2 requires S3 Access Key + Secret Key)
* Token/keys don’t have permission to the bucket
* Path-style needed → set `DEST_FORCE_PATH_STYLE=true`

---

## Licence

MIT.
