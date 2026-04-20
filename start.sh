#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Rutas y permisos adaptados a Pterodactyl
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# ===========================================================

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   Planka - Iniciando servidor"
echo "=========================================="

# -------------------------------------------------------
# PASO 0: Instalar PostgreSQL si no está disponible
# -------------------------------------------------------
echo "[0/5] Verificando PostgreSQL..."
if ! command -v initdb &>/dev/null || ! command -v pg_isready &>/dev/null; then
    echo "  PostgreSQL no encontrado. Instalando (puede tardar ~30s)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq postgresql postgresql-client
    echo "  PostgreSQL instalado OK."
else
    echo "  PostgreSQL disponible."
fi

# Detectar versión y agregar binarios al PATH
PG_VER=$(ls /usr/lib/postgresql/ 2>/dev/null | sort -V | tail -1)
[ -n "$PG_VER" ] && export PATH="/usr/lib/postgresql/${PG_VER}/bin:$PATH"

# -------------------------------------------------------
# PASO 1: Configurar e iniciar PostgreSQL
# -------------------------------------------------------
echo "[1/5] Configurando PostgreSQL..."

export PGDATA=/home/container/postgresql_data
export PGUSER=postgres
export PGHOST=127.0.0.1
export PGPORT=5432

# Inicializar el clúster si no existe
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando clúster PostgreSQL en $PGDATA..."
    mkdir -p "$PGDATA"
    initdb -D "$PGDATA" --username=postgres --auth=trust --locale=C > /dev/null 2>&1
    echo "  Clúster inicializado."
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

# Iniciar PostgreSQL
echo "  Iniciando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start -w -t 30 > /dev/null 2>&1 || true

# Esperar a que esté listo (máx 60s)
PG_READY=0
for i in $(seq 1 30); do
    if pg_isready -q -h 127.0.0.1 -p 5432 -U postgres; then
        PG_READY=1
        echo "  PostgreSQL listo (intento $i)."
        break
    fi
    echo "  Esperando PostgreSQL... ($i/30)"
    sleep 2
done

if [ "$PG_READY" -eq 0 ]; then
    echo "ERROR FATAL: PostgreSQL no pudo iniciar."
    echo "Últimas líneas del log:"
    tail -n 20 "$PGDATA/logfile"
    exit 1
fi

# Crear superusuario 'container' para gestionar DB sin sudo
psql -h 127.0.0.1 -p 5432 -U postgres -c "CREATE ROLE container WITH SUPERUSER LOGIN PASSWORD 'container';" > /dev/null 2>&1 || true

export PGUSER=container
export PGPASSWORD=container

# -------------------------------------------------------
# PASO 2: Crear usuario y base de datos de Planka
# -------------------------------------------------------
echo "[2/5] Configurando base de datos..."

USER_EXISTS=$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | tr -d '[:space:]')
if [ "$USER_EXISTS" != "1" ]; then
    psql -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1
    echo "  Usuario '${DB_USER}' creado."
fi

psql -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1

DB_EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]')
if [ "$DB_EXISTS" != "1" ]; then
    createdb -O "${DB_USER}" "${DB_NAME}" > /dev/null 2>&1
    psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" > /dev/null 2>&1
    echo "  Base de datos '${DB_NAME}' creada."
fi

echo "  Base de datos OK."

# -------------------------------------------------------
# PASO 3: SECRET_KEY persistente
# -------------------------------------------------------
echo "[3/5] Verificando clave secreta..."
SECRET_FILE="/home/container/.secret_key"
if [ ! -f "$SECRET_FILE" ]; then
    openssl rand -hex 64 > "$SECRET_FILE"
    echo "  SECRET_KEY generada por primera vez."
fi
SECRET_KEY=$(cat "$SECRET_FILE")

# -------------------------------------------------------
# PASO 4: Escribir .env
# -------------------------------------------------------
echo "[4/5] Aplicando configuración del panel..."

cat > /home/container/.env << ENVEOF
## === Planka - Generado automáticamente por start.sh ===
## No edites este archivo manualmente; se regenera al iniciar.

## Requerido
BASE_URL=${BASE_URL}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}
SECRET_KEY=${SECRET_KEY}

## Puerto asignado por Pterodactyl
PORT=${SERVER_PORT}

## Proxy inverso: 'true' o 'false'
TRUST_PROXY=${TRUST_PROXY}

## Administrador inicial
DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}
DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME}
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
DEFAULT_ADMIN_NAME=${ADMIN_NAME}
ENVEOF

if [ -n "${SMTP_URI}" ]; then echo "SMTP_URI=${SMTP_URI}" >> /home/container/.env; fi
if [ -n "${SMTP_FROM}" ]; then echo "SMTP_FROM=${SMTP_FROM}" >> /home/container/.env; fi

echo "  Configuración aplicada."

# -------------------------------------------------------
# PASO 5: Inicializar BD de Planka y arrancar
# -------------------------------------------------------
echo "[5/5] Inicializando base de datos de Planka y arrancando..."
echo ""
echo "  Puerto : ${SERVER_PORT}"
echo "  URL    : ${BASE_URL}"
echo "  Admin  : ${ADMIN_EMAIL}"
echo ""
echo "=========================================="

cd /home/container
npm run db:init 2>&1
exec npm start --prod
