#!/bin/sh
# Loads your SQL into an empty database, file by file, stopping at the first error.
# The postgres container runs it on its first start; you run it by hand against RDS:
#   PGHOST=<rds-endpoint> PGUSER=postgres PGDATABASE=<db> PGPASSWORD=<pw> \
#     SQL_DIR=Databases/PostgreSQL SQL_FILES="schema.sql seed-data.sql" sh deploy/docker/load-sql.sh
#
# CHANGE ME in deploy/.env: SQL_FILES, if your files are not schema.sql and seed-data.sql.
# An entry can also be a folder (for example migrations): all its .sql files, in version order.
set -eu
dir="${SQL_DIR:-/sql}"
db="${PGDATABASE:-${POSTGRES_DB:-postgres}}"
user="${PGUSER:-${POSTGRES_USER:-postgres}}"
cd "$dir"   # so \i and \ir inside the files find their neighbours
for entry in ${SQL_FILES:-schema.sql seed-data.sql}; do
  if [ -d "$entry" ]; then files=$(ls "$entry"/*.sql | sort -V); else files=$entry; fi
  for f in $files; do
    echo "== $f"
    psql -v ON_ERROR_STOP=1 -q -U "$user" -d "$db" -f "$f"
  done
done
echo "== SQL loaded"
