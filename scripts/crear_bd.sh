#!/usr/bin/env bash
# Crea el usuario app, la base hadb y el esquema en el primario. Se corre UNA vez desde cualquier nodo.
# Si ya existen, no hace nada.
set -euo pipefail
source "$(dirname "$0")/comun.sh"
cargar_env

PRIMARIO=$(ip_primario) || fallo "no hay primario. Corre ./scripts/iniciar.sh primero"
info "Primario: $PRIMARIO"

psql_pg() {
  dk exec -i -e PGPASSWORD="$PG_SUPERUSER_PASSWORD" patroni \
    psql -h "$PRIMARIO" -U postgres -v ON_ERROR_STOP=1 -qtA "$@"
}

if [ "$(psql_pg -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = 'app'")" != "1" ]; then
  psql_pg -d postgres -c "CREATE ROLE app LOGIN PASSWORD '$APP_PASSWORD'"
  ok "usuario app creado"
else
  ok "usuario app ya existía"
fi

if [ "$(psql_pg -d postgres -c "SELECT 1 FROM pg_database WHERE datname = 'hadb'")" != "1" ]; then
  psql_pg -d postgres -c "CREATE DATABASE hadb OWNER app"
  ok "base hadb creada"
else
  ok "base hadb ya existía"
fi

if [ "$(psql_pg -d hadb -c "SELECT to_regclass('public.cuentas') IS NOT NULL")" != "t" ]; then
  dk exec -i -e PGPASSWORD="$APP_PASSWORD" patroni \
    psql -h "$PRIMARIO" -U app -d hadb -v ON_ERROR_STOP=1 -q < sql/esquema.sql
  ok "esquema creado"
else
  ok "el esquema ya existía"
fi

psql_pg -d hadb -c "SELECT 'cuentas: ' || count(*) || ', suma: ' || sum(saldo) FROM cuentas"
