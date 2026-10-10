#!/usr/bin/env bash
# Creates the database on RDS (if missing) and loads the project's SQL, in order.
# psql runs from the postgres Docker image, so nothing is installed.
#
#   export PGPASSWORD='<RDS master password>'
#   deploy/load-db.sh <rds-endpoint>
#
# Run from the Application folder, on a machine that can reach the database
# (the EC2 box in the same VPC). Run it ONCE: seed data is not idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:?usage: deploy/load-db.sh <rds-endpoint>}"
: "${PGPASSWORD:?export PGPASSWORD first}"
DB_NAME="${DB_NAME:-trading_system_db}"                # <-- PROJECT
DB_USER="${DB_USER:-postgres}"
DB_INIT_DIR="${DB_INIT_DIR:-Databases/PostgreSQL}"     # <-- PROJECT
DB_INIT_FILES="${DB_INIT_FILES:-schema.sql seed_data.sql}"   # <-- PROJECT (files or folders, in order)

psql() { docker run --rm -i -e PGPASSWORD -e PGSSLMODE=require -v "$PWD/$DB_INIT_DIR:/sql:ro" \
           postgres:16-alpine psql -h "$HOST" -U "$DB_USER" -v ON_ERROR_STOP=1 "$@"; }

if [ "$(psql -d postgres -tAc "select 1 from pg_database where datname='$DB_NAME'")" != 1 ]; then
  psql -d postgres -c "CREATE DATABASE \"$DB_NAME\""
fi
for item in $DB_INIT_FILES; do
  if [ -d "$DB_INIT_DIR/$item" ]; then files=$(cd "$DB_INIT_DIR" && ls -1 "$item"/*.sql | sort); else files="$item"; fi
  for f in $files; do echo "== $f"; psql -q -d "$DB_NAME" -f "/sql/$f"; done
done
psql -d "$DB_NAME" -c "select table_schema, count(*) as tables from information_schema.tables
                       where table_schema not in ('pg_catalog','information_schema') group by 1 order by 1"
