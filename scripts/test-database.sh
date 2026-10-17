#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="${PG_BIN:-$(pg_config --bindir)}"
test_dir="$(mktemp -d /tmp/ecc-db-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
"$pg_bin/initdb" -D "$test_dir/db" -A trust > "$test_dir/init.log"
python3 - "$repo_dir" "$test_dir/input.sql" <<'PY'
from pathlib import Path
import sys
repo=Path(sys.argv[1])
parts=[p.read_text() for p in sorted((repo/'api/migrations').glob('*.sql'))]
parts.append((repo/'api/tests/operations.sql').read_text())
parts.append("SELECT 'PASS: database workflow integration tests' AS result;")
Path(sys.argv[2]).write_text('\n'.join(parts).replace('\n\n','\n')+'\n\n')
PY
"$pg_bin/postgres" --single -j -D "$test_dir/db" postgres < "$test_dir/input.sql" > "$test_dir/results.log" 2>&1
if rg 'ERROR:|FATAL:|PANIC:' "$test_dir/results.log"; then
  cat "$test_dir/results.log"
  exit 1
fi
rg 'PASS: database workflow integration tests' "$test_dir/results.log"
