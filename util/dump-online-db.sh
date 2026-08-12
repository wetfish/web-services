#!/usr/bin/env bash
# dump-online-db.sh — Dump the production "online" forum database (SMF 2.0.12)
#
# Dumps the `forums` database from the `online-db` MariaDB container.
# Credentials are read from prod/services/online/mariadb.env (never committed).
#
# Usage:
#   ./dump-online-db.sh [output_dir]
#
# Defaults:
#   SERVICE_DIR  /opt/web-services/prod/services
#   CONTAINER    online-db
#   output_dir   /mnt/wetfish/backups/dumps

set -euo pipefail

SERVICE_DIR="${SERVICE_DIR:-/opt/web-services/prod/services}"
ONLINE_DIR="${SERVICE_DIR}/online"
CONTAINER="${CONTAINER:-online-db}"
OUTPUT_DIR="${1:-/mnt/wetfish/backups/dumps}"

log() { echo "$(date '+%F %T') - $*"; }

get_env_var() {
  local key="$1"
  local env_file="${ONLINE_DIR}/mariadb.env"

  [[ -f "$env_file" ]] || {
    echo "ERROR: env file not found: $env_file" >&2
    exit 1
  }

  grep -E "^${key}=" "$env_file" | head -1 | cut -d '=' -f2- | tr -d '"'"'
}

main() {
  command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker not found in PATH" >&2
    exit 1
  }

  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
    echo "ERROR: container '$CONTAINER' is not running" >&2
    exit 1
  }

  local db root_pass
  db=$(get_env_var "MARIADB_DATABASE")
  root_pass=$(get_env_var "MARIADB_ROOT_PASSWORD")

  [[ -n "$db" ]] || db="forums"
  [[ -n "$root_pass" ]] || {
    echo "ERROR: could not read MARIADB_ROOT_PASSWORD from mariadb.env" >&2
    exit 1
  }

  mkdir -p "$OUTPUT_DIR"

  local timestamp dump_file
  timestamp=$(date +%Y%m%d-%H%M%S)
  dump_file="${OUTPUT_DIR}/${db}-${timestamp}.sql"

  log "Dumping '${db}' from ${CONTAINER} -> ${dump_file}"
  docker exec "$CONTAINER" bash -c "MYSQL_PWD='${root_pass}' mysqldump -u root --single-transaction --quick '$db'" > "$dump_file"

  local size
  size=$(du -h "$dump_file" | cut -f1)
  log "Dump complete: ${dump_file} (${size})"
}

main "$@"
