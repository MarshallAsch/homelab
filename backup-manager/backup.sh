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
    printf "From: %s\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n%s" \
        "$NOTIFICATION_FROM" "$NOTIFICATION_EMAIL" "$subject" "$body" \
    | msmtp "$NOTIFICATION_EMAIL"
}

html_wrap() {
    local title="$1" content="$2"
    cat <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f4f4f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f7;padding:24px 0;">
<tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.1);">
<tr><td style="background:#1a1a2e;padding:20px 24px;">
  <h1 style="margin:0;color:#ffffff;font-size:18px;font-weight:600;">$title</h1>
</td></tr>
<tr><td style="padding:24px;">
$content
</td></tr>
<tr><td style="padding:16px 24px;background:#f8f8fa;border-top:1px solid #e8e8ed;color:#8e8ea0;font-size:12px;">
  Homelab Backup Manager &middot; $(date '+%Y-%m-%d %H:%M:%S')
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>
EOF
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
    dump_postgres "inventory_db" "inventory_db" "${INVENTORY_DB:-inventory}" || true
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
        local content
        content=$(html_wrap "Weekly Backup Summary" "<p style=\"color:#666;\">No backup log found.</p>")
        send_email "[Backup] Weekly Summary" "$content"
        return
    fi
    local week_ago
    week_ago=$(date -u -d "@$(($(date +%s) - 604800))" '+%Y-%m-%d')
    local logs
    logs=$(awk -v since="$week_ago" '$0 >= "["since {print}' "$LOG_FILE" | tail -200)
    local ok_count fail_count warn_count
    ok_count=$(echo "$logs" | grep -c '\[OK\]' || true)
    fail_count=$(echo "$logs" | grep -c '\[FAIL\]' || true)
    warn_count=$(echo "$logs" | grep -c '\[WARN\]' || true)

    local status_color status_label
    if [ "$fail_count" -gt 0 ]; then
        status_color="#dc2626"; status_label="Issues Detected"
    else
        status_color="#16a34a"; status_label="All Healthy"
    fi

    local log_rows=""
    log_rows=$(echo "$logs" | grep -v '^\s*$' | tail -30 | while IFS= read -r line; do
        local row_color="#f0fdf4" row_icon="&#9989;"
        case "$line" in
            *"[FAIL]"*) row_color="#fef2f2"; row_icon="&#10060;" ;;
            *"[WARN]"*) row_color="#fffbeb"; row_icon="&#9888;&#65039;" ;;
            *"[INFO]"*) row_color="#f0f9ff"; row_icon="&#8505;&#65039;" ;;
        esac
        local escaped_line
        escaped_line=$(echo "$line" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
        echo "<tr><td style=\"padding:6px 10px;background:$row_color;font-size:12px;font-family:monospace;border-bottom:1px solid #f0f0f3;\">$row_icon $escaped_line</td></tr>"
    done)

    local content
    content=$(cat <<INNER
<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:20px;">
<tr>
  <td width="33%" style="padding:12px;text-align:center;background:#f0fdf4;border-radius:6px;">
    <div style="font-size:28px;font-weight:700;color:#16a34a;">$ok_count</div>
    <div style="font-size:12px;color:#666;text-transform:uppercase;">Successful</div>
  </td>
  <td width="8"></td>
  <td width="33%" style="padding:12px;text-align:center;background:#fef2f2;border-radius:6px;">
    <div style="font-size:28px;font-weight:700;color:#dc2626;">$fail_count</div>
    <div style="font-size:12px;color:#666;text-transform:uppercase;">Failed</div>
  </td>
  <td width="8"></td>
  <td width="33%" style="padding:12px;text-align:center;background:#fffbeb;border-radius:6px;">
    <div style="font-size:28px;font-weight:700;color:#d97706;">$warn_count</div>
    <div style="font-size:12px;color:#666;text-transform:uppercase;">Warnings</div>
  </td>
</tr>
</table>

<div style="background:${status_color}11;border-left:4px solid ${status_color};padding:10px 14px;border-radius:0 6px 6px 0;margin-bottom:20px;">
  <span style="color:${status_color};font-weight:600;">Status: ${status_label}</span>
</div>

<h2 style="font-size:14px;color:#1a1a2e;margin:0 0 8px 0;">Recent Activity</h2>
<table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e8e8ed;border-radius:6px;overflow:hidden;">
$log_rows
</table>
INNER
    )

    send_email "[Backup] Weekly Summary: ${ok_count} OK, ${fail_count} FAIL" \
        "$(html_wrap "Weekly Backup Summary" "$content")"
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
        local rows
        rows=$(echo "$FAILURES" | grep -v '^\s*$' | while IFS=: read -r svc msg; do
            echo "<tr><td style=\"padding:8px 12px;border-bottom:1px solid #f0f0f3;font-weight:500;\">$svc</td><td style=\"padding:8px 12px;border-bottom:1px solid #f0f0f3;color:#666;\">$msg</td></tr>"
        done)
        local content
        content=$(cat <<INNER
<div style="background:#fef2f2;border:1px solid #fecaca;border-radius:6px;padding:12px 16px;margin-bottom:16px;">
  <span style="color:#dc2626;font-weight:600;">&#9888; One or more backups failed</span>
</div>
<table width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">
<tr style="background:#f8f8fa;">
  <th style="padding:8px 12px;text-align:left;font-size:12px;text-transform:uppercase;color:#8e8ea0;">Service</th>
  <th style="padding:8px 12px;text-align:left;font-size:12px;text-transform:uppercase;color:#8e8ea0;">Error</th>
</tr>
$rows
</table>
INNER
        )
        send_email "[Backup] FAILURE Alert" "$(html_wrap "Backup Failure Report" "$content")"
        exit 1
    fi

    log "backup" "OK" "Backup run completed successfully"
}

main "$@"
