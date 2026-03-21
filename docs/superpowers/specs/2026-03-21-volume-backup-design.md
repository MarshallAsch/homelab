# Volume Backup Design

## Problem

The homelab has ~57 services with persistent data stored in Docker volumes under `./volumes/`. There are no automated backups. A host failure, accidental deletion, or corruption would result in total data loss for all services.

## Goals

- Automated daily backups of all configuration volumes and database dumps
- Database-consistent backups via proper dump tools (not raw file copies)
- Off-site storage via Backblaze Personal Backup (unlimited, $9/mo)
- 14-day local retention for database dumps
- Failure notifications via SMTP relay; weekly success digest
- Read-only database access for the backup process

## Prerequisites

- **Host architecture must be `linux/amd64`** — the Backblaze Personal container (`tessypowder/backblaze-personal-wine`) does not support ARM.

## Non-Goals

- Backing up `mongo_botomir` (temp profile) or `unifi-db` (excluded by user)
- Backing up Redis/Valkey instances (cache-only, no persistent data worth backing up)
- Real-time / continuous backup — daily is sufficient
- Automated restore tooling (manual restore from dumps is acceptable for now)

## Architecture

Two new services added to `compose.yaml`:

```
┌──────────────────────────────────────────────────────────┐
│                      Host / Compose                       │
│                                                           │
│  ┌──────────────┐           ┌───────────────────┐         │
│  │backup-manager│───cron───▶│ ./volumes/backups/ │         │
│  │  (Alpine +   │           │     /dumps/        │         │
│  │  DB clients) │           └────────┬───────────┘         │
│  └──┬───┬───────┘                    │ (read-only)         │
│     │   │                            ▼                     │
│     │   │ smtp_internal        ┌───────────┐               │
│     │   └──▶ smtp-relay        │ backblaze │──egress──▶ Backblaze Cloud
│     │                          │ (WINE +   │               │
│     │                          │  noVNC)   │               │
│     │                          └───────────┘               │
│     │                                                      │
│     │ backup_internal (added to each DB service)           │
│     ├──▶ mariadb         (also on: internal)               │
│     ├──▶ inventory_db    (also on: inventory_internal)     │
│     ├──▶ fills_db        (also on: internal)               │
│     ├──▶ divetec_db      (also on: internal)               │
│     ├──▶ firefly_db      (also on: firefly_iii)            │
│     ├──▶ postal_db       (also on: internal)               │
│     ├──▶ gitea_db        (also on: gitea_internal)         │
│     ├──▶ immich_db       (also on: immich_internal)        │
│     └──▶ analytics_db    (also on: analytics_internal)     │
└──────────────────────────────────────────────────────────┘
```

**Network approach:** The `backup_internal` network is added as an *additional* network to each of the 8 database services. Their existing networks remain unchanged. The `backup-manager` container connects only to `backup_internal` and `smtp_internal`.

## Database Inventory

| Service | Engine | Network (existing) | Database | Backup User |
|---|---|---|---|---|
| `mariadb` | MariaDB | `internal` | all | `backup_ro` |
| `inventory_db` | MariaDB | `inventory_internal` | `${INVENTORY_DB}` | `backup_ro` |
| `fills_db` | MariaDB | `internal` | `${FILLS_DB}` | `backup_ro` |
| `divetec_db` | MariaDB | `internal` | `divetec` | `backup_ro` |
| `firefly_db` | MariaDB | `firefly_iii` | (from `.firefly.db.env`) | `backup_ro` |
| `postal_db` | MariaDB | `internal` | `${POSTAL_DB}` | `backup_ro` |
| `gitea_db` | PostgreSQL 14 | `gitea_internal` | `gitea` | `backup_ro` |
| `immich_db` | PostgreSQL 14 (vectorchord) | `immich_internal` | `immich` | `backup_ro` |
| `analytics_db` | PostgreSQL 14 | `analytics_internal` | `analytics` | `backup_ro` |

**Excluded:**
- `mongo_botomir` — temp profile, not always running
- `unifi-db` — excluded per user preference
- `authelia_redis`, `immich_redis` — cache-only, ephemeral

## Components

### 1. backup-manager Container

**Purpose:** Run daily database dumps, manage local retention, send notifications.

**Image:** Custom Dockerfile based on Alpine:

```dockerfile
FROM alpine:3.21
RUN apk add --no-cache \
    mariadb-client \
    postgresql14-client \
    curl \
    gzip \
    mailx
COPY backup.sh /usr/local/bin/backup.sh
COPY crontab /etc/crontabs/root
RUN chmod +x /usr/local/bin/backup.sh
CMD ["crond", "-f", "-l", "2"]
```

**Networks:**
- `backup_internal` — access to all 8 database containers
- `smtp_internal` — send failure/summary notifications via SMTP relay

**Volumes:**
- `${CONFIG_VOLUMES}/backups/dumps:/backups/dumps` — dump output directory

**Environment variables:**
- `BACKUP_MARIADB_PASSWORD` — shared password for `backup_ro` user across all MariaDB instances
- `BACKUP_POSTGRES_PASSWORD` — shared password for `backup_ro` user across all PostgreSQL instances
- `NOTIFICATION_EMAIL` — email address for alerts
- `SMTP_RELAY_HOST` — hostname of SMTP relay (e.g., `smtp-relay`)
- `NOTIFICATION_FROM` — sender address (must use an allowed domain: `marshallasch.ca`, `road2ir.org`, `dive-tec.ca`, or `pigilab.com`)
- `TZ` — timezone for cron scheduling

**Cron schedule:**
```crontab
# Daily database dumps at 3:00 AM
0 3 * * * /usr/local/bin/backup.sh

# Weekly success summary every Sunday at 8:00 AM
0 8 * * 0 /usr/local/bin/backup.sh --summary
```

### 2. backup.sh Script

The dump script performs these steps:

1. **For each MariaDB instance** (`mariadb`, `inventory_db`, `fills_db`, `divetec_db`, `firefly_db`, `postal_db`):
   ```
   # For main mariadb (multi-database): use --all-databases with --ignore-database for system DBs
   mariadb-dump -h mariadb -u backup_ro -p${BACKUP_MARIADB_PASSWORD} --all-databases \
     --ignore-database=information_schema --ignore-database=performance_schema \
     --ignore-database=sys | gzip > /backups/dumps/mariadb/$(date +%Y-%m-%d).sql.gz

   # For single-database instances: dump only the specific database
   mariadb-dump -h <host> -u backup_ro -p${BACKUP_MARIADB_PASSWORD} <dbname> | gzip > /backups/dumps/<service>/$(date +%Y-%m-%d).sql.gz
   ```

2. **For each PostgreSQL instance** (`gitea_db`, `immich_db`, `analytics_db`):
   ```
   PGPASSWORD=${BACKUP_POSTGRES_PASSWORD} pg_dump -h <host> -U backup_ro <dbname> | gzip > /backups/dumps/<service>/$(date +%Y-%m-%d).sql.gz
   ```

3. **Retention pruning:** Delete dump files older than 14 days:
   ```
   find /backups/dumps -name "*.gz" -mtime +14 -delete
   ```

4. **Notifications:**
   - On failure: send immediate email per failed dump via SMTP relay
   - `--summary` flag: collect results from last 7 days of logs, send weekly digest

5. **Verification:** Each dump is verified after creation:
   - `gzip -t` to confirm the archive is valid
   - Check file size is non-zero
   - Failed verification triggers a notification and skips the file (does not replace previous good dump)

Each dump is independent — a failure in one does not prevent the others from running.

**Logging:** All output goes to stdout/stderr (captured by Docker's logging driver) and is also appended to `/backups/dumps/backup.log`. Log lines are structured as `[TIMESTAMP] [SERVICE] [STATUS] message` for easy parsing. The weekly summary script parses the local log file (not `docker logs`, which would require Docker socket access).

### 3. Backblaze Personal Container

**Image:** `tessypowder/backblaze-personal-wine:latest`

**Networks:**
- `egress` — internet access for uploading to Backblaze

**Volumes (read-only data):**
- `${CONFIG_VOLUMES}:/data/volumes:ro` — all service config volumes
- `${CONFIG_VOLUMES}/backups/dumps:/data/dumps:ro` — database dumps

**Volumes (read-write, own state):**
- `${CONFIG_VOLUMES}/backblaze:/config` — WINE prefix and Backblaze client state

**Ports:**
- VNC/noVNC port exposed for initial setup and monitoring

**Initial setup:** Requires one-time interactive VNC session to:
1. Sign into Backblaze account
2. Select `/data/volumes` and `/data/dumps` as backup targets
3. Verify backup schedule is running

After initial setup, the container runs unattended.

### 4. Dedicated Backup Network

```yaml
backup_internal:
  driver: bridge
  internal: true
```

An internal-only bridge network. No external access — the backup-manager reaches databases over this network and uses `smtp_internal` separately for notifications.

### 5. Read-Only Database Users

**MariaDB** (per instance):
```sql
CREATE USER 'backup_ro'@'%' IDENTIFIED BY '<password>';
GRANT SELECT, LOCK TABLES ON *.* TO 'backup_ro'@'%';
FLUSH PRIVILEGES;
```

**PostgreSQL** (per instance):
```sql
CREATE ROLE backup_ro LOGIN PASSWORD '<password>';
GRANT pg_read_all_data TO backup_ro;
```

A `setup.sh` script will contain `docker compose exec` commands to create these users across all 8 databases.

**Superuser credentials for setup (one-time use):**

| Service | Image | Connect as | Notes |
|---|---|---|---|
| `mariadb` | `linuxserver/mariadb` | root (no password by default) | Uses `/config` data dir |
| `inventory_db` | `linuxserver/mariadb` | root (no password) | |
| `fills_db` | `linuxserver/mariadb` | root (no password) | |
| `divetec_db` | `linuxserver/mariadb` | root (no password) | |
| `firefly_db` | `linuxserver/mariadb` | root (no password) | DB name sourced from `.firefly.db.env` |
| `postal_db` | `linuxserver/mariadb` | root (no password) | |
| `gitea_db` | `postgres:14-alpine` | `gitea` / `${GITEA_DB_PASSWORD}` | Standard postgres image |
| `immich_db` | `immich-app/postgres` | `postgres` / `${IMMICH_DB_PASSWORD}` | Superuser is `postgres` |
| `analytics_db` | `postgres:14-alpine` | `analytics` / `${ANALYTICS_DB_PASSWORD}` | Standard postgres image |

Note: `linuxserver/mariadb` containers run MariaDB with `mariadb` client available inside the container at the default path. The `setup.sh` uses `docker compose exec <service> mariadb -u root` to connect.

## New / Modified Files

**New files:**
- `volumes/backup-manager/Dockerfile` — Alpine image with DB clients
- `volumes/backup-manager/backup.sh` — Dump + retention + notification script
- `volumes/backup-manager/crontab` — Cron schedule
- `setup.sh` — One-time `docker compose exec` commands for read-only user creation

**Modified files:**
- `compose.yaml` — Add `backup-manager`, `backblaze` services; add `backup_internal` network; add `backup_internal` network to 8 database services
- `env.template` — Add `BACKUP_MARIADB_PASSWORD`, `BACKUP_POSTGRES_PASSWORD`, `NOTIFICATION_EMAIL`, `NOTIFICATION_FROM`, `SMTP_RELAY_HOST`

## Dump Directory Structure

```
volumes/backups/dumps/
├── mariadb/
│   ├── 2026-03-21.sql.gz
│   └── ...
├── inventory_db/
│   ├── 2026-03-21.sql.gz
│   └── ...
├── fills_db/
├── divetec_db/
├── firefly_db/
├── postal_db/
├── gitea_db/
├── immich_db/
└── analytics_db/
```

## Security Considerations

- Backup database users are read-only (`SELECT` + `LOCK TABLES` only)
- Backup network is internal-only (no external routing)
- Config volumes mounted read-only into the Backblaze container
- Database credentials for backup user stored in `.env` (same pattern as existing credentials)
- Backblaze container has internet access via `egress` but no access to internal services

## Implementation Notes

- The main `mariadb` service will be dumped with `--all-databases`. System databases (`information_schema`, `performance_schema`) are excluded via `--ignore-database` flags to avoid restore conflicts.
- PostgreSQL dumps use `pg_dump` per database (not `pg_dumpall`). Cluster-level objects (roles, tablespaces) are not backed up — this is acceptable since the only non-default role is `backup_ro` itself, which is recreated by `setup.sh`.
- The `firefly_db` database name must be read from `.firefly.db.env` during implementation and hardcoded in the backup script.
- The backup script should include connection retry logic (5 attempts, 30s interval) per database to handle cold starts after host restarts. No `depends_on` is needed since the cron schedule provides a natural delay — databases will be long running before 3:00 AM in normal operation.
- The `firefly_db` instance uses a non-standard volume mount (`/var/lib/mysql` instead of `/config`). Root access may require a password set in `.firefly.db.env` — `setup.sh` should attempt passwordless root first and prompt if it fails.
