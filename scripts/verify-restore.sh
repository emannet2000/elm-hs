#!/usr/bin/env bash
set -euo pipefail
: "${ECC_RESTORE_DATABASE_URL:?Set ECC_RESTORE_DATABASE_URL to a dedicated empty verification database}"
backup_file="${1:?Usage: verify-restore.sh backup.dump}"
# Never clean or overwrite an existing database.
table_count="$(psql "$ECC_RESTORE_DATABASE_URL" -XAt -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'")"
if [[ "$table_count" != 0 ]]; then
  printf 'Restore verification requires an empty database.\n' >&2
  exit 1
fi
pg_restore --dbname="$ECC_RESTORE_DATABASE_URL" --no-owner --no-acl --exit-on-error --single-transaction "$backup_file"
psql "$ECC_RESTORE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -c 'SELECT (SELECT count(*) FROM clients) AS clients, (SELECT count(*) FROM documents) AS documents, (SELECT count(*) FROM cases) AS cases;'
printf 'Restore completed successfully in the verification database.\n'
