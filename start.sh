#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Hosteado en GitHub y descargado durante la instalacion.
#
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# (incluye Node.js 22 y PostgreSQL pre-instalado)
# ===========================================================

cd /mnt/server

echo "=== Planka - Iniciando servidor ==="

# -------------------------------------------------------
# PASO 1: Iniciar PostgreSQL
# -------------------------------------------------------
echo "[1/5] Iniciando PostgreSQL..."
service postgresql start > /dev/null 2>&1

# Esperar hasta que PostgreSQL este listo (max 60s)
PG_READY=0
for i in $(seq 1 30); do
    if sudo -u postgres pg_isready -q 2>/dev/null; then
        PG_READY=1
        echo "  PostgreSQL listo en intento $i."
        break
    fi
    echo "  Esperando PostgreSQL... ($i/30)"
    sleep 2
done

if [ "$PG_READY" -eq 0 ]; then
    echo "ERROR: PostgreSQL no pudo iniciar. Revisa los logs."
    exit 1
fi

# -------------------------------------------------------
# PASO 2: Crear usuario y base de datos (idempotente)
# -------------------------------------------------------
echo "[2/5] Configurando base de datos..."

# Crear usuario si no existe
USER_EXISTS=$(sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | tr -d '[:space:]')
if [ "$USER_EXISTS" != "1" ]; then
    sudo -u postgres psql -c \
        "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1
    echo "  Usuario '${DB_USER}' creado."
fi

# Actualizar contrasena siempre (por si se cambio en el panel)
sudo -u postgres psql -c \
    "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" > /dev/null 2>&1

# Crear base de datos si no existe
DB_EXISTS=$(sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]')
if [ "$DB_EXISTS" != "1" ]; then
    sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}" > /dev/null 2>&1
    sudo -u postgres psql -c \
        "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" > /dev/null 2>&1
    echo "  Base de datos '${DB_NAME}' creada."
fi

echo "  Base de datos OK."

# -------------------------------------------------------
# PASO 3: SECRET_KEY persistente
# -------------------------------------------------------
echo "[3/5] Verificando clave secreta..."
SECRET_FILE="/mnt/server/.secret_key"
if [ ! -f "$SECRET_FILE" ]; then
    openssl rand -hex 64 > "$SECRET_FILE"
    echo "  SECRET_KEY generada por primera vez."
fi
SECRET_KEY=$(cat "$SECRET_FILE")

# -------------------------------------------------------
# PASO 4: Escribir .env con la configuracion actual
# -------------------------------------------------------
echo "[4/5] Aplicando configuracion del panel..."

cat > /mnt/server/.env << ENVEOF
## === Planka - Generado automaticamente por start.sh ===
## No edites este archivo manualmente; se regenera al iniciar.

## Requerido
BASE_URL=${BASE_URL}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}
SECRET_KEY=${SECRET_KEY}

## Puerto asignado por Pterodactyl (no cambiar manualmente)
PORT=${SERVER_PORT}

## Proxy inverso: 'true' o 'false'
TRUST_PROXY=${TRUST_PROXY}

## Administrador inicial
## Solo crea la cuenta si no existe aun en la base de datos.
DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}
DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME}
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
DEFAULT_ADMIN_NAME=${ADMIN_NAME}
ENVEOF

# SMTP solo si se configuro
if [ -n "${SMTP_URI}" ]; then
    echo "SMTP_URI=${SMTP_URI}" >> /mnt/server/.env
fi
if [ -n "${SMTP_FROM}" ]; then
    echo "SMTP_FROM=${SMTP_FROM}" >> /mnt/server/.env
fi

echo "  Configuracion aplicada."

# -------------------------------------------------------
# PASO 5: Inicializar/migrar DB y arrancar Planka
# -------------------------------------------------------
echo "[5/5] Inicializando base de datos y arrancando Planka..."
echo ""
echo "  Puerto : ${SERVER_PORT}"
echo "  URL    : ${BASE_URL}"
echo "  Admin  : ${ADMIN_EMAIL}"
echo ""
echo "========================================="

cd /mnt/server

# Inicializar / migrar la base de datos (seguro de correr multiples veces)
npm run db:init 2>&1

# Arrancar Planka (reemplaza el proceso actual con exec)
exec npm start --prod
