#!/bin/bash
# ===========================================================
# Planka v2 - Script de inicio para Pterodactyl
# Imagen de runtime: ghcr.io/zastinian/esdock:nodejs_22
# PostgreSQL embebido: binarios nativos copiados desde
# postgres:16-bullseye durante la instalación
# ===========================================================

# NOTA: NO usar "set -e" — necesitamos controlar manualmente
# los códigos de retorno de pg_ctl, psql, etc.

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
PG_SHARE_BASE="/home/container/pg_bin/share"

if [ ! -d "$PG_BIN_DIR" ]; then
    echo "ERROR FATAL: No se encontro el directorio de binarios: $PG_BIN_DIR"
    echo "  Reinstala el servidor desde el panel de Pterodactyl."
    exit 1
fi

export LD_LIBRARY_PATH="${PG_LIB_DIR}:${LD_LIBRARY_PATH:-}"
export PATH="${PG_BIN_DIR}:$PATH"
export HOME=/home/container
export USER=${USER:-container}

for bin in initdb pg_ctl pg_isready psql createdb; do
    if [ ! -f "${PG_BIN_DIR}/${bin}" ]; then
        echo "ERROR FATAL: Binario faltante: ${PG_BIN_DIR}/${bin}"
        exit 1
    fi
done

if ! pg_ctl --version >/dev/null 2>&1; then
    echo "ERROR FATAL: No se puede ejecutar pg_ctl."
    echo "  LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
    echo "  Libs en $PG_LIB_DIR:"
    ls "$PG_LIB_DIR" 2>/dev/null || echo "  (vacio)"
    ldd "${PG_BIN_DIR}/postgres" 2>&1 || true
    exit 1
fi

echo "  PostgreSQL: $(pg_ctl --version)"

# -------------------------------------------------------
# PASO 0.5: NSS Wrapper para UIDs dinámicos de Pterodactyl
# -------------------------------------------------------
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

if ! getent passwd "$CURRENT_UID" > /dev/null 2>&1; then
    echo "  UID $CURRENT_UID no en /etc/passwd — activando libnss_wrapper..."

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

    if [ -n "$NSS_WRAPPER_LIB" ]; then
        PASSWD_FILE="/tmp/planka_passwd_$$"
        GROUP_FILE="/tmp/planka_group_$$"

        echo "container:x:${CURRENT_UID}:${CURRENT_GID}:container:/home/container:/bin/bash" > "$PASSWD_FILE"
        echo "container:x:${CURRENT_GID}:" > "$GROUP_FILE"

        export NSS_WRAPPER_PASSWD="$PASSWD_FILE"
        export NSS_WRAPPER_GROUP="$GROUP_FILE"
        export LD_PRELOAD="${NSS_WRAPPER_LIB}${LD_PRELOAD:+:$LD_PRELOAD}"

        echo "  libnss_wrapper activo: $NSS_WRAPPER_LIB"
    else
        echo "  ADVERTENCIA: libnss_wrapper no encontrado."
        echo "  Reinstala el servidor para que el instalador lo copie."
        exit 1
    fi
else
    echo "  UID $CURRENT_UID ya registrado en /etc/passwd."
fi

# -------------------------------------------------------
# PASO 1: Configurar e iniciar PostgreSQL
# -------------------------------------------------------
echo "[1/5] Configurando PostgreSQL..."

export PGDATA=/home/container/postgresql_data
export PGHOST=127.0.0.1
export PGPORT=5432

mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "  Inicializando cluster PostgreSQL en $PGDATA..."

    # Buscar el share que contenga postgres.bki Y postgresql.conf.sample
    PG_SHARE=""
    for candidate in \
        "${PG_SHARE_BASE}/16" \
        "${PG_SHARE_BASE}/postgresql/16" \
        "${PG_SHARE_BASE}"; do
        if [ -f "${candidate}/postgres.bki" ] && [ -f "${candidate}/postgresql.conf.sample" ]; then
            PG_SHARE="$candidate"
            break
        fi
    done

    if [ -z "$PG_SHARE" ]; then
        echo "ERROR FATAL: share de PostgreSQL incompleto o no encontrado."
        echo "  Buscando postgres.bki:"
        find "${PG_SHARE_BASE}" -name 'postgres.bki' 2>/dev/null || echo "  (no encontrado)"
        echo "  Buscando postgresql.conf.sample:"
        find "${PG_SHARE_BASE}" -name 'postgresql.conf.sample' 2>/dev/null || echo "  (no encontrado)"
        echo "  Estructura de pg_bin/share:"
        find "${PG_SHARE_BASE}" -maxdepth 3 2>/dev/null | head -30
        echo "  => Reinstala el servidor desde el panel de Pterodactyl."
        exit 1
    fi

    echo "  Usando share: $PG_SHARE"
    echo "  Archivos en share: $(ls "$PG_SHARE" | wc -l)"

    # -----------------------------------------------------------
    # VERIFICACION CRITICA: timezonesets debe existir y tener
    # archivos. Si esta vacio o ausente, initdb falla buscando
    # la ruta del sistema (/usr/share/postgresql/16/timezonesets)
    # -----------------------------------------------------------
    echo "  Verificando subdirectorios criticos del share..."
    for subdir in timezonesets timezone tsearch_data; do
        SUBDIR_PATH="${PG_SHARE}/${subdir}"
        COUNT=0
        [ -d "$SUBDIR_PATH" ] && COUNT=$(ls "$SUBDIR_PATH" 2>/dev/null | wc -l)

        if [ "$COUNT" -eq 0 ]; then
            echo "  ERROR: ${subdir} faltante o vacio en ${PG_SHARE}"
            echo "  Estructura actual del share:"
            find "$PG_SHARE" -maxdepth 2 2>/dev/null | head -30
            echo ""
            echo "  Este error se produce cuando el instalador no copio"
            echo "  correctamente los subdirectorios de PostgreSQL."
            echo "  => Reinstala el servidor desde el panel de Pterodactyl."
            exit 1
        fi
        echo "  ${subdir}: ${COUNT} archivos OK"
    done

    # Añadir timezone_abbreviations a la plantilla de configuración
    # para que el bootstrap lo use correctamente desde nuestro share
    echo "timezone_abbreviations = 'Default'" >> "$PG_SHARE/postgresql.conf.sample"

    if ! initdb -D "$PGDATA" -L "$PG_SHARE" \
            --username=postgres --auth=trust \
            --locale=C --encoding=UTF8; then
        echo "ERROR FATAL: initdb fallo."
        echo ""
        echo "  Contenido de $PG_SHARE:"
        ls -la "$PG_SHARE" 2>/dev/null
        echo ""
        echo "  Contenido de $PG_SHARE/timezonesets:"
        ls "$PG_SHARE/timezonesets" 2>/dev/null | head -10 || echo "  (vacio o no existe)"
        exit 1
    fi
    echo "  Cluster inicializado correctamente."
else
    echo "  Cluster existente en $PGDATA."
fi

# Configurar pg_hba.conf
cat > "$PGDATA/pg_hba.conf" << 'PGHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
PGHBA

sed -i "s|^#*listen_addresses.*|listen_addresses = '127.0.0.1'|" "$PGDATA/postgresql.conf"
sed -i "s|^#*port = .*|port = 5432|"                              "$PGDATA/postgresql.conf"

if grep -q "^unix_socket_directories" "$PGDATA/postgresql.conf"; then
    sed -i "s|^unix_socket_directories.*|unix_socket_directories = '/tmp'|" "$PGDATA/postgresql.conf"
else
    echo "unix_socket_directories = '/tmp'" >> "$PGDATA/postgresql.conf"
fi

echo "  Iniciando PostgreSQL..."
pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start -w -t 60
PG_START_RC=$?

if [ $PG_START_RC -ne 0 ]; then
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

if [ -z "${SERVER_PORT}" ]; then
    echo "ERROR FATAL: SERVER_PORT no definido."
    exit 1
fi

if [ -z "${BASE_URL}" ]; then
    BASE_URL="http://localhost:${SERVER_PORT}"
    echo "  ADVERTENCIA: BASE_URL vacio. Usando $BASE_URL"
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
    pg_ctl -D "$PGDATA" stop -m fast 2>/dev/null || true
    rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

npm start &
PLANKA_PID=$!
wait $PLANKA_PID
