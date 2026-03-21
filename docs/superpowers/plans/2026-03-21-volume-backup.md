# Volume Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automated daily database dumps and off-site backup of all homelab config volumes via Backblaze Personal.

**Architecture:** A `backup-manager` container (Alpine + DB clients + cron) dumps 8 databases daily to a shared volume. A `backblaze` container (Backblaze Personal via WINE) picks up dumps + config volumes and uploads to Backblaze cloud. A dedicated `backup_internal` network connects the backup-manager to all databases without touching their existing network isolation.

**Tech Stack:** Docker Compose, Alpine Linux, mariadb-client, postgresql14-client, `boky/postfix` SMTP relay, `tessypowder/backblaze-personal-wine`

**Spec:** `docs/superpowers/specs/2026-03-21-volume-backup-design.md`

---

### Task 1: Add `backup_internal` network definition

**Files:**
- Modify: `compose.yaml:1162-1196` (networks section)

- [ ] **Step 1: Add the network definition**

Add `backup_internal` after `smtp_internal` (line 1184) in the networks section:

```yaml
  backup_internal:
    internal: true
```

- [ ] **Step 2: Validate compose syntax**

Run: `docker compose config --quiet`
Expected: No output (exit 0)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "chore: add backup_internal network definition"
```

---

### Task 2: Add `backup_internal` network to all 8 database services

**Files:**
- Modify: `compose.yaml:8-130` (database service definitions)

Each database service needs `backup_internal` added to its networks list. The existing networks must remain unchanged.

- [ ] **Step 1: Add `backup_internal` to `mariadb` (line ~10)**

```yaml
  mariadb:
    image: linuxserver/mariadb
    networks:
      - internal
      - backup_internal
```

- [ ] **Step 2: Add `backup_internal` to `inventory_db` (line ~22)**

```yaml
    networks:
      - inventory_internal
      - backup_internal
```

- [ ] **Step 3: Add `backup_internal` to `fills_db` (line ~37)**

```yaml
    networks:
      - internal
      - backup_internal
```

- [ ] **Step 4: Add `backup_internal` to `divetec_db` (line ~52)**

```yaml
    networks:
      - internal
      - backup_internal
```

- [ ] **Step 5: Add `backup_internal` to `gitea_db` (line ~68)**

```yaml
    networks:
      - gitea_internal
      - backup_internal
```

- [ ] **Step 6: Add `backup_internal` to `immich_db` (line ~79)**

```yaml
    networks:
      - immich_internal
      - backup_internal
```

- [ ] **Step 7: Add `backup_internal` to `firefly_db` (line ~98)**

```yaml
    networks:
      - firefly_iii
      - backup_internal
```

- [ ] **Step 8: Add `backup_internal` to `postal_db` (line ~105)**

```yaml
    networks:
      - internal
      - backup_internal
```

- [ ] **Step 9: Add `backup_internal` to `analytics_db` (line ~121)**

```yaml
    networks:
      - analytics_internal
      - backup_internal
```

- [ ] **Step 10: Validate compose syntax**

Run: `docker compose config --quiet`
Expected: No output (exit 0)

- [ ] **Step 11: Commit**

```bash
git add compose.yaml
git commit -m "chore: add backup_internal network to all 8 database services"
```

---

### Task 3: Add backup env vars to `env.template`

**Files:**
- Modify: `env.template` (append to end)

- [ ] **Step 1: Add backup-related env vars**

Append to `env.template`:

```
# Backup configuration
BACKUP_MARIADB_PASSWORD=
BACKUP_POSTGRES_PASSWORD=
NOTIFICATION_EMAIL=
NOTIFICATION_FROM=
SMTP_RELAY_HOST=smtp-relay
```

- [ ] **Step 2: Commit**

```bash
git add env.template
git commit -m "chore: add backup env vars to env.template"
```

---

### Task 4: Create the backup-manager Dockerfile

**Files:**
- Create: `volumes/backup-manager/Dockerfile`

- [ ] **Step 1: Create the directory**

Run: `mkdir -p volumes/backup-manager`

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
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
```

Note: Using `msmtp` instead of `mailx` — it's a lightweight SMTP client available in Alpine that works well with relay hosts. `mailx` (from `s-nail` or `heirloom-mailx`) has more complex dependencies.

- [ ] **Step 3: Commit**

```bash
git add volumes/backup-manager/Dockerfile
git commit -m "feat: add backup-manager Dockerfile"
```

---

### Task 5: Create the crontab file

**Files:**
- Create: `volumes/backup-manager/crontab`

- [ ] **Step 1: Write the crontab**

```crontab
# Daily database dumps at 3:00 AM
0 3 * * * /usr/local/bin/backup.sh 2>&1

# Weekly success summary every Sunday at 8:00 AM
0 8 * * 0 /usr/local/bin/backup.sh --summary 2>&1
```

- [ ] **Step 2: Commit**

```bash
git add volumes/backup-manager/crontab
git commit -m "feat: add backup-manager crontab schedule"
```

---

### Task 6: Create the backup.sh script — helper functions

**Files:**
- Create: `volumes/backup-manager/backup.sh`

This task creates the script skeleton with logging, notification, retry, and verification helpers. The actual dump logic comes in Task 7.

- [ ] **Step 1: Write the script skeleton**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add volumes/backup-manager/backup.sh
git commit -m "feat: add backup.sh helper functions"
```

---

### Task 7: Create the backup.sh script — dump logic and main flow

**Files:**
- Modify: `volumes/backup-manager/backup.sh`

Append the MariaDB dump, PostgreSQL dump, retention pruning, notification, and summary functions to the script.

- [ ] **Step 1: Look up the firefly_db database name**

Read `.firefly.db.env` on the server to find the `MYSQL_DATABASE` value. If the file isn't in the repo, check the running container or ask the user. For the plan, we'll use a placeholder `FIREFLY_DB_NAME` that must be replaced during implementation.

- [ ] **Step 2: Append the dump functions**

Append to `volumes/backup-manager/backup.sh`:

```bash
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
    week_ago=$(date -u -D '%s' -d "$(($(date +%s) - 604800))" '+%Y-%m-%d')
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
```

- [ ] **Step 3: Verify the script has valid shell syntax**

Run: `sh -n volumes/backup-manager/backup.sh`
Expected: No output (exit 0)

- [ ] **Step 4: Commit**

```bash
git add volumes/backup-manager/backup.sh
git commit -m "feat: add backup.sh dump logic and main flow"
```

---

### Task 8: Add `backup-manager` service to compose.yaml

**Files:**
- Modify: `compose.yaml` (add service in the services section, after `smtp-relay` around line 562)

- [ ] **Step 1: Add the service definition**

Add after the `smtp-relay` service block:

```yaml
  backup-manager:
    build: ${CONFIG_VOLUMES}/backup-manager
    networks:
      - backup_internal
      - smtp_internal
    volumes:
      - ${CONFIG_VOLUMES}/backups/dumps:/backups/dumps
    environment:
      - TZ
      - BACKUP_MARIADB_PASSWORD
      - BACKUP_POSTGRES_PASSWORD
      - NOTIFICATION_EMAIL
      - NOTIFICATION_FROM
      - SMTP_RELAY_HOST
      - INVENTORY_DB
      - FILLS_DB
      - POSTAL_DB
      - FIREFLY_DB_NAME
    depends_on:
      - smtp-relay
    restart: unless-stopped
```

Note: `INVENTORY_DB`, `FILLS_DB`, `POSTAL_DB` are passed through so the backup script can use the correct database names. `FIREFLY_DB_NAME` must be added to `.env` with the value from `.firefly.db.env`'s `MYSQL_DATABASE` field — determine this during Task 7 Step 1 and add it to both `.env` and `env.template`.

- [ ] **Step 2: Validate compose syntax**

Run: `docker compose config --quiet`
Expected: No output (exit 0)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add backup-manager service to compose"
```

---

### Task 9: Add `backblaze` service to compose.yaml

**Files:**
- Modify: `compose.yaml` (add service after `backup-manager`)

- [ ] **Step 1: Add the service definition**

```yaml
  backblaze:
    image: tessypowder/backblaze-personal-wine:latest
    networks:
      - egress
    volumes:
      - ${CONFIG_VOLUMES}:/data/volumes:ro
      - ${CONFIG_VOLUMES}/backups/dumps:/data/dumps:ro
      - ${CONFIG_VOLUMES}/backblaze:/config
    environment:
      - TZ
    ports:
      - "5800:5800"
    restart: unless-stopped
```

Port 5800 is the noVNC web UI for initial Backblaze setup.

- [ ] **Step 2: Validate compose syntax**

Run: `docker compose config --quiet`
Expected: No output (exit 0)

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "feat: add backblaze personal backup service to compose"
```

---

### Task 10: Create `setup.sh` for read-only database user provisioning

**Files:**
- Create: `setup.sh`

This script is run once by the user to create `backup_ro` users on all databases. It must be run after the `backup_internal` network is created (i.e., after `docker compose up` has been run at least once with the new network).

- [ ] **Step 1: Write setup.sh**

```bash
#!/bin/bash
set -euo pipefail

# ── Volume Backup: Read-Only User Setup ─────────────
#
# Run this script once after adding the backup_internal network
# and restarting the database containers.
#
# Usage: ./setup.sh
#
# Requires: .env file with BACKUP_MARIADB_PASSWORD, BACKUP_POSTGRES_PASSWORD,
#           GITEA_DB_PASSWORD, IMMICH_DB_PASSWORD, ANALYTICS_DB_PASSWORD

if [ ! -f .env ]; then
    echo "ERROR: .env file not found. Copy env.template to .env and fill in values first."
    exit 1
fi

# shellcheck disable=SC1091
source .env

if [ -z "${BACKUP_MARIADB_PASSWORD:-}" ] || [ -z "${BACKUP_POSTGRES_PASSWORD:-}" ]; then
    echo "ERROR: BACKUP_MARIADB_PASSWORD and BACKUP_POSTGRES_PASSWORD must be set in .env"
    exit 1
fi

MARIADB_SQL="CREATE USER IF NOT EXISTS 'backup_ro'@'%' IDENTIFIED BY '${BACKUP_MARIADB_PASSWORD}';
GRANT SELECT, LOCK TABLES ON *.* TO 'backup_ro'@'%';
FLUSH PRIVILEGES;"

POSTGRES_SQL="DO \\\$\\\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup_ro') THEN
        CREATE ROLE backup_ro LOGIN PASSWORD '${BACKUP_POSTGRES_PASSWORD}';
        GRANT pg_read_all_data TO backup_ro;
    END IF;
END
\\\$\\\$;"

echo "=== Setting up MariaDB backup users ==="

for service in mariadb inventory_db fills_db divetec_db postal_db; do
    echo "  -> $service"
    if docker compose exec -T "$service" mariadb -u root -e "$MARIADB_SQL" 2>/dev/null; then
        echo "     OK"
    else
        echo "     WARN: passwordless root failed, trying with empty password flag..."
        if docker compose exec -T "$service" mariadb -u root -p'' -e "$MARIADB_SQL" 2>/dev/null; then
            echo "     OK (with empty password)"
        else
            echo "     FAIL: could not connect as root. Check root credentials for $service."
        fi
    fi
done

# firefly_db may need a root password from .firefly.db.env
echo "  -> firefly_db"
if docker compose exec -T firefly_db mariadb -u root -e "$MARIADB_SQL" 2>/dev/null; then
    echo "     OK"
else
    echo "     WARN: passwordless root failed for firefly_db."
    echo "     Check .firefly.db.env for MYSQL_ROOT_PASSWORD and run manually:"
    echo "     docker compose exec firefly_db mariadb -u root -p'<password>' -e \"$MARIADB_SQL\""
fi

echo ""
echo "=== Setting up PostgreSQL backup users ==="

setup_pg() {
    local service="$1" user="$2" password_var="$3" dbname="$4"
    local password="${!password_var}"
    echo "  -> $service"
    if docker compose exec -T "$service" psql -U "$user" -d "$dbname" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup_ro') THEN
        CREATE ROLE backup_ro LOGIN PASSWORD '${BACKUP_POSTGRES_PASSWORD}';
        GRANT pg_read_all_data TO backup_ro;
    END IF;
END
\$\$;" 2>/dev/null; then
        echo "     OK"
    else
        echo "     FAIL: could not connect to $service as $user"
    fi
}

setup_pg "gitea_db" "gitea" "GITEA_DB_PASSWORD" "gitea"
setup_pg "immich_db" "postgres" "IMMICH_DB_PASSWORD" "immich"
setup_pg "analytics_db" "analytics" "ANALYTICS_DB_PASSWORD" "analytics"

echo ""
echo "=== Setup complete ==="
echo "Verify by running: docker compose exec backup-manager mariadb -h mariadb -u backup_ro -p'\$BACKUP_MARIADB_PASSWORD' -e 'SELECT 1'"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x setup.sh`

- [ ] **Step 3: Verify shell syntax**

Run: `bash -n setup.sh`
Expected: No output (exit 0)

- [ ] **Step 4: Commit**

```bash
git add setup.sh
git commit -m "feat: add setup.sh for backup read-only user provisioning"
```

---

### Task 11: Verify `.gitignore` covers backup dumps

**Files:**
- Check: `.gitignore`

- [ ] **Step 1: Confirm `volumes` is already in `.gitignore`**

The existing `.gitignore` already contains `volumes` on line 3, which covers `volumes/backups/dumps/`. No changes needed. Skip this task.

---

### Task 12: Configure msmtp for the backup-manager container

**Files:**
- Create: `volumes/backup-manager/msmtprc`
- Modify: `volumes/backup-manager/Dockerfile`

The `msmtp` client needs a config file to know which relay host to use. We'll template it using env vars at container startup.

- [ ] **Step 1: Create msmtprc template**

Create `volumes/backup-manager/msmtprc`:

```
account default
host SMTP_RELAY_HOST_PLACEHOLDER
port 587
from NOTIFICATION_FROM_PLACEHOLDER
auth off
tls off
```

Note: `auth off` and `tls off` because the relay is internal (no auth needed for `boky/postfix` on the internal network).

- [ ] **Step 2: Update the Dockerfile to use an entrypoint that templates the config**

Create `volumes/backup-manager/entrypoint.sh`:

```bash
#!/bin/sh
# Template msmtp config with env vars
sed -e "s|SMTP_RELAY_HOST_PLACEHOLDER|${SMTP_RELAY_HOST}|g" \
    -e "s|NOTIFICATION_FROM_PLACEHOLDER|${NOTIFICATION_FROM}|g" \
    /etc/msmtprc.template > /etc/msmtprc

exec "$@"
```

- [ ] **Step 3: Update Dockerfile**

Update the Dockerfile to copy msmtprc and use the entrypoint:

```dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    mariadb-client \
    postgresql14-client \
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
```

- [ ] **Step 4: Update backup.sh `send_email` function**

Replace the `send_email` function to use `msmtp` via its config file (simpler invocation):

```bash
send_email() {
    local subject="$1" body="$2"
    printf "From: %s\nTo: %s\nSubject: %s\n\n%s" \
        "$NOTIFICATION_FROM" "$NOTIFICATION_EMAIL" "$subject" "$body" \
    | msmtp "$NOTIFICATION_EMAIL"
}
```

- [ ] **Step 5: Commit**

```bash
git add volumes/backup-manager/msmtprc volumes/backup-manager/entrypoint.sh volumes/backup-manager/Dockerfile volumes/backup-manager/backup.sh
git commit -m "feat: add msmtp config and entrypoint for backup notifications"
```

---

### Task 13: End-to-end verification

This task is manual — run on the actual homelab host after deploying.

- [ ] **Step 1: Copy env.template values to .env**

Ensure `BACKUP_MARIADB_PASSWORD`, `BACKUP_POSTGRES_PASSWORD`, `NOTIFICATION_EMAIL`, `NOTIFICATION_FROM`, and `SMTP_RELAY_HOST` are set in `.env`.

- [ ] **Step 2: Bring up the new services**

Run: `docker compose up -d mariadb inventory_db fills_db divetec_db firefly_db postal_db gitea_db immich_db analytics_db backup-manager backblaze`

- [ ] **Step 3: Run setup.sh to create backup users**

Run: `./setup.sh`
Expected: "OK" for each database service.

- [ ] **Step 4: Test a manual backup run**

Run: `docker compose exec backup-manager /usr/local/bin/backup.sh`
Expected: Log lines for each database with `[OK]` status. Check `volumes/backups/dumps/` for `.sql.gz` files.

- [ ] **Step 5: Verify dump files are valid**

Run: `for f in volumes/backups/dumps/*/*.sql.gz; do echo "$f: $(gzip -t "$f" && echo OK || echo FAIL)"; done`
Expected: All files show OK.

- [ ] **Step 6: Test email notification**

Temporarily break a dump (e.g., wrong password) and run the backup script again to confirm failure email is sent. Then fix and re-run.

- [ ] **Step 7: Set up Backblaze via VNC**

Open `http://<host-ip>:5800` in a browser. Sign into Backblaze, select `/data/volumes` and `/data/dumps` as backup directories. Verify initial backup starts.

- [ ] **Step 8: Verify Backblaze is uploading**

Check the Backblaze web dashboard to confirm files are appearing.
