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
    | msmtp "$NOTIFICATION_EMAIL"
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

# ── MariaDB connectivity check ──────────────────────
check_mariadb() {
    local host="$1"
    mariadb -h "$host" -u backup_ro -p"$BACKUP_MARIADB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1
}

# ── MariaDB dumps ───────────────────────────────────
dump_mariadb() {
    local service="$1" host="$2" db_arg="$3"
    local outdir="/backups/dumps/$service"
    local outfile="$outdir/$DATE.sql.gz"
    mkdir -p "$outdir"

    local tmp="$outfile.tmp"
    if with_retry "$service" check_mariadb "$host"; then
        if mariadb-dump -h "$host" -u backup_ro -p"$BACKUP_MARIADB_PASSWORD" $db_arg 2>/dev/null | gzip > "$tmp"; then
            if verify_dump "$service" "$tmp"; then
                mv "$tmp" "$outfile"
                return 0
            fi
        fi
    fi
    rm -f "$tmp"
    record_failure "$service" "MariaDB dump failed"
    return 1
}

dump_all_mariadb() {
    # Main mariadb: dump all user databases
    # (--all-databases includes system schemas but they are harmless on restore)
    dump_mariadb "mariadb" "mariadb" "--all-databases" || true

    # Single-database instances: dump only the application database
    dump_mariadb "inventory_db" "inventory_db" "${INVENTORY_DB:-inventory}" || true
    dump_mariadb "fills_db" "fills_db" "${FILLS_DB:-fills}" || true
    dump_mariadb "divetec_db" "divetec_db" "divetec" || true
    dump_mariadb "firefly_db" "firefly_db" "${FIREFLY_DB_NAME:-firefly}" || true
    dump_mariadb "postal_db" "postal_db" "${POSTAL_DB:-postal}" || true
}

# ── PostgreSQL dumps ────────────────────────────────
dump_postgres() {
    local service="$1" host="$2" dbname="$3"
    local outdir="/backups/dumps/$service"
    local outfile="$outdir/$DATE.sql.gz"
    mkdir -p "$outdir"

    local tmp="$outfile.tmp"
    export PGPASSWORD="$BACKUP_POSTGRES_PASSWORD"
    if with_retry "$service" pg_isready -h "$host" -U backup_ro; then
        if pg_dump -h "$host" -U backup_ro "$dbname" 2>/dev/null | gzip > "$tmp"; then
            if verify_dump "$service" "$tmp"; then
                mv "$tmp" "$outfile"
                unset PGPASSWORD
                return 0
            fi
        fi
    fi
    rm -f "$tmp"
    unset PGPASSWORD
    record_failure "$service" "PostgreSQL dump failed"
    return 1
}

dump_all_postgres() {
    dump_postgres "gitea_db" "gitea_db" "gitea" || true
    dump_postgres "immich_db" "immich_db" "immich" || true
    dump_postgres "analytics_db" "analytics_db" "analytics" || true
}

# ── Retention pruning ───────────────────────────────
prune_old_dumps() {
    local count
    count=$(find /backups/dumps -name "*.sql.gz" -mtime +"$RETENTION_DAYS" | wc -l)
    if [ "$count" -gt 0 ]; then
        find /backups/dumps -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
        log "retention" "OK" "Pruned $count dump files older than ${RETENTION_DAYS} days"
    else
        log "retention" "OK" "No dump files older than ${RETENTION_DAYS} days to prune"
    fi
}

# ── Weekly summary ──────────────────────────────────
send_summary() {
    if [ ! -f "$LOG_FILE" ]; then
        send_email "[Backup] Weekly Summary" "No backup log found."
        return
    fi
    local week_ago
    week_ago=$(date -u -d "@$(($(date +%s) - 604800))" '+%Y-%m-%d')
    local body
    body=$(awk -v since="$week_ago" '$0 >= "["since {print}' "$LOG_FILE" | tail -200)
    local ok_count fail_count
    ok_count=$(echo "$body" | grep -c '\[OK\]' || true)
    fail_count=$(echo "$body" | grep -c '\[FAIL\]' || true)
    send_email "[Backup] Weekly Summary: ${ok_count} OK, ${fail_count} FAIL" \
        "Backup summary for the past 7 days:\n\nSuccesses: $ok_count\nFailures: $fail_count\n\nRecent log:\n$body"
}

# ── Main ────────────────────────────────────────────
main() {
    if [ "${1:-}" = "--summary" ]; then
        send_summary
        exit 0
    fi

    log "backup" "INFO" "Starting daily backup run"

    dump_all_mariadb
    dump_all_postgres
    prune_old_dumps

    if [ -n "$FAILURES" ]; then
        log "backup" "FAIL" "Backup run completed with failures"
        send_email "[Backup] FAILURE Alert" "The following backups failed:\n\n${FAILURES}"
        exit 1
    fi

    log "backup" "OK" "Backup run completed successfully"
}

main "$@"
