# --- build go-cron ---
FROM alpine:3.22 AS build
WORKDIR /src
RUN apk add --no-cache go
COPY main.go .
RUN go mod init local/cron \
 && go get github.com/robfig/cron/v3 \
 && go build -o /out/go-cron main.go

# --- runtime ---
FROM alpine:3.22
RUN apk add --no-cache bash curl ca-certificates tzdata aws-cli \
 && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc \
 && chmod +x /usr/local/bin/mc

COPY --from=build /out/go-cron /usr/local/bin/go-cron

# Defaults (override at runtime)
ENV MINIO_URL="" \
    MINIO_ACCESS_KEY="" \
    MINIO_SECRET_KEY="" \
    AWS_ACCESS_KEY_ID="" \
    AWS_SECRET_ACCESS_KEY="" \
    AWS_REGION="ap-southeast-2" \
    DEST_MODE="prefix" \
    DEST_BUCKET="" \
    DEST_PREFIX="" \
    DEST_BUCKET_TEMPLATE="" \
    BUCKETS="" \
    REMOVE="yes" \
    DRY_RUN="no" \
    ALLOW_INSECURE="no" \
    SCHEDULE="" \
    TZ="UTC"

ADD run.sh /run.sh
ADD backup.sh /backup.sh
RUN sed -i 's/\r$//' /run.sh /backup.sh && chmod +x /run.sh /backup.sh

CMD ["sh", "/run.sh"]
