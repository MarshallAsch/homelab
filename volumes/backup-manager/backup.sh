#!/bin/sh
set -u

# ── Config ──────────────────────────────────────────
LOG_FILE="/backups/dumps/backup.log"
RETENTION_DAYS=14
MAX_RETRIES=5
RETRY_INTERVAL=30
DATE=$(date +%Y-%m-%d)
FAILURES=""

# ── Logging ─────────────────────────────────────────
log() {
    local service="$1" status="$2" msg="$3"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$service] [$status] $msg"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# ── Email ───────────────────────────────────────────
send_email() {
    local subject="$1" body="$2"
    printf "From: %s\nTo: %s\nSubject: %s\n\n%s" \
        "$NOTIFICATION_FROM" "$NOTIFICATION_EMAIL" "$subject" "$body" \
    | msmtp --host="$SMTP_RELAY_HOST" --port=587 --from="$NOTIFICATION_FROM" "$NOTIFICATION_EMAIL"
}

# ── Retry wrapper ───────────────────────────────────
with_retry() {
    local service="$1"
    shift
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        log "$service" "WARN" "Attempt $attempt/$MAX_RETRIES failed, retrying in ${RETRY_INTERVAL}s..."
        sleep $RETRY_INTERVAL
        attempt=$((attempt + 1))
    done
    return 1
}

# ── Verification ────────────────────────────────────
verify_dump() {
    local service="$1" filepath="$2"
    if [ ! -s "$filepath" ]; then
        log "$service" "FAIL" "Dump file is empty or missing: $filepath"
        rm -f "$filepath"
        return 1
    fi
    if ! gzip -t "$filepath" 2>/dev/null; then
        log "$service" "FAIL" "Dump file failed gzip integrity check: $filepath"
        rm -f "$filepath"
        return 1
    fi
    log "$service" "OK" "Verified: $filepath ($(du -h "$filepath" | cut -f1))"
    return 0
}

# ── Record failure ──────────────────────────────────
record_failure() {
    local service="$1" msg="$2"
    FAILURES="$(printf '%s%s: %s\n' "$FAILURES" "$service" "$msg")"
    log "$service" "FAIL" "$msg"
}
