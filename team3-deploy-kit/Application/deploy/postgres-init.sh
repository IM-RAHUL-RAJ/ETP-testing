#!/bin/sh
# Loads the project's SQL into the empty Postgres container, once (first start
# of an empty volume). Used by docker-compose.yaml.
#
#   DB_INIT_DIR    folder mounted at /sql            (./Databases/PostgreSQL)
#   DB_INIT_FILES  files or sub-folders under it, in order; a folder means
#                  all its *.sql files in name order  ("schema.sql seed_data.sql")
set -eu
for item in ${DB_INIT_FILES}; do
  path="/sql/${item}"
  if [ -d "$path" ]; then
    files=$(ls -1 "$path"/*.sql | sort)
  elif [ -f "$path" ]; then
    files="$path"
  else
    echo "DB_INIT_FILES: $item not found under DB_INIT_DIR" >&2
    exit 1
  fi
  for f in $files; do
    echo "== loading $f"
    psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$f"
  done
done
echo "== SQL loaded"
