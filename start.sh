#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# PostgreSQL embebido via binarios estáticos (instalados por el egg)
# ===========================================================

set -e

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   Planka - Iniciando servidor"
echo "=========================================="

# -------------------------------------------------------
# PASO 0: Configurar PATH para PostgreSQL embebido
# -------------------------------------------------------
echo "[0/5] Configurando entorno de PostgreSQL..."

PG_BIN_DIR="/home/container/pg_bin/bin"
PG_LIB_DIR="/home/container/pg_bin/lib"

if [ ! -d "$PG_BIN_DIR" ]; then
    echo "ERROR FATAL: Directorio de binarios PostgreSQL no encontrado: $PG_BIN_DIR"
    echo "  Vuelve a ejecutar la instalacion del egg para regenerar los binarios."
    exit 1
fi

export PATH="${PG_BIN_DIR}:$PATH"
export LD_LIBRARY_PATH="${PG_LIB_DIR}:${LD_LIBRARY_PATH:-}"

# Verificar que los binarios clave existan
for bin in initdb pg_ctl pg_isready psql createdb; do
    if ! command -v "$bin" &>/dev/null; then
        echo "ERROR FATAL: Binario '$bin' no encontrado en $PG_BIN_DIR"
        exit 1
    fi
done

# Probar ejecución real de pg_ctl (detecta faltantes de bibliotecas)
if ! pg_ctl --version &>/dev/null; then
    echo "ERROR FATAL: No se puede ejecutar pg_ctl. Faltan bibliotecas compartidas."
    echo "  Asegúrate de que $PG_LIB_DIR contenga las .so necesarias."
    echo "  Contenido de $PG_LIB_DIR:"
    ls -la "$PG_LIB_DIR" || echo "  (directorio vacío o inexistente)"
    exit 1
fi

echo "  PostgreSQL listo: $(pg_ctl --version)"

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

# Inicializar clúster si no existe
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando clúster PostgreSQL en $PGDATA..."
    if ! initdb -D "$PGDATA" --username=postgres --auth=trust --locale=C --encoding=UTF8; then
        echo "ERROR FATAL: initdb falló."
        exit 1
    fi
    echo "  Clúster inicializado correctamente."
else
    echo "  Clúster existente detectado en $PGDATA."
fi

# Configurar pg_hba.conf
cat > "$PGDATA/pg_hba.conf" << 'PGHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
PGHBA

# Configurar postgresql.conf
sed -i "s|^#*listen_addresses.*|listen_addresses = '127.0.0.1'|" "$PGDATA/postgresql.conf"
sed -i "s|^#*port = .*|port = 5432|" "$PGDATA/postgresql.conf"

if ! grep -q "^unix_socket_directories" "$PGDATA/postgresql.conf"; then
    echo "unix_socket_directories = '/tmp'" >> "$PGDATA/postgresql.conf"
fi

# Iniciar PostgreSQL
echo "  Iniciando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start -w -t 60

if [ $? -ne 0 ]; then
    echo "ERROR FATAL: pg_ctl no pudo iniciar PostgreSQL."
    echo "--- Últimas líneas del log ---"
    tail -n 30 "$PGDATA/postgres.log" 2>/dev/null || echo "(log no disponible)"
    exit 1
fi

# Esperar a que esté listo
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
    echo "ERROR FATAL: PostgreSQL no respondió a tiempo."
    echo "--- Log ---"
    tail -n 30 "$PGDATA/postgres.log" 2>/dev/null
    exit 1
fi

# Crear rol container
psql -h 127.0.0.1 -p 5432 -U postgres \
    -c "CREATE ROLE container WITH SUPERUSER LOGIN PASSWORD 'container';" \
    > /dev/null 2>&1 || true

export PGUSER=container
export PGPASSWORD=container

# -------------------------------------------------------
# PASO 2: Crear usuario y base de datos de Planka
# -------------------------------------------------------
echo "[2/5] Configurando base de datos..."

if [ -z "${DB_NAME}" ] || [ -z "${DB_USER}" ] || [ -z "${DB_PASSWORD}" ]; then
    echo "ERROR FATAL: Las variables DB_NAME, DB_USER y DB_PASSWORD son obligatorias."
    exit 1
fi

USER_EXISTS=$(psql -h 127.0.0.1 -p 5432 -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | tr -d '[:space:]')

if [ "$USER_EXISTS" != "1" ]; then
    psql -h 127.0.0.1 -p 5432 \
        -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1
    echo "  Usuario '${DB_USER}' creado."
fi

psql -h 127.0.0.1 -p 5432 \
    -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1

DB_EXISTS=$(psql -h 127.0.0.1 -p 5432 -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]')

if [ "$DB_EXISTS" != "1" ]; then
    createdb -h 127.0.0.1 -p 5432 -O "${DB_USER}" "${DB_NAME}" > /dev/null 2>&1
    psql -h 127.0.0.1 -p 5432 \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" > /dev/null 2>&1
    echo "  Base de datos '${DB_NAME}' creada."
else
    echo "  Base de datos '${DB_NAME}' ya existe."
fi

echo "  Base de datos OK."

# -------------------------------------------------------
# PASO 3: SECRET_KEY persistente
# -------------------------------------------------------
echo "[3/5] Verificando clave secreta..."
SECRET_FILE="/home/container/.secret_key"

if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
    openssl rand -hex 64 > "$SECRET_FILE"
    echo "  SECRET_KEY generada por primera vez."
fi

SECRET_KEY=$(cat "$SECRET_FILE")

if [ -z "$SECRET_KEY" ]; then
    echo "ERROR FATAL: No se pudo leer/generar SECRET_KEY."
    exit 1
fi

# -------------------------------------------------------
# PASO 4: Escribir .env
# -------------------------------------------------------
echo "[4/5] Aplicando configuración del panel..."

if [ -z "${BASE_URL}" ]; then
    echo "  ADVERTENCIA: BASE_URL está vacío. Usando http://localhost:${SERVER_PORT}"
    BASE_URL="http://localhost:${SERVER_PORT}"
fi

if [ -z "${SERVER_PORT}" ]; then
    echo "ERROR FATAL: SERVER_PORT no está definido por Pterodactyl."
    exit 1
fi

cat > /home/container/.env << ENVEOF
## === Planka - Generado automáticamente por start.sh ===
## No edites este archivo; se regenera en cada inicio.

## Requerido
BASE_URL=${BASE_URL}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}
SECRET_KEY=${SECRET_KEY}

## Puerto asignado por Pterodactyl
PORT=${SERVER_PORT}

## Proxy inverso: 'true' si usas nginx/Cloudflare, 'false' si accedes por IP:puerto
TRUST_PROXY=${TRUST_PROXY:-false}

## Administrador inicial (solo aplica la primera vez que se crea la cuenta)
DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}
DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME}
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
DEFAULT_ADMIN_NAME=${ADMIN_NAME}
ENVEOF

if [ -n "${SMTP_URI}" ]; then
    echo "SMTP_URI=${SMTP_URI}" >> /home/container/.env
fi
if [ -n "${SMTP_FROM}" ]; then
    echo "SMTP_FROM=${SMTP_FROM}" >> /home/container/.env
fi

echo "  .env aplicado correctamente."

# -------------------------------------------------------
# PASO 5: Inicializar BD de Planka y arrancar
# -------------------------------------------------------
echo "[5/5] Migrando base de datos e iniciando Planka..."
echo ""
echo "  Puerto : ${SERVER_PORT}"
echo "  URL    : ${BASE_URL}"
echo "  Admin  : ${ADMIN_EMAIL}"
echo ""
echo "=========================================="

cd /home/container

# Migrar base de datos
if ! npm run db:init; then
    echo "ERROR FATAL: La migración de la base de datos falló."
    exit 1
fi

# Función para detener PostgreSQL al salir
cleanup() {
    echo ""
    echo "Deteniendo PostgreSQL..."
    pg_ctl -D "$PGDATA" stop -m fast || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Arrancar Planka
npm start &
PLANKA_PID=$!
wait $PLANKA_PID
