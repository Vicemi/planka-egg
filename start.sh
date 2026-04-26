#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Yolk      : ghcr.io/vicemi/planka-egg:latest
# Node.js   : 22 (nativo en la imagen)
# PostgreSQL: 16 (nativo en la imagen, /usr/lib/postgresql/16)
# Repositorio: https://github.com/Vicemi/planka-egg
# ===========================================================

set -euo pipefail

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   Planka v2 — Iniciando"
echo "   Yolk: ghcr.io/vicemi/planka-egg:latest"
echo "=========================================="

# ── Colores para logs ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
die()  { echo -e "${RED}  ✗ FATAL: $*${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# PASO 0: Verificar variables obligatorias
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[0/5] Verificando variables de entorno..."

: "${DB_NAME:?}"     || die "DB_NAME no definida"
: "${DB_USER:?}"     || die "DB_USER no definida"
: "${DB_PASSWORD:?}" || die "DB_PASSWORD no definida"
: "${ADMIN_EMAIL:?}" || die "ADMIN_EMAIL no definida"
: "${ADMIN_USERNAME:?}" || die "ADMIN_USERNAME no definida"
: "${ADMIN_PASSWORD:?}" || die "ADMIN_PASSWORD no definida"
: "${ADMIN_NAME:?}"  || die "ADMIN_NAME no definida"

BASE_URL="${BASE_URL:-http://localhost:${PLANKA_PORT}}"
ok "Variables OK"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Verificar binarios de Node.js y PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[1/5] Verificando binarios..."

command -v node   >/dev/null 2>&1 || die "node no encontrado en PATH"
command -v npm    >/dev/null 2>&1 || die "npm no encontrado en PATH"
command -v initdb >/dev/null 2>&1 || die "initdb no encontrado — verifica que el yolk tenga PostgreSQL 16"
command -v pg_ctl >/dev/null 2>&1 || die "pg_ctl no encontrado"
command -v psql   >/dev/null 2>&1 || die "psql no encontrado"

ok "Node.js : $(node --version)"
ok "npm     : $(npm --version)"
ok "pg_ctl  : $(pg_ctl --version)"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: NSS Wrapper (UIDs dinámicos de Pterodactyl)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[2/5] Configurando identidad de usuario..."

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

if ! getent passwd "$CURRENT_UID" >/dev/null 2>&1; then
    warn "UID $CURRENT_UID no registrado — activando libnss_wrapper"

    NSS_WRAPPER_LIB=$(find /usr/lib -name 'libnss_wrapper.so*' 2>/dev/null | head -1)
    [ -n "$NSS_WRAPPER_LIB" ] || die "libnss_wrapper.so no encontrado en la imagen"

    PASSWD_FILE="/tmp/planka_passwd_$$"
    GROUP_FILE="/tmp/planka_group_$$"
    echo "container:x:${CURRENT_UID}:${CURRENT_GID}:container:/home/container:/bin/bash" > "$PASSWD_FILE"
    echo "container:x:${CURRENT_GID}:" > "$GROUP_FILE"

    export NSS_WRAPPER_PASSWD="$PASSWD_FILE"
    export NSS_WRAPPER_GROUP="$GROUP_FILE"
    export LD_PRELOAD="${NSS_WRAPPER_LIB}${LD_PRELOAD:+:$LD_PRELOAD}"
    ok "libnss_wrapper activado: $NSS_WRAPPER_LIB"
else
    ok "UID $CURRENT_UID ya registrado en /etc/passwd"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: PostgreSQL — inicializar y arrancar
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[3/5] Configurando PostgreSQL..."

export PGDATA=/home/container/postgresql_data
export PGHOST=127.0.0.1
export PGPORT=5432

mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

# Detectar share de PostgreSQL automáticamente
PG_SHARE=""
for candidate in \
    "/usr/share/postgresql/16" \
    "/usr/share/postgresql"; do
    if [ -f "${candidate}/postgres.bki" ]; then
        PG_SHARE="$candidate"
        break
    fi
done
[ -n "$PG_SHARE" ] || die "Share de PostgreSQL no encontrado — el yolk puede estar mal construido"
ok "Share PG: $PG_SHARE"

# Inicializar cluster si no existe
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando cluster PostgreSQL..."
    initdb -D "$PGDATA" \
           --username=postgres \
           --auth=trust \
           --locale=C \
           --encoding=UTF8 \
           >/dev/null 2>&1 || die "initdb falló"
    ok "Cluster inicializado"
else
    ok "Cluster existente en $PGDATA"
fi

# Configurar pg_hba.conf
cat > "$PGDATA/pg_hba.conf" << 'PGHBA'
local   all   all                  trust
host    all   all   127.0.0.1/32   trust
host    all   all   ::1/128        trust
PGHBA

# Configurar postgresql.conf
{
    grep -v -E "^#*(listen_addresses|port|unix_socket_directories)" "$PGDATA/postgresql.conf"
    echo "listen_addresses = '127.0.0.1'"
    echo "port = 5432"
    echo "unix_socket_directories = '/tmp'"
} > "$PGDATA/postgresql.conf.new"
mv "$PGDATA/postgresql.conf.new" "$PGDATA/postgresql.conf"

# Arrancar PostgreSQL
echo "  Arrancando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start -w -t 60 >/dev/null 2>&1 || {
    echo "  Log de error:"
    tail -n 30 "$PGDATA/postgres.log" 2>/dev/null
    die "pg_ctl no pudo arrancar PostgreSQL"
}

# Esperar que esté listo
PG_READY=0
for i in $(seq 1 30); do
    if pg_isready -q -h 127.0.0.1 -p 5432 -U postgres; then
        PG_READY=1
        break
    fi
    sleep 2
done
[ "$PG_READY" -eq 1 ] || {
    tail -n 30 "$PGDATA/postgres.log" 2>/dev/null
    die "PostgreSQL no respondió a tiempo"
}
ok "PostgreSQL listo"

# Rol interno de trabajo
psql -h 127.0.0.1 -p 5432 -U postgres \
    -c "CREATE ROLE container WITH SUPERUSER LOGIN PASSWORD 'container';" \
    >/dev/null 2>&1 || true

export PGUSER=container
export PGPASSWORD=container

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3b: Crear usuario y base de datos de Planka
# ─────────────────────────────────────────────────────────────────────────────

USER_EXISTS=$(psql -h 127.0.0.1 -p 5432 -U postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | tr -d '[:space:]')

if [ "$USER_EXISTS" != "1" ]; then
    psql -h 127.0.0.1 -p 5432 -U postgres \
        -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" >/dev/null 2>&1
    ok "Usuario '${DB_USER}' creado"
fi

# Actualizar contraseña siempre (por si cambió en el panel)
psql -h 127.0.0.1 -p 5432 -U postgres \
    -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" >/dev/null 2>&1

DB_EXISTS=$(psql -h 127.0.0.1 -p 5432 -U postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]')

if [ "$DB_EXISTS" != "1" ]; then
    createdb -h 127.0.0.1 -p 5432 -U postgres -O "${DB_USER}" "${DB_NAME}" >/dev/null 2>&1
    psql -h 127.0.0.1 -p 5432 -U postgres \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" >/dev/null 2>&1
    ok "Base de datos '${DB_NAME}' creada"
else
    ok "Base de datos '${DB_NAME}' ya existe"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: SECRET_KEY persistente + generar .env
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[4/5] Aplicando configuración..."

SECRET_FILE="/home/container/.secret_key"
if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
    openssl rand -hex 64 > "$SECRET_FILE"
    ok "SECRET_KEY generada"
fi
SECRET_KEY=$(cat "$SECRET_FILE")
[ -n "$SECRET_KEY" ] || die "No se pudo leer/generar SECRET_KEY"

cat > /home/container/.env << ENVEOF
## === Planka — Generado por start.sh ===
## Se regenera en cada inicio. No editar manualmente.

BASE_URL=${BASE_URL}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}
SECRET_KEY=${SECRET_KEY}
PORT=${SERVER_PORT}
TRUST_PROXY=${TRUST_PROXY:-false}

DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}
DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME}
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
DEFAULT_ADMIN_NAME=${ADMIN_NAME}
ENVEOF

[ -n "${SMTP_URI:-}"  ] && echo "SMTP_URI=${SMTP_URI}"   >> /home/container/.env
[ -n "${SMTP_FROM:-}" ] && echo "SMTP_FROM=${SMTP_FROM}" >> /home/container/.env

ok ".env generado"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 5: Migrar BD y arrancar Planka
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Migrando base de datos e iniciando Planka..."
echo ""
echo "  Puerto : ${PLANKA_PORT}"
echo "  URL    : ${BASE_URL}"
echo "  Admin  : ${ADMIN_EMAIL}"
echo ""
echo "=========================================="

npm run db:init || die "Migración de la base de datos falló"

# Limpieza al recibir señal de parada
cleanup() {
    echo ""
    echo "Señal recibida — deteniendo PostgreSQL..."
    pg_ctl -D "$PGDATA" stop -m fast 2>/dev/null || true
    rm -f "${NSS_WRAPPER_PASSWD:-}" "${NSS_WRAPPER_GROUP:-}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

npm start &
PLANKA_PID=$!
wait $PLANKA_PID
