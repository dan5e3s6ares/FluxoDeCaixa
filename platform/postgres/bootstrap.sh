#!/usr/bin/env sh
# Idempotent PostgreSQL bootstrap per docs 05/07.
set -eu

PGHOST="${PGHOST:-fluxo-pg-rw.database.svc.cluster.local}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-fluxo}"
PGSUPERUSER="${PGSUPERUSER:-postgres}"

export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSUPERUSER PGSUPERPASSWORD
export PGSSLMODE="${PGSSLMODE:-prefer}"

log() {
  echo "[postgres-bootstrap] $*"
}

wait_for_postgres() {
  local attempt=1
  local max="${PG_WAIT_ATTEMPTS:-60}"
  local delay="${PG_WAIT_DELAY:-2}"
  while [ "${attempt}" -le "${max}" ]; do
    if pg_isready -h "${PGHOST}" -p "${PGPORT}" -d "${PGDATABASE}" >/dev/null 2>&1; then
      log "PostgreSQL ready at ${PGHOST}:${PGPORT}/${PGDATABASE}"
      return 0
    fi
    log "waiting for PostgreSQL (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
  log "PostgreSQL not reachable at ${PGHOST}:${PGPORT}"
  return 1
}

ensure_ory_databases() {
  if [ -z "${PGSUPERPASSWORD:-}" ]; then
    log "PGSUPERPASSWORD not set; skipping kratos/hydra database ensure"
    return 0
  fi

  for db in kratos hydra; do
    if PGPASSWORD="${PGSUPERPASSWORD}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGSUPERUSER}" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q '^1$'; then
      log "database ${db} already exists"
      continue
    fi
    log "creating database ${db} (owner ${PGUSER})"
    PGPASSWORD="${PGSUPERPASSWORD}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGSUPERUSER}" -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE \"${db}\" OWNER \"${PGUSER}\";"
  done
}

main() {
  wait_for_postgres
  ensure_ory_databases
  log "applying bootstrap SQL"
  psql -v ON_ERROR_STOP=1 -f /scripts/bootstrap.sql
  log "verifying schemas"
  psql -v ON_ERROR_STOP=1 -c \
    "SELECT schema_name FROM information_schema.schemata
     WHERE schema_name IN ('lancamentos', 'consolidado')
     ORDER BY schema_name;"
  log "bootstrap complete"
}

main "$@"
