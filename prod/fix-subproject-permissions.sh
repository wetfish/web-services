#!/usr/bin/env bash

set -exu

# where this .sh file lives
DIRNAME=$(dirname "$0")
SCRIPT_DIR=$(cd "$DIRNAME" || exit; pwd)
cd "$SCRIPT_DIR" || exit

# blog posts (only needs read access)
sudo chown 1101:1101 services/blog/config.js

# fourms fish uploads
mkdir -p services/online/storage/fish
sudo chown -R 33:33 services/online/storage/fish

# wiki
mkdir -p services/wiki/upload
mkdir -p services/wiki/db/data
sudo chown -R 33:33 services/wiki/upload
sudo chown -R 999:999 services/wiki/db

# danger
mkdir -p services/danger/db/data
sudo chown -R 999:999 services/danger/db/data
