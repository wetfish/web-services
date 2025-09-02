#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/mnt/wetfish/backups"
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

usage() {
  echo "Usage: $0 [--dry-run]"
  echo "Set DEBUG=1 to enable debug output"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $arg"; usage ;;
  esac
done

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

get_mariadb_user_password() {
  local pass
  pass=$(get_env_var "$1" "MARIADB_PASSWORD")
  debug "User password for '$1': ${pass:+<hidden>}"
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

apply_backup() {
  local service="$1" container="$2" db="$3" backup_file="$4"

  local root_pass user_pass
  root_pass=$(get_mariadb_root_password "$service")
  user_pass=$(get_mariadb_user_password "$service")

  if [[ -z "$root_pass" ]]; then
    log "ERROR: No root password found for $service"
    return 1
  fi

  log "Applying backup for service '$service' to database '$db' in container '$container'..."

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] cat $backup_file | docker exec -i $container mysql -u root -p<REDACTED> $db"
    echo "[DRY RUN] docker exec $container mysqlcheck -u root -p<REDACTED> --databases $db"
    return 0
  fi

  #DEBUG log $root_pass
  #DEBUG log $backup_file

  # Try with root credentials, stream output live
  if cat "$backup_file" | docker exec -i "$container" mysql -u root -p"$root_pass" "$db"; then
    log "Backup successfully applied using root credentials."
  else
    log "Root credentials backup failed, trying user credentials..."

    if [[ -n "$user_pass" ]]; then
      if cat "$backup_file" | docker exec -i "$container" mysql -u "$service" -p"$user_pass" "$db"; then
        log "Backup successfully applied using user credentials."
      else
        log "ERROR: Backup failed using both root and user credentials."
        return 1
      fi
    else
      log "ERROR: No user password found; cannot retry without it."
      return 1
    fi
  fi

  log "Running mysqlcheck on $db..."

  if docker exec "$container" mysqlcheck -u root -p"$root_pass" --databases "$db"; then
    log "mysqlcheck passed for $db"
  else
    log "WARNING: mysqlcheck failed or returned warnings for $db"
  fi
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

find_latest_backup_dir() {
  shopt -s nullglob
  local dirs=( "$BACKUP_DIR"/[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]-service-backups-????????-????-????-????-???????????? )
  shopt -u nullglob

  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo ""
    return 1
  fi

  printf '%s\n' "${dirs[@]}" | sort -V | tail -n 1
}

main() {
  log "--- Starting MariaDB Restore Process ---"

  local latest_backup_dir
  latest_backup_dir=$(find_latest_backup_dir) || {
    log "No backup directories found matching pattern. Exiting."
    exit 1
  }

  debug "Using latest backup directory: $latest_backup_dir"

  local containers
  containers=$(docker ps --filter ancestor=mariadb:10.10 --format "{{.Names}}")

  if [[ -z "$containers" ]]; then
    log "No MariaDB containers running. Exiting."
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

    local db
    db=$(get_database_name "$service")

    if [[ -z "$db" ]]; then
      log "INFO: Service '$service' has no database configured. Skipping."
      continue
    fi

    shopt -s nullglob
    local backups=( "$latest_backup_dir/${db}-backup-"*.sql )
    shopt -u nullglob

    if [[ ${#backups[@]} -eq 0 ]]; then
      log "No backups found for service '$service' (database '$db') in $latest_backup_dir."
      continue
    fi

    local latest_backup
    latest_backup=$(printf '%s\n' "${backups[@]}" | sort -V | tail -n 1)

    if [[ ! -f "$latest_backup" ]]; then
      log "Backup file $latest_backup not found or not a regular file. Skipping."
      continue
    fi

    apply_backup "$service" "$container" "$db" "$latest_backup"
  done

  log "--- Restore Process Complete ---"
}

main "$@"
