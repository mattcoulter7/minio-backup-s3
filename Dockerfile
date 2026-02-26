FROM rclone/rclone:latest

RUN apk add --no-cache bash ca-certificates curl tzdata && \
    curl -fsSL -o /usr/local/bin/supercronic \
      https://github.com/aptible/supercronic/releases/download/v0.2.26/supercronic-linux-amd64 && \
    chmod +x /usr/local/bin/supercronic

WORKDIR /app
COPY backup.sh /app/backup.sh
COPY run.sh /app/run.sh
RUN sed -i 's/\r$//' /app/run.sh /app/backup.sh && chmod +x /app/run.sh /app/backup.sh

ENTRYPOINT ["/app/run.sh"]