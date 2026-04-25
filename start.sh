#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# PostgreSQL embebido: binarios copiados durante instalación
# Repositorio: https://github.com/Vicemi/planka-egg
# ===========================================================

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   Planka v2 - Iniciando servidor"
echo "=========================================="

# -------------------------------------------------------
# PASO 0: Configurar PATH y entorno de PostgreSQL
# -------------------------------------------------------
echo "[0/5] Configurando entorno..."

PG_BIN_DIR="/home/container/pg_bin/bin"
PG_LIB_DIR="/home/container/pg_bin/lib"
PG_SHARE_BASE="/home/container/pg_bin/share"

if [ ! -d "$PG_BIN_DIR" ]; then
    echo "ERROR FATAL: No se encontró pg_bin/bin — reinstala el servidor."
    exit 1
fi

export LD_LIBRARY_PATH="${PG_LIB_DIR}:${LD_LIBRARY_PATH:-}"
export PATH="${PG_BIN_DIR}:$PATH"
export HOME=/home/container
export USER=${USER:-container}

# Verificar binarios esenciales
for bin in initdb pg_ctl pg_isready psql createdb; do
    if [ ! -f "${PG_BIN_DIR}/${bin}" ]; then
        echo "ERROR FATAL: Binario faltante: ${PG_BIN_DIR}/${bin} — reinstala el servidor."
        exit 1
    fi
done

# Verificar que pg_ctl funcione (libs OK)
if ! pg_ctl --version >/dev/null 2>&1; then
    echo "ERROR FATAL: pg_ctl no se puede ejecutar. Diagnóstico:"
    echo "  LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
    echo "  Libs disponibles en $PG_LIB_DIR:"
    ls "$PG_LIB_DIR" 2>/dev/null | head -20 || echo "  (vacío)"
    echo "  Dependencias faltantes de postgres:"
    ldd "${PG_BIN_DIR}/postgres" 2>&1 | grep "not found" || echo "  (ninguna detectada)"
    echo "  => Reinstala el servidor desde el panel de Pterodactyl."
    exit 1
fi

echo "  PostgreSQL: $(pg_ctl --version)"

# -------------------------------------------------------
# PASO 0.5: NSS Wrapper para UIDs dinámicos de Pterodactyl
# -------------------------------------------------------
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

if ! getent passwd "$CURRENT_UID" > /dev/null 2>&1; then
    echo "  UID $CURRENT_UID no encontrado en /etc/passwd — activando libnss_wrapper..."

    NSS_WRAPPER_LIB=""
    for candidate in \
        "${PG_LIB_DIR}/libnss_wrapper.so" \
        "${PG_LIB_DIR}/libnss_wrapper.so.0" \
        "/usr/lib/x86_64-linux-gnu/libnss_wrapper.so" \
        "/usr/lib/libnss_wrapper.so"; do
        if [ -f "$candidate" ]; then
            NSS_WRAPPER_LIB="$candidate"
            break
        fi
    done

    if [ -z "$NSS_WRAPPER_LIB" ]; then
        echo "ERROR FATAL: libnss_wrapper.so no encontrado — reinstala el servidor."
        exit 1
    fi

    PASSWD_FILE="/tmp/planka_passwd_$$"
    GROUP_FILE="/tmp/planka_group_$$"
    echo "container:x:${CURRENT_UID}:${CURRENT_GID}:container:/home/container:/bin/bash" > "$PASSWD_FILE"
    echo "container:x:${CURRENT_GID}:" > "$GROUP_FILE"

    export NSS_WRAPPER_PASSWD="$PASSWD_FILE"
    export NSS_WRAPPER_GROUP="$GROUP_FILE"
    export LD_PRELOAD="${NSS_WRAPPER_LIB}${LD_PRELOAD:+:$LD_PRELOAD}"
    echo "  libnss_wrapper activo: $NSS_WRAPPER_LIB"
else
    echo "  UID $CURRENT_UID ya registrado en /etc/passwd."
fi

# -------------------------------------------------------
# PASO 1: Localizar share de PostgreSQL
# -------------------------------------------------------
echo "[1/5] Localizando share de PostgreSQL..."

PG_SHARE=""
for candidate in \
    "${PG_SHARE_BASE}/16" \
    "${PG_SHARE_BASE}/postgresql/16" \
    "${PG_SHARE_BASE}"; do
    if [ -f "${candidate}/postgres.bki" ] && \
       [ -f "${candidate}/postgresql.conf.sample" ] && \
       [ -d "${candidate}/timezonesets" ] && \
       [ -d "${candidate}/timezone" ]; then
        PG_SHARE="$candidate"
        break
    fi
done

if [ -z "$PG_SHARE" ]; then
    echo "ERROR FATAL: Share de PostgreSQL incompleto o no encontrado en $PG_SHARE_BASE"
    echo "  Estructura actual:"
    find "$PG_SHARE_BASE" -maxdepth 3 2>/dev/null | head -30
    echo "  => Reinstala el servidor desde el panel de Pterodactyl."
    exit 1
fi

echo "  Share OK: $PG_SHARE"

# Verificar subdirectorios críticos
for subdir in timezonesets timezone tsearch_data; do
    COUNT=$(ls "${PG_SHARE}/${subdir}" 2>/dev/null | wc -l)
    if [ "$COUNT" -eq 0 ]; then
        echo "ERROR FATAL: ${subdir} faltante o vacío en ${PG_SHARE}"
        echo "  => Reinstala el servidor desde el panel de Pterodactyl."
        exit 1
    fi
    echo "  ${subdir}: ${COUNT} archivos OK"
done

# -------------------------------------------------------
# PASO 2: Iniciar PostgreSQL
# -------------------------------------------------------
echo "[2/5] Configurando PostgreSQL..."

export PGDATA=/home/container/postgresql_data
export PGHOST=127.0.0.1
export PGPORT=5432

mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando cluster PostgreSQL..."
    if ! initdb -D "$PGDATA" -L "$PG_SHARE" \
            --username=postgres --auth=trust \
            --locale=C --encoding=UTF8; then
        echo "ERROR FATAL: initdb falló."
        exit 1
    fi
    echo "  Cluster inicializado."
else
    echo "  Cluster existente en $PGDATA."
fi

# Escribir pg_hba.conf
cat > "$PGDATA/pg_hba.conf" << 'PGHBA'
local   all   all                  trust
host    all   all   127.0.0.1/32   trust
host    all   all   ::1/128        trust
PGHBA

# Configurar postgresql.conf
sed -i "s|^#*listen_addresses.*|listen_addresses = '127.0.0.1'|" "$PGDATA/postgresql.conf"
sed -i "s|^#*port = .*|port = 5432|"                              "$PGDATA/postgresql.conf"

if grep -q "^unix_socket_directories" "$PGDATA/postgresql.conf"; then
    sed -i "s|^unix_socket_directories.*|unix_socket_directories = '/tmp'|" "$PGDATA/postgresql.conf"
else
    echo "unix_socket_directories = '/tmp'" >> "$PGDATA/postgresql.conf"
fi

echo "  Iniciando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start -w -t 60
if [ $? -ne 0 ]; then
    echo "ERROR FATAL: pg_ctl no pudo iniciar PostgreSQL."
    echo "  Últimas líneas del log:"
    tail -n 40 "$PGDATA/postgres.log" 2>/dev/null || echo "  (log no disponible)"
    exit 1
fi

# Esperar a que PostgreSQL esté listo
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
    tail -n 40 "$PGDATA/postgres.log" 2>/dev/null
    exit 1
fi

# Crear rol de trabajo interno
psql -h 127.0.0.1 -p 5432 -U postgres \
    -c "CREATE ROLE container WITH SUPERUSER LOGIN PASSWORD 'container';" \
    >/dev/null 2>&1 || true

export PGUSER=container
export PGPASSWORD=container

# -------------------------------------------------------
# PASO 3: Crear usuario y base de datos de Planka
# -------------------------------------------------------
echo "[3/5] Configurando base de datos..."

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

# Siempre actualizar la contraseña (por si cambió en el panel)
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
# PASO 4: SECRET_KEY persistente + escribir .env
# -------------------------------------------------------
echo "[4/5] Aplicando configuración..."

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

if [ -z "${SERVER_PORT}" ]; then
    echo "ERROR FATAL: SERVER_PORT no definido."
    exit 1
fi

if [ -z "${BASE_URL}" ]; then
    BASE_URL="http://localhost:${SERVER_PORT}"
    echo "  ADVERTENCIA: BASE_URL vacío. Usando $BASE_URL"
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

if ! npm run db:init; then
    echo "ERROR FATAL: Migración de la base de datos falló."
    exit 1
fi

cleanup() {
    echo "Señal recibida — deteniendo PostgreSQL..."
    pg_ctl -D "$PGDATA" stop -m fast 2>/dev/null || true
    rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

npm start &
PLANKA_PID=$!
wait $PLANKA_PID
