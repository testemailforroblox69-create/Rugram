#!/usr/bin/env bash
# Opengram one-shot VPS setup (Debian 13 "trixie" / Ubuntu).
# Run from the repo root on a fresh server:
#   sudo bash deploy/setup.sh <SERVER_PUBLIC_IP>
# If you omit the IP it will be auto-detected.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/docker/compose"
SECRETS_DIR="$COMPOSE_DIR/secrets/mtproto"
ENV_FILE="$COMPOSE_DIR/.env"

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo/root."; exit 1; fi

# --- 1. Server IP ---------------------------------------------------------
SERVER_IP="${1:-}"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
fi
log "Using SERVER_IP=$SERVER_IP"

# --- 2. Docker + compose plugin ------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker (official convenience script — supports Debian/Ubuntu)"
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  log "Installing docker compose plugin"
  apt-get update -y && apt-get install -y docker-compose-plugin || true
fi
docker --version && docker compose version

# --- 3. Swap (the build is RAM-hungry; safety net on small boxes) --------
TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MB" -lt 14000 ] && ! swapon --show | grep -q .; then
  log "Creating 8G swap (RAM=${TOTAL_MB}MB)"
  fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 4. MTProto RSA keys --------------------------------------------------
if [ ! -f "$SECRETS_DIR/rsa_private.pem" ]; then
  log "Generating MTProto RSA keys in $SECRETS_DIR"
  mkdir -p "$SECRETS_DIR"
  openssl genrsa -out "$SECRETS_DIR/rsa_private.pem" 2048
  openssl rsa -in "$SECRETS_DIR/rsa_private.pem" -traditional -out "$SECRETS_DIR/rsa_private_pkcs1.pem"
  openssl rsa -in "$SECRETS_DIR/rsa_private.pem" -pubout -out "$SECRETS_DIR/rsa_public.pem"
fi
# containers run as a NON-root user and mount the keys read-only, so they must be
# world-readable or auth-server crashes with "Permission denied" on rsa_private.pem
chmod 644 "$SECRETS_DIR"/*.pem 2>/dev/null || true

# --- 5. .env from template (server IP + random secrets) ------------------
if [ ! -f "$ENV_FILE" ]; then
  log "Creating $ENV_FILE from .env.example"
  cp "$COMPOSE_DIR/.env.example" "$ENV_FILE"
  sed -i "s/YOUR_SERVER_IP/$SERVER_IP/g" "$ENV_FILE"
  # replace each CHANGE_ME with a unique random secret
  while grep -q 'CHANGE_ME' "$ENV_FILE"; do
    sed -i "0,/CHANGE_ME/s//$(openssl rand -hex 16)/" "$ENV_FILE"
  done
  echo "  -> filled server IP + generated secrets"
else
  log ".env already exists — leaving it untouched"
fi

# --- 6. Build + start -----------------------------------------------------
cd "$COMPOSE_DIR"
log "Building images from source (this takes a while on first run)"
docker compose build
log "Starting the stack"
docker compose up -d
docker compose ps

cat <<EOF

\033[1;32mDone.\033[0m Open these ports in your VPS firewall/security group:
  TCP 20443 20543 20643 20644 30443 30444   (MTProto / web gateway)
  UDP 3478 + the coturn/mediasoup RTC range  (only if you use voice/video calls)

Clients should point at:  $SERVER_IP
Login uses the fixed code in .env (App__FixedVerifyCode) unless you wire real SMS.
EOF
