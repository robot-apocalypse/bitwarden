#!/bin/bash
set -euo pipefail

echo "=== Vaultwarden Setup ==="

# Create .env from example if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env from template..."
    cp .env.example .env
    echo "Edit .env with your values before running docker compose up -d"
    exit 0
fi

echo "Loading environment..."
set -a
source .env
set +a

# Validate required vars
if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN is required"
    exit 1
fi

if [ -z "${ADMIN_TOKEN:-}" ]; then
    echo "Generating ADMIN_TOKEN..."
    export ADMIN_TOKEN=$(openssl rand -base64 48)
    echo "ADMIN_TOKEN=$ADMIN_TOKEN" >> .env
fi

echo "Starting services..."
docker compose up -d

echo "Done! Access ${DOMAIN}/admin for admin panel"