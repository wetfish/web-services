#!/usr/bin/env bash
# test-backups.sh — Legacy backup script (stale, not in cron)
# WARNING: This script has stale paths (web-services-cybaxx) and is NOT actively used.
# Retained for reference. See improved-backups.sh for the active backup script.

set -euo pipefail

BACKUP_ROOT="/mnt/wetfish/backups"
SERVICE_DIR="/opt/web-services-cybaxx/prod/services"
DRY_RUN=0
DEBUG="${DEBUG:-0}"

ALLOWED_SERVICES=("wiki" "online" "click" "danger")

log() {
  local ts
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$ts - $*"
}

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$ts - [DEBUG] $*"
  fi
}

get_env_var() {
  local service="$1" key="$2"
  local env_file="$SERVICE_DIR/$service/mariadb.env"
  if [[ -f "$env_file" ]]; then
    grep -E "^${key}=" "$env_file" | cut -d '=' -f2- || true
  fi
}

get_mariadb_root_password() {
  local pass
  pass=$(get_env_var "$1" "MARIADB_ROOT_PASSWORD")
  debug "Root password for '$1': ${pass:+<hidden>}"
  echo "$pass"
}

get_database_name() {
  case "$1" in
    wiki) echo "wiki" ;;
    click|danger) echo "fishy" ;;
    online) echo "forums" ;;
    *) echo "" ;;
  esac
}

is_allowed_service() {
  local svc="$1"
  for allowed in "${ALLOWED_SERVICES[@]}"; do
    if [[ "$svc" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

main() {
  local timestamp unique_id backup_dir
  timestamp=$(date +%Y-%m-%d)
  unique_id=$(uuidgen)
  backup_dir="${BACKUP_ROOT}/${timestamp}-service-backups-${unique_id}"

  mkdir -p "$backup_dir"
  log "Created backup directory $backup_dir"

  local containers
  containers=$(docker ps --filter ancestor=mariadb:10.10 --format "{{.Names}}")

  if [[ -z "$containers" ]]; then
    log "No MariaDB containers running. Nothing to backup."
    exit 0
  fi

  for container in $containers; do
    if [[ "$container" =~ ^(.+)-db$ ]]; then
      service="${BASH_REMATCH[1]}"
    else
      log "Skipping unrecognized container name format: $container"
      continue
    fi

    if ! is_allowed_service "$service"; then
      log "Skipping service '$service' (not in allowlist)"
      continue
    fi

    local db root_pass
    db=$(get_database_name "$service")
    root_pass=$(get_mariadb_root_password "$service")

    if [[ -z "$db" || -z "$root_pass" ]]; then
      log "Skipping $service: missing database name or root password"
      continue
    fi

    log "Dumping database '$db' from container '$container'..."

    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[DRY RUN] docker exec $container mysqldump -u root -p<REDACTED> $db > $backup_dir/${db}-backup-${timestamp}.sql"
      continue
    fi

    if docker exec "$container" mysqldump -u root -p"$root_pass" "$db" \
      > "$backup_dir/${db}-backup-${timestamp}.sql"; then
      log "Database '$db' dumped successfully."
    else
      log "ERROR: Failed to dump $db from $container"
      continue
    fi
  done

  log "Archiving uploads..."
  if [[ -d /mnt/wetfish/wiki/uploads ]]; then
    tar czf "$backup_dir/wiki-uploads-${timestamp}.tar.gz" -C /mnt/wetfish/wiki/uploads .
    log "Uploads archived."
  else
    log "WARNING: /mnt/wetfish/wiki/uploads not found or not mounted!"
  fi

  log "Creating tarball..."
  tar czf "${backup_dir}.tar.gz" -C "$BACKUP_ROOT" "$(basename "$backup_dir")"

  log "Computing checksum..."
  sha256sum "${backup_dir}.tar.gz" > "${backup_dir}.sha256"

  log "Uploading to S3..."
  rclone --s3-no-check-bucket copy "${backup_dir}.tar.gz" vultr-s3:wetfish-backups/
  rclone --s3-no-check-bucket copy "${backup_dir}.sha256" vultr-s3:wetfish-backups/

  log "Backup complete. Stored at ${backup_dir}.tar.gz and uploaded to S3."
}

main "$@"
