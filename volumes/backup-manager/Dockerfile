FROM alpine:3.21

RUN apk add --no-cache \
    mariadb-client \
    postgresql14-client \
    curl \
    gzip \
    msmtp

COPY backup.sh /usr/local/bin/backup.sh
COPY crontab /etc/crontabs/root

RUN chmod +x /usr/local/bin/backup.sh

CMD ["crond", "-f", "-l", "2"]
