#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL to the PostgreSQL connection string}"
backup_dir="${ECC_BACKUP_DIR:-./backups}"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
umask 077
backup_file="$backup_dir/ecc-$(date -u +%Y%m%dT%H%M%SZ)-$$.dump"
trap 'rm -f "$backup_file.partial"' EXIT
pg_dump --dbname="$DATABASE_URL" --format=custom --file="$backup_file.partial"
pg_restore --list "$backup_file.partial" > /dev/null
mv "$backup_file.partial" "$backup_file"
printf 'Backup saved: %s\n' "$backup_file"
