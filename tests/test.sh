#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$root/setup.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "$root/setup.sh"
fi
grep -q 'nginx -t' "$root/setup.sh"
grep -q 'backup' "$root/setup.sh"
grep -q 'XHTTP' "$root/docs/architecture.md"
grep -q 'Apache License' "$root/LICENSE"
printf 'All repository checks passed.\n'
