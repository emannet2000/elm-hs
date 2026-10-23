#!/bin/sh
set -eu
printf '%s\n' 'ECC CRM production smoke checks'
test -f web/public/css/ecc-redesign.css
grep -q 'ecc-redesign.css' web/public/index.html
grep -q 'id="app"' web/public/index.html
grep -q 'main.js' web/public/index.html
printf '%s\n' 'UI rollout files present and wired.'
