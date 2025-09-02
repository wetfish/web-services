#!/usr/bin/env bash

set -eux

trapdoor() {
  # Define a list of .env files to check in service directories
  ENV_FILES=(
    "./services/*/php.env"
    "./services/*/mariadb.env"
  )

  # Check if any of the .env files already exist
  for env_file in ${ENV_FILES[@]}; do
    if [[ -f "$env_file" ]]; then
      echo "Environment file $env_file already exists. Exiting."
      exit 1
    fi
  done

  # If no .env files are found, proceed with the script
  echo "No .env files found. Proceeding with the script."
}

# Generate a random SHA-512 hash for passwords
generate_random_pass() {
  pwgen -s 32 1
}

# Get all service directories dynamically
count_dir() {
  SERVICE_ITEMS=($(find ./services/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;))
  echo "Service items: ${SERVICE_ITEMS[@]}"
}

# Create environment variables for services
export_secrets() {
  export ENV_TAG="stage"
  #export SITE_URL="wetfish.net"

  # Use count_dir to get the service directories if not already populated
  if [[ ${#SERVICE_ITEMS[@]} -eq 0 ]]; then
    count_dir
  fi

  # Iterate through all service items
  for item in "${SERVICE_ITEMS[@]}"; do
    local service_name
    service_name="${item//-/_}"

    # Generate random passwords and assign service-specific variables
    local root_password
    root_password=$(generate_random_pass)
    local password
    password=$(generate_random_pass)

    export "${service_name^^}_MARIADB_ROOT_PASSWORD"="$root_password"
    export "${service_name^^}_MARIADB_PASSWORD"="$password"
  done

  # Export other secrets (with 'WIKI' removed from variable names)
  export DB_PASSWORD
  DB_PASSWORD=$(generate_random_pass)
  export LOGIN_PASSWORD
  LOGIN_PASSWORD=$(generate_random_pass)
  export ADMIN_PASSWORD
  ADMIN_PASSWORD=$(generate_random_pass)
  export BAN_PASSWORD
  BAN_PASSWORD=$(generate_random_pass)
  export ALLOWED_EMBEDS="/^.*\.wetfish.net$/i"
}

# Generate configuration files from templates
generate_configs() {
  local files
  files=(
    "./services/*/php.env.example"
    "./services/*/mariadb.env.example"
  )

  # Explicitly expand wildcards to get a list of files
  for file in ${files[@]}; do
    if [[ -f "$file" ]]; then
      local output
      output="${file%.example}"  # Remove .example extension
      envsubst < "$file" > "$output" && echo "Generated: $output"
    else
      echo "Warning: Template file $file not found."
    fi
  done
}

# Replace variables directly in .env files
update_env_files() {
  local files
  files=(
    "./services/*/php.env.example"
    "./services/*/mariadb.env.example"
  )

  # Explicitly expand wildcards to get a list of files
  for file in ${files[@]}; do
    if [[ -f "$file" ]]; then
      echo "Updating variables in: $file"

      # Create a backup before making any changes
      cp "$file" "${file}.bak"

      # Substitute service-specific secrets
      for item in "${SERVICE_ITEMS[@]}"; do
        local service_name
        service_name="${item//-/_}"

        # Ensure service_name is set (not empty)
        if [[ -z "$service_name" ]]; then
          echo "Error: service_name is empty for item $item. Skipping."
          continue
        fi

        # Get the values for passwords from the environment variables
        local var_name="${service_name^^}_MARIADB_ROOT_PASSWORD"
        local mariadb_root_password="${!var_name}"
        local var_name2="${service_name^^}_MARIADB_PASSWORD"
        local mariadb_password="${!var_name2}"

        # Check if the environment variables are set
        if [[ -z "$mariadb_root_password" || -z "$mariadb_password" ]]; then
          echo "Error: Missing environment variables for ${service_name^^}. Skipping."
          continue
        fi

        # Perform in-place substitution
        sed -i "s|${service_name^^}_MARIADB_ROOT_PASSWORD=.*|${service_name^^}_MARIADB_ROOT_PASSWORD=$mariadb_root_password|" "$file"
        sed -i "s|${service_name^^}_MARIADB_PASSWORD=.*|${service_name^^}_MARIADB_PASSWORD=$mariadb_password|" "$file"
      done

      # Substitute the global secrets
      sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" "$file"
      sed -i "s|LOGIN_PASSWORD=.*|LOGIN_PASSWORD=$LOGIN_PASSWORD|" "$file"
      sed -i "s|ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$ADMIN_PASSWORD|" "$file"
      sed -i "s|BAN_PASSWORD=.*|BAN_PASSWORD=$BAN_PASSWORD|" "$file"
      sed -i "s|SITE_URL=.*|SITE_URL=$SITE_URL|" "$file"
      sed -i "s|ALLOWED_EMBEDS=.*|ALLOWED_EMBEDS=$ALLOWED_EMBEDS|" "$file"

      echo "Successfully updated $file"
    else
      echo "Warning: .env file $file not found."
    fi
  done
}

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

  # Get the list of services dynamically if not already populated
  if [[ ${#SERVICE_ITEMS[@]} -eq 0 ]]; then
    count_dir
  fi

  case "$action" in
    "down")
      for dir in "${SERVICE_ITEMS[@]}"; do
        echo "Running \"docker compose down\" in ${dir}"
        if cd "${SCRIPT_DIR}/services/${dir}"; then
          docker compose down || echo "Failed to bring down the service in $dir. Continuing..."
        else
          echo "Failed to change directory to ${SCRIPT_DIR}/services/${dir}. Skipping..."
        fi
      done
      ;;
    "up")
      for dir in "${SERVICE_ITEMS[@]}"; do
        echo "Running \"docker compose up -d --force-recreate\" in ${dir}"
        if cd "${SCRIPT_DIR}/services/${dir}"; then
          docker compose -f docker-compose.yml up -d --force-recreate || echo "Failed to start the service in $dir. Continuing..."
        else
          echo "Failed to change directory to ${SCRIPT_DIR}/services/${dir}. Skipping..."
        fi
      done
      ;;
    "dev-build")
      for dir in "${SERVICE_ITEMS[@]}"; do
        echo "Running \"docker compose up -d --force-recreate --build --no-deps\" in ${dir}"
        if cd "${SCRIPT_DIR}/services/${dir}"; then
          docker compose up -d --force-recreate --build --no-deps || echo "Failed to set the service in $dir. Continuing..."
        else
          echo "Failed to change directory to ${SCRIPT_DIR}/services/${dir}. Skipping..."
        fi
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

  # Proceed with the script tasks
  # Uncommented the trapdoor function call - you can comment it out again if not needed
  trapdoor
  count_dir
  export_secrets
  generate_configs
  update_env_files
  config_traefik
  set_script_dir
  check_docker_compose
  run_docker_compose "$action"
}

main "$@"
