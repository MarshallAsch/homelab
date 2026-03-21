FROM alpine:3.21

RUN apk add --no-cache \
    mariadb-client \
    postgresql16-client \
    curl \
    gzip \
    msmtp

COPY backup.sh /usr/local/bin/backup.sh
COPY crontab /etc/crontabs/root
COPY msmtprc /etc/msmtprc.template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["crond", "-f", "-l", "2"]
