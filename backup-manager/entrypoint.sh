#!/bin/sh
# Template msmtp config with env vars
sed -e "s|SMTP_RELAY_HOST_PLACEHOLDER|${SMTP_RELAY_HOST}|g" \
    -e "s|NOTIFICATION_FROM_PLACEHOLDER|${NOTIFICATION_FROM}|g" \
    /etc/msmtprc.template > /etc/msmtprc

exec "$@"
