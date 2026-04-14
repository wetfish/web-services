#!/usr/bin/env bash
# streamlined-backups.sh — Efficient MariaDB backup & S3 sync
# Eliminates redundant tarballs and implements automatic rotation

set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/wetfish/backups}"
SERVICE_DIR="${SERVICE_DIR:-/opt/web-services/prod/services}"
# S3_REMOTE="${S3_REMOTE:wetfish-backups}"
ALLOWED_SERVICES=("wiki" "online" "click" "danger")
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"

# ----------- Utilities -----------

log() { echo "$(date '+%F %T') - $*"; }
debug() { [[ "$DEBUG" == "1" ]] && log "[DEBUG] $*"; }

require_cmds() {
  for cmd in docker rclone uuidgen mysqldump sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Missing required command: $cmd" >&2; exit 1;
    }
  done
}

get_env_var() {
  local service="$1" key="$2"
  local env_file="$SERVICE_DIR/$service/mariadb.env"
  [[ -f "$env_file" ]] || return
  grep -E "^${key}=" "$env_file" | cut -d '=' -f2- || true
}

get_database_name() {
  local db
  db=$(get_env_var "$1" "MARIADB_DATABASE" | tr -d '"'"'" )
  if [[ -n "$db" ]]; then
    echo "$db"
  else
    case "$1" in
      wiki) echo "wiki" ;;
      online) echo "forums" ;;
      *) echo "" ;;
    esac
  fi
}

is_allowed_service() {
  local svc="$1"
  for allowed in "${ALLOWED_SERVICES[@]}"; do
    [[ "$svc" == "$allowed" ]] && return 0
  done
  return 1
}

# ----------- Main Backup Logic -----------

main() {
  require_cmds

  local timestamp backup_dir
  timestamp=$(date +%Y-%m-%d)
  backup_dir="${BACKUP_ROOT}/${timestamp}"
  mkdir -p "$backup_dir"

  log "Starting backup run ($timestamp)..."

  local containers
  containers=$(docker ps --filter ancestor=mariadb:10.10 --format "{{.Names}}")

  if [[ -z "$containers" ]]; then
    log "No MariaDB containers running. Nothing to backup."
  fi

  for container in $containers; do
    if [[ "$container" =~ ^(.+)-db$ ]]; then
      service="${BASH_REMATCH[1]}"
    else
      log "Skipping unrecognized container name: $container"
      continue
    fi

    if ! is_allowed_service "$service"; then
      log "Skipping service '$service' (not in allowlist)"
      continue
    fi

    db=$(get_database_name "$service")
    root_pass=$(get_env_var "$service" "MARIADB_ROOT_PASSWORD")

    if [[ -z "$db" || -z "$root_pass" ]]; then
      log "Skipping $service: missing db or password"
      continue
    fi

    local dump_file="${backup_dir}/${service}-${db}-${timestamp}.sql"
    log "Dumping $db from $container to $dump_file..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY RUN] Would dump $db from $container"
      continue
    fi

    docker exec "$container" bash -c "MYSQL_PWD='${root_pass}' mysqldump -u root '$db'" > "$dump_file"
    sha256sum "$dump_file" > "${dump_file}.sha256"

    log "Uploading $db backup to S3..."
    rclone copy --s3-no-check-bucket "$dump_file" vultr-s3:wetfish-backups/databases/$timestamp/
    rclone copy --s3-no-check-bucket "${dump_file}.sha256" vultr-s3:wetfish-backups/databases/$timestamp/

    rm -f "$dump_file" "${dump_file}.sha256"
    log "$db backup complete and local copy removed."
  done

  # -------- Upload Wiki Uploads --------
  if [[ -d /opt/web-services/prod/services/wiki/upload ]]; then
    log "Syncing wiki uploads to S3..."
    rclone copy --s3-no-check-bucket /opt/web-services/prod/services/wiki/upload/ vultr-s3:wetfish-uploads --checksum
  else
    log "WARNING: /opt/web-services/prod/services/wiki/upload not found."
  fi

  # -------- Cleanup Old Backups --------
  log "Pruning backups older than ${RETENTION_DAYS} days..."
  find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} +

  # -------- Write Prometheus Metric --------
  local textfile_dir="/var/lib/node_exporter/textfile_collector"
  if [[ -d "$textfile_dir" ]]; then
    echo "# HELP backup_last_success_timestamp Unix timestamp of last successful backup run" > "${textfile_dir}/backup.prom"
    echo "# TYPE backup_last_success_timestamp gauge" >> "${textfile_dir}/backup.prom"
    echo "backup_last_success_timestamp $(date +%s)" >> "${textfile_dir}/backup.prom"
    log "Wrote backup metric to ${textfile_dir}/backup.prom"
  fi

  log "Backup cycle completed successfully."
}

main "$@"
