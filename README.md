# minio-backup-s3

Mirror **all MinIO buckets** to **one S3 bucket**, under per‑bucket prefixes.

* **Upsert** destination bucket: creates it if missing (in `AWS_REGION`), otherwise uses the existing bucket.
* **Region‑aware:** automatically binds `mc` to the bucket’s **correct regional endpoint** (no 301 redirects).
* **Overwrite by default:** uses `mc mirror --overwrite` (and optionally `--remove` to delete objects not present in source).
* **Simple scheduling:** run **once** or **periodically** using `SCHEDULE` (robfig/cron via the tiny `go-cron` runner built into the image).

```
s3://<DEST_BUCKET>/<DEST_PREFIX>/<minio-bucket-name>/...
```

> ⚠️ **Bucket ownership**: If `DEST_BUCKET` exists but you **don’t** own it (global name collision), the run fails with a clear error. Use a bucket you own or pick a globally unique name.

---

## Requirements

* A running **MinIO** server you can reach over HTTP/HTTPS.
* An AWS user/role with S3 permissions:

  * `s3:HeadBucket`, `s3:GetBucketLocation`, `s3:GetBucketAcl`
  * `s3:CreateBucket`
  * `s3:ListBucket`, `s3:PutObject`, `s3:DeleteObject` (delete only if you enable `REMOVE=yes`)

---

## Environment variables

| Variable                | Required | Default          | Notes                                                                           |      |                                          |
| ----------------------- | -------- | ---------------- | ------------------------------------------------------------------------------- | ---- | ---------------------------------------- |
| `MINIO_URL`             | ✅        | —                | e.g., `http://minio:9000`                                                       |      |                                          |
| `MINIO_ACCESS_KEY`      | ✅        | —                | MinIO access key                                                                |      |                                          |
| `MINIO_SECRET_KEY`      | ✅        | —                | MinIO secret key                                                                |      |                                          |
| `AWS_ACCESS_KEY_ID`     | ✅        | —                | AWS access key                                                                  |      |                                          |
| `AWS_SECRET_ACCESS_KEY` | ✅        | —                | AWS secret key                                                                  |      |                                          |
| `AWS_REGION`            | ✅        | `ap-southeast-2` | Used to create buckets when missing                                             |      |                                          |
| `DEST_BUCKET`           | ✅        | —                | S3 bucket **you own** (or new unique name)                                      |      |                                          |
| `DEST_PREFIX`           |          | *(empty)*        | Optional prefix inside `DEST_BUCKET`                                            |      |                                          |
| `BUCKETS`               |          | *(all)*          | Space/newline list to restrict MinIO buckets (e.g. `"jellyfin navidrome"`)      |      |                                          |
| `REMOVE`                |          | `yes`            | \`yes                                                                           | true | 1\` to delete objects on S3 not in MinIO |
| `DRY_RUN`               |          | `no`             | \`yes                                                                           | true | 1\` to preview actions only              |
| `ALLOW_INSECURE`        |          | `no`             | \`yes                                                                           | true | 1\` if MinIO is HTTP or self‑signed TLS  |
| `SCHEDULE`              |          | *(empty)*        | Cron string (e.g. `@every 1h`, `0 2 * * *`). If **empty**, runs once and exits. |      |                                          |
| `TZ`                    |          | `UTC`            | For timestamped logs & cron timing; set e.g. `Australia/Melbourne`              |      |                                          |

---

## How it works

1. **Resolve/ensure** the destination bucket:

   * If it exists and you own it → detect its **region**.
   * If missing → create it in `AWS_REGION`.
   * If the name is taken by another account → **fail clearly**.
2. Bind an `mc` alias to the bucket’s **regional endpoint** (e.g., `https://s3.ap-southeast-2.amazonaws.com`).
3. **List MinIO buckets**, optionally filtered by `BUCKETS`.
4. For each, run:

   ```
   mc mirror --overwrite [--remove] src/<bucket> dst/<DEST_BUCKET>/<DEST_PREFIX>/<bucket>
   ```

---

## Quick start (Docker Compose)

```yaml
version: "3.9"
services:
  minio:
    image: minio/minio:latest
    command: server --address :9000 --console-address :9001 /data
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: miniosecret
    ports: ["9000:9000", "9001:9001"]
    volumes:
      - ./data:/data

  minio-backup-s3:
    build:
      context: .
      dockerfile: Dockerfile
    depends_on: [minio]
    environment:
      TZ: "Australia/Melbourne"

      MINIO_URL: http://minio:9000
      MINIO_ACCESS_KEY: minio
      MINIO_SECRET_KEY: miniosecret
      ALLOW_INSECURE: "yes"

      AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
      AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
      AWS_REGION: ap-southeast-2

      DEST_BUCKET: your-bucket
      DEST_PREFIX: minio
      REMOVE: "yes"
      DRY_RUN: "no"

      # Every hour:
      SCHEDULE: "@every 1h"
```

**Run once and exit:** remove `SCHEDULE` (or set it empty).
**Dry run:** set `DRY_RUN=yes` to see the plan, no writes.

---

## Kubernetes

You can run this two ways:

### A) **Self‑scheduled Deployment** (container handles `SCHEDULE`)

Use this when you prefer the container to do its own cron.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: backup
---
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: backup
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "<your-aws-key>"
  AWS_SECRET_ACCESS_KEY: "<your-aws-secret>"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: minio-backup-config
  namespace: backup
data:
  TZ: "Australia/Melbourne"
  MINIO_URL: "http://minio.minio.svc.cluster.local:9000"
  MINIO_ACCESS_KEY: "<minio-access>"
  MINIO_SECRET_KEY: "<minio-secret>"
  ALLOW_INSECURE: "yes"                 # if MinIO uses HTTP/self-signed
  AWS_REGION: "ap-southeast-2"
  DEST_BUCKET: "your-bucket"
  DEST_PREFIX: "minio"
  REMOVE: "yes"
  DRY_RUN: "no"
  SCHEDULE: "0 2 * * *"                 # run daily at 02:00 local time
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-backup-s3
  namespace: backup
spec:
  replicas: 1
  selector:
    matchLabels: { app: minio-backup-s3 }
  template:
    metadata:
      labels: { app: minio-backup-s3 }
    spec:
      containers:
        - name: minio-backup-s3
          image: your-registry/minio-backup-s3:latest
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef: { name: minio-backup-config }
            - secretRef:    { name: s3-credentials }
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
```

> Adjust the `MINIO_URL` to point at your MinIO Service (or external address).
> If your k8s uses real TLS for MinIO, set `ALLOW_INSECURE` to `"no"`.

---

### B) **Native CronJob** (Kubernetes schedules; container runs once)

Use this when you want **Kubernetes** to control the schedule. In this mode, **do not set `SCHEDULE`** in env; the container runs once and exits.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: minio-backup-s3
  namespace: backup
spec:
  schedule: "0 * * * *"   # hourly
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: minio-backup-s3
              image: your-registry/minio-backup-s3:latest
              imagePullPolicy: IfNotPresent
              env:
                - name: TZ
                  value: "Australia/Melbourne"
                - name: MINIO_URL
                  value: "http://minio.minio.svc.cluster.local:9000"
                - name: MINIO_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: minio-keys, key: access } }
                - name: MINIO_SECRET_KEY
                  valueFrom: { secretKeyRef: { name: minio-keys, key: secret } }
                - name: ALLOW_INSECURE
                  value: "yes"

                - name: AWS_REGION
                  value: "ap-southeast-2"
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: s3-credentials, key: AWS_ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: s3-credentials, key: AWS_SECRET_ACCESS_KEY } }

                - name: DEST_BUCKET
                  value: "your-bucket"
                - name: DEST_PREFIX
                  value: "minio"
                - name: REMOVE
                  value: "yes"
                - name: DRY_RUN
                  value: "no"
              # Do NOT set SCHEDULE here; CronJob controls timing.
```

> Create `minio-keys` and `s3-credentials` Secrets in the same namespace.
> This job runs once per schedule and exits cleanly.

---

## Logs you’ll see

* Bucket creation/selection:

  * `Using existing bucket s3://... (region ap-southeast-2)` **or**
  * `Creating bucket s3://... in region ap-southeast-2`
* Alias binding:

  * `S3 alias 'dst' -> https://s3.ap-southeast-2.amazonaws.com`
* Mirroring per source bucket:

  * `Mirroring: src/<bucket>  -->  dst/<DEST_BUCKET>/<DEST_PREFIX>/<bucket>`

If `DEST_BUCKET` exists but you don’t own it:

```
ERROR: S3 bucket 's3://...' is NOT available (owned by another account). Choose a bucket you own or a unique name.
```

---

## Tips & troubleshooting

* **301 Moved Permanently**: The script binds `mc` to the **actual** bucket region; if you still see 301s, ensure the image you’re running is the latest build and `DEST_BUCKET` is owned by your account.
* **Dry run** first:

  ```
  DRY_RUN=yes REMOVE=no
  ```
* **Restrict buckets**:

  ```
  BUCKETS="audiobookshelf jellyfin"
  ```
* **Deletes**: `REMOVE=yes` enables deletion on S3 for keys not present in MinIO. Omit or set to `no` to keep extra objects.

---

## One‑off local run

```bash
docker run --rm \
  -e MINIO_URL=http://localhost:9000 \
  -e MINIO_ACCESS_KEY=minio \
  -e MINIO_SECRET_KEY=miniosecret \
  -e ALLOW_INSECURE=yes \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_REGION=ap-southeast-2 \
  -e DEST_BUCKET=your-bucket \
  -e DEST_PREFIX=minio \
  -e REMOVE=yes \
  -e DRY_RUN=no \
  mattcoulter7/minio-backup-s3:latest
```
