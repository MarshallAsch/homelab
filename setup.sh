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
    echo "     docker compose exec firefly_db mariadb -u root -p'<password>' -e \"<SQL>\""
fi

echo ""
echo "=== Setting up PostgreSQL backup users ==="

setup_pg() {
    local service="$1" user="$2" dbname="$3"
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

setup_pg "gitea_db" "gitea" "gitea"
setup_pg "immich_db" "postgres" "immich"
setup_pg "analytics_db" "analytics" "analytics"

echo ""
echo "=== Setup complete ==="
echo "Verify by running: docker compose exec backup-manager mariadb -h mariadb -u backup_ro -p'\$BACKUP_MARIADB_PASSWORD' -e 'SELECT 1'"
