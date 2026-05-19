#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# GARAGE AUTO INSTALLER v4
# - TLS internal para wildcard (Cloudflare proxy maneja TLS publico)
# - Fix DNS check para Cloudflare Proxy
# - Fix layout version detection para Garage v2
# - Wildcard S3 subdomain support
# - WebUI auth bcrypt fix
# - Watchtower scoped al stack
# - Backup mejorado con error handling
# - Output limpio y coloreado
########################################

APP_DIR="/opt/garage-stack"
GARAGE_DIR="$APP_DIR/garage"
FILES_DIR="$GARAGE_DIR/files"
BACKUP_DIR="$APP_DIR/backups"
NETWORK_NAME="garage_proxy"
COMPOSE_FILE="$GARAGE_DIR/docker-compose.yml"
GARAGE_TOML="$FILES_DIR/garage.toml"
CADDY_FILE="$FILES_DIR/Caddyfile"
SUMMARY_FILE="$GARAGE_DIR/INSTALL_SUMMARY.txt"
ENV_FILE="$GARAGE_DIR/.env"
NPM_HTTP_PORT="80"
NPM_HTTPS_PORT="443"

GARAGE_IMAGE="dxflrs/garage:v2.0.0"
GARAGE_WEBUI_IMAGE="khairul169/garage-webui:latest"
CADDY_IMAGE="caddy:2-alpine"
WATCHTOWER_IMAGE="containrrr/watchtower:latest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

section() {
  echo
  echo -e "${CYAN}${BOLD}=================================================="
  echo -e " $1"
  echo -e "==================================================${NC}"
}

trap 'echo -e "\n${RED}[ERROR]${NC} Fallo inesperado en linea $LINENO." >&2' ERR

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Ejecuta como root o con sudo."
}

ask() {
  local prompt="$1" default="${2:-}" value=""
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    echo "${value:-$default}"
  else
    read -rp "$prompt: " value
    echo "$value"
  fi
}

ask_required() {
  local prompt="$1" value=""
  while [[ -z "$value" ]]; do
    read -rp "$prompt: " value
    value="$(printf '%s' "$value" | xargs || true)"
  done
  echo "$value"
}

ask_secret() {
  local prompt="$1" value=""
  echo >&2
  while [[ -z "$value" ]]; do
    read -rsp "$prompt: " value
    echo >&2
    value="$(printf '%s' "$value" | tr -d '\r')"
  done
  echo "$value"
}

confirm() {
  local prompt="${1:-Continuar?}" default="${2:-s}" answer=""
  read -rp "$prompt (s/n) [$default]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[sS]$ ]]
}

slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

rand() { openssl rand -hex 4; }

sanitize_password() {
  printf '%s' "$1" | tr -d '\r'
}

escape_compose_dollars() {
  printf '%s' "$1" | sed 's/\$/$$/g'
}

extract_garage_node_id() {
  echo "$1" | grep -Eo '[0-9a-f]{16,64}' | head -n1
}

get_public_ip() {
  curl -4 -fsS https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

resolve_latest_docker_hub_tag() {
  local repo="$1" fallback="$2" tag=""
  tag="$(curl -fsSL "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=1&page=1&ordering=last_updated" 2>/dev/null \
    | jq -r '.results[0].name // empty' 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then echo "${repo}:${tag}"; else echo "${repo}:${fallback}"; fi
}

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || fail "Dominio invalido: $1"
}

validate_capacity() {
  [[ "$1" =~ ^[0-9]+[GMTP]$ ]] || fail "Capacidad invalida: $1 (usa ej: 20G, 1T)"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || fail "Puerto invalido: $1"
}

########################################
# DNS CHECK - Soporta Cloudflare Proxy
# Si el dominio resuelve a IP de Cloudflare
# (AS13335) simplemente lo informa como OK
# porque el trafico si llegara al VPS via proxy.
########################################

CLOUDFLARE_RANGES=(
  "173.245.48." "103.21.244." "103.22.200." "103.31.4."
  "141.101.64." "108.162.192." "190.93.240." "188.114.96."
  "197.234.240." "198.41.128." "162.158." "104.16." "104.17."
  "104.18." "104.19." "104.20." "104.21." "104.22." "104.23."
  "104.24." "104.25." "104.26." "104.27." "104.28." "104.29."
  "104.30." "104.31." "172.64." "172.65." "172.66." "172.67."
  "172.68." "172.69." "172.70." "172.71." "131.0.72."
)

is_cloudflare_ip() {
  local ip="$1"
  local range
  for range in "${CLOUDFLARE_RANGES[@]}"; do
    [[ "$ip" == ${range}* ]] && return 0
  done
  return 1
}

check_dns() {
  local domain="$1" server_ip="$2" resolved=""

  resolved="$(dig +short A "$domain" 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1 || true)"

  if [[ -z "$resolved" ]]; then
    warn "$domain no resuelve aun. Crea registro A: $domain -> $server_ip"
    return 0
  fi

  if is_cloudflare_ip "$resolved"; then
    log "$domain usa Cloudflare Proxy (OK - el trafico llegara a tu VPS)"
    return 0
  fi

  if [[ "$resolved" == "$server_ip" ]]; then
    log "$domain apunta correctamente a $server_ip"
  else
    warn "$domain apunta a $resolved (esperado: $server_ip)"
    warn "Verifica el registro DNS o activa el proxy de Cloudflare."
  fi
}

########################################
# DEPENDENCIES
########################################

install_dependencies() {
  info "Actualizando sistema..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq 2>/dev/null

  info "Instalando dependencias..."
  apt-get install -y -qq \
    curl wget ca-certificates gnupg lsb-release openssl ufw dnsutils jq cron \
    tar gzip unzip nano net-tools apache2-utils 2>/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    info "Instalando Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  else
    log "Docker ya instalado."
  fi

  systemctl enable docker >/dev/null 2>&1
  systemctl start docker >/dev/null 2>&1
  docker compose version >/dev/null 2>&1 || fail "Docker Compose no disponible."
  log "Dependencias instaladas."
}

resolve_container_images() {
  info "Resolviendo versiones de contenedores..."
  # Garage se fija a v2.0.0 estable para evitar instalar versiones alpha/rc
  GARAGE_IMAGE="dxflrs/garage:v2.0.0"
  GARAGE_WEBUI_IMAGE="khairul169/garage-webui:latest"
  CADDY_IMAGE="caddy:2-alpine"
  WATCHTOWER_IMAGE="containrrr/watchtower:latest"
  log "Garage image: $GARAGE_IMAGE"
  log "Caddy image: $CADDY_IMAGE"
}

validate_resources() {
  info "Validando recursos del VPS..."
  TOTAL_RAM_MB="$(free -m | awk '/Mem:/ {print $2}')"
  DISK_TOTAL_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$2); print $2}')"
  DISK_AVAIL_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
  [[ -z "${DISK_AVAIL_GB:-}" ]] && fail "No se pudo detectar disco."
  RECOMMENDED_GB=$(( DISK_AVAIL_GB * 85 / 100 ))
  [[ "$RECOMMENDED_GB" -lt 10 ]] && RECOMMENDED_GB=10
  log "RAM: ${TOTAL_RAM_MB}MB | Disco disponible: ${DISK_AVAIL_GB}GB | Recomendado: ${RECOMMENDED_GB}G"
  [[ "$DISK_AVAIL_GB" -lt 20 ]] && fail "Espacio insuficiente. Se necesitan al menos 20GB."
  [[ "$TOTAL_RAM_MB" -lt 900 ]] && warn "RAM baja detectada (<900MB)."
  return 0
}

########################################
# PORTS
########################################

port_in_use() { ss -tulpn 2>/dev/null | grep -q ":$1 "; }

find_free_port() {
  local c; for c in "$@"; do ! port_in_use "$c" && { echo "$c"; return 0; }; done; return 1
}

remove_port_blockers() {
  local port
  for port in "$@"; do
    local ids=""
    ids="$(docker ps -q --filter "publish=$port" 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
      echo "$ids" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
    if port_in_use "$port"; then
      local pids=""
      pids="$(ss -tulpn 2>/dev/null | grep ":$port " | grep -Eo 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
      if [[ -n "$pids" ]]; then
        echo "$pids" | xargs -r kill -9 2>/dev/null || true
      fi
    fi
  done
}

check_ports() {
  info "Revisando puertos..."
  local blocked=()
  for port in "$NPM_HTTP_PORT" "$NPM_HTTPS_PORT"; do
    if port_in_use "$port"; then
      warn "Puerto $port en uso."
      blocked+=("$port")
    else
      log "Puerto $port libre."
    fi
  done

  if (( ${#blocked[@]} > 0 )); then
    if confirm "Liberar puertos ocupados ${blocked[*]}?" "n"; then
      remove_port_blockers "${blocked[@]}"
    fi
  fi

  port_in_use "$NPM_HTTP_PORT"  && NPM_HTTP_PORT="$(find_free_port 8080 8000 30080)"   || true
  port_in_use "$NPM_HTTPS_PORT" && NPM_HTTPS_PORT="$(find_free_port 8443 4443 30443)"  || true

  [[ -n "${NPM_HTTP_PORT:-}"  ]] || fail "Sin puerto libre para HTTP."
  [[ -n "${NPM_HTTPS_PORT:-}" ]] || fail "Sin puerto libre para HTTPS."

  validate_port "$NPM_HTTP_PORT"
  validate_port "$NPM_HTTPS_PORT"
  log "Puertos proxy: HTTP=$NPM_HTTP_PORT  HTTPS=$NPM_HTTPS_PORT"
}

########################################
# PREPARE
########################################

backup_existing() {
  [[ -d "$APP_DIR" ]] || return 0
  local bk="${APP_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
  warn "Instalacion previa detectada. Creando backup..."
  cp -a "$APP_DIR" "$bk"
  log "Backup: $bk"
}

stop_existing_stack() {
  info "Deteniendo stack previo..."
  [[ -f "$COMPOSE_FILE" ]] && COMPOSE_DISABLE_ENV_FILE=1 \
    docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  for c in garage garage-webui caddy-proxy watchtower nginx-proxy-manager; do
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c" \
      && docker rm -f "$c" >/dev/null 2>&1 || true
  done
  log "Stack previo detenido."
}

cleanup_old_stack_artifacts() {
  mkdir -p "$GARAGE_DIR" "$FILES_DIR" "$BACKUP_DIR"
  rm -f "$COMPOSE_FILE" "$GARAGE_TOML" "$CADDY_FILE"
  log "Directorio limpio."
}

fix_invalid_env_file() {
  [[ -f "$ENV_FILE" ]] || return 0
  local bk="${ENV_FILE}.invalid.$(date +%Y%m%d_%H%M%S)"
  warn ".env encontrado (puede romper docker compose). Moviendo a $bk"
  mv "$ENV_FILE" "$bk"
}

########################################
# CREATE FILES
########################################

create_files() {
  info "Generando archivos de configuracion..."
  mkdir -p "$FILES_DIR" "$BACKUP_DIR" "$GARAGE_DIR"

  GARAGE_ADMIN_TOKEN="$(openssl rand -hex 32)"
  GARAGE_METRICS_TOKEN="$(openssl rand -hex 32)"
  GARAGE_RPC_SECRET="$(openssl rand -hex 32)"

  WEBUI_PASS="$(sanitize_password "$WEBUI_PASS")"
  WEBUI_PASS_HASH="$(htpasswd -nbBC 10 "$WEBUI_USER" "$WEBUI_PASS" | cut -d: -f2-)"
  [[ -n "$WEBUI_PASS_HASH" ]] || fail "No se pudo generar hash bcrypt."
  WEBUI_PASS_HASH_COMPOSE="$(escape_compose_dollars "$WEBUI_PASS_HASH")"

  # ---- garage.toml ----
  cat > "$GARAGE_TOML" <<EOF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"
replication_factor = 1

rpc_bind_addr = "0.0.0.0:3901"
rpc_public_addr = "garage:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
s3_region = "${S3_REGION}"
api_bind_addr = "0.0.0.0:3900"
root_domain = ".${S3_DOMAIN}"

[s3_web]
bind_addr = "0.0.0.0:3902"
root_domain = ".web.${S3_DOMAIN}"
index = "index.html"
error_document = "error/index.html"

[admin]
api_bind_addr = "0.0.0.0:3903"
admin_token = "${GARAGE_ADMIN_TOKEN}"
metrics_token = "${GARAGE_METRICS_TOKEN}"
EOF

  # ---- Caddyfile ----
  # s3.domain          -> S3 API (port 3900) para aws-cli, s3cmd, etc.
  # bucket.s3.domain   -> S3 Web (port 3902) acceso publico desde navegador
  # TLS internal: Caddy genera certs auto-firmados, Cloudflare proxy
  # se encarga del TLS publico (SSL mode "Full" en Cloudflare).
  # Referencia:  https://garagehq.deuxfleurs.fr/documentation/cookbook/reverse-proxy/
  local BASE_DOMAIN="${WEBUI_DOMAIN#*.}"
  [[ "$BASE_DOMAIN" == "$WEBUI_DOMAIN" ]] && BASE_DOMAIN="$WEBUI_DOMAIN"

  cat > "$CADDY_FILE" <<EOF
{
  email admin@${BASE_DOMAIN}
}

# WebUI de administracion
${WEBUI_DOMAIN} {
  tls internal
  reverse_proxy garage-webui:3909
}

# S3 API - acceso path-based (para aws-cli, s3cmd, etc.)
${S3_DOMAIN} {
  tls internal
  reverse_proxy garage:3900
}

# S3 API - wildcard vhost (bucket.${S3_DOMAIN}) para Nextcloud/S3 clients
*.${S3_DOMAIN} {
  tls internal
  reverse_proxy garage:3900
}

# S3 Web - wildcard vhost (bucket.web.${S3_DOMAIN} para acceso publico en navegador)
*.web.${S3_DOMAIN} {
  tls internal
  reverse_proxy garage:3902
}
EOF

  # ---- docker-compose.yml ----
  cat > "$COMPOSE_FILE" <<EOF
services:

  garage:
    image: ${GARAGE_IMAGE}
    container_name: garage
    restart: unless-stopped
    command: ["/garage", "server"]
    networks:
      - ${NETWORK_NAME}
    volumes:
      - ./files/garage.toml:/etc/garage.toml:ro
      - garage-storage:/var/lib/garage
    expose:
      - "3900"
      - "3901"
      - "3902"
      - "3903"
    healthcheck:
      test: ["CMD", "/garage", "status"]
      interval: 10s
      timeout: 8s
      retries: 20
      start_period: 30s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  garage-webui:
    image: ${GARAGE_WEBUI_IMAGE}
    container_name: garage-webui
    restart: unless-stopped
    depends_on:
      garage:
        condition: service_healthy
    networks:
      - ${NETWORK_NAME}
    environment:
      AUTH_USER_PASS: "${WEBUI_USER}:${WEBUI_PASS_HASH_COMPOSE}"
      API_BASE_URL: "http://garage:3903"
      S3_ENDPOINT_URL: "http://garage:3900"
    volumes:
      - ./files/garage.toml:/etc/garage.toml:ro
    expose:
      - "3909"
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  caddy-proxy:
    image: ${CADDY_IMAGE}
    container_name: caddy-proxy
    restart: unless-stopped
    depends_on:
      - garage-webui
    networks:
      - ${NETWORK_NAME}
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_HTTPS_PORT}:443"
    volumes:
      - ./files/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config

  watchtower:
    image: ${WATCHTOWER_IMAGE}
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --label-enable --schedule "0 0 4 * * *"

networks:
  ${NETWORK_NAME}:
    external: true

volumes:
  garage-storage:
  caddy-data:
  caddy-config:
EOF

  chmod 600 "$GARAGE_TOML" "$CADDY_FILE" "$COMPOSE_FILE"
  log "Archivos generados."
}

validate_generated_files() {
  info "Validando archivos generados..."
  [[ -f "$GARAGE_TOML"  ]] || fail "Falta $GARAGE_TOML"
  [[ -f "$CADDY_FILE"   ]] || fail "Falta $CADDY_FILE"
  [[ -f "$COMPOSE_FILE" ]] || fail "Falta $COMPOSE_FILE"
  grep -q 'AUTH_USER_PASS:' "$COMPOSE_FILE" || fail "AUTH_USER_PASS no esta en docker-compose.yml"
  cd "$GARAGE_DIR"
  export COMPOSE_DISABLE_ENV_FILE=1
  docker compose config >/dev/null 2>&1 || fail "docker compose config fallo. YAML invalido."
  log "Archivos validos."
}

configure_firewall() {
  info "Configurando firewall..."
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow "${NPM_HTTP_PORT}/tcp"  >/dev/null 2>&1 || true
  ufw allow "${NPM_HTTPS_PORT}/tcp" >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  log "Firewall configurado."
}

########################################
# DEPLOY
########################################

ensure_docker_network() {
  docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 \
    || docker network create "$NETWORK_NAME" >/dev/null
  log "Red Docker lista: $NETWORK_NAME"
}

deploy_stack() {
  info "Descargando imagenes y levantando stack..."
  cd "$GARAGE_DIR"
  export COMPOSE_DISABLE_ENV_FILE=1
  docker compose pull
  docker compose up -d
  sleep 10
  docker compose ps
  log "Stack desplegado."
}

wait_for_garage() {
  info "Esperando a que Garage este listo..."
  local i status=""
  for i in $(seq 1 40); do
    status="$(docker inspect -f '{{.State.Status}}' garage 2>/dev/null || true)"
    if [[ "$status" == "running" ]] && docker exec garage /garage status >/dev/null 2>&1; then
      log "Garage responde al CLI."
      return 0
    fi
    sleep 3
  done
  docker logs --tail 80 garage || true
  fail "Garage no inicio correctamente."
}

########################################
# INIT GARAGE LAYOUT
# Fix: verify_layout_applied no usa regex
# fragil, solo verifica que apply no fallo
# y que el output no sea literalmente "0 B"
# como unica capacidad.
########################################

verify_layout_applied() {
  local out=""
  out="$(docker exec garage /garage layout show 2>/dev/null || true)"

  # Falla solo si NO hay ningun nodo con capacidad > 0
  # Garage v2 muestra: "1000.0 MB", "17.0 GB", "900.0 GB", "0 B"
  # Si hay al menos una linea de capacidad que NO sea "0 B" -> OK
  if echo "$out" | grep -qE '[0-9]+\.?[0-9]*\s+(KB|MB|GB|TB|PB)'; then
    return 0
  fi

  warn "Layout show output:"
  echo "$out"
  return 1
}

init_garage() {
  info "Inicializando Garage..."
  wait_for_garage

  local node_raw="" node_hex="" node_short=""
  node_raw="$(docker exec garage /garage node id 2>/dev/null | head -n1 || true)"
  node_hex="$(extract_garage_node_id "$node_raw")"

  if [[ -z "$node_hex" ]]; then
    node_hex="$(docker exec garage /garage status 2>/dev/null \
      | grep -Eo '[0-9a-f]{16,}' | head -n1 || true)"
  fi

  [[ -n "$node_hex" ]] || fail "No se pudo obtener Node ID."
  node_short="$(printf '%s' "$node_hex" | cut -c1-16)"
  log "Node ID: $node_hex"

  # Assign
  if ! docker exec garage /garage layout assign -z dc1 -c "$GARAGE_CAPACITY" "$node_short" 2>/dev/null; then
    warn "Reintentando con ID completo..."
    docker exec garage /garage layout assign -z dc1 -c "$GARAGE_CAPACITY" "$node_hex" \
      || fail "No se pudo asignar layout."
  fi
  log "Layout asignado."

  # Apply - detectar version actual y usar la siguiente
  local current_v next_v applied=0
  current_v="$(docker exec garage /garage layout show 2>/dev/null \
    | grep -iE 'version' | grep -oE '[0-9]+' | sort -rn | head -n1 || echo "0")"
  [[ -z "$current_v" ]] && current_v=0
  next_v=$((current_v + 1))
  info "Layout version actual: $current_v, aplicando version $next_v..."

  for v in $(seq "$next_v" "$((next_v + 5))"); do
    if docker exec garage /garage layout apply --version "$v" >/dev/null 2>&1; then
      applied=1
      log "Layout aplicado (version $v)."
      break
    fi
  done
  [[ "$applied" -eq 1 ]] || fail "No se pudo aplicar layout."

  sleep 5

  if ! verify_layout_applied; then
    fail "Layout aplicado pero sin capacidad usable. Revisa los logs de Garage."
  fi

  log "Garage inicializado correctamente."
}

########################################
# S3
########################################

create_s3() {
  info "Creando bucket y key S3..."

  docker exec garage /garage bucket create "$BUCKET_NAME" \
    || fail "No se pudo crear bucket '$BUCKET_NAME'."

  KEY_OUTPUT="$(docker exec garage /garage key create "$S3_KEY_NAME" 2>&1)" \
    || fail "No se pudo crear key '$S3_KEY_NAME'."

  printf '%s\n' "$KEY_OUTPUT" > "$GARAGE_DIR/s3-credentials.txt"
  chmod 600 "$GARAGE_DIR/s3-credentials.txt"

  docker exec garage /garage bucket allow \
    --read --write --owner \
    "$BUCKET_NAME" --key "$S3_KEY_NAME" \
    || fail "No se pudo asignar permisos."

  # Habilitar web hosting en el bucket
  docker exec garage /garage bucket website --allow "$BUCKET_NAME" 2>/dev/null \
    && log "Web hosting activado en bucket." || warn "Web hosting no se pudo activar (no critico)."

  log "Bucket: $BUCKET_NAME"
  log "Credenciales: $GARAGE_DIR/s3-credentials.txt"
}

########################################
# CLEANUP EMPTY BUCKETS
########################################

cleanup_empty_buckets() {
  info "Buscando buckets vacios..."

  # Listar todos los buckets
  local bucket_list=""
  bucket_list="$(docker exec garage /garage bucket list 2>/dev/null || true)"

  if [[ -z "$bucket_list" ]]; then
    log "No hay buckets existentes."
    return 0
  fi

  # Extraer nombres de buckets
  local buckets=() empty_buckets=()
  while IFS= read -r line; do
    local bname=""
    bname="$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')"
    [[ -z "$bname" || "$bname" == "ID" || "$bname" == "List" ]] && continue
    # Intentar extraer el alias/nombre legible
    local balias=""
    balias="$(echo "$line" | sed -E 's/.*\s+([a-zA-Z0-9_-]+[a-zA-Z0-9])\s*$/\1/' || true)"
    [[ -n "$balias" && "$balias" != "$bname" ]] && bname="$balias"
    [[ -z "$bname" ]] && continue
    buckets+=("$bname")
  done <<< "$bucket_list"

  if [[ ${#buckets[@]} -eq 0 ]]; then
    log "No hay buckets existentes."
    return 0
  fi

  # Verificar cuales estan vacios
  for b in "${buckets[@]}"; do
    local info_out=""
    info_out="$(docker exec garage /garage bucket info "$b" 2>/dev/null || true)"
    # Buscar "Objects: 0" o "0 objects" en el output
    if echo "$info_out" | grep -qiE '(objects.*:\s*0$|0\s+objects|number of objects.*0)'; then
      empty_buckets+=("$b")
    fi
  done

  if [[ ${#empty_buckets[@]} -eq 0 ]]; then
    log "No se encontraron buckets vacios."
    return 0
  fi

  echo
  warn "Se encontraron ${#empty_buckets[@]} bucket(s) vacio(s):"
  echo
  for b in "${empty_buckets[@]}"; do
    echo -e "  ${YELLOW}•${NC} $b"
  done
  echo

  if confirm "Eliminar todos los buckets vacios?" "n"; then
    for b in "${empty_buckets[@]}"; do
      if docker exec garage /garage bucket delete --yes "$b" >/dev/null 2>&1; then
        log "Bucket eliminado: $b"
      else
        warn "No se pudo eliminar: $b (puede tener aliases o estar en uso)"
      fi
    done
  else
    info "Buckets vacios conservados."
  fi
  return 0
}

########################################
# BACKUP CRON
########################################

create_backup_cron() {
  local BSCRIPT="/usr/local/bin/garage-backup.sh"
  cat > "$BSCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
DATE=\$(date +%Y%m%d_%H%M%S)
LOG="/var/log/garage-backup.log"
mkdir -p "$BACKUP_DIR"
echo "[\$DATE] Iniciando backup..." >> "\$LOG"
if tar -czf "$BACKUP_DIR/garage_\$DATE.tar.gz" \\
  "$GARAGE_DIR/files" \\
  "$GARAGE_DIR/docker-compose.yml" \\
  "$GARAGE_DIR/s3-credentials.txt" \\
  "$GARAGE_DIR/INSTALL_SUMMARY.txt" 2>>"\$LOG"; then
  echo "[\$DATE] Backup OK: garage_\$DATE.tar.gz" >> "\$LOG"
else
  echo "[\$DATE] ERROR: Backup fallo" >> "\$LOG"
fi
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +7 -delete
# Mantener log pequeño
tail -200 "\$LOG" > "\$LOG.tmp" && mv "\$LOG.tmp" "\$LOG" 2>/dev/null || true
EOF
  chmod +x "$BSCRIPT"

  cat > /etc/cron.d/garage-backup <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3 * * * root $BSCRIPT >>/var/log/garage-backup.log 2>&1
EOF

  systemctl enable cron >/dev/null 2>&1 || true
  systemctl restart cron >/dev/null 2>&1 || true
  log "Backup diario activado (3:15 AM)."
}

########################################
# SUMMARY
########################################

write_summary() {
  local AK="" SK=""
  [[ -f "$GARAGE_DIR/s3-credentials.txt" ]] && {
    AK="$(grep -i 'Key ID'     "$GARAGE_DIR/s3-credentials.txt" | awk '{print $NF}' || true)"
    SK="$(grep -i 'Secret key' "$GARAGE_DIR/s3-credentials.txt" | awk '{print $NF}' || true)"
  }

  cat > "$SUMMARY_FILE" <<EOF
GARAGE INSTALL SUMMARY
======================
IP:               $SERVER_IP

WEBUI:            https://$WEBUI_DOMAIN
S3 API:           https://$S3_DOMAIN
S3 API Vhost:     https://<bucket>.${S3_DOMAIN}
S3 Web Vhost:     https://<bucket>.web.${S3_DOMAIN}

USUARIO:          $WEBUI_USER
PASSWORD:         $WEBUI_PASS

BUCKET:           $BUCKET_NAME
REGION:           $S3_REGION
KEY NAME:         $S3_KEY_NAME
CAPACITY:         $GARAGE_CAPACITY

ACCESS KEY ID:    ${AK:-ver s3-credentials.txt}
SECRET KEY:       ${SK:-ver s3-credentials.txt}

TLS:              internal (Cloudflare proxy maneja TLS publico)
NOTA SSL:         Configura SSL mode "Full" en Cloudflare

CREDENCIALES:     $GARAGE_DIR/s3-credentials.txt
ARCHIVOS CONFIG:  $FILES_DIR/
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_summary() {
  local AK="" SK=""
  [[ -f "$GARAGE_DIR/s3-credentials.txt" ]] && {
    AK="$(grep -i 'Key ID'     "$GARAGE_DIR/s3-credentials.txt" | awk '{print $NF}' || true)"
    SK="$(grep -i 'Secret key' "$GARAGE_DIR/s3-credentials.txt" | awk '{print $NF}' || true)"
  }

  echo
  echo -e "${GREEN}${BOLD}=================================================="
  echo -e " INSTALACION COMPLETADA"
  echo -e "==================================================${NC}"
  echo
  printf "  ${CYAN}%-14s${NC} %s\n" "WEBUI:"     "https://$WEBUI_DOMAIN"
  printf "  ${CYAN}%-14s${NC} %s\n" "S3 API:"    "https://$S3_DOMAIN"
  printf "  ${CYAN}%-14s${NC} %s\n" "S3 Vhost:"  "https://<bucket>.${S3_DOMAIN}"
  echo
  printf "  ${CYAN}%-14s${NC} %s\n" "Usuario:"   "$WEBUI_USER"
  printf "  ${CYAN}%-14s${NC} %s\n" "Password:"  "$WEBUI_PASS"
  echo
  printf "  ${CYAN}%-14s${NC} %s\n" "Bucket:"    "$BUCKET_NAME"
  printf "  ${CYAN}%-14s${NC} %s\n" "Region:"    "$S3_REGION"
  [[ -n "$AK" ]] && printf "  ${CYAN}%-14s${NC} %s\n" "Access Key:" "$AK"
  [[ -n "$SK" ]] && printf "  ${CYAN}%-14s${NC} %s\n" "Secret Key:" "$SK"
  echo
  printf "  ${YELLOW}%-14s${NC} %s\n" "Credenciales:" "$GARAGE_DIR/s3-credentials.txt"
  printf "  ${YELLOW}%-14s${NC} %s\n" "Resumen:"       "$SUMMARY_FILE"
  echo
  echo -e "${GREEN}${BOLD}==================================================${NC}"
  echo

  # Recordatorio DNS wildcard
  echo -e "${YELLOW}NOTA:${NC} Para subdominios de bucket (*.${S3_DOMAIN}) asegurate"
  echo -e "      de tener un registro DNS wildcard en Cloudflare:"
  echo -e "      Tipo: A  |  Nombre: *.${S3_DOMAIN%%.*}  |  Valor: $SERVER_IP"
  echo
}

########################################
# MAIN
########################################

main() {
  require_root

  section "GARAGE AUTO INSTALLER v4"
  SERVER_IP="$(get_public_ip)"
  log "IP publica: $SERVER_IP"

  section "INSTALANDO DEPENDENCIAS"
  install_dependencies
  resolve_container_images
  validate_resources

  section "DATOS DE DESPLIEGUE"
  echo
  WEBUI_DOMAIN="$(ask_required "Dominio WEBUI (ej: storage.5-l.cc)")"
  S3_DOMAIN="$(ask_required   "Dominio S3   (ej: s3.5-l.cc)")"
  validate_domain "$WEBUI_DOMAIN"
  validate_domain "$S3_DOMAIN"

  S3_REGION="$(ask    "Region S3"     "us-east-1")"
  WEBUI_USER="$(ask   "Usuario WEBUI" "admin")"
  WEBUI_PASS="$(ask_secret "Password WEBUI")"

  AUTO_NAME="$(slug "${S3_DOMAIN%%.*}")-$(rand)"
  S3_KEY_NAME="$(ask "Nombre access key S3 (enter = auto)" "")"
  [[ -z "$S3_KEY_NAME" ]] && S3_KEY_NAME="key-$AUTO_NAME"

  BUCKET_NAME="$(ask "Nombre bucket (enter = auto)" "")"
  [[ -z "$BUCKET_NAME" ]] && BUCKET_NAME="bucket-$AUTO_NAME"

  GARAGE_CAPACITY="$(ask "Capacidad Garage" "${RECOMMENDED_GB}G")"
  validate_capacity "$GARAGE_CAPACITY"

  CAP_NUM="$(echo "$GARAGE_CAPACITY" | grep -oE '^[0-9]+' || echo 0)"
  if [[ "$CAP_NUM" -gt "$DISK_AVAIL_GB" ]]; then
    warn "Capacidad superior al disco. Usando ${RECOMMENDED_GB}G."
    GARAGE_CAPACITY="${RECOMMENDED_GB}G"
  fi

  section "VALIDANDO DNS"
  check_dns "$WEBUI_DOMAIN" "$SERVER_IP"
  check_dns "$S3_DOMAIN"    "$SERVER_IP"

  echo
  echo -e "${BOLD}RESUMEN:${NC}"
  echo
  printf "  %-16s %s\n" "WEBUI:"       "$WEBUI_DOMAIN"
  printf "  %-16s %s\n" "S3 API:"      "$S3_DOMAIN"
  printf "  %-16s %s\n" "S3 Wildcard:" "*.${S3_DOMAIN}"
  printf "  %-16s %s\n" "S3 Web Wild:" "*.web.${S3_DOMAIN}"
  printf "  %-14s %s\n" "REGION:"    "$S3_REGION"
  printf "  %-14s %s\n" "USUARIO:"   "$WEBUI_USER"
  printf "  %-14s %s\n" "BUCKET:"    "$BUCKET_NAME"
  printf "  %-14s %s\n" "KEY:"       "$S3_KEY_NAME"
  printf "  %-14s %s\n" "CAPACITY:"  "$GARAGE_CAPACITY"
  echo

  confirm "Continuar instalacion?" "s" || fail "Instalacion cancelada."

  section "PREPARANDO ENTORNO"
  backup_existing
  stop_existing_stack
  cleanup_old_stack_artifacts
  fix_invalid_env_file
  check_ports
  configure_firewall

  section "GENERANDO CONFIGURACION"
  create_files
  validate_generated_files

  section "DESPLEGANDO STACK"
  ensure_docker_network
  deploy_stack

  section "INICIALIZANDO GARAGE"
  init_garage
  cleanup_empty_buckets
  create_s3

  section "CONFIGURANDO BACKUPS"
  create_backup_cron

  section "RESUMEN FINAL"
  write_summary
  print_summary
}

main "$@"
