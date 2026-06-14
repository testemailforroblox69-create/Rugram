# Deploying Opengram on a VPS (Debian 13)

This guide deploys the Opengram backend (Docker Compose) on a fresh VPS so your
clients (Android / web) can connect to it over the internet.

> Secrets are **never** committed. The repo ships `.env.example` templates only —
> your real `docker/compose/.env` (with passwords + server IP) is created on the
> server and is git-ignored.

## 0. Prerequisites
- A VPS with a **static public IPv4** (Debian 13 "trixie" or Ubuntu 22.04/24.04).
- Ability to **open custom ports** in the provider's firewall/security group.
- ~12 GB RAM is enough (the setup script adds an 8 GB swap for the build), 150 GB disk.

## 1. Get the code onto the server
```bash
# as your sudo user
git clone https://github.com/<your-account>/<your-repo>.git opengram
cd opengram
```

## 2. One-shot setup (recommended)
```bash
sudo bash deploy/setup.sh <YOUR_SERVER_PUBLIC_IP>
```
This will: install Docker + Compose, add swap, generate the MTProto RSA keys,
create `docker/compose/.env` from the template (filling your IP + random secrets),
then **build and start** the stack.

> First build compiles ~8 .NET services from source — expect a while. The script
> uses swap so it won't OOM on 12 GB.

### …or do it manually
```bash
# Docker
curl -fsSL https://get.docker.com | sh

# RSA keys
cd docker/compose/secrets/mtproto
openssl genrsa -out rsa_private.pem 2048
openssl rsa -in rsa_private.pem -traditional -out rsa_private_pkcs1.pem
openssl rsa -in rsa_private.pem -pubout -out rsa_public.pem
cd -

# Config
cp docker/compose/.env.example docker/compose/.env
#   - replace every YOUR_SERVER_IP with your VPS public IP
#   - replace every CHANGE_ME with a strong random value
#   (Minio__SecretKey is the important one; the *_PASSWORD vars are unused stubs)

# Build + run
cd docker/compose
docker compose build
docker compose up -d
docker compose ps
```

## 3. Open firewall ports
**Required (MTProto + web gateway):** TCP `20443 20543 20643 20644 30443 30444`
**Calls only (optional):** UDP `3478` + the coturn/mediasoup RTC port range.

Example with ufw:
```bash
sudo ufw allow 20443:20644/tcp
sudo ufw allow 30443:30444/tcp
```
Also make sure the **provider's** security group allows them.

## 4. Verify
```bash
docker compose ps                       # all services Up / healthy
docker compose logs -f gateway-server   # watch for startup errors
curl http://127.0.0.1:30444/            # web gateway -> "Only websocket requests are supported"
```

## 5. Point clients at the server
The server's public IP is what clients dial — set it in:
- **Android** (`opengram-server/Telegram`): `TMessagesProj/jni/tgnet/ConnectionsManager.cpp` (DC address) → your VPS IP, gateway TCP port `20443`.
- **Web** (Telegram Web fork): `getDC()` in `src/lib/gramjs/Utils.ts` → your VPS IP + WS port.

Login uses `App__FixedVerifyCode` from `.env` (default `22222`) unless you configure real SMS.

## Notes
- `session-server`, `file-server`, `sms-sender` are pulled as `mytelegram/*:0.32.206.802` images; the rest build from source.
- To update later: `git pull && docker compose build && docker compose up -d`.
- To stop: `docker compose stop`. To wipe data: stop, then remove `docker/compose/data/`.
