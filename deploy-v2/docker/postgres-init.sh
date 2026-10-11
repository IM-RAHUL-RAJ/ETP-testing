#!/bin/sh
# Loads the project's SQL (`sql` in project.yaml) into an empty
# database, in order. A folder means all its *.sql files in version order
# (V2 before V10, 002 before 010).
#
#   SQL_PATHS  space-separated paths; "path@schema" runs those files with
#              search_path set to that schema (then public)
#   SQL_VARS   space-separated name=value pairs passed as psql variables
#              (:name in the SQL). A value that starts with $ is read from
#              that environment variable, so a secret stays in .env.
load_sql() {
  vars=""
  for pair in ${SQL_VARS:-}; do
    name="${pair%%=*}"; value="${pair#*=}"
    case "$value" in \$*) value="$(printenv "${value#\$}")" ;; esac
    vars="$vars -v $name=$value"
  done
  for entry in $SQL_PATHS; do
    path="${entry%%@*}"; schema=""
    [ "$path" != "$entry" ] && schema="${entry#*@}"
    if [ -d "/project/$path" ]; then
      files=$(ls -1 "/project/$path"/*.sql 2>/dev/null | sort -V)
    elif [ -f "/project/$path" ]; then
      files="/project/$path"
    else
      echo "SQL path not found in the project: $path" >&2
      return 1
    fi
    for f in $files; do
      echo "== $f${schema:+ (search_path $schema)}"
      # A Flyway-named file (V3__name.sql) expects Flyway's one transaction per file.
      tx=""; case "$(basename "$f")" in V[0-9]*__*.sql) tx="--single-transaction" ;; esac
      PGOPTIONS="${schema:+-c search_path=$schema,public}" \
        psql -v ON_ERROR_STOP=1 $tx $vars -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$f" || return 1
    done
  done
  echo "== SQL loaded"
}
load_sql
