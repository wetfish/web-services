#!/bin/env bash

# Get the current timestamp
timestamp=$(date +%Y-%m-%d)

# Generate a unique ID for this backup folder
unique_id=$(uuidgen)

# Create a directory to store backups with the unique ID appended
backup_dir="${timestamp}-service-backups-${unique_id}"
mkdir -p "$backup_dir"

# Array of database details: (docker_container, database_name, password, backup_filename)
declare -a db_details=(
  "wiki-db wiki $SECRET wiki-backup"
  "online-db online $SECRET forums-backup"
  "danger-db danger $SECRET danger-backup"
  "click-db click $SECRET click-backup"
)

# Loop through each database and run the mysqldump command
for db in "${db_details[@]}"; do
  IFS=' ' read -r container db_name password filename <<< "$db"
  docker exec "$container" mysqldump -u root --password="$password" "$db_name" > "$backup_dir/$filename-$(date +%Y-%m-%d).sql"
done

tar -cvf "${backup_dir}.tar.gz" "$backup_dir"

rsync -av -r -e "ssh -i ~/.ssh/vultr-prod" "/mnt/wetfish/backups/$backup_dir" root@wetfish-host:/mnt/wetfish/backups
rsync -av -r -e "ssh -i ~/.ssh/vultr-prod" /mnt/wetfish/wiki/uploads root@wetfish-host:/mnt/wetfish/wiki/

echo "Backups completed and saved to $backup_dir and moved to new prod server"
