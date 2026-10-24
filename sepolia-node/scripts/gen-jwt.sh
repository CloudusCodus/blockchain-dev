#!/usr/bin/env bash
# Creates the shared JWT secret that authenticates Lighthouse at geth's Engine API.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f jwt/jwt.hex ]; then
    echo "jwt/jwt.hex already exists, keeping it"
    exit 0
fi

mkdir -p jwt
openssl rand -hex 32 | tr -d '\n' > jwt/jwt.hex
# Readable by the container users; tighten to 600 if both containers run as the file owner
chmod 644 jwt/jwt.hex
echo "created jwt/jwt.hex"
