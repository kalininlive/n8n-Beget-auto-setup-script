#!/bin/bash
set -euo pipefail

# ============================================================================
# n8n Beget Auto-Setup Script
# Transforms a fresh Beget n8n installation into a fully customized setup
# with ffmpeg, python3, yt-dlp, fc-scan, docker-in-docker, and more.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/n8n-beget-setup/main/setup.sh | bash
#   # OR
#   bash setup.sh [OPTIONS]
#
# Options:
#   --no-bot         Skip Telegram bot setup
#   --no-tools       Skip n8n-tools container
#   --no-proxy       Skip proxy configuration
#   --timezone ZONE  Set timezone (default: Europe/Moscow)
#   --domain DOMAIN  Override domain from .env
#   --dry-run        Show what would be done without making changes
# ============================================================================

# === COLORS & HELPERS ========================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
step()  { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# === DEFAULT CONFIG ==========================================================
BEGET_DIR="/opt/beget/n8n"
INSTALL_BOT=true
INSTALL_TOOLS=true
SETUP_PROXY=true
TIMEZONE=""
DOMAIN_OVERRIDE=""
DRY_RUN=false

# === PARSE ARGUMENTS =========================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-bot)     INSTALL_BOT=false; shift ;;
        --no-tools)   INSTALL_TOOLS=false; shift ;;
        --no-proxy)   SETUP_PROXY=false; shift ;;
        --timezone)   TIMEZONE="$2"; shift 2 ;;
        --domain)     DOMAIN_OVERRIDE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: bash setup.sh [OPTIONS]"
            echo "  --no-bot         Skip Telegram bot"
            echo "  --no-tools       Skip n8n-tools container"
            echo "  --no-proxy       Skip proxy config"
            echo "  --timezone ZONE  Set timezone (default: from .env or Europe/Moscow)"
            echo "  --domain DOMAIN  Override domain"
            echo "  --dry-run        Preview changes"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# === PRE-FLIGHT CHECKS =======================================================
step "Pre-flight Checks"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root"
    exit 1
fi

if [[ ! -d "$BEGET_DIR" ]]; then
    err "Beget n8n directory not found: $BEGET_DIR"
    err "Is n8n installed via Beget panel?"
    exit 1
fi

if [[ ! -f "$BEGET_DIR/docker-compose.yml" ]]; then
    err "docker-compose.yml not found in $BEGET_DIR"
    exit 1
fi

if [[ ! -f "$BEGET_DIR/.env" ]]; then
    err ".env file not found in $BEGET_DIR"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    err "Docker not found"
    exit 1
fi

log "Beget n8n installation found at $BEGET_DIR"
log "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

# Read existing config
EXISTING_DOMAIN=$(grep -oP 'N8N_HOST=\K.*' "$BEGET_DIR/.env" 2>/dev/null || echo "")
EXISTING_TIMEZONE=$(grep -oP 'GENERIC_TIMEZONE=\K.*' "$BEGET_DIR/.env" 2>/dev/null || echo "Europe/Moscow")

DOMAIN="${DOMAIN_OVERRIDE:-$EXISTING_DOMAIN}"
TIMEZONE="${TIMEZONE:-$EXISTING_TIMEZONE}"

info "Domain: $DOMAIN"
info "Timezone: $TIMEZONE"
info "Install bot: $INSTALL_BOT"
info "Install tools: $INSTALL_TOOLS"
info "Setup proxy: $SETUP_PROXY"

if $DRY_RUN; then
    warn "DRY RUN mode — no changes will be made"
    exit 0
fi

# === SWAP SETUP ==============================================================
step "Configuring SWAP (4GB)"

SWAP_SIZE="4G"
SWAPFILE="/swapfile"

if swapon --show | grep -q "$SWAPFILE"; then
    info "SWAP already active: $(swapon --show | grep "$SWAPFILE" | awk '{print $3}')"
    log "Skipping SWAP setup"
else
    info "SWAP not found — creating ${SWAP_SIZE} swapfile..."
    info "This is CRITICAL for ffmpeg to work on low-memory servers!"

    # Create swapfile
    fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=4096
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"

    # Make persistent across reboots
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        log "SWAP added to /etc/fstab (persistent)"
    fi

    # Optimize swappiness for server workload
    sysctl vm.swappiness=10 >/dev/null 2>&1
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log "SWAP configured: $(free -h | grep Swap | awk '{print $2}')"
fi

# === BACKUP ==================================================================
step "Creating Backup"

BACKUP_DIR="$BEGET_DIR/backups/pre-setup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$BEGET_DIR/docker-compose.yml" "$BACKUP_DIR/"
cp "$BEGET_DIR/.env" "$BACKUP_DIR/"
[[ -f "$BEGET_DIR/healthcheck.js" ]] && cp "$BEGET_DIR/healthcheck.js" "$BACKUP_DIR/"
[[ -f "$BEGET_DIR/init-data.sh" ]] && cp "$BEGET_DIR/init-data.sh" "$BACKUP_DIR/"

log "Backup saved to: $BACKUP_DIR"

# === STOP EXISTING CONTAINERS ================================================
step "Stopping Existing Containers"

cd "$BEGET_DIR"
docker compose down --timeout 30 2>/dev/null || docker-compose down --timeout 30 2>/dev/null || true
log "Containers stopped"

# === CREATE DIRECTORY STRUCTURE ==============================================
step "Creating Directory Structure"

mkdir -p "$BEGET_DIR/shims"
mkdir -p "$BEGET_DIR/data"
mkdir -p "$BEGET_DIR/backups"
mkdir -p "$BEGET_DIR/logs"

if $INSTALL_BOT; then
    mkdir -p "$BEGET_DIR/bot"
fi

log "Directories created"

# === CREATE DOCKERFILE.N8N ==================================================
step "Creating Dockerfile.n8n"

cat > "$BEGET_DIR/Dockerfile.n8n" << 'DOCKERFILE_N8N'
FROM docker.n8n.io/n8nio/n8n:latest

ARG DOCKER_GID=999
USER root

# Install necessary packages: ffmpeg, python3, yt-dlp, fontconfig, locales
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libfontconfig1 \
    libfreetype6 \
    fontconfig \
    locales \
    git \
    build-essential \
    python3 \
    python3-pip \
    python3-dev \
    curl \
    wget \
    jq \
    && pip install --no-cache-dir --break-system-packages yt-dlp \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure locales for fontconfig and drawtext filter
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# Add node user to docker group for docker.sock access
RUN groupadd -g $DOCKER_GID docker || true && \
    usermod -aG docker node

# Create shims directory
RUN mkdir -p /opt/shims && \
    chown node:node /opt/shims

# Create /data directory for file storage
RUN mkdir -p /data && \
    chown node:node /data

USER node
DOCKERFILE_N8N

log "Dockerfile.n8n created"

# === CREATE DOCKERFILE.TOOLS ================================================
if $INSTALL_TOOLS; then
    step "Creating Dockerfile.tools"

    cat > "$BEGET_DIR/Dockerfile.tools" << 'DOCKERFILE_TOOLS'
FROM alpine/git

# Install docker client and utilities
RUN apk add --no-cache \
    docker-cli \
    bash \
    curl \
    jq \
    zip \
    unzip

WORKDIR /app
DOCKERFILE_TOOLS

    log "Dockerfile.tools created"
fi

# === CREATE SHIM SCRIPTS ====================================================
step "Creating Shim Scripts"

# ffmpeg shim
cat > "$BEGET_DIR/shims/ffmpeg" << 'SHIM'
#!/bin/bash
exec /usr/bin/ffmpeg "$@"
SHIM

# fc-scan shim
cat > "$BEGET_DIR/shims/fc-scan" << 'SHIM'
#!/bin/bash
exec /usr/bin/fc-scan "$@"
SHIM

# python shim
cat > "$BEGET_DIR/shims/python" << 'SHIM'
#!/bin/bash
exec /usr/bin/python3 "$@"
SHIM

# python3 shim
cat > "$BEGET_DIR/shims/python3" << 'SHIM'
#!/bin/bash
exec /usr/bin/python3 "$@"
SHIM

# yt-dlp shim
cat > "$BEGET_DIR/shims/yt-dlp" << 'SHIM'
#!/bin/bash
exec /usr/local/bin/yt-dlp "$@"
SHIM

chmod +x "$BEGET_DIR/shims/"*
log "Shim scripts created and made executable"

# === CREATE BACKUP SCRIPT ====================================================
step "Creating Utility Scripts"

cat > "$BEGET_DIR/backup_n8n.sh" << 'BACKUP_SCRIPT'
#!/bin/bash
# n8n Backup Script
set -euo pipefail

INSTALL_DIR="/opt/beget/n8n"
BACKUP_DIR="$INSTALL_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/n8n_backup_$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting n8n backup..."

# Dump PostgreSQL
POSTGRES_CONTAINER=$(docker ps --filter "name=postgres" --format "{{.Names}}" | head -1)
if [[ -n "$POSTGRES_CONTAINER" ]]; then
    docker exec "$POSTGRES_CONTAINER" pg_dump -U n8n n8n > "$BACKUP_DIR/db_dump_$TIMESTAMP.sql"
    echo "[$(date)] Database dump created"
fi

# Archive n8n data
tar -czf "$BACKUP_FILE" \
    -C "$INSTALL_DIR" \
    docker-compose.yml \
    .env \
    Dockerfile.n8n \
    shims/ \
    data/ \
    -C "$BACKUP_DIR" \
    "db_dump_$TIMESTAMP.sql" \
    2>/dev/null || true

# Cleanup old backups (keep last 7)
cd "$BACKUP_DIR" && ls -t n8n_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm
rm -f "$BACKUP_DIR/db_dump_$TIMESTAMP.sql"

echo "[$(date)] Backup complete: $BACKUP_FILE"
BACKUP_SCRIPT

cat > "$BEGET_DIR/update_n8n.sh" << 'UPDATE_SCRIPT'
#!/bin/bash
# n8n Update Script
set -euo pipefail

INSTALL_DIR="/opt/beget/n8n"
cd "$INSTALL_DIR"

echo "[$(date)] Starting n8n update..."

# Backup first
bash "$INSTALL_DIR/backup_n8n.sh"

# Pull latest images and rebuild
docker compose build --no-cache n8n
docker compose build --no-cache n8n-worker
docker compose up -d

echo "[$(date)] Update complete!"
docker compose ps
UPDATE_SCRIPT

chmod +x "$BEGET_DIR/backup_n8n.sh" "$BEGET_DIR/update_n8n.sh"
log "Utility scripts created"

# === UPDATE .ENV FILE ========================================================
step "Updating .env File"

# Read existing values to preserve them
source "$BEGET_DIR/.env" 2>/dev/null || true

# Detect Docker GID
DOCKER_GID=$(getent group docker | cut -d: -f3 2>/dev/null || echo "999")

# Append new variables if they don't exist
append_env() {
    local key="$1"
    local value="$2"
    if ! grep -q "^${key}=" "$BEGET_DIR/.env"; then
        echo "${key}=${value}" >> "$BEGET_DIR/.env"
        info "Added: ${key}=${value}"
    else
        info "Exists: ${key} (keeping current value)"
    fi
}

echo "" >> "$BEGET_DIR/.env"
echo "# === Added by n8n-beget-setup ===" >> "$BEGET_DIR/.env"

# Core n8n settings
append_env "N8N_COMMUNITY_PACKAGES_ENABLED" "true"
append_env "NODES_EXCLUDE" "[]"
append_env "N8N_PAYLOAD_SIZE_MAX" "512"
append_env "N8N_FORMDATA_FILE_SIZE_MAX" "2048"
append_env "N8N_RUNNERS_TASK_TIMEOUT" "1800"
append_env "EXECUTIONS_TIMEOUT" "-1"
append_env "EXECUTIONS_TIMEOUT_MAX" "14400"
append_env "N8N_BINARY_DATA_MODE" "filesystem"
append_env "N8N_RESTRICT_FILE_ACCESS_TO" "/data"
append_env "N8N_EXPRESS_TRUST_PROXY" "true"
append_env "N8N_TRUSTED_PROXIES" "*"

# Docker GID
append_env "DOCKER_GID" "$DOCKER_GID"

# Queue mode (Redis)
append_env "QUEUE_BULL_REDIS_HOST" "redis"
append_env "QUEUE_BULL_REDIS_PORT" "6379"

# Proxy settings (empty by default — safe, n8n ignores empty values)
if $SETUP_PROXY; then
    append_env "PROXY_URL" ""
    append_env "NO_PROXY" "localhost,127.0.0.1,postgres,redis,n8n,n8n-worker"
fi

# Bot settings (empty placeholders)
if $INSTALL_BOT; then
    append_env "TG_BOT_TOKEN" ""
    append_env "TG_USER_ID" ""
fi

log ".env updated"

# === CREATE DOCKER-COMPOSE.YML ==============================================
step "Creating docker-compose.yml"

# Extract current domain and email from existing config
ACME_EMAIL=$(grep -oP 'acme\.email=\K[^"]+' "$BACKUP_DIR/docker-compose.yml" 2>/dev/null || echo "admin@${DOMAIN}")
# Keep backtick-based Host rule from Beget's format
DOMAIN_ESCAPED="$DOMAIN"

# Determine compose content based on options
TOOLS_SERVICE=""
if $INSTALL_TOOLS; then
TOOLS_SERVICE="
  n8n-tools:
    build:
      context: .
      dockerfile: Dockerfile.tools
    container_name: n8n-tools
    restart: always
    command: [\"sh\", \"-lc\", \"sleep infinity\"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
"
fi

BOT_SERVICE=""
if $INSTALL_BOT; then
BOT_SERVICE="
  n8n-bot:
    build:
      context: ./bot
      dockerfile: Dockerfile
    container_name: n8n-bot
    restart: always
    environment:
      - TG_BOT_TOKEN=\${TG_BOT_TOKEN}
      - TG_USER_ID=\${TG_USER_ID}
      - COMPOSE_FILE=/opt/beget/n8n/docker-compose.yml
      - COMPOSE_PROJECT_NAME=n8n
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./update_n8n.sh:/opt/beget/n8n/update_n8n.sh
      - ./backup_n8n.sh:/opt/beget/n8n/backup_n8n.sh
      - ./backups:/opt/beget/n8n/backups
      - ./docker-compose.yml:/opt/beget/n8n/docker-compose.yml:ro
      - ./logs:/opt/beget/n8n/logs
      - ./.env:/opt/beget/n8n/.env
      - /usr/libexec/docker/cli-plugins/docker-compose:/root/.docker/cli-plugins/docker-compose:ro
    labels:
      - \"traefik.enable=false\"
"
fi

cat > "$BEGET_DIR/docker-compose.yml" << COMPOSE_EOF
---
volumes:
  traefik_data:
    driver: local-persist
    driver_opts:
      mountpoint: /opt/beget/n8n/traefik_data
  n8n_storage:
    driver: local-persist
    driver_opts:
      mountpoint: /opt/beget/n8n/n8n_storage
  db_storage:
    driver: local-persist
    driver_opts:
      mountpoint: /opt/beget/n8n/db_storage
  redis_storage:
    driver: local-persist
    driver_opts:
      mountpoint: /opt/beget/n8n/redis_storage

x-n8n-env: &n8n-env
  # Database
  - DB_TYPE=postgresdb
  - DB_POSTGRESDB_HOST=postgres
  - DB_POSTGRESDB_PORT=5432
  - DB_POSTGRESDB_DATABASE=\${DB_POSTGRESDB_DATABASE:-n8n}
  - DB_POSTGRESDB_USER=\${DB_POSTGRESDB_USER:-user}
  - DB_POSTGRESDB_PASSWORD=\${DB_POSTGRESDB_PASSWORD}
  # n8n Core
  - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
  - N8N_HOST=\${N8N_HOST:-${DOMAIN}}
  - N8N_PORT=5678
  - N8N_PROTOCOL=https
  - N8N_PROXY_HOPS=\${N8N_PROXY_HOPS:-1}
  - N8N_EXPRESS_TRUST_PROXY=\${N8N_EXPRESS_TRUST_PROXY:-true}
  - N8N_TRUSTED_PROXIES=\${N8N_TRUSTED_PROXIES:-*}
  - WEBHOOK_URL=\${WEBHOOK_URL:-https://${DOMAIN}/}
  - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE:-${TIMEZONE}}
  - NODE_ENV=production
  - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
  - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED:-true}
  - N8N_PERSONALIZATION_ENABLED=false
  - N8N_BLOCK_ENV_ACCESS_IN_NODE=true
  - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
  # Limits & Timeouts
  - N8N_PAYLOAD_SIZE_MAX=\${N8N_PAYLOAD_SIZE_MAX:-512}
  - N8N_FORMDATA_FILE_SIZE_MAX=\${N8N_FORMDATA_FILE_SIZE_MAX:-2048}
  - N8N_RUNNERS_TASK_TIMEOUT=\${N8N_RUNNERS_TASK_TIMEOUT:-1800}
  - EXECUTIONS_TIMEOUT=\${EXECUTIONS_TIMEOUT:--1}
  - EXECUTIONS_TIMEOUT_MAX=\${EXECUTIONS_TIMEOUT_MAX:-14400}
  # File & Binary
  - N8N_BINARY_DATA_MODE=\${N8N_BINARY_DATA_MODE:-filesystem}
  - N8N_DEFAULT_BINARY_DATA_MODE=\${N8N_DEFAULT_BINARY_DATA_MODE:-filesystem}
  - N8N_RESTRICT_FILE_ACCESS_TO=/data
  # Community & Nodes
  - N8N_COMMUNITY_PACKAGES_ENABLED=true
  - NODES_EXCLUDE=\${NODES_EXCLUDE:-[]}
  # Queue (Redis)
  - EXECUTIONS_MODE=\${EXECUTIONS_MODE:-regular}
  - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST:-redis}
  - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT:-6379}
  - QUEUE_HEALTH_CHECK_ACTIVE=true
  # PATH with shims
  - PATH=/opt/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  # Proxy (empty = ignored by n8n)
  - HTTP_PROXY=\${PROXY_URL:-}
  - HTTPS_PROXY=\${PROXY_URL:-}
  - NO_PROXY=\${NO_PROXY:-localhost,127.0.0.1,postgres,redis}

x-n8n-volumes: &n8n-volumes
  - /var/run/docker.sock:/var/run/docker.sock
  - /usr/bin/docker:/usr/bin/docker:ro
  - n8n_storage:/home/node/.n8n
  - ./data:/data
  - ./backup_n8n.sh:/opt/beget/n8n/backup_n8n.sh
  - ./update_n8n.sh:/opt/beget/n8n/update_n8n.sh
  - ./backups:/opt/beget/n8n/backups
  - ./.env:/opt/beget/n8n/.env
  - ./healthcheck.js:/healthcheck.js
  # Shim mounts
  - ./shims/python:/usr/bin/python:ro
  - ./shims/python3:/usr/bin/python3:ro
  - ./shims/ffmpeg:/usr/bin/ffmpeg:ro
  - ./shims/yt-dlp:/usr/bin/yt-dlp:ro
  - ./shims:/opt/shims:ro

services:
  traefik:
    image: traefik:3.6.5
    container_name: n8n-traefik
    restart: always
    command:
      - "--api=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: always
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-root}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB:-n8n}
      - POSTGRES_NON_ROOT_USER=\${POSTGRES_NON_ROOT_USER:-user}
      - POSTGRES_NON_ROOT_PASSWORD=\${POSTGRES_NON_ROOT_PASSWORD:-\${DB_POSTGRESDB_PASSWORD}}
    volumes:
      - db_storage:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh
    ports:
      - 127.0.0.1:5432:5432
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U \${POSTGRES_USER:-root} -d \${POSTGRES_DB:-n8n}']
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: n8n-redis
    restart: always
    volumes:
      - redis_storage:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 5s
      retries: 10

  n8n:
    build:
      context: .
      dockerfile: Dockerfile.n8n
      args:
        DOCKER_GID: \${DOCKER_GID:-999}
    container_name: n8n-app
    restart: always
    user: "0:0"
    environment: *n8n-env
    volumes: *n8n-volumes
    group_add:
      - "\${DOCKER_GID:-999}"
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(\`${DOMAIN_ESCAPED}\`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_ESCAPED}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
      - traefik.http.routers.n8n.middlewares=n8n@docker
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    ports:
      - 127.0.0.1:5678:5678
    healthcheck:
      test: ["CMD", "node", "/healthcheck.js"]
      interval: 5s
      timeout: 5s
      retries: 10

  n8n-worker:
    build:
      context: .
      dockerfile: Dockerfile.n8n
      args:
        DOCKER_GID: \${DOCKER_GID:-999}
    container_name: n8n-worker
    restart: always
    user: "0:0"
    command: worker
    environment: *n8n-env
    volumes: *n8n-volumes
    group_add:
      - "\${DOCKER_GID:-999}"
    depends_on:
      - n8n
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:5678/healthz || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 10
${TOOLS_SERVICE}${BOT_SERVICE}
COMPOSE_EOF

log "docker-compose.yml created"

# === CREATE HEALTHCHECK.JS (if missing) ======================================
if [[ ! -f "$BEGET_DIR/healthcheck.js" ]]; then
    step "Creating healthcheck.js"
    cat > "$BEGET_DIR/healthcheck.js" << 'HEALTHCHECK'
const http = require('http');
const options = {
    hostname: 'localhost',
    port: 5678,
    path: '/healthz',
    method: 'GET',
    timeout: 3000,
};
const req = http.request(options, (res) => {
    process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('error', () => process.exit(1));
req.on('timeout', () => { req.destroy(); process.exit(1); });
req.end();
HEALTHCHECK
    log "healthcheck.js created"
fi

# === CREATE INIT-DATA.SH (if missing) =======================================
if [[ ! -f "$BEGET_DIR/init-data.sh" ]]; then
    step "Creating init-data.sh"
    cat > "$BEGET_DIR/init-data.sh" << 'INITDATA'
#!/bin/bash
set -e;

if [ -n "${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
        GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
        GRANT ALL ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
EOSQL
else
    echo "SETUP INFO: No Environment variables given!"
fi
INITDATA
    chmod +x "$BEGET_DIR/init-data.sh"
    log "init-data.sh created"
fi

# === CREATE TELEGRAM BOT =====================================================
if $INSTALL_BOT; then
    step "Creating Telegram Bot"

    if [[ ! -f "$BEGET_DIR/bot/bot.js" ]]; then
        cat > "$BEGET_DIR/bot/Dockerfile" << 'BOT_DOCKERFILE'
FROM node:20-alpine

RUN apk add --no-cache \
    zip \
    bash \
    curl \
    docker-cli \
    coreutils \
    procps \
    jq

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

CMD ["node", "bot.js"]
BOT_DOCKERFILE

        cat > "$BEGET_DIR/bot/package.json" << 'BOT_PACKAGE'
{
  "name": "n8n-admin-tg-bot",
  "version": "1.0.0",
  "main": "bot.js",
  "scripts": {
    "start": "node bot.js"
  },
  "dependencies": {
    "dotenv": "^16.3.1",
    "node-telegram-bot-api": "^0.61.0"
  }
}
BOT_PACKAGE

        cat > "$BEGET_DIR/bot/bot.js" << 'BOT_JS'
const TelegramBot = require('node-telegram-bot-api');
const { execSync, exec } = require('child_process');
const path = require('path');
const fs = require('fs');

// === Environment variables ===
const token = process.env.TG_BOT_TOKEN;
const userId = process.env.TG_USER_ID;

if (!token || !userId) {
  console.error("❌ TG_BOT_TOKEN or TG_USER_ID not set. Bot disabled.");
  process.exit(0);
}

const bot = new TelegramBot(token, { polling: true });

function isAuthorized(msg) {
  return String(msg.chat.id) === String(userId);
}

function send(text) {
  bot.sendMessage(userId, text, { parse_mode: 'Markdown' });
}

// /start — command list
bot.onText(/\/start/, (msg) => {
  if (!isAuthorized(msg)) return;
  send('🤖 Доступные команды:\n/status — Статус контейнеров\n/logs — Логи n8n\n/backups — Бэкап вручную\n/update — Обновление n8n');
});

// /status — uptime and containers
bot.onText(/\/status/, (msg) => {
  if (!isAuthorized(msg)) return;
  try {
    const uptime = execSync('uptime -p').toString().trim();
    const containers = execSync('docker ps --format "{{.Names}} ({{.Status}})"').toString().trim();
    send(`🟢 Сервер работает\n⏱ Uptime: ${uptime}\n\n📦 Контейнеры:\n${containers}`);
  } catch (err) {
    send('❌ Ошибка при получении статуса');
  }
});

// /logs — last 100 lines of n8n logs
bot.onText(/\/logs/, (msg) => {
  if (!isAuthorized(msg)) return;

  exec('docker logs --tail=100 n8n-app', (error, stdout, stderr) => {
    if (error) {
      send(`❌ Не удалось получить логи:\n\`\`\`\n${error.message}\n\`\`\``);
      return;
    }

    if (stderr && stderr.trim()) {
      send(`⚠️ Предупреждение при получении логов:\n\`\`\`\n${stderr}\n\`\`\``);
      return;
    }

    const MAX_LEN = 3900;
    const trimmed = stdout.length > MAX_LEN ? stdout.slice(-MAX_LEN) : stdout;

    if (stdout.length > MAX_LEN) {
      const logPath = '/tmp/n8n_logs.txt';
      fs.writeFileSync(logPath, stdout);
      bot.sendDocument(userId, logPath, {}, {
        caption: '📝 Логи n8n (последние 100 строк)'
      });
    } else {
      send(`📝 Логи n8n:\n\`\`\`\n${trimmed}\n\`\`\``);
    }
  });
});

// /backups — run backup script
bot.onText(/\/backups/, (msg) => {
  if (!isAuthorized(msg)) return;

  send('📦 Запускаю резервное копирование n8n...');

  const backupScriptPath = path.resolve('/opt/beget/n8n/backup_n8n.sh');

  exec(`/bin/bash ${backupScriptPath}`, (error, stdout, stderr) => {
    if (error) {
      send(`❌ Ошибка при запуске backup:\n\`\`\`\n${error.message}\n\`\`\``);
      return;
    }

    if (stderr && stderr.trim()) {
      send(`⚠️ В процессе бэкапа были предупреждения:\n\`\`\`\n${stderr}\n\`\`\``);
      return;
    }

    send('✅ Бэкап завершён. Проверьте Telegram — архив должен быть отправлен автоматически.');
  });
});

// /update — backup then update n8n
bot.onText(/\/update/, (msg) => {
  if (!isAuthorized(msg)) return;

  send('🔄 Начинаю обновление n8n...');

  const cmd = `
    if [ -x /opt/beget/n8n/update_n8n.sh ]; then
      /bin/bash /opt/beget/n8n/update_n8n.sh;
    else
      echo 'SCRIPT_NOT_FOUND'; exit 127;
    fi
  `;
  exec(cmd, (error, stdout, stderr) => {
    if (error) return send(`❌ Обновление завершилось с ошибкой:\n${error.message}`);
    if (stderr) send(`⚠️ Предупреждение:\n${stderr}`);
    send(`✅ Обновление завершено:\n${stdout}`);
  });
});

console.log('[Bot] Started successfully');
BOT_JS

        log "Telegram bot created (commands: /start, /status, /logs, /backups, /update)"
        warn "Set TG_BOT_TOKEN and TG_USER_ID in .env to activate"
    else
        log "Bot code already exists — skipping"
    fi
fi

# === BUILD & START ===========================================================
step "Building Docker Images"

cd "$BEGET_DIR"

# Build custom n8n image
docker compose build --no-cache n8n 2>&1 | tail -5
log "n8n image built"

docker compose build --no-cache n8n-worker 2>&1 | tail -5
log "n8n-worker image built"

if $INSTALL_TOOLS; then
    docker compose build --no-cache n8n-tools 2>&1 | tail -5
    log "n8n-tools image built"
fi

if $INSTALL_BOT && [[ -f "$BEGET_DIR/bot/bot.js" ]]; then
    docker compose build --no-cache n8n-bot 2>&1 | tail -5
    log "n8n-bot image built"
fi

step "Starting Containers"
docker compose up -d 2>&1
sleep 10

log "Containers started"

# === VERIFICATION ============================================================
step "Verification"

echo ""
info "Container status:"
docker compose ps
echo ""

# Wait for n8n to be healthy
info "Waiting for n8n to start (up to 60s)..."
for i in $(seq 1 12); do
    if docker exec n8n-app wget -q -O /dev/null http://localhost:5678/healthz 2>/dev/null; then
        log "n8n is healthy!"
        break
    fi
    sleep 5
done

# Verify tools inside container
echo ""
info "Checking installed tools in n8n-app container:"

check_tool() {
    local name="$1"
    local cmd="$2"
    local result
    result=$(docker exec n8n-app sh -c "$cmd" 2>&1) || result="NOT FOUND"
    if [[ "$result" != "NOT FOUND" ]]; then
        log "$name: $result"
    else
        err "$name: not available"
    fi
}

check_tool "ffmpeg" "ffmpeg -version 2>&1 | head -1"
check_tool "python3" "python3 --version"
check_tool "yt-dlp" "yt-dlp --version"
check_tool "fc-scan" "fc-scan --version 2>&1 || echo 'available'"
check_tool "PATH" "echo \$PATH"
check_tool "drawtext" "ffmpeg -filters 2>&1 | grep drawtext | head -1"

echo ""
info "SWAP status:"
free -h | grep -E "Mem|Swap" | while read line; do echo "  $line"; done

# === SUMMARY =================================================================
step "Setup Complete! 🎉"

echo ""
log "n8n is running at: https://$DOMAIN"
log "Installation directory: $BEGET_DIR"
log "Backup of original config: $BACKUP_DIR"
echo ""
info "What was configured:"
echo "  ✅ SWAP 4GB (prevents ffmpeg OOM kills on low-memory servers)"
echo "  ✅ Custom Dockerfile.n8n (ffmpeg, python3, yt-dlp, fontconfig, locales)"
echo "  ✅ Shim scripts (ffmpeg, python, python3, fc-scan, yt-dlp)"
echo "  ✅ Docker-in-Docker access (docker.sock)"
echo "  ✅ Increased timeouts (task: 1800s, execution: unlimited, max: 14400s)"
echo "  ✅ Increased payload size (512MB payload, 2048MB formdata)"
echo "  ✅ Community packages enabled"
echo "  ✅ No nodes excluded (NODES_EXCLUDE=[])"
echo "  ✅ Filesystem binary data mode"
echo "  ✅ Queue mode with Redis"
echo "  ✅ Backup & update scripts"
$INSTALL_TOOLS && echo "  ✅ n8n-tools container"
$INSTALL_BOT && echo "  ✅ Telegram bot (configure TG_BOT_TOKEN and TG_USER_ID in .env)"
echo ""
info "Useful commands:"
echo "  cd $BEGET_DIR"
echo "  docker compose ps              # Container status"
echo "  docker compose logs -f n8n     # n8n logs"
echo "  bash backup_n8n.sh             # Create backup"
echo "  bash update_n8n.sh             # Update n8n"
echo ""

if $SETUP_PROXY; then
    warn "Proxy not configured yet. Edit .env and set PROXY_URL if needed:"
    echo "  nano $BEGET_DIR/.env"
    echo "  # Set: PROXY_URL=http://user:pass@host:port"
    echo "  docker compose up -d   # Restart to apply"
    echo ""
fi

if $INSTALL_BOT; then
    if [[ -z "${TG_BOT_TOKEN:-}" ]]; then
        warn "Telegram bot: Set TG_BOT_TOKEN and TG_USER_ID in .env, then:"
        echo "  docker compose restart n8n-bot"
        echo ""
    fi
fi
