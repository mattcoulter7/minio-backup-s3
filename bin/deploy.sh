docker build -f Dockerfile -t mattcoulter7/minio-backup-s3:latest -t mattcoulter7/minio-backup-s3:1.0.0 .
docker login
docker push mattcoulter7/minio-backup-s3:1.0.0
docker push mattcoulter7/minio-backup-s3:latest
