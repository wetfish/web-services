#!/usr/bin/env bash

set -eu

# Configure Traefik environment file
config_traefik() {
  cp ./traefik/traefik.env.example ./traefik/traefik.env
}

# Change to the script's directory
set_script_dir() {
  local dirname
  dirname=$(dirname "$0")
  SCRIPT_DIR=$(cd "$dirname" || exit; pwd)
  cd "$SCRIPT_DIR" || exit
}

# Check Docker Compose version
check_docker_compose() {
  if ! docker compose version &>/dev/null; then
    echo "Error: Docker Compose is not installed or not found."
    exit 2
  fi
}

# Run Docker Compose commands
run_docker_compose() {
  local action="$1"
  local project_dirs=("traefik" "services/home" "services/online" "services/wiki" "services/danger" "services/click")

  case "$action" in
    "down")
      for dir in "${project_dirs[@]}"; do
        echo "Running \"docker compose down\" in ${dir}"
        cd "${SCRIPT_DIR}/${dir}" && docker compose down || {
          echo "Failed to bring down the service in $dir. Continuing..."
        }
      done
      ;;
    "up")
      for dir in "${project_dirs[@]}"; do
        echo "Running \"docker compose up -d --force-recreate\" in ${dir}"
        cd "${SCRIPT_DIR}/${dir}" && docker compose -f docker-compose.yml up -d --force-recreate || {
          echo "Failed to start the service in $dir. Continuing..."
        }
      done
      ;;
    "dev-build")
      for dir in "${project_dirs[@]}"; do
        echo "Running \"docker compose up -d --force-recreate --build --no-deps\" in ${dir}"
        cd "${SCRIPT_DIR}/${dir}" && docker compose up -d --force-recreate --build --no-deps || {
          echo "Failed to set the service in $dir. Continuing..."
        }
      done
      ;;
    *)
      echo "Error: Invalid action '$action'. Allowed values are 'up', 'down', or 'dev-build'."
      echo "Usage: $0 [up | down | dev-build]"
      exit 1
      ;;
  esac
}

# Main script execution
main() {
  # Ensure an action argument is passed
  if [[ $# -eq 0 ]]; then
    echo "Error: No action specified. Please provide 'up', 'down', or 'dev-build'."
    echo "Usage: $0 [up | down | dev-build]"
    exit 1
  fi

  # Validate the action argument
  local action="$1"
  if [[ "$action" != "up" && "$action" != "down" && "$action" != "dev-build" ]]; then
    echo "Error: Invalid action '$action'. Allowed values are 'up', 'down', or 'dev-build'."
    echo "Usage: $0 [up | down | dev-build]"
    exit 1
  fi

  config_traefik
  set_script_dir
  check_docker_compose
  run_docker_compose "$action"
}

main "$@"
