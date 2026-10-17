#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$repo_dir/api" && cabal build --offline --build-summary=dist-newstyle/build-summary.log)
(cd "$repo_dir/web" && elm make src/Main.elm --optimize --output=dist/main.js)
cp "$repo_dir/web/public/"*.html "$repo_dir/web/public/"*.js "$repo_dir/web/dist/"
cp "$repo_dir/web/public/css/"*.css "$repo_dir/web/dist/css/"
cp "$repo_dir/web/public/icons/"*.png "$repo_dir/web/dist/icons/"
