#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# PostgreSQL embebido: binarios nativos copiados desde
# postgres:16-bullseye durante la instalación
# ===========================================================

set -e

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   Planka - Iniciando servidor"
echo "=========================================="

# -------------------------------------------------------
# PASO 0: Configurar PATH y librerías para PostgreSQL
# -------------------------------------------------------
echo "[0/5] Configurando entorno de PostgreSQL..."

PG_BIN_DIR="/home/container/pg_bin/bin"
PG_LIB_DIR="/home/container/pg_bin/lib"

if [ ! -d "$PG_BIN_DIR" ]; then
    echo "ERROR FATAL: No se encontro el directorio de binarios: $PG_BIN_DIR"
    echo "  Reinstala el servidor desde el panel de Pterodactyl."
    exit 1
fi

# Las libs copiadas van PRIMERO para que PG use las versiones con las que fue compilado
export LD_LIBRARY_PATH="${PG_LIB_DIR}:${LD_LIBRARY_PATH:-}"
export PATH="${PG_BIN_DIR}:$PATH"

# Verificar binarios
for bin in initdb pg_ctl pg_isready psql createdb; do
    if [ ! -f "${PG_BIN_DIR}/${bin}" ]; then
        echo "ERROR FATAL: Binario faltante: ${PG_BIN_DIR}/${bin}"
        exit 1
    fi
done

# Probar ejecución
if ! pg_ctl --version >/dev/null 2>&1; then
    echo "ERROR FATAL: No se puede ejecutar pg_ctl."
    echo "  LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
    echo "  Libs en $PG_LIB_DIR:"
    ls "$PG_LIB_DIR" 2>/dev/null || echo "  (vacio)"
    echo "  ldd:"
    ldd "${PG_BIN_DIR}/postgres" 2>&1 || true
    exit 1
fi

echo "  PostgreSQL: $(pg_ctl --version)"

# -------------------------------------------------------
# PASO 1: Configurar e iniciar PostgreSQL
# -------------------------------------------------------
echo "[1/5] Configurando PostgreSQL..."

export PGDATA=/home/container/postgresql_data
export PGUSER=postgres
export PGHOST=127.0.0.1
export PGPORT=5432

mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

# Inicializar cluster si no existe
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando cluster PostgreSQL en $PGDATA..."

    # El share/ de PG (timezones, etc.) debe estar disponible
    PG_SHARE=""
    if [ -d "/home/container/pg_bin/share/16" ]; then
        PG_SHARE="/home/container/pg_bin/share/16"
    elif [ -d "/home/container/pg_bin/share/postgresql/16" ]; then
        PG_SHARE="/home/container/pg_bin/share/postgresql/16"
    elif [ -d "/home/container/pg_bin/share" ]; then
        PG_SHARE="/home/container/pg_bin/share"
    fi

    [ -n "$PG_SHARE" ] && export PGSHAREPATH="$PG_SHARE"

    if ! initdb -D "$PGDATA" --username=postgres --auth=trust --locale=C --encoding=UTF8; then
        echo "ERROR FATAL: initdb fallo."
        exit 1
    fi
    echo "  Cluster inicializado."
else
    echo "  Cluster existente en $PGDATA."
fi

# pg_hba.conf
cat > "$PGDATA/pg_hba.conf" << 'PGHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
PGHBA

# postgresql.conf
sed -i "s|^#*listen_addresses.*|listen_addresses = '127.0.0.1'|" "$PGDATA/postgresql.conf"
sed -i "s|^#*port = .*|port = 5432|" "$PGDATA/postgresql.conf"

if grep -q "^unix_socket_directories" "$PGDATA/postgresql.conf"; then
    sed -i "s|^unix_socket_directories.*|unix_socket_directories = '/tmp'|" "$PGDATA/postgresql.conf"
else
    echo "unix_socket_directories = '/tmp'" >> "$PGDATA/postgresql.conf"
fi

echo "  Iniciando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start -w -t 60

if [ $? -ne 0 ]; then
    echo "ERROR FATAL: pg_ctl no pudo iniciar PostgreSQL."
    tail -n 40 "$PGDATA/postgres.log" 2>/dev/null || echo "(log no disponible)"
    exit 1
fi

PG_READY=0
for i in $(seq 1 30); do
    if pg_isready -q -h 127.0.0.1 -p 5432 -U postgres; then
        PG_READY=1
        echo "  PostgreSQL listo (intento $i/30)."
        break
    fi
    echo "  Esperando PostgreSQL... ($i/30)"
    sleep 2
done

if [ "$PG_READY" -eq 0 ]; then
    echo "ERROR FATAL: PostgreSQL no respondio a tiempo."
    tail -n 40 "$PGDATA/postgres.log" 2>/dev/null
    exit 1
fi

psql -h 127.0.0.1 -p 5432 -U postgres \
    -c "CREATE ROLE container WITH SUPERUSER LOGIN PASSWORD 'container';" \
    >/dev/null 2>&1 || true

export PGUSER=container
export PGPASSWORD=container

# -------------------------------------------------------
# PASO 2: Crear usuario y base de datos de Planka
# -------------------------------------------------------
echo "[2/5] Configurando base de datos..."

if [ -z "${DB_NAME}" ] || [ -z "${DB_USER}" ] || [ -z "${DB_PASSWORD}" ]; then
    echo "ERROR FATAL: DB_NAME, DB_USER y DB_PASSWORD son obligatorias."
    exit 1
fi

USER_EXISTS=$(psql -h 127.0.0.1 -p 5432 -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | tr -d '[:space:]')

if [ "$USER_EXISTS" != "1" ]; then
    psql -h 127.0.0.1 -p 5432 \
        -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" >/dev/null 2>&1
    echo "  Usuario '${DB_USER}' creado."
fi

psql -h 127.0.0.1 -p 5432 \
    -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" >/dev/null 2>&1

DB_EXISTS=$(psql -h 127.0.0.1 -p 5432 -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]')

if [ "$DB_EXISTS" != "1" ]; then
    createdb -h 127.0.0.1 -p 5432 -O "${DB_USER}" "${DB_NAME}" >/dev/null 2>&1
    psql -h 127.0.0.1 -p 5432 \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" >/dev/null 2>&1
    echo "  Base de datos '${DB_NAME}' creada."
else
    echo "  Base de datos '${DB_NAME}' ya existe."
fi

echo "  BD OK."

# -------------------------------------------------------
# PASO 3: SECRET_KEY persistente
# -------------------------------------------------------
echo "[3/5] Verificando clave secreta..."
SECRET_FILE="/home/container/.secret_key"

if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
    openssl rand -hex 64 > "$SECRET_FILE"
    echo "  SECRET_KEY generada."
fi

SECRET_KEY=$(cat "$SECRET_FILE")

if [ -z "$SECRET_KEY" ]; then
    echo "ERROR FATAL: No se pudo leer/generar SECRET_KEY."
    exit 1
fi

# -------------------------------------------------------
# PASO 4: Escribir .env
# -------------------------------------------------------
echo "[4/5] Aplicando configuracion..."

if [ -z "${BASE_URL}" ]; then
    BASE_URL="http://localhost:${SERVER_PORT}"
    echo "  ADVERTENCIA: BASE_URL vacio. Usando $BASE_URL"
fi

if [ -z "${SERVER_PORT}" ]; then
    echo "ERROR FATAL: SERVER_PORT no definido."
    exit 1
fi

cat > /home/container/.env << ENVEOF
## === Planka - Generado por start.sh ===
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

[ -n "${SMTP_URI}"  ] && echo "SMTP_URI=${SMTP_URI}"   >> /home/container/.env
[ -n "${SMTP_FROM}" ] && echo "SMTP_FROM=${SMTP_FROM}" >> /home/container/.env

echo "  .env aplicado."

# -------------------------------------------------------
# PASO 5: Migrar BD y arrancar Planka
# -------------------------------------------------------
echo "[5/5] Migrando base de datos e iniciando Planka..."
echo ""
echo "  Puerto : ${SERVER_PORT}"
echo "  URL    : ${BASE_URL}"
echo "  Admin  : ${ADMIN_EMAIL}"
echo ""
echo "=========================================="

cd /home/container

if ! npm run db:init; then
    echo "ERROR FATAL: Migracion de la base de datos fallo."
    exit 1
fi

cleanup() {
    echo "Deteniendo PostgreSQL..."
    pg_ctl -D "$PGDATA" stop -m fast || true
    exit 0
}
trap cleanup SIGTERM SIGINT

npm start &
PLANKA_PID=$!
wait $PLANKA_PID
